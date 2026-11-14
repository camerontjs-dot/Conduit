#define _DARWIN_C_SOURCE 1
#include "NativeOfflineWorkerSupport.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Native process/descriptor mechanics only. This executable never starts a VM. */
extern char **environ;
static const uint8_t ticket[] = "synthetic-native-ticket\n";
static int failures = 0;
static volatile sig_atomic_t child_notifications = 0;
static void child_notice(int number) { (void)number; ++child_notifications; }

static void check(const char *name, int passed) {
    printf("%s %s\n", passed ? "PASS" : "FAIL", name);
    if (!passed) ++failures;
}
static double now_seconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return -1;
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}
static int write_all(int fd, const void *bytes, size_t count) {
    const uint8_t *data = bytes;
    size_t offset = 0;
    while (offset < count) {
        ssize_t written = write(fd, data + offset, count - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return 0;
        offset += (size_t)written;
    }
    return 1;
}

/* The same executable is the harmless payload for cnw_spawn's exact argv shape. */
static int payload(int argc, char **argv) {
    if (argc != 4 || strcmp(argv[1], "/synthetic-native-kernel") ||
        strcmp(argv[2], "/synthetic-native-initrd") || strcmp(argv[3], "--fixture-fd=3")) return 90;
    struct stat facts;
    if (fstat(3, &facts) || !S_ISFIFO(facts.st_mode)) return 91;
    uint8_t received[128]; size_t used = 0;
    for (;;) {
        ssize_t count = read(3, received + used, sizeof(received) - used);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 || used == sizeof(received)) return 92;
        if (count == 0) break;
        used += (size_t)count;
    }
    if (used != sizeof(ticket) - 1 || memcmp(received, ticket, used)) return 93;
    /* Check before closing FD3: the complete inherited inventory is stdio + 3. */
    int limit = getdtablesize();
    if (limit < 4 || limit > (1 << 20)) return 94;
    for (int fd = 0; fd < limit; ++fd) {
        errno = 0; int flags = fcntl(fd, F_GETFD);
        if ((fd <= 3 && flags < 0) || (fd > 3 && (flags >= 0 || errno != EBADF))) return 95;
    }
    for (int index = 0; index < 3; ++index) {
        int signals[] = {SIGTERM, SIGCHLD, SIGPIPE};
        struct sigaction action;
        if (sigaction(signals[index], NULL, &action) || action.sa_handler != SIG_DFL) return 96;
    }
    sigset_t mask;
    if (sigprocmask(SIG_SETMASK, NULL, &mask)) return 97;
    for (int number = 1; number < NSIG; ++number) if (sigismember(&mask, number) == 1) return 98;
    if (getpgrp() != getpgid(getppid())) return 99;
    size_t variables = 0; int path = 0, lang = 0;
    for (char **entry = environ; *entry; ++entry) {
        ++variables;
        if (!strcmp(*entry, "PATH=/usr/bin:/bin")) ++path;
        if (!strcmp(*entry, "LANG=C")) ++lang;
    }
    if (variables != 2 || path != 1 || lang != 1) return 100;
    char out[128];
    int length = snprintf(out, sizeof(out), "NATIVE_MECHANICS_OK pgid=%d\n", (int)getpgrp());
    const char err[] = "NATIVE_MECHANICS_STDERR\n";
    if (length <= 0 || (size_t)length >= sizeof(out) || !write_all(1, out, (size_t)length) ||
        !write_all(2, err, sizeof(err) - 1)) return 101;
    return 23; /* An observed nonzero normal exit, not a synthesized success. */
}

typedef struct {
    char out[256], err[256];
    size_t out_count, err_count;
    int out_eof, err_eof, failed, manual_reaped, manual_status;
} Observation;
static void drain(int fd, char *bytes, size_t *used, int *eof, int *failed) {
    if (*eof || *failed) return;
    for (int attempt = 0; attempt < 8; ++attempt) {
        char chunk[128];
        ssize_t count = read(fd, chunk, sizeof(chunk));
        if (count == 0) { *eof = 1; return; }
        if (count < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            *failed = 1; return;
        }
        if (*used + (size_t)count > 255) { *failed = 1; return; }
        memcpy(bytes + *used, chunk, (size_t)count); *used += (size_t)count;
        bytes[*used] = 0;
    }
}

/* Manual mode deliberately takes sole wait custody away from the support object. */
static Observation observe(CNWChild *child, int manual) {
    Observation value; memset(&value, 0, sizeof(value));
    double started = now_seconds(), term_at = -1; int killed = 0;
    if (started < 0) value.failed = 1;
    for (int iteration = 0; ; ++iteration) {
        drain(child->stdout_fd, value.out, &value.out_count, &value.out_eof, &value.failed);
        drain(child->stderr_fd, value.err, &value.err_count, &value.err_eof, &value.failed);
        int reaped = 0;
        if (manual) {
            if (!value.manual_reaped) {
                pid_t result = waitpid(child->pid, &value.manual_status, WNOHANG);
                if (result == child->pid) value.manual_reaped = 1;
                else if (result < 0 && errno != EINTR) value.failed = 1;
            }
            reaped = value.manual_reaped;
        } else {
            int result = cnw_wait(child);
            if (result < 0) value.failed = 1;
            reaped = result == 1;
        }
        if (reaped && value.out_eof && value.err_eof) break;
        double now = now_seconds();
        if (now < 0 || iteration >= 600) {
            value.failed = 1;
            if (!reaped) (void)cnw_signal_child(child, SIGKILL);
            break;
        }
        if ((value.failed || now - started >= 2) && term_at < 0) {
            value.failed = 1; term_at = now;
            if (!reaped) (void)cnw_signal_child(child, SIGTERM);
        }
        if (term_at >= 0) {
            if (now - term_at >= 0.25 && !killed) {
                killed = 1;
                if (!reaped) (void)cnw_signal_child(child, SIGKILL);
            }
            if (now - term_at >= 0.75) break;
        }
        struct pollfd items[2] = {
            {.fd = value.out_eof ? -1 : child->stdout_fd, .events = POLLIN | POLLHUP | POLLERR},
            {.fd = value.err_eof ? -1 : child->stderr_fd, .events = POLLIN | POLLHUP | POLLERR}
        };
        if (poll(items, 2, 5) < 0 && errno != EINTR) value.failed = 1;
    }
    close(child->stdout_fd); close(child->stderr_fd);
    child->stdout_fd = child->stderr_fd = -1;
    return value;
}
static int expected_streams(const Observation *observed) {
    char expected[128];
    int count = snprintf(expected, sizeof(expected), "NATIVE_MECHANICS_OK pgid=%d\n", (int)getpgrp());
    const char error[] = "NATIVE_MECHANICS_STDERR\n";
    return !observed->failed && observed->out_eof && observed->err_eof && count > 0 &&
        observed->out_count == (size_t)count && !memcmp(observed->out, expected, (size_t)count) &&
        observed->err_count == sizeof(error) - 1 && !memcmp(observed->err, error, sizeof(error) - 1);
}
static int launch(CNWChild *child, const char *self) {
    return cnw_spawn(child, self, "/synthetic-native-kernel", "/synthetic-native-initrd", ticket, sizeof(ticket) - 1);
}

static int bounded_wait(pid_t child, int *status) {
    double started = now_seconds();
    for (;;) {
        pid_t result = waitpid(child, status, WNOHANG);
        if (result == child) return 1;
        if (result < 0 && errno != EINTR) return 0;
        double now = now_seconds();
        if (now < 0 || started < 0 || now - started >= 2) break;
        (void)poll(NULL, 0, 5);
    }
    /* This helper alone owns the unreaped fork child. Bound failure cleanup too. */
    (void)kill(child, SIGKILL);
    double deadline = now_seconds() + 0.5;
    for (int attempt = 0; attempt < 100; ++attempt) {
        pid_t result = waitpid(child, status, WNOHANG);
        if (result == child || (result < 0 && errno != EINTR)) break;
        (void)poll(NULL, 0, 5);
        if (now_seconds() < 0 || now_seconds() >= deadline) break;
    }
    return 0;
}
static void isolated_term_cases(const char *self) {
    pid_t child = fork();
    if (child == 0) {
        if (cnw_install_term_handler() || raise(SIGTERM) || !cnw_term_observed()) _exit(110);
        CNWChild native;
        int error = launch(&native, self);
        errno = 0; int status;
        int no_child = waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD;
        _exit(error == ECANCELED && native.pid == 0 && no_child ? 0 : 111);
    }
    int status = 0;
    check("preobserved_term_refuses_before_child_creation",
          child > 0 && bounded_wait(child, &status) && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    child = fork();
    if (child == 0) {
        if (cnw_install_term_handler() || raise(SIGTERM) || !cnw_term_observed()) _exit(112);
        (void)cnw_reraise_term();
        _exit(113);
    }
    status = 0;
    check("term_reraise_is_actual_signal_termination",
          child > 0 && bounded_wait(child, &status) && WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM);
}

int main(int argc, char **argv) {
    if (argc == 4) return payload(argc, argv);
    if (argc != 1) return 2;
    char located[PATH_MAX], self[PATH_MAX]; uint32_t size = sizeof(located);
    if (_NSGetExecutablePath(located, &size) || !realpath(located, self)) return 2;
    char temporary[] = "/tmp/conduit-native-support-XXXXXX";
    int owned = mkstemp(temporary);
    if (owned < 0) return 2;
    /* If FD3 was already occupied, preserve it; otherwise mkstemp owns FD3. */
    struct stat before, after;
    int before_flags = fcntl(3, F_GETFD), have_fd3 = before_flags >= 0 && fstat(3, &before) == 0;
    off_t before_offset = lseek(3, 0, SEEK_CUR);
    const char marker[] = "owned parent descriptor marker";
    int preparation = pwrite(owned, marker, sizeof(marker) - 1, 0) == (ssize_t)(sizeof(marker) - 1);
    int sentinel = open("/dev/null", O_RDONLY);
    if (sentinel < 0 || fcntl(sentinel, F_SETFD, 0) < 0) preparation = 0;
    struct sigaction notice, ignored, previous_chld, previous_pipe;
    memset(&notice, 0, sizeof(notice)); sigemptyset(&notice.sa_mask); notice.sa_handler = child_notice;
    memset(&ignored, 0, sizeof(ignored)); sigemptyset(&ignored.sa_mask); ignored.sa_handler = SIG_IGN;
    sigset_t blocked, previous_mask;
    sigemptyset(&blocked); sigaddset(&blocked, SIGUSR1); sigaddset(&blocked, SIGUSR2);
    if (sigaction(SIGCHLD, &notice, &previous_chld) || sigaction(SIGPIPE, &ignored, &previous_pipe) ||
        sigprocmask(SIG_BLOCK, &blocked, &previous_mask) || cnw_install_term_handler()) preparation = 0;
    check("owned_parent_fixture_prepared_with_occupied_fd3_and_inheritable_sentinel", preparation && have_fd3 && sentinel > 3);
    if (preparation && have_fd3 && sentinel > 3) {
        CNWChild native;
        int error = launch(&native, self);
        check("exact_spawn_succeeds_with_occupied_parent_fd3", error == 0 && native.pid > 0 && native.setup_error == 0);
        if (!error && native.pid > 0) {
            Observation observed = observe(&native, 0);
            if (!expected_streams(&observed)) {
                printf("native_payload_failure exit=%d signal=%d reaped=%d wait_lost=%d out_bytes=%zu err_bytes=%zu\n",
                       native.exit_code, native.termination_signal, native.reaped, native.wait_lost,
                       observed.out_count, observed.err_count);
            }
            check("child_ticket_descriptor_inventory_signals_mask_environment_and_group", expected_streams(&observed));
            check("exact_stdout_stderr_eof_and_nonzero_child_reap", expected_streams(&observed) && native.reaped &&
                  !native.wait_lost && native.exit_code == 23 && native.termination_signal == 0);
            check("postreap_signal_refused", cnw_signal_child(&native, SIGTERM) == ECHILD);
        }
        int after_flags = fcntl(3, F_GETFD);
        check("occupied_parent_fd3_identity_flags_and_offset_unchanged", have_fd3 && after_flags == before_flags &&
              fstat(3, &after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
              before.st_mode == after.st_mode && (before_offset < 0 || lseek(3, 0, SEEK_CUR) == before_offset));
        char reread[sizeof(marker)]; memset(reread, 0, sizeof(reread));
        check("owned_parent_file_bytes_unchanged", pread(owned, reread, sizeof(marker) - 1, 0) == (ssize_t)(sizeof(marker) - 1) &&
              !memcmp(reread, marker, sizeof(marker) - 1));
        error = cnw_spawn(&native, "/synthetic-absent-native-worker-mechanics", "/synthetic-native-kernel",
                          "/synthetic-native-initrd", ticket, sizeof(ticket) - 1);
        check("missing_executable_refused_without_child", error == ENOENT && native.pid <= 0 &&
              native.stdout_fd == -1 && native.stderr_fd == -1);
        error = launch(&native, self);
        if (!error && native.pid > 0) {
            Observation observed = observe(&native, 1);
            int lost = cnw_wait(&native);
            check("actual_wait_ownership_loss_refuses_further_signalling", expected_streams(&observed) && observed.manual_reaped &&
                  WIFEXITED(observed.manual_status) && WEXITSTATUS(observed.manual_status) == 23 && lost == -ECHILD &&
                  native.wait_lost && cnw_signal_child(&native, SIGTERM) == ECHILD);
        } else check("actual_wait_ownership_loss_refuses_further_signalling", 0);
        isolated_term_cases(self);
    }
    if (sentinel >= 0) close(sentinel);
    close(owned); unlink(temporary);
    /* Restore only successfully established policies on the normal prepared path. */
    if (preparation) {
        sigaction(SIGCHLD, &previous_chld, NULL); sigaction(SIGPIPE, &previous_pipe, NULL);
        sigprocmask(SIG_SETMASK, &previous_mask, NULL);
    }
    printf("native_worker_support_mechanics failures=%d; no_VM_or_isolation_qualification\n", failures);
    return failures ? 1 : 0;
}
