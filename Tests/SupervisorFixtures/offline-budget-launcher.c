/* Fixture-only resource setup before the deprecated development OS boundary.
 * This is never packaged or selected by the app. It adds no production grant.
 * Per-process CPU/descriptor and per-file size limits are not aggregate quotas.
 */
#include <sys/resource.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

static int limit(int resource, rlim_t value) {
    struct rlimit bound = { value, value };
    return setrlimit(resource, &bound);
}

int main(int argc, char **argv) {
    if (argc < 4 || strcmp(argv[1], "--") || strcmp(argv[2], "/usr/bin/sandbox-exec")) return 64;
    if (limit(RLIMIT_CORE, 0) || limit(RLIMIT_CPU, 2) ||
        limit(RLIMIT_FSIZE, 1024 * 1024) || limit(RLIMIT_NOFILE, 64)) {
        perror("development resource limits"); return 70;
    }
    char *environment[] = { "PATH=/usr/bin:/bin", "LANG=C", NULL };
    execve(argv[2], &argv[2], environment);
    perror("development boundary exec");
    return 71;
}
