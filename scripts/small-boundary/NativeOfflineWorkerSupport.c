#define _DARWIN_C_SOURCE 1
#include "NativeOfflineWorkerSupport.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t term_seen = 0;
static void on_term(int ignored) { (void)ignored; term_seen = 1; }

int cnw_install_term_handler(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = on_term;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0) return errno;
    sigset_t term;
    sigemptyset(&term); sigaddset(&term, SIGTERM);
    return sigprocmask(SIG_UNBLOCK, &term, NULL) == 0 ? 0 : errno;
}
int cnw_term_observed(void) { return term_seen != 0; }

static double now_seconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}
static int pipe_owned(int pair[2]) {
    if (pipe(pair) != 0) return errno;
    if (fcntl(pair[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(pair[1], F_SETFD, FD_CLOEXEC) < 0) {
        int error = errno;
        close(pair[0]); close(pair[1]); pair[0] = pair[1] = -1;
        return error;
    }
    return 0;
}
static int nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return errno;
    return 0;
}
static int pending_term(void) {
    sigset_t pending;
    if (sigpending(&pending) != 0) return -1;
    return sigismember(&pending, SIGTERM);
}
static int deliver_ticket(int fd, const uint8_t *ticket, size_t length) {
    size_t offset = 0;
    double started = now_seconds();
    if (started < 0) return EIO;
    while (offset < length) {
        ssize_t count = write(fd, ticket + offset, length - offset);
        if (count > 0) { offset += (size_t)count; continue; }
        if (count < 0 && errno == EINTR) continue;
        if (count == 0) return EIO;
        if (errno != EAGAIN && errno != EWOULDBLOCK) return errno;
        double now = now_seconds();
        if (now < 0 || now - started >= 0.25) return ETIMEDOUT;
        struct pollfd item = { .fd = fd, .events = POLLOUT, .revents = 0 };
        if (poll(&item, 1, 5) < 0 && errno != EINTR) return errno;
    }
    return 0;
}

int cnw_spawn(CNWChild *child, const char *executable, const char *kernel,
              const char *initrd, const uint8_t *ticket, size_t ticket_length) {
    if (!child || !executable || !kernel || !initrd || executable[0] != '/' ||
        kernel[0] != '/' || initrd[0] != '/' || !ticket || !ticket_length || ticket_length > 16384) return EINVAL;
    memset(child, 0, sizeof(*child));
    child->stdout_fd = child->stderr_fd = -1; child->exit_code = -1;
    int capability[2] = {-1, -1}, out[2] = {-1, -1}, err[2] = {-1, -1};
    int sources[3] = {-1, -1, -1}, error = 0, actions_ready = 0, attributes_ready = 0, blocked = 0;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    sigset_t term, previous;
    if ((error = pipe_owned(capability)) || (error = pipe_owned(out)) || (error = pipe_owned(err))) goto done;
    if ((error = nonblocking(out[0])) || (error = nonblocking(err[0])) || (error = nonblocking(capability[1]))) goto done;
    if (fcntl(capability[1], F_SETNOSIGPIPE, 1) != 0) { error = errno; goto done; }
    int originals[3] = {out[1], err[1], capability[0]};
    for (int i = 0; i < 3; ++i) {
        sources[i] = fcntl(originals[i], F_DUPFD_CLOEXEC, 10);
        if (sources[i] < 0) { error = errno; goto done; }
    }
    if ((error = posix_spawn_file_actions_init(&actions))) goto done;
    actions_ready = 1;
    if ((error = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0))) goto done;
    for (int i = 0; i < 3; ++i) {
        if ((error = posix_spawn_file_actions_adddup2(&actions, sources[i], i + 1))) goto done;
    }
    if ((error = posix_spawnattr_init(&attributes))) goto done;
    attributes_ready = 1;
    sigset_t empty, defaults;
    sigemptyset(&empty); sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP);
    short flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
    if ((error = posix_spawnattr_setsigmask(&attributes, &empty)) ||
        (error = posix_spawnattr_setsigdefault(&attributes, &defaults)) ||
        (error = posix_spawnattr_setflags(&attributes, flags))) goto done;
    sigemptyset(&term); sigaddset(&term, SIGTERM);
    if (sigprocmask(SIG_BLOCK, &term, &previous) != 0) { error = errno; goto done; }
    blocked = 1;
    int pending = pending_term();
    if (pending < 0) { error = errno; goto done; }
    if (term_seen || pending) { term_seen = 1; error = ECANCELED; goto done; }
    char *argv[] = {(char *)executable, (char *)kernel, (char *)initrd, "--fixture-fd=3", NULL};
    char *environment[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
    error = posix_spawn(&child->pid, executable, &actions, &attributes, argv, environment);
    if (error) goto done;
    child->stdout_fd = out[0]; out[0] = -1;
    child->stderr_fd = err[0]; err[0] = -1;
    pending = pending_term();
    if (pending < 0) child->setup_error = errno;
    else if (term_seen || pending) {
        term_seen = 1;
        if (kill(child->pid, SIGTERM) == 0) child->term_forwarded = 1;
        else if (errno != ESRCH) child->setup_error = errno;
    }
    if (sigprocmask(SIG_SETMASK, &previous, NULL) != 0 && !child->setup_error) child->setup_error = errno;
    blocked = 0;
    close(capability[0]); capability[0] = -1;
    child->setup_error = child->setup_error ? child->setup_error : deliver_ticket(capability[1], ticket, ticket_length);
    /* A successful spawn always transfers exact-child custody, even if delivery
       failed. The caller must drain/reap and cannot report a valid result. */
done:
    if (blocked && sigprocmask(SIG_SETMASK, &previous, NULL) != 0 && !error) error = errno;
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    if (attributes_ready) posix_spawnattr_destroy(&attributes);
    for (int i = 0; i < 3; ++i) if (sources[i] >= 0) close(sources[i]);
    for (int i = 0; i < 2; ++i) {
        if (capability[i] >= 0) close(capability[i]);
        if (out[i] >= 0) close(out[i]);
        if (err[i] >= 0) close(err[i]);
    }
    return error;
}

int cnw_wait(CNWChild *child) {
    if (!child || child->pid <= 0 || child->wait_lost) return -ECHILD;
    if (child->reaped) return 1;
    int status = 0;
    pid_t result = waitpid(child->pid, &status, WNOHANG);
    if (result == 0 || (result < 0 && errno == EINTR)) return 0;
    if (result < 0) { child->wait_lost = 1; return -errno; }
    child->reaped = 1; child->wait_status = status;
    if (WIFEXITED(status)) child->exit_code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) child->termination_signal = WTERMSIG(status);
    else { child->wait_lost = 1; return -ECHILD; }
    return 1;
}
int cnw_signal_child(CNWChild *child, int signal_number) {
    if (!child || child->pid <= 0 || child->reaped || child->wait_lost) return ECHILD;
    if (signal_number != SIGTERM && signal_number != SIGKILL) return EINVAL;
    return kill(child->pid, signal_number) == 0 ? 0 : errno;
}
int cnw_reraise_term(void) {
    if (!term_seen) return EINVAL;
    struct sigaction action;
    memset(&action, 0, sizeof(action)); action.sa_handler = SIG_DFL; sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0) return errno;
    sigset_t term;
    sigemptyset(&term); sigaddset(&term, SIGTERM);
    if (sigprocmask(SIG_UNBLOCK, &term, NULL) != 0) return errno;
    if (kill(getpid(), SIGTERM) != 0) return errno;
    _exit(125); /* Defensive fallback; never claim a normal successful return. */
}
