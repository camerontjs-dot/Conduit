#!/usr/bin/env python3
"""Read-only, source-only custody check. Python 3.9+ on POSIX; no build or launch.

The external lock and exclusively created receipt must be outside the checkout.
SOURCE_MATCH binds Git identity and tracked bytes/modes during this observation;
it is not native qualification, an atomic snapshot, or trusted-Git attestation.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
from datetime import datetime, timezone


SCHEMA = "conduit-frozen-candidate-lock/v1"


class Blocked(Exception):
    pass


def now():
    return datetime.now(timezone.utc).isoformat()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def path_record(raw):
    return {"path_b64": base64.b64encode(raw).decode("ascii"),
            "path_display": os.fsdecode(raw)}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Blocked("DUPLICATE_LOCK_MEMBER")
        result[key] = value
    return result


def load_candidate(lock, candidate, receipt):
    raw = lock.read_bytes()
    receipt["lock_sha256"] = sha256(raw)
    value = json.loads(raw, object_pairs_hook=unique_object)
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise Blocked("INVALID_LOCK_SCHEMA")
    if value.get("repository") != "camerontjs-dot/Conduit":
        raise Blocked("INVALID_REPOSITORY_LABEL")
    candidates = value.get("candidates")
    if not isinstance(candidates, list) or any(not isinstance(x, dict) for x in candidates):
        raise Blocked("INVALID_CANDIDATE_LIST")
    ids = [x.get("id") for x in candidates]
    if any(not isinstance(x, str) for x in ids) or len(set(ids)) != len(ids):
        raise Blocked("INVALID_OR_DUPLICATE_CANDIDATE_ID")
    matches = [x for x in candidates if x.get("id") == candidate]
    if len(matches) != 1:
        raise Blocked("CANDIDATE_NOT_UNIQUELY_LOCKED")
    selected = matches[0]
    if any(not isinstance(selected.get(k), str) or not re.fullmatch(r"[0-9a-f]{40}", selected[k])
           for k in ("head", "tree")):
        raise Blocked("INVALID_LOCKED_GIT_IDENTITY")
    return {k: selected[k] for k in ("head", "tree")}


def parse_status(raw):
    if raw and not raw.endswith(b"\0"):
        raise Blocked("NON_NUL_TERMINATED_STATUS")
    pieces = raw.split(b"\0")[:-1] if raw else []
    result, index = [], 0
    while index < len(pieces):
        entry = pieces[index]
        index += 1
        if len(entry) < 4 or entry[2:3] != b" " or any(c not in b" MADRCU?!T" for c in entry[:2]):
            raise Blocked("MALFORMED_PORCELAIN_STATUS")
        item = {"xy": entry[:2].decode("ascii"), **path_record(entry[3:])}
        if b"R" in entry[:2] or b"C" in entry[:2]:
            if index >= len(pieces) or not pieces[index]:
                raise Blocked("MALFORMED_RENAME_STATUS")
            item["original_path"] = path_record(pieces[index])
            index += 1
        result.append(item)
    return result


def parse_tree(raw):
    if raw and not raw.endswith(b"\0"):
        raise Blocked("NON_NUL_TERMINATED_TREE")
    entries, seen = [], set()
    for record in raw.split(b"\0")[:-1] if raw else []:
        try:
            header, path = record.split(b"\t", 1)
            mode, kind, oid = header.split(b" ")
        except ValueError as error:
            raise Blocked("MALFORMED_TREE_RECORD") from error
        if not path or any(part in (b"", b".", b"..", b".git") for part in path.split(b"/")):
            raise Blocked("UNSAFE_TREE_PATH")
        if path in seen:
            raise Blocked("DUPLICATE_TREE_PATH")
        seen.add(path)
        if kind != b"blob" or mode not in (b"100644", b"100755", b"120000"):
            raise Blocked("UNSUPPORTED_TREE_ENTRY_OR_SUBMODULE")
        if not re.fullmatch(b"[0-9a-f]{40}", oid):
            raise Blocked("INVALID_TREE_BLOB_ID")
        entries.append((path, mode.decode("ascii"), oid.decode("ascii")))
    return entries


def identity(st):
    return (st.st_dev, st.st_ino, st.st_mode, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


def inspect_file(root_fd, path, expected_mode, expected_blob):
    """Use descriptor-relative no-follow traversal; never open a FIFO/device."""
    item = {**path_record(path), "expected_mode": expected_mode, "expected_blob": expected_blob}
    parent_fd = os.dup(root_fd)
    try:
        pieces = path.split(b"/")
        for part in pieces[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
            os.close(parent_fd)
            parent_fd = child
        name = pieces[-1]
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        item["posix_mode"] = oct(stat.S_IMODE(before.st_mode))
        if stat.S_ISLNK(before.st_mode):
            actual_mode = "120000"
            data = os.readlink(name, dir_fd=parent_fd)
            blob = hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data)
            content_hash, count = sha256(data), len(data)
        elif stat.S_ISREG(before.st_mode):
            actual_mode = "100755" if before.st_mode & stat.S_IXUSR else "100644"
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
            with os.fdopen(fd, "rb") as source:
                opened = os.fstat(source.fileno())
                if not stat.S_ISREG(opened.st_mode) or identity(opened) != identity(before):
                    raise Blocked("FILE_CHANGED_BEFORE_READ")
                blob = hashlib.sha1(b"blob " + str(before.st_size).encode("ascii") + b"\0")
                content, count = hashlib.sha256(), 0
                # Read no more than initial size + one byte, even if a writer appends.
                while count <= before.st_size:
                    data = source.read(min(1024 * 1024, before.st_size + 1 - count))
                    if not data:
                        break
                    count += len(data)
                    blob.update(data)
                    content.update(data)
                if count != before.st_size or identity(os.fstat(source.fileno())) != identity(before):
                    raise Blocked("FILE_CHANGED_DURING_READ")
                content_hash = content.hexdigest()
        else:
            raise Blocked("NONREGULAR_WORKING_FILE_UNSUPPORTED")
        if identity(os.stat(name, dir_fd=parent_fd, follow_symlinks=False)) != identity(before):
            raise Blocked("FILE_CHANGED_AFTER_READ")
        item.update(actual_mode=actual_mode, actual_blob=blob.hexdigest(), sha256=content_hash, bytes=count)
        item["matches"] = actual_mode == expected_mode and blob.hexdigest() == expected_blob
    except FileNotFoundError:
        item.update(matches=False, problem="TRACKED_PATH_MISSING")
    except (Blocked, OSError) as error:
        item.update(matches=False, blocked=True, problem=str(error) if isinstance(error, Blocked) else type(error).__name__)
    finally:
        os.close(parent_fd)
    return item


def inspect(args, repo, lock, receipt):
    expected = load_candidate(lock, args.candidate, receipt)
    receipt["expected"] = expected
    if not args.git.is_absolute():
        raise Blocked("GIT_EXECUTABLE_MUST_BE_ABSOLUTE")
    git = args.git.resolve(strict=True)
    if not git.is_file() or not os.access(git, os.X_OK):
        raise Blocked("GIT_EXECUTABLE_UNAVAILABLE")
    receipt["git_executable"] = {"requested": str(args.git), "resolved": str(git), "sha256": sha256(git.read_bytes())}
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    environment.update(GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", GIT_NO_REPLACE_OBJECTS="1",
                       GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    prefix = [str(git), "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
              "-c", "core.hooksPath=" + os.devnull, "-C", str(repo)]

    def run(*command):
        argv = prefix + list(command)
        entry = {"argv": argv, "started_at": now(), "completed": False, "timed_out": False}
        receipt["commands"].append(entry)
        started = time.monotonic()
        try:
            result = subprocess.run(argv, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    timeout=args.git_timeout, check=False)
            entry.update(completed=True, exit_code=result.returncode,
                         stdout_sha256=sha256(result.stdout), stderr_sha256=sha256(result.stderr),
                         stdout_bytes=len(result.stdout), stderr_bytes=len(result.stderr))
            if result.returncode != 0:
                raise Blocked("GIT_COMMAND_FAILED")
            return result.stdout
        except subprocess.TimeoutExpired as error:
            entry.update(timed_out=True, exit_code=None, stdout_sha256=sha256(error.stdout or b""),
                         stderr_sha256=sha256(error.stderr or b""),
                         captured_output_scope="partial_at_timeout")
            raise Blocked("GIT_COMMAND_TIMED_OUT") from error
        except OSError as error:
            entry.update(exit_code=None, launch_error=type(error).__name__)
            raise Blocked("GIT_COMMAND_COULD_NOT_START") from error
        finally:
            entry.update(finished_at=now(), duration_seconds=round(time.monotonic() - started, 6))

    if run("rev-parse", "--is-inside-work-tree", "--show-prefix") != b"true\n\n":
        raise Blocked("REPO_MUST_BE_WORKING_TREE_ROOT")
    for phase in ("before", "after"):
        observed = {}
        for key, expression in (("head", "HEAD^{commit}"), ("tree", "HEAD^{tree}")):
            raw = run("rev-parse", "--verify", expression)
            if not re.fullmatch(b"[0-9a-f]{40}\n", raw):
                raise Blocked("MALFORMED_GIT_IDENTITY")
            observed[key] = raw[:-1].decode("ascii")
        receipt["observed"][phase] = observed
        if observed != expected:
            receipt["problems"].append("GIT_IDENTITY_MISMATCH_" + phase.upper())
            return "SOURCE_MISMATCH"
        if phase == "before":
            entries = parse_tree(run("ls-tree", "-r", "-z", "--full-tree", expected["tree"]))
        status_rows = parse_status(run("status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"))
        receipt["observed"]["status_" + phase] = status_rows
        if status_rows:
            receipt["problems"].append("NONEMPTY_GIT_STATUS_" + phase.upper())
        if phase == "before":
            with_root = os.open(repo, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                receipt["files"] = [inspect_file(with_root, *entry) for entry in entries]
            finally:
                os.close(with_root)
            receipt["tracked_files_inspected"] = len(receipt["files"])
    receipt["inspection_complete"] = not any(x.get("blocked") for x in receipt["files"])
    if not receipt["inspection_complete"]:
        return "BLOCKED"
    if receipt["problems"] or any(not x["matches"] for x in receipt["files"]):
        return "SOURCE_MISMATCH"
    return "SOURCE_MATCH"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, help="Exact unique candidate id in the external lock")
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--git", required=True, type=Path)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--git-timeout", type=float, default=15.0, help="Positive per-Git-command seconds; default 15")
    args = parser.parse_args(argv)
    # Refuse an unsafe destination before any candidate command or receipt write.
    try:
        repo, lock = args.repo.resolve(strict=True), args.lock.resolve(strict=True)
        output = args.output.parent.resolve(strict=True) / args.output.name
        if not repo.is_dir() or lock.is_relative_to(repo) or output.is_relative_to(repo):
            raise Blocked("LOCK_AND_OUTPUT_MUST_BE_OUTSIDE_CHECKOUT")
        if args.git_timeout <= 0 or not args.git_timeout < float("inf"):
            raise Blocked("INVALID_GIT_TIMEOUT")
        fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except (Blocked, OSError) as error:
        print(json.dumps({"status": "BLOCKED", "receipt_created": False, "reason": str(error)}), file=sys.stderr)
        return 2
    receipt = {"schema": "conduit-source-custody-preflight/v1", "candidate": args.candidate,
               "repository_label": "camerontjs-dot/Conduit", "repo": str(repo), "started_at": now(),
               "status": "BLOCKED", "inspection_complete": False, "commands": [], "observed": {},
               "files": [], "problems": [], "scope": "GIT_IDENTITY_AND_TRACKED_WORKING_BYTES_ONLY",
               "limitations": [
                   "Not native/product qualification, runtime/process isolation, release or acceptance evidence.",
                   "Not an atomic filesystem snapshot; stable per-file reads plus before/after Git checks only.",
                   "Git executable/configuration are selected local inputs, not independently authenticated.",
                   "Ignored/untracked-ignored files, full POSIX permissions, ownership and extended attributes are outside the comparison.",
                   "Regular files compare raw bytes, not clean-filter/EOL transformed content; submodules and nonregular files are unsupported.",
                   "Git executable mode means owner executable bit; symlinks compare link bytes without dereferencing their targets."
               ]}
    try:
        receipt["status"] = inspect(args, repo, lock, receipt)
    except (Blocked, OSError, ValueError, TypeError) as error:
        receipt["problems"].append(str(error) if isinstance(error, Blocked) else type(error).__name__)
    finally:
        receipt["finished_at"] = now()
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(receipt, stream, indent=2, ensure_ascii=True)
            stream.write("\n")
    print(receipt["status"])
    return {"SOURCE_MATCH": 0, "SOURCE_MISMATCH": 1, "BLOCKED": 2}[receipt["status"]]


if __name__ == "__main__":
    sys.exit(main())
