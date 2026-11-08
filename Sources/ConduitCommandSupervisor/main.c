#define _DARWIN_C_SOURCE 1
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <sys/param.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <ctype.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

enum { CONTROL_FD = 3, STATUS_FD = 4, STORE_FD = 5, CWD_FD = 6 };
enum { LINE_LIMIT = 256, INPUT_LIMIT = 512, STATUS_LIMIT = 4096, FRAME_BUDGET = 8 };
enum { REAP_DEFERRED = 2 };
enum { CAUSE_NATURAL = 0, CAUSE_CANCEL = 1, CAUSE_TIMEOUT = 2,
       CAUSE_DISCONNECT = 3, CAUSE_SETUP = 4, CAUSE_OWNERSHIP = 5 };

struct ready_report {
    uint32_t magic;
    int32_t pid;
    int32_t pgid;
    int32_t sid;
    int32_t ppid;
};

struct supervisor {
    char nonce[33];
    char operation[129];
    pid_t child;
    int release_write;
    int ready_read;
    int exec_error_read;
    int child_started;
    int ready;
    int stub_reported;
    int go_seen;
    int go_committed;
    int go_reply_sent;
    int cancel_seen;
    int cancel_accepted;
    int observe_seen;
    int control_open;
    int status_open;
    int status_lost;
    int signals_open;
    int closed_queued;
    int root_observed;
    int root_reaped;
    int root_exit;
    int root_signal;
    int root_status_valid;
    int group_absent;
    int wait_lost;
    int protocol_failed;
    int error_sent;
    int cause;
    int cause_set;
    int termination_started;
    int term_sent;
    int kill_sent;
    int final_ready;
    int final_flushed;
    int input_eof;
    int setup_timed_out;
    int natural_observation;
    int exec_error_seen;
    int exec_errno;
    int timeout_ms;
    uint64_t revision;
    double setup_deadline;
    double active_deadline;
    double root_deadline;
    double term_at;
    double cleanup_deadline;
    double final_deadline;
    struct ready_report ready_message;
    size_t ready_bytes;
    char input[INPUT_LIMIT];
    size_t input_len;
    char output[STATUS_LIMIT];
    size_t output_len;
    size_t output_off;
};

static double monotonic_seconds(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) _exit(70);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static int set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

static int set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD, 0);
    return flags >= 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0;
}

static void close_from(int first) {
    int top = getdtablesize();
    if (top < first) top = 65536;
    for (int fd = first; fd < top; ++fd) close(fd);
}

static int write_all_blocking(int fd, const void *bytes, size_t count) {
    const unsigned char *p = (const unsigned char *)bytes;
    size_t off = 0;
    while (off < count) {
        ssize_t n = write(fd, p + off, count - off);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        off += (size_t)n;
    }
    return 0;
}

static int valid_nonce(const char *s) {
    if (strlen(s) != 32) return 0;
    for (size_t i = 0; i < 32; ++i)
        if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
    return 1;
}

static int valid_operation(const char *s) {
    size_t n = strlen(s);
    if (n < 1 || n > 128) return 0;
    for (size_t i = 0; i < n; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-')) return 0;
    }
    return 1;
}

static int parse_timeout(const char *s, int *out) {
    if (!s || !*s) return 0;
    unsigned long value = 0;
    for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {
        if (*p < '0' || *p > '9') return 0;
        value = value * 10 + (unsigned long)(*p - '0');
        if (value > 5000) return 0;
    }
    if (value < 1 || value > 5000) return 0;
    *out = (int)value;
    return 1;
}

static int configure_supervisor_signals(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &action, NULL) != 0) return -1;
    action.sa_handler = SIG_DFL;
    if (sigaction(SIGCHLD, &action, NULL) != 0) return -1;
    sigset_t empty;
    sigemptyset(&empty);
    if (sigprocmask(SIG_SETMASK, &empty, NULL) != 0) return -1;
    return 0;
}

static int reset_stub_signals(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_handler = SIG_DFL;
    for (int sig = 1; sig < NSIG; ++sig) {
        if (sig == SIGKILL || sig == SIGSTOP) continue;
        if (sigaction(sig, &action, NULL) != 0 && errno != EINVAL) return -1;
    }
    sigset_t empty;
    sigemptyset(&empty);
    return sigprocmask(SIG_SETMASK, &empty, NULL);
}

static int create_pipe_cloexec(int fds[2]) {
    if (pipe(fds) != 0) return -1;
    if (!set_cloexec(fds[0]) || !set_cloexec(fds[1])) {
        int saved = errno;
        close(fds[0]); close(fds[1]); errno = saved; return -1;
    }
    return 0;
}

static int write_claim(int store_fd, const char *operation, const char *nonce) {
    char name[160];
    int n = snprintf(name, sizeof(name), "%s.launch-claim", operation);
    if (n < 0 || (size_t)n >= sizeof(name)) { errno = EINVAL; return -1; }
    int fd = openat(store_fd, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    char claim[40];
    int claim_len = snprintf(claim, sizeof(claim), "%s\n", nonce);
    int result = write_all_blocking(fd, claim, (size_t)claim_len);
    if (result == 0 && fsync(fd) != 0) result = -1;
    int saved = errno;
    if (close(fd) != 0 && result == 0) { result = -1; saved = errno; }
    if (result == 0 && fsync(store_fd) != 0) { result = -1; saved = errno; }
    errno = saved;
    return result;
}

static int stub_role(int argc, char **argv) {
    if (argc < 4 || strcmp(argv[1], "--stub") != 0 || strcmp(argv[2], "--") != 0 ||
        argv[3][0] != '/' || getpgrp() != getpid() ||
        fchdir(CWD_FD) != 0 || reset_stub_signals() != 0 || !set_cloexec(9)) return 125;
    close(CWD_FD);
    struct ready_report report;
    report.magic = UINT32_C(0x43445231);
    report.pid = (int32_t)getpid();
    report.pgid = (int32_t)getpgrp();
    report.sid = (int32_t)getsid(0);
    report.ppid = (int32_t)getppid();
    if (write_all_blocking(8, &report, sizeof(report)) != 0) return 125;
    unsigned char release = 0;
    ssize_t count = -1;
    double deadline = monotonic_seconds() + 2.0;
    while (monotonic_seconds() < deadline) {
        int ms = (int)((deadline - monotonic_seconds()) * 1000.0);
        if (ms < 0) ms = 0;
        struct pollfd p = { .fd = 7, .events = POLLIN | POLLHUP | POLLERR, .revents = 0 };
        int ready = poll(&p, 1, ms);
        if (ready < 0 && errno == EINTR) break;
        if (ready <= 0) break;
        count = read(7, &release, 1);
        if (count < 0 && errno == EINTR) count = -1;
        break;
    }
    close(7); close(8);
    if (count != 1 || release != 1) return 125;
    char *environment[] = { "PATH=/usr/bin:/bin", "LANG=C", NULL };
    execve(argv[3], &argv[3], environment);
    int error = errno;
    (void)write_all_blocking(9, &error, sizeof(error));
    return 127;
}

static void compact_output(struct supervisor *s) {
    if (s->output_off == 0) return;
    if (s->output_off >= s->output_len) {
        s->output_off = s->output_len = 0;
        return;
    }
    memmove(s->output, s->output + s->output_off, s->output_len - s->output_off);
    s->output_len -= s->output_off;
    s->output_off = 0;
}

static int queue_frame(struct supervisor *s, const char *type, const char *fields) {
    compact_output(s);
    char frame[LINE_LIMIT + 1];
    uint64_t next = s->revision + 1;
    int n = snprintf(frame, sizeof(frame), "CDS1 %s %llu %s%s%s\n", s->nonce,
                     (unsigned long long)next, type, fields && *fields ? " " : "",
                     fields && *fields ? fields : "");
    if (n < 0 || n > LINE_LIMIT || (size_t)n >= sizeof(frame) ||
        s->output_len + (size_t)n > STATUS_LIMIT) {
        s->status_lost = 1;
        return -1;
    }
    memcpy(s->output + s->output_len, frame, (size_t)n);
    s->output_len += (size_t)n;
    s->revision = next;
    return 0;
}

static int queue_error(struct supervisor *s, int error) {
    char fields[40];
    snprintf(fields, sizeof(fields), "%d", error > 0 ? error : EIO);
    s->error_sent = 1;
    return queue_frame(s, "ERROR", fields);
}

static int queue_go_disposition(struct supervisor *s) {
    char fields[8];
    snprintf(fields, sizeof(fields), "%d", s->go_committed ? 1 : 0);
    return queue_frame(s, "GO", fields);
}

static int queue_cancel_disposition(struct supervisor *s) {
    char fields[8];
    snprintf(fields, sizeof(fields), "%d", s->cancel_accepted ? 1 : 0);
    return queue_frame(s, "CANCEL", fields);
}

static int queue_ready(struct supervisor *s) {
    char fields[96];
    snprintf(fields, sizeof(fields), "%ld %ld %ld", (long)s->child,
             (long)s->child, (long)getsid(s->child));
    return queue_frame(s, "READY", fields);
}

static int queue_root(struct supervisor *s) {
    if (!s->root_observed || !s->root_status_valid) return 0;
    char fields[80];
    snprintf(fields, sizeof(fields), "%d %d", s->root_exit, s->root_signal);
    return queue_frame(s, "ROOT", fields);
}

static int queue_final(struct supervisor *s) {
    char fields[128];
    snprintf(fields, sizeof(fields), "%d %d %d %d %d %d",
             s->root_observed ? 1 : 0, s->root_reaped ? 1 : 0,
             s->group_absent ? 1 : 0, s->cause_set ? s->cause : CAUSE_NATURAL,
             s->root_exit, s->root_signal);
    return queue_frame(s, "FINAL", fields);
}

static int flush_status(struct supervisor *s, size_t budget) {
    if (!s->status_open || s->status_lost || s->output_off >= s->output_len) return 0;
    size_t left = s->output_len - s->output_off;
    if (left > budget) left = budget;
    ssize_t n = write(STATUS_FD, s->output + s->output_off, left);
    if (n > 0) { s->output_off += (size_t)n; return 0; }
    if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    s->status_lost = 1;
    s->status_open = 0;
    return -1;
}

static void set_cause(struct supervisor *s, int cause) {
    if (!s->cause_set) { s->cause = cause; s->cause_set = 1; }
}

static void close_signal_authority(struct supervisor *s) {
    s->signals_open = 0;
    if (!s->closed_queued) {
        s->closed_queued = 1;
        (void)queue_frame(s, "CLOSED", "");
    }
}

static void close_control(struct supervisor *s) {
    if (s->control_open) { close(CONTROL_FD); s->control_open = 0; }
}

static void start_cleanup(struct supervisor *s, int cause, double now) {
    set_cause(s, cause);
    if (!s->termination_started) {
        s->termination_started = 1;
        double base = now + 2.0;
        s->cleanup_deadline = base;
        if (s->root_observed && s->root_deadline + 1.75 < s->cleanup_deadline)
            s->cleanup_deadline = s->root_deadline + 1.75;
    }
}

static int wait_observe(struct supervisor *s) {
    if (!s->child_started || s->wait_lost) return s->wait_lost ? -1 : 0;
    if (s->root_reaped) return 1;
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    int result = waitid(P_PID, (id_t)s->child, &info, WEXITED | WNOHANG | WNOWAIT);
    if (result < 0) {
        if (errno == EINTR) return 0;
        (void)queue_error(s, errno);
        s->wait_lost = 1;
        close_signal_authority(s);
        set_cause(s, CAUSE_OWNERSHIP);
        return -1;
    }
    if (info.si_pid != 0 && info.si_pid != s->child) {
        (void)queue_error(s, ECHILD);
        s->wait_lost = 1;
        close_signal_authority(s);
        set_cause(s, CAUSE_OWNERSHIP);
        return -1;
    }
    if (info.si_pid == s->child && !s->root_observed) {
        s->root_observed = 1;
        s->root_deadline = monotonic_seconds() + 0.25;
        s->root_status_valid = 1;
        s->root_exit = -1;
        s->root_signal = 0;
        if (info.si_code == CLD_EXITED) s->root_exit = info.si_status;
        else if (info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED) s->root_signal = info.si_status;
        else s->root_status_valid = 0;
        if (s->root_status_valid) (void)queue_root(s);
    }
    return 1;
}

static int commit_go(struct supervisor *s, double now) {
    if (s->go_committed || !s->go_seen || !s->ready) return 0;
    if (s->cancel_seen || s->termination_started || s->final_ready || !s->signals_open) {
        if (!s->go_reply_sent) {
            s->go_reply_sent = 1;
            return queue_go_disposition(s);
        }
        return 0;
    }
    s->go_committed = 1;
    s->active_deadline = now + (double)s->timeout_ms / 1000.0;
    unsigned char release = 1;
    if (s->release_write < 0 || write_all_blocking(s->release_write, &release, 1) != 0)
        start_cleanup(s, CAUSE_SETUP, now);
    if (s->release_write >= 0) { close(s->release_write); s->release_write = -1; }
    if (!s->go_reply_sent) {
        s->go_reply_sent = 1;
        return queue_go_disposition(s);
    }
    return 0;
}

static int parse_control_line(struct supervisor *s, char *line) {
    size_t n = strlen(line);
    if (n < 1 || line[n - 1] != '\n' || n > LINE_LIMIT) return -1;
    line[n - 1] = '\0';
    for (size_t i = 0; i < n - 1; ++i) {
        unsigned char c = (unsigned char)line[i];
        if (c < 0x20 || c > 0x7e) return -1;
    }
    char *tokens[6]; size_t count = 0;
    char *start = line;
    for (char *p = line;; ++p) {
        if (*p == ' ' || *p == '\0') {
            if (p == start || count == 6) return -1;
            tokens[count++] = start;
            if (*p == '\0') break;
            *p = '\0'; start = p + 1;
        }
    }
    if (count != 4 || strcmp(tokens[0], "CDS1") != 0 ||
        strcmp(tokens[1], s->nonce) != 0) return -1;
    double now = monotonic_seconds();
    if (strcmp(tokens[2], "1") == 0 && strcmp(tokens[3], "GO") == 0) {
        if (!s->go_seen) {
            s->go_seen = 1;
            if (s->ready) return commit_go(s, now);
            if (s->cancel_seen || s->termination_started || s->final_ready) {
                s->go_reply_sent = 1;
                return queue_go_disposition(s);
            }
            return 0;
        }
        if (!s->go_reply_sent && (s->cancel_seen || s->termination_started || s->final_ready)) {
            s->go_reply_sent = 1;
            return queue_go_disposition(s);
        }
        if (!s->go_reply_sent) return 0;
        return queue_go_disposition(s);
    }
    if (strcmp(tokens[2], "2") == 0 && strcmp(tokens[3], "CANCEL") == 0) {
        if (!s->cancel_seen) {
            s->cancel_seen = 1;
            if (!s->final_ready && s->signals_open) {
                s->cancel_accepted = 1;
                start_cleanup(s, CAUSE_CANCEL, now);
            }
            if (s->go_seen && !s->go_reply_sent) {
                s->go_reply_sent = 1;
                if (queue_go_disposition(s) != 0) return -1;
            }
        }
        return queue_cancel_disposition(s);
    }
    if (strcmp(tokens[2], "3") == 0 && strcmp(tokens[3], "OBSERVE") == 0) {
        s->observe_seen = 1;
        if (s->go_seen && s->go_reply_sent && queue_go_disposition(s) != 0) return -1;
        if (s->cancel_seen && queue_cancel_disposition(s) != 0) return -1;
        if (s->root_observed && queue_root(s) != 0) return -1;
        return 0;
    }
    return -1;
}

static int process_input(struct supervisor *s, size_t *frame_count) {
    while (*frame_count < FRAME_BUDGET) {
        char *newline = memchr(s->input, '\n', s->input_len);
        if (!newline) break;
        size_t line_len = (size_t)(newline - s->input) + 1;
        if (line_len > LINE_LIMIT) return -1;
        char line[LINE_LIMIT + 1];
        memcpy(line, s->input, line_len); line[line_len] = '\0';
        memmove(s->input, s->input + line_len, s->input_len - line_len);
        s->input_len -= line_len;
        if (parse_control_line(s, line) != 0) return -1;
        ++*frame_count;
    }
    if ((!memchr(s->input, '\n', s->input_len) && s->input_len >= LINE_LIMIT) ||
        s->input_len > INPUT_LIMIT) return -1;
    return 0;
}

static void read_control(struct supervisor *s, size_t *frames) {
    if (!s->control_open || s->input_eof || s->protocol_failed) return;
    if (process_input(s, frames) != 0) goto bad;
    unsigned char chunk[256];
    size_t read_budget = 512;
    while (*frames < FRAME_BUDGET && read_budget > 0) {
        size_t room = INPUT_LIMIT - s->input_len;
        if (room == 0) goto bad;
        size_t ask = sizeof(chunk);
        if (ask > room) ask = room;
        if (ask > read_budget) ask = read_budget;
        ssize_t n = read(CONTROL_FD, chunk, ask);
        if (n > 0) {
            if (memchr(chunk, '\0', (size_t)n)) goto bad;
            memcpy(s->input + s->input_len, chunk, (size_t)n);
            s->input_len += (size_t)n;
            read_budget -= (size_t)n;
            if (process_input(s, frames) != 0) goto bad;
            continue;
        }
        if (n == 0) {
            s->input_eof = 1; close_control(s);
            if (s->input_len != 0) goto bad;
            start_cleanup(s, CAUSE_DISCONNECT, monotonic_seconds());
            break;
        }
        if (errno == EINTR) break;
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        goto bad;
    }
    if (s->input_eof && s->input_len != 0) goto bad;
    return;
bad:
    s->protocol_failed = 1;
    if (!s->error_sent) (void)queue_error(s, EPROTO);
    close_control(s);
    start_cleanup(s, CAUSE_SETUP, monotonic_seconds());
}

static int read_ready_report(struct supervisor *s) {
    if (s->stub_reported) {
        int custody = wait_observe(s);
        if (custody < 0 || s->root_observed) return -1;
        if (custody == 0) return 0;
        s->ready = 1;
        return queue_ready(s);
    }
    while (s->ready_bytes < sizeof(s->ready_message)) {
        ssize_t n = read(s->ready_read, (unsigned char *)&s->ready_message + s->ready_bytes,
                         sizeof(s->ready_message) - s->ready_bytes);
        if (n > 0) { s->ready_bytes += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        if (n == 0 && s->ready_bytes == 0) return -1;
        return -1;
    }
    close(s->ready_read); s->ready_read = -1;
    pid_t sid = getsid(s->child);
    if (s->ready_message.magic != UINT32_C(0x43445231) || s->ready_message.pid != s->child ||
        s->ready_message.pgid != s->child || s->ready_message.sid != getpid() ||
        s->ready_message.sid != sid || s->ready_message.ppid != getpid() ||
        getpgid(s->child) != s->child) return -1;
    s->stub_reported = 1;
    int custody = wait_observe(s);
    if (custody < 0 || s->root_observed) return -1;
    if (custody == 0) return 0;
    s->ready = 1;
    return queue_ready(s);
}

static void read_exec_error(struct supervisor *s) {
    if (s->exec_error_read < 0 || s->exec_error_seen) return;
    int error = 0;
    ssize_t n = read(s->exec_error_read, &error, sizeof(error));
    if (n == (ssize_t)sizeof(error)) {
        s->exec_error_seen = 1; s->exec_errno = error;
        (void)queue_error(s, error);
        close(s->exec_error_read); s->exec_error_read = -1;
    } else if (n == 0) {
        s->exec_error_seen = 1;
        close(s->exec_error_read); s->exec_error_read = -1;
    } else if (n < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
        s->exec_error_seen = 1; s->exec_errno = errno;
        (void)queue_error(s, errno);
        close(s->exec_error_read); s->exec_error_read = -1;
    }
}

static int signal_owned(struct supervisor *s, int sig, int pre_ready) {
    if (!s->child_started || !s->signals_open || s->wait_lost) return 0;
    if (wait_observe(s) != 1) return 0;
    pid_t target = pre_ready || !s->ready ? s->child : -s->child;
    if (kill(target, sig) < 0 && errno != ESRCH) (void)queue_error(s, errno);
    return 1;
}

static int reap_exact_child(struct supervisor *s) {
    if (!s->child_started || s->root_reaped || s->wait_lost) return s->root_reaped;
    if (s->signals_open) return 0;
    int status = 0;
    for (;;) {
        pid_t result = waitpid(s->child, &status, WNOHANG);
        if (result == s->child) {
            s->root_reaped = 1;
            if (!s->root_observed) {
                s->root_observed = 1;
                s->root_status_valid = 1;
                if (WIFEXITED(status)) { s->root_exit = WEXITSTATUS(status); s->root_signal = 0; }
                else if (WIFSIGNALED(status)) { s->root_exit = -1; s->root_signal = WTERMSIG(status); }
                else s->root_status_valid = 0;
                if (s->root_status_valid) (void)queue_root(s);
            }
            return 1;
        }
        if (result == 0) return 0;
        if (errno == EINTR) return REAP_DEFERRED;
        s->wait_lost = 1;
        (void)queue_error(s, errno);
        set_cause(s, CAUSE_OWNERSHIP);
        return -1;
    }
}

static void probe_group(struct supervisor *s) {
    if (!s->ready || !s->root_reaped) return;
    if (kill(-s->child, 0) < 0) {
        if (errno == ESRCH) s->group_absent = 1;
        else { s->group_absent = 0; (void)queue_error(s, errno); }
    } else s->group_absent = 0;
}

static void begin_final(struct supervisor *s) {
    if (s->final_ready) return;
    close_signal_authority(s);
    if (s->release_write >= 0) { close(s->release_write); s->release_write = -1; }
    if (!s->root_reaped && !s->wait_lost && reap_exact_child(s) == REAP_DEFERRED) return;
    probe_group(s);
    if (s->go_seen && !s->go_reply_sent) {
        s->go_reply_sent = 1;
        (void)queue_go_disposition(s);
    }
    (void)queue_final(s);
    s->final_ready = 1;
    s->final_deadline = monotonic_seconds() + 0.1;
}

static void drive_state(struct supervisor *s, double now) {
    if (s->status_lost) {
        close_control(s);
        start_cleanup(s, CAUSE_DISCONNECT, now);
    }
    if (s->child_started && !s->wait_lost) (void)wait_observe(s);
    if (!s->go_committed && !s->termination_started && now >= s->setup_deadline) {
        s->setup_timed_out = 1;
        start_cleanup(s, CAUSE_SETUP, now);
        if (!s->error_sent) (void)queue_error(s, ETIMEDOUT);
    }
    /* wait_observe runs first: an observed root exit ends active execution.
       Its cancellation/cleanup window must not turn that exit into a timeout.
       A timeout already started keeps its cause and cleanup obligations. */
    if (s->go_committed && !s->root_observed && !s->termination_started && now >= s->active_deadline)
        start_cleanup(s, CAUSE_TIMEOUT, now);
    if (s->termination_started && !s->term_sent && s->signals_open) {
        if (signal_owned(s, SIGTERM, !s->ready)) {
            s->term_sent = 1;
            s->term_at = now;
        }
    }
    if (s->termination_started && s->term_sent && !s->kill_sent &&
        now - s->term_at >= 0.5 && s->signals_open) {
        if (signal_owned(s, SIGKILL, !s->ready)) {
            s->kill_sent = 1;
        }
    }
    if (!s->termination_started && s->root_observed && now >= s->root_deadline) {
        close_signal_authority(s);
        if (reap_exact_child(s) == REAP_DEFERRED) return;
        probe_group(s);
        s->natural_observation = 1;
        s->cleanup_deadline = s->root_deadline + 1.75;
        if (s->group_absent || now >= s->cleanup_deadline || s->wait_lost) begin_final(s);
        return;
    }
    if (s->natural_observation) {
        probe_group(s);
        if (s->group_absent || now >= s->cleanup_deadline || s->wait_lost) begin_final(s);
        return;
    }
    if (s->termination_started && s->root_observed && s->kill_sent) {
        close_signal_authority(s);
        if (reap_exact_child(s) == REAP_DEFERRED) return;
        probe_group(s);
        if (s->group_absent || now >= s->cleanup_deadline || s->wait_lost) begin_final(s);
        return;
    }
    if (s->termination_started && now >= s->cleanup_deadline) {
        close_signal_authority(s);
        if (reap_exact_child(s) == REAP_DEFERRED) return;
        probe_group(s);
        begin_final(s);
        return;
    }
    if (s->wait_lost) {
        close_signal_authority(s);
        if (!s->termination_started) start_cleanup(s, CAUSE_OWNERSHIP, now);
        if (now >= s->cleanup_deadline) begin_final(s);
    }
}

static int run_loop(struct supervisor *s) {
    while (!s->final_ready) {
        size_t control_frames = 0;
        if (s->control_open && memchr(s->input, '\n', s->input_len))
            read_control(s, &control_frames);
        if (s->stub_reported && !s->ready) {
            int ready = read_ready_report(s);
            if (ready < 0) {
                if (!s->error_sent) (void)queue_error(s, EPROTO);
                start_cleanup(s, CAUSE_SETUP, monotonic_seconds());
            } else if (ready > 0) {
                if (!s->error_sent) (void)queue_error(s, EIO);
                start_cleanup(s, CAUSE_SETUP, monotonic_seconds());
            }
        }
        double now = monotonic_seconds();
        struct pollfd fds[3]; nfds_t count = 0;
        if (s->control_open) { fds[count].fd = CONTROL_FD; fds[count].events = POLLIN | POLLHUP | POLLERR; fds[count].revents = 0; ++count; }
        if (s->ready_read >= 0) { fds[count].fd = s->ready_read; fds[count].events = POLLIN | POLLHUP | POLLERR; fds[count].revents = 0; ++count; }
        if (s->exec_error_read >= 0) { fds[count].fd = s->exec_error_read; fds[count].events = POLLIN | POLLHUP | POLLERR; fds[count].revents = 0; ++count; }
        int timeout = 10;
        if (!s->go_committed && s->setup_deadline > now && s->setup_deadline - now < 0.01)
            timeout = (int)((s->setup_deadline - now) * 1000.0);
        int result = poll(fds, count, timeout);
        if (result < 0 && errno != EINTR) {
            if (!s->error_sent) (void)queue_error(s, errno);
            close_control(s); start_cleanup(s, CAUSE_SETUP, monotonic_seconds());
        }
        for (nfds_t i = 0; i < count; ++i) {
            if (fds[i].revents == 0) continue;
            if (fds[i].fd == CONTROL_FD) read_control(s, &control_frames);
            else if (fds[i].fd == s->ready_read) {
                int ready = read_ready_report(s);
                if (ready < 0) {
                    if (!s->error_sent) (void)queue_error(s, EPROTO);
                    start_cleanup(s, CAUSE_SETUP, monotonic_seconds());
                } else if (ready > 0) {
                    if (!s->error_sent) (void)queue_error(s, EIO);
                    start_cleanup(s, CAUSE_SETUP, monotonic_seconds());
                }
            } else if (fds[i].fd == s->exec_error_read) read_exec_error(s);
        }
        if (s->ready && s->go_seen && !s->go_committed && !s->go_reply_sent)
            (void)commit_go(s, monotonic_seconds());
        flush_status(s, 512);
        drive_state(s, monotonic_seconds());
        flush_status(s, 512);
    }
    while (s->output_off < s->output_len && monotonic_seconds() < s->final_deadline) {
        flush_status(s, 512);
        if (s->output_off < s->output_len) {
            struct pollfd p = { .fd = STATUS_FD, .events = POLLOUT, .revents = 0 };
            (void)poll(&p, 1, 5);
        }
    }
    s->final_flushed = s->output_off >= s->output_len && !s->status_lost;
    return s->final_flushed ? 0 : 1;
}

static int high_duplicate(int fd) {
    return fcntl(fd, F_DUPFD_CLOEXEC, 10);
}

static int launch_child(struct supervisor *s, const char *helper_path, char **payload_argv) {
    int release_pipe[2] = { -1, -1 }, ready_pipe[2] = { -1, -1 }, error_pipe[2] = { -1, -1 };
    int child_fds[7] = { -1, -1, -1, -1, -1, -1, -1 };
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int actions_ready = 0, attributes_ready = 0;
    int result = -1, saved = 0;
    pid_t child = -1;
    if (create_pipe_cloexec(release_pipe) || create_pipe_cloexec(ready_pipe) || create_pipe_cloexec(error_pipe)) {
        saved = errno; goto done;
    }
    if (!set_nonblock(ready_pipe[0]) || !set_nonblock(error_pipe[0])) {
        saved = errno; goto done;
    }
    child_fds[0] = high_duplicate(CWD_FD);
    child_fds[1] = high_duplicate(release_pipe[0]);
    child_fds[2] = high_duplicate(ready_pipe[1]);
    child_fds[3] = high_duplicate(error_pipe[1]);
    child_fds[4] = high_duplicate(STDIN_FILENO);
    child_fds[5] = high_duplicate(STDOUT_FILENO);
    child_fds[6] = high_duplicate(STDERR_FILENO);
    for (size_t i = 0; i < 7; ++i) {
        if (child_fds[i] < 0) { saved = errno; goto done; }
    }
    int spawn_error = posix_spawn_file_actions_init(&actions);
    if (spawn_error != 0) { saved = spawn_error; goto done; }
    actions_ready = 1;
    if ((spawn_error = posix_spawn_file_actions_adddup2(&actions, child_fds[4], STDIN_FILENO)) != 0 ||
        (spawn_error = posix_spawn_file_actions_adddup2(&actions, child_fds[5], STDOUT_FILENO)) != 0 ||
        (spawn_error = posix_spawn_file_actions_adddup2(&actions, child_fds[6], STDERR_FILENO)) != 0 ||
        (spawn_error = posix_spawn_file_actions_adddup2(&actions, child_fds[0], CWD_FD)) != 0 ||
        (spawn_error = posix_spawn_file_actions_adddup2(&actions, child_fds[1], 7)) != 0 ||
        (spawn_error = posix_spawn_file_actions_adddup2(&actions, child_fds[2], 8)) != 0 ||
        (spawn_error = posix_spawn_file_actions_adddup2(&actions, child_fds[3], 9)) != 0) {
        saved = spawn_error; goto done;
    }
    spawn_error = posix_spawnattr_init(&attributes);
    if (spawn_error != 0) { saved = spawn_error; goto done; }
    attributes_ready = 1;
    sigset_t empty, defaults;
    sigemptyset(&empty);
    sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL);
    sigdelset(&defaults, SIGSTOP);
    short flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF |
                  POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT;
    if ((spawn_error = posix_spawnattr_setsigmask(&attributes, &empty)) != 0 ||
        (spawn_error = posix_spawnattr_setsigdefault(&attributes, &defaults)) != 0 ||
        (spawn_error = posix_spawnattr_setpgroup(&attributes, 0)) != 0 ||
        (spawn_error = posix_spawnattr_setflags(&attributes, flags)) != 0) {
        saved = spawn_error; goto done;
    }
    size_t payload_count = 0;
    while (payload_argv[payload_count]) ++payload_count;
    char **stub_argv = calloc(payload_count + 4, sizeof(char *));
    if (!stub_argv) { saved = errno; goto done; }
    stub_argv[0] = (char *)helper_path;
    stub_argv[1] = (char *)"--stub";
    stub_argv[2] = (char *)"--";
    for (size_t i = 0; i < payload_count; ++i) stub_argv[i + 3] = payload_argv[i];
    close(STORE_FD);
    spawn_error = posix_spawn(&child, helper_path, &actions, &attributes, stub_argv, environ);
    free(stub_argv);
    if (spawn_error != 0) { saved = spawn_error; goto done; }
    s->child = child; s->child_started = 1;
    s->signals_open = 1;
    close(release_pipe[0]); release_pipe[0] = -1;
    close(ready_pipe[1]); ready_pipe[1] = -1;
    close(error_pipe[1]); error_pipe[1] = -1;
    s->release_write = release_pipe[1];
    release_pipe[1] = -1;
    s->ready_read = ready_pipe[0];
    ready_pipe[0] = -1;
    s->exec_error_read = error_pipe[0];
    error_pipe[0] = -1;
    close(CWD_FD);
    close(1); close(2);
    result = 0;
done:
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    if (attributes_ready) posix_spawnattr_destroy(&attributes);
    for (size_t i = 0; i < 7; ++i) if (child_fds[i] >= 0) close(child_fds[i]);
    int *pipe_fds[] = { release_pipe, ready_pipe, error_pipe };
    for (size_t i = 0; i < 3; ++i) {
        for (size_t j = 0; j < 2; ++j) if (pipe_fds[i][j] >= 0) close(pipe_fds[i][j]);
    }
    if (result != 0) { errno = saved ? saved : EIO; return -1; }
    return 0;
}

static int parse_arguments(int argc, char **argv, char ***payload_argv, int *timeout_ms,
                           struct supervisor *s) {
    if (argc < 7 || strcmp(argv[1], "--supervise") != 0 ||
        !valid_nonce(argv[2]) || !valid_operation(argv[3]) ||
        !parse_timeout(argv[4], timeout_ms) || strcmp(argv[5], "--") != 0 ||
        argv[0][0] != '/' || argv[6][0] != '/') return -1;
    strcpy(s->nonce, argv[2]); strcpy(s->operation, argv[3]);
    *payload_argv = &argv[6];
    s->timeout_ms = *timeout_ms;
    return 0;
}

static int startup_failure(struct supervisor *s, int error) {
    set_cause(s, CAUSE_SETUP);
    (void)queue_error(s, error);
    close_signal_authority(s);
    (void)queue_final(s);
    double deadline = monotonic_seconds() + 0.1;
    while (s->output_off < s->output_len && monotonic_seconds() < deadline) {
        (void)flush_status(s, 512);
        if (s->output_off < s->output_len) {
            struct pollfd p = { .fd = STATUS_FD, .events = POLLOUT, .revents = 0 };
            (void)poll(&p, 1, 5);
        }
    }
    return 70;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "--stub") == 0) return stub_role(argc, argv);
    struct supervisor s;
    memset(&s, 0, sizeof(s));
    s.child = -1; s.release_write = s.ready_read = s.exec_error_read = -1;
    s.root_exit = -1; s.root_signal = 0; s.control_open = 1; s.status_open = 1;
    s.signals_open = 0; s.cause = CAUSE_NATURAL;
    int timeout_ms = 0; char **payload_argv = NULL;
    if (parse_arguments(argc, argv, &payload_argv, &timeout_ms, &s) != 0) return 64;
    close_from(7);
    if (!set_nonblock(CONTROL_FD) || !set_nonblock(STATUS_FD) ||
        configure_supervisor_signals() != 0) {
        int saved = errno; return startup_failure(&s, saved);
    }
    struct stat store_facts, cwd_facts;
    if (fstat(STORE_FD, &store_facts) != 0 || !S_ISDIR(store_facts.st_mode) ||
        fstat(CWD_FD, &cwd_facts) != 0 || !S_ISDIR(cwd_facts.st_mode)) {
        int saved = errno ? errno : ENOTDIR; return startup_failure(&s, saved);
    }
    if (write_claim(STORE_FD, s.operation, s.nonce) != 0) {
        int saved = errno; return startup_failure(&s, saved);
    }
    s.setup_deadline = monotonic_seconds() + 2.0;
    if (setsid() < 0) {
        int saved = errno; return startup_failure(&s, saved);
    }
    if (launch_child(&s, argv[0], payload_argv) != 0) {
        int saved = errno; return startup_failure(&s, saved);
    }
    int result = run_loop(&s);
    if (s.control_open) close_control(&s);
    if (s.status_open) close(STATUS_FD);
    if (s.ready_read >= 0) close(s.ready_read);
    if (s.exec_error_read >= 0) close(s.exec_error_read);
    if (s.release_write >= 0) close(s.release_write);
    return result;
}
