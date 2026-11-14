#ifndef CONDUIT_NATIVE_OFFLINE_WORKER_SUPPORT_H
#define CONDUIT_NATIVE_OFFLINE_WORKER_SUPPORT_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct {
    pid_t pid;
    int stdout_fd;
    int stderr_fd;
    int reaped;
    int wait_lost;
    int wait_status;
    int exit_code;             /* -1 when not observed as a normal exit. */
    int termination_signal;    /* 0 when no terminating signal observed. */
    int term_forwarded;
    int setup_error;           /* A post-spawn ticket delivery failure. */
} CNWChild;

/* Error-code returns (0 on success), except cnw_wait's documented tri-state. */
int cnw_install_term_handler(void);
int cnw_term_observed(void);
int cnw_spawn(CNWChild *child, const char *executable, const char *kernel,
              const char *initrd, const uint8_t *ticket, size_t ticket_length);
/* Sole waiter: 1 reaped, 0 still live/interrupted, negative errno on loss. */
int cnw_wait(CNWChild *child);
/* Exact, unreaped child only; never adopts recovered PIDs. */
int cnw_signal_child(CNWChild *child, int signal_number);
/* Returns an errno only on failure; success terminates this process by TERM. */
int cnw_reraise_term(void);

#endif
