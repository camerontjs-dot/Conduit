#!/usr/bin/env python3
"""Disposable macOS policy feasibility probes; never an execution grant.

Owner: #170. Deterministic development evidence, not installed qualification.
Writes only a newly created output directory and its synthetic fixtures. Runs
owned native children; no provider, UI, credentials, settings or installation.
The proposed profile is deliberately narrower than a Swift build profile.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys
import time


PROBE = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
static int file(const char *mode, const char *path) {
  int fd = open(path, !strcmp(mode,"read") ? O_RDONLY : O_WRONLY|O_CREAT|O_EXCL, 0600);
  if (fd < 0) { printf("open_errno=%d\n",errno); return 13; }
  if (!strcmp(mode,"read")) { char c; if (read(fd,&c,1)!=1) return 14; }
  else if (write(fd,"fixture",7)!=7) return 15;
  close(fd); puts("ok"); return 0;
}
int main(int argc, char **argv) {
  if (argc < 3) return 64;
  if (!strcmp(argv[1],"read") || !strcmp(argv[1],"write")) return file(argv[1],argv[2]);
  if (!strcmp(argv[1],"exec")) {
    char *args[] = {argv[2],"allowed",NULL}; execv(argv[2],args);
    printf("exec_errno=%d\n",errno); return 126;
  }
  if (!strcmp(argv[1],"detached-write")) {
    pid_t p=fork(); if (p<0) { printf("fork_errno=%d\n",errno); return 16; }
    if (!p) { if (setsid()<0) { printf("setsid_errno=%d\n",errno); return 17; }
      puts("setsid_ok"); return file("write",argv[2]); }
    int s; if (waitpid(p,&s,0)!=p) return 18;
    return WIFEXITED(s) ? WEXITSTATUS(s) : 19;
  }
  if (!strcmp(argv[1],"connect")) {
    int fd=socket(AF_INET,SOCK_STREAM,0);
    if (fd<0) { printf("socket_errno=%d\n",errno); return 20; }
    struct sockaddr_in a={0}; a.sin_family=AF_INET;
    a.sin_port=htons(atoi(argv[2])); inet_pton(AF_INET,"127.0.0.1",&a.sin_addr);
    int r=connect(fd,(struct sockaddr*)&a,sizeof(a)); int e=errno; close(fd);
    if (r<0) { printf("connect_errno=%d\n",e); return 21; }
    puts("connected"); return 0;
  }
  return 64;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-directory", type=Path, required=True,
                        help="New directory for synthetic fixtures and receipts; must not exist")
    args = parser.parse_args()
    out = args.output_directory.resolve()
    out.mkdir(parents=False, exist_ok=False)
    result = {"schema_version": "conduit-policy-probe/v1", "status": "BLOCKED",
              "evidence_layer": "development_os_policy_only", "production_grant": False,
              "host": platform.platform(), "cases": [], "started_at_epoch": time.time(),
              "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    try:
        if sys.platform != "darwin" or not Path("/usr/bin/sandbox-exec").is_file():
            raise RuntimeError("macOS sandbox-exec unavailable; no fallback executor")
        workspace, scratch, denied = [out / p for p in ("project", "scratch", "denied")]
        for directory in (workspace, scratch, denied): directory.mkdir()
        (workspace / "source.txt").write_text("fixture input\n")
        (denied / "secret.txt").write_text("synthetic outside sentinel\n")
        (workspace / "outside-link").symlink_to(denied, target_is_directory=True)
        source, binary, policy = out / "probe.c", out / "probe", out / "policy.sb"
        source.write_text(PROBE)
        compile_result = subprocess.run(["/usr/bin/clang", str(source), "-o", str(binary)],
                                        capture_output=True, timeout=60)
        (out / "compile.stdout").write_bytes(compile_result.stdout)
        (out / "compile.stderr").write_bytes(compile_result.stderr)
        if compile_result.returncode: raise RuntimeError("Native probe compilation failed")
        # This is an OS access policy, not a cwd check. No network permission is
        # granted. Only two executable paths and enumerated read roots exist.
        policy.write_text('''(version 1)
(deny default)
(allow process-fork)
(allow process-exec (literal (param "PROBE")) (literal "/bin/echo"))
(allow sysctl-read)
(allow file-read-metadata)
(allow file-read-data
  (literal "/") (subpath "/System") (subpath "/usr/lib")
  (literal (param "PROBE")) (literal "/bin/echo")
  (subpath (param "PROJECT")) (subpath (param "SCRATCH")))
(allow file-write* (subpath (param "PROJECT")) (subpath (param "SCRATCH")))
''')
        result["policy_sha256"] = hashlib.sha256(policy.read_bytes()).hexdigest()
        result["probe_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        prefix = ["/usr/bin/sandbox-exec", "-f", str(policy), "-D", f"PROBE={binary}",
                  "-D", f"PROJECT={workspace}", "-D", f"SCRATCH={scratch}"]
        environment = {"PATH": "/usr/bin:/bin", "LANG": "C", "HOME": str(scratch), "TMPDIR": str(scratch)}

        def case(name, arguments, expected_exit, expected_output, confined=True, absent=None):
            command = (prefix if confined else []) + [str(binary), *map(str, arguments)]
            run = subprocess.run(command, capture_output=True, env=environment, timeout=10)
            (out / f"{name}.stdout").write_bytes(run.stdout)
            (out / f"{name}.stderr").write_bytes(run.stderr)
            text = run.stdout.decode("utf-8", errors="replace")
            passed = run.returncode == expected_exit and text in expected_output
            if absent is not None: passed = passed and not absent.exists()
            row = {"id": name, "command": command, "exit_code": run.returncode,
                   "expected_exit": expected_exit, "stdout": text,
                   "stderr": run.stderr.decode("utf-8", errors="replace"),
                   "status": "PASS" if passed else "FAIL", "confined": confined}
            if absent is not None: row["denied_file_absent"] = not absent.exists()
            result["cases"].append(row)
            return passed

        # A positive control must work before a refusal is called enforcement.
        if not case("allowed-write", ["write", workspace / "allowed.txt"], 0, ["ok\n"]):
            raise RuntimeError("Policy positive control failed; denials NOT_RUN, not containment evidence")
        case("allowed-read", ["read", workspace / "source.txt"], 0, ["ok\n"])
        for name, target in [("outside-write", denied / "outside.txt"),
                             ("parent-traversal", workspace / ".." / "denied" / "traversal.txt"),
                             ("symlink-outside", workspace / "outside-link" / "link.txt")]:
            case(name, ["write", target], 13, ["open_errno=1\n"], absent=target)
        case("outside-read", ["read", denied / "secret.txt"], 13, ["open_errno=1\n"])
        case("allowed-subprocess", ["exec", "/bin/echo"], 0, ["allowed\n"])
        case("denied-subprocess", ["exec", "/usr/bin/true"], 126, ["exec_errno=1\n"])
        case("detached-child-write", ["detached-write", denied / "detached.txt"], 13,
             ["setsid_ok\nopen_errno=1\n"], absent=denied / "detached.txt")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0)); listener.listen(2)
            port = listener.getsockname()[1]
            if not case("network-control", ["connect", port], 0, ["connected\n"], confined=False):
                raise RuntimeError("Loopback positive control failed; network denial unestablished")
            case("network-denied", ["connect", port], 21, ["connect_errno=1\n"])
        result["status"] = "PASS_BOUNDED" if all(c["status"] == "PASS" for c in result["cases"]) else "FAIL"
    except Exception as error:
        result["error"] = str(error)
    result["ended_at_epoch"] = time.time()
    (out / "RESULT.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"status": result["status"], "cases": len(result["cases"]), "result": str(out / "RESULT.json")}))
    return 0 if result["status"] == "PASS_BOUNDED" else 1


if __name__ == "__main__":
    raise SystemExit(main())
