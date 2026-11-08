#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <linux/landlock.h>

// First boot capability observation only. Replaced by a separately retained
// suite attempt after the actual kernel/API path is established.
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    int abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    printf("M2_BOOT {\"landlock_abi\":%d,\"pid\":%d}\n", abi, getpid());
    fflush(stdout);
    reboot(RB_POWER_OFF);
    return 1;
}
