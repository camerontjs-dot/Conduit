#define _DARWIN_C_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

static int parse_milliseconds(const char *value, unsigned *milliseconds) {
    if (!value || !*value) return -1;
    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno || !end || *end || parsed > 4000) return -1;
    *milliseconds = (unsigned)parsed;
    return 0;
}

static void bounded_expiry(void) {
    alarm(4);
}

static int write_marker(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    static const char marker[] = "effect\n";
    size_t offset = 0;
    while (offset < sizeof(marker) - 1) {
        ssize_t count = write(fd, marker + offset, sizeof(marker) - 1 - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            int saved = errno ? errno : EIO;
            close(fd);
            errno = saved;
            return -1;
        }
        offset += (size_t)count;
    }
    return close(fd);
}

static int run_effect(int argc, char **argv) {
    if (argc != 4) return 64;
    unsigned milliseconds = 0;
    if (parse_milliseconds(argv[3], &milliseconds) != 0) return 64;
    bounded_expiry();
    if (write_marker(argv[2]) != 0) return 70;
    usleep((useconds_t)milliseconds * 1000U);
    return 0;
}

static int run_flood(void) {
    bounded_expiry();
    static const char block[4096] = { 'F' };
    for (;;) {
        ssize_t count = write(STDOUT_FILENO, block, sizeof(block));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return 0;
    }
}

static int run_peer(const char *group) {
    bounded_expiry();
    pid_t pid = getpid();
    if (setpgid(0, 0) != 0) return 70;
    char *end = NULL;
    long target = strtol(group, &end, 10);
    if (!end || *end || target <= 1) return 64;
    errno = 0;
    int result = setpgid(0, (pid_t)target);
    int observed_error = errno;
    char line[128];
    int length = snprintf(line, sizeof(line), "PEER %ld %ld %ld JOIN %d %d\n",
                          (long)pid, (long)getpgrp(), (long)getsid(0), result, observed_error);
    if (length <= 0 || (size_t)length >= sizeof(line)) return 70;
    size_t offset = 0;
    while (offset < (size_t)length) {
        ssize_t count = write(STDOUT_FILENO, line + offset, (size_t)length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return 70;
        offset += (size_t)count;
    }
    for (;;) pause();
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "--effect") == 0) return run_effect(argc, argv);
    if (argc == 2 && strcmp(argv[1], "--flood") == 0) return run_flood();
    if (argc == 3 && strcmp(argv[1], "--peer") == 0) return run_peer(argv[2]);
    return 64;
}
