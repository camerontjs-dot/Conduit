#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <grp.h>
#include <signal.h>
#include <time.h>
#include <poll.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/mount.h>
#include <sys/mman.h>
#include <sys/reboot.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <net/if.h>
#include <netinet/in.h>
#include <linux/landlock.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <linux/audit.h>
#include <linux/sched.h>

// Trusted PID 1 in an owned, no-NIC/no-share/no-disk Linux fixture VM.
// Payload streams go through pipes; only PID 1 writes serial protocol frames.
static const char *job = "/sys/fs/cgroup/check";
static char nonce[80];
static int abi;
static unsigned long long clock_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (unsigned long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static void stop(void) { fflush(stdout); reboot(RB_POWER_OFF); for (;;) pause(); }
static void fatal(const char *what) {
    printf("M2_FATAL {\"where\":\"%s\",\"errno\":%d}\n", what, errno); stop();
}
static void directory(const char *path, int mode) {
    if (mkdir(path, mode) && errno != EEXIST) fatal(path);
}
static void put(const char *path, const char *value) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0 || write(fd, value, strlen(value)) != (ssize_t)strlen(value)) fatal(path);
    close(fd);
}
static unsigned long long number(const char *name, const char *key) {
    char path[256], line[256], label[128]; unsigned long long value = 0;
    snprintf(path, sizeof(path), "%s/%s", job, name);
    FILE *f = fopen(path, "r"); if (!f) fatal(path);
    if (!key) { if (fscanf(f, "%llu", &value) != 1) fatal(path); }
    else while (fgets(line, sizeof(line), f)) {
        unsigned long long v;
        if (sscanf(line, "%127s %llu", label, &v) == 2 && !strcmp(label, key)) { value = v; break; }
    }
    fclose(f); return value;
}
static void copy(const char *from, const char *to, int mode) {
    int src = open(from, O_RDONLY | O_CLOEXEC), dst = open(to, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode);
    if (src < 0 || dst < 0) fatal("project_copy");
    char bytes[4096]; ssize_t n; size_t total = 0;
    while ((n = read(src, bytes, sizeof(bytes))) > 0) {
        total += n; if (total > 1024*1024 || write(dst, bytes, n) != n) fatal("project_copy_bound");
    }
    if (n < 0 || fchown(dst, 1000, 1000)) fatal("project_copy_metadata");
    close(src); close(dst);
}
static int allow_path(int rules, const char *path, uint64_t access) {
    int fd = open(path, O_PATH | O_CLOEXEC); if (fd < 0) return -1;
    struct landlock_path_beneath_attr rule = { .allowed_access = access, .parent_fd = fd };
    int result = syscall(SYS_landlock_add_rule, rules, LANDLOCK_RULE_PATH_BENEATH, &rule, 0);
    close(fd); return result;
}
static void restrict_payload(void) {
    // ABI 3 is required; never silently remove an unsupported restriction.
    uint64_t read = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;
    uint64_t all = (1ULL << 15) - 1;
    struct landlock_ruleset_attr attr = { .handled_access_fs = all };
    int rules = syscall(SYS_landlock_create_ruleset, &attr, sizeof(attr), 0);
    if (rules < 0 || prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) fatal("landlock_create");
    // The ELF interpreter is part of the declared executable closure. Data
    // mounts are noexec as well: direct invocation of this loader must not
    // turn a readable project/scratch ELF into an executable.
    const char *executables[] = { "/bin/bash", "/usr/bin/grep", "/lib/ld-musl-aarch64.so.1", "/probe" };
    for (size_t i = 0; i < sizeof(executables)/sizeof(*executables); i++)
        if (allow_path(rules, executables[i], LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_READ_FILE)) fatal("landlock_executable");
    if (allow_path(rules, "/lib", read) || allow_path(rules, "/usr/lib", read) ||
        allow_path(rules, "/work/project", read) ||
        allow_path(rules, "/work/scratch", all & ~LANDLOCK_ACCESS_FS_EXECUTE) ||
        allow_path(rules, "/dev/null", LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_WRITE_FILE)) fatal("landlock_paths");
    if (syscall(SYS_landlock_restrict_self, rules, 0)) fatal("landlock_restrict");
    close(rules);
    // Landlock handles paths; seccomp handles network and privilege/namespace
    // operations. Neither is described as a complete boundary on its own.
    struct sock_filter filters[160]; unsigned count = 0;
#define STMT(c,k) filters[count++] = (struct sock_filter)BPF_STMT(c,k)
#define JUMP(c,k,t,f) filters[count++] = (struct sock_filter)BPF_JUMP(c,k,t,f)
    STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, arch));
    JUMP(BPF_JMP|BPF_JEQ|BPF_K, AUDIT_ARCH_AARCH64, 1, 0);
    STMT(BPF_RET|BPF_K, SECCOMP_RET_KILL_PROCESS);
    STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, nr));
    int denied[] = { SYS_socket, SYS_socketpair, SYS_connect, SYS_bind, SYS_listen,
        SYS_accept, SYS_accept4, SYS_mount, SYS_umount2, SYS_unshare, SYS_setns,
        SYS_bpf, SYS_ptrace, SYS_process_vm_writev, SYS_process_vm_readv,
        SYS_io_uring_setup, SYS_userfaultfd, SYS_perf_event_open, SYS_reboot,
        SYS_kexec_load, SYS_init_module, SYS_finit_module, SYS_delete_module,
        SYS_open_by_handle_at, SYS_chroot, SYS_pivot_root, SYS_fsopen, SYS_fsconfig,
        SYS_fsmount, SYS_move_mount, SYS_open_tree, SYS_mount_setattr };
    for (size_t i=0; i<sizeof(denied)/sizeof(*denied); i++) {
        JUMP(BPF_JMP|BPF_JEQ|BPF_K, denied[i], 0, 1);
        STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO | EPERM);
    }
    JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_clone3, 0, 1);
    STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO | ENOSYS);
    JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_clone, 0, 3);
    STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, args[0]));
    JUMP(BPF_JMP|BPF_JSET|BPF_K, CLONE_NEWUSER|CLONE_NEWNS|CLONE_NEWNET|CLONE_NEWPID|CLONE_NEWIPC|CLONE_NEWUTS|CLONE_NEWCGROUP, 0, 1);
    STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO | EPERM);
    STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW);
    struct sock_fprog program = { .len = count, .filter = filters };
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program)) fatal("seccomp");
}

enum mode { EXECUTE, ORPHAN, PID_LIMIT, SCRATCH_LIMIT, MEMORY_LIMIT, CPU_LIMIT, WALL_LIMIT, MMAP_PROJECT, MMAP_SCRATCH, OUTPUT_LIMIT };
static void body(enum mode mode, char *const argv[]) {
    if (mode == EXECUTE) { execve(argv[0], argv, (char *const[]){"PATH=/usr/bin:/bin", "LANG=C", "HOME=/work/scratch", "TMPDIR=/work/scratch", NULL}); perror("execve"); _exit(126); }
    if (mode == ORPHAN) {
        pid_t child = fork(); if (child < 0) _exit(111); if (child) _exit(0);
        pid_t sid = setsid();
        while (getppid() != 1) usleep(1000);
        int fd = open("/outside/orphan-write", O_WRONLY|O_CREAT|O_EXCL, 0600), error = errno;
        printf("orphan_ppid=%d setsid=%d open_errno=%d\n", getppid(), sid, fd < 0 ? error : 0);
        if (fd >= 0) { write(fd,"escape",6); close(fd); }
        _exit(fd < 0 ? 13 : 0);
    }
    if (mode == PID_LIMIT) {
        int gate[2]; if (pipe(gate)) _exit(111); int n = 0, error = 0;
        for (; n < 32; n++) {
            pid_t child = fork(); if (child < 0) { error = errno; break; }
            if (!child) { close(gate[1]); char byte; read(gate[0],&byte,1); _exit(0); }
        }
        close(gate[0]); close(gate[1]); while (wait(NULL) > 0) {}
        printf("fork_count=%d fork_errno=%d\n", n, error); _exit(error == EAGAIN ? 0 : 11);
    }
    if (mode == SCRATCH_LIMIT) {
        int fd = open("/work/scratch/fill", O_CREAT|O_EXCL|O_WRONLY, 0600); if(fd < 0) _exit(111);
        char block[4096]; memset(block,'x',sizeof(block)); size_t total=0; int error=0;
        while(total < 2*1024*1024) { ssize_t n=write(fd,block,sizeof(block)); if(n<0){error=errno;break;} total+=n; }
        printf("written=%zu write_errno=%d\n",total,error);close(fd);_exit(error==ENOSPC?0:11);
    }
    if (mode == MEMORY_LIMIT) {
        volatile char *bytes = malloc(40*1024*1024); if(!bytes){perror("malloc");_exit(12);}
        for (size_t i=0;i<40*1024*1024;i+=4096) bytes[i]=1;
        printf("allocated_all\n");_exit(11);
    }
    if (mode == CPU_LIMIT) {
        struct timespec t; clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t);
        unsigned long long start=(unsigned long long)t.tv_sec*1000000000+t.tv_nsec,now=start;volatile uint64_t value=1;
        while(now-start<100000000) { for(int i=0;i<10000;i++)value=value*3+1;clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t);now=(unsigned long long)t.tv_sec*1000000000+t.tv_nsec; }
        printf("cpu_ns=%llu\n",now-start);_exit(0);
    }
    if (mode == MMAP_PROJECT || mode == MMAP_SCRATCH) {
        const char *path = mode == MMAP_PROJECT ? "/work/project/undeclared" : "/work/scratch/undeclared";
        int fd=open(path,O_RDONLY); if(fd<0){perror("mmap_input");_exit(111);}
        void *address=mmap(NULL,4096,PROT_READ|PROT_EXEC,MAP_PRIVATE,fd,0); int error=errno;
        printf("mmap_exec_errno=%d\n",address==MAP_FAILED?error:0);
        if(address!=MAP_FAILED)munmap(address,4096);close(fd);_exit(address==MAP_FAILED?13:0);
    }
    if (mode == OUTPUT_LIMIT) { char bytes[4096];memset(bytes,'x',sizeof(bytes));for(;;)write(1,bytes,sizeof(bytes)); }
    for (;;) pause();
}

struct capture { unsigned char prefix[4096]; size_t kept; unsigned long long total; int eof; };
static void drain(int fd, struct capture *out) {
    unsigned char bytes[4096];ssize_t n;
    // Bound one drain turn so a busy writer cannot starve the deadline/kill.
    size_t turn=0;
    while(turn<65536&&(n=read(fd,bytes,sizeof(bytes)))>0) {
        size_t keep=4096-out->kept;if(keep>(size_t)n)keep=n;
        memcpy(out->prefix+out->kept,bytes,keep);out->kept+=keep;out->total+=n;turn+=n;
    }
    if(turn>=65536)return;
    if(n==0)out->eof=1;else if(errno!=EAGAIN&&errno!=EINTR)fatal("capture");
}
static void hex(const unsigned char *bytes,size_t n) { for(size_t i=0;i<n;i++)printf("%02x",bytes[i]); }
static void run(const char *name, enum mode mode, int confined, char *const argv[]) {
    int witness = !strcmp(name, "live-timeout-witness");
    unsigned long long wall_limit_ms = witness ? 3000 : 1500;
    int out[2],err[2];if(pipe2(out,O_CLOEXEC)||pipe2(err,O_CLOEXEC))fatal("pipe");
    unsigned long long before_oom=number("memory.events","oom_kill"),before_pid=number("pids.events","max"),before_cpu=number("cpu.stat","nr_throttled");
    unsigned long long start=clock_ms();pid_t child=fork();if(child<0)fatal("fork_case");
    if(!child) {
        put("/sys/fs/cgroup/check/cgroup.procs","0");
        int null=open("/dev/null",O_RDONLY);if(null<0)fatal("null");
        if(dup2(null,0)<0||dup2(out[1],1)<0||dup2(err[1],2)<0)fatal("dup");
        for(int fd=3;fd<1024;fd++)close(fd);
        struct rlimit files={64,64};if(setrlimit(RLIMIT_NOFILE,&files)||setgroups(0,NULL)||setgid(1000)||setuid(1000))fatal("drop_identity");
        if(chdir("/work/project"))fatal("cwd");
        if(confined)restrict_payload();
        if(witness && write(1,"active\n",7)!=7) _exit(111);
        body(mode,argv);_exit(111);
    }
    close(out[1]);close(err[1]);fcntl(out[0],F_SETFL,O_NONBLOCK);fcntl(err[0],F_SETFL,O_NONBLOCK);
    struct capture o={0},e={0};int observed=0,status=0,extra=0,orphan_status=-1,timed=0,output_limit=0;
    unsigned long long next_witness=0;
    for(;;) {
        drain(out[0],&o);drain(err[0],&e);
        int s;pid_t p;while((p=waitpid(-1,&s,WNOHANG))>0){if(p==child){observed=1;status=s;}else{extra++;orphan_status=WIFEXITED(s)?WEXITSTATUS(s):-1;}}
        if(observed&&o.eof&&e.eof&&number("pids.current",NULL)==0)break;
        if(witness && !observed && o.kept==7 && !memcmp(o.prefix,"active\n",7) && clock_ms()>=next_witness) {
            unsigned long long pids=number("pids.current",NULL);
            if(pids) {
                printf("M2_LIVE {\"nonce\":\"%s\",\"job_pids\":%llu,\"child_pid\":%d,\"job_wall_ms\":%llu}\n",
                       nonce,pids,child,clock_ms()-start);
                fflush(stdout);
                next_witness=clock_ms()+100;
            }
        }
        if(!timed&&!output_limit&&(clock_ms()-start>wall_limit_ms||o.total>65536||e.total>65536)) {
            timed=clock_ms()-start>wall_limit_ms;output_limit=!timed;put("/sys/fs/cgroup/check/cgroup.kill","1");
        }
        if(clock_ms()-start>wall_limit_ms+1000)fatal("job_ownership_unknown");
        struct pollfd fds[]={{out[0],POLLIN,0},{err[0],POLLIN,0}};poll(fds,2,5);
    }
    close(out[0]);close(err[0]);
    printf("M2_RESULT {\"nonce\":\"%s\",\"case\":\"%s\",\"confined\":%s,\"root_observed\":%s,\"exit_code\":%d,\"signal\":%d,\"deadline\":%s,\"output_limit\":%s,\"extra_reaped\":%d,\"orphan_exit\":%d,\"job_pids\":%llu,\"oom_kill_delta\":%llu,\"pids_max_delta\":%llu,\"throttled_delta\":%llu,\"wall_ms\":%llu,\"stdout_hex\":\"",
      nonce,name,confined?"true":"false",observed?"true":"false",WIFEXITED(status)?WEXITSTATUS(status):-1,WIFSIGNALED(status)?WTERMSIG(status):0,timed?"true":"false",output_limit?"true":"false",extra,orphan_status,number("pids.current",NULL),number("memory.events","oom_kill")-before_oom,number("pids.events","max")-before_pid,number("cpu.stat","nr_throttled")-before_cpu,clock_ms()-start);
    hex(o.prefix,o.kept);printf("\",\"stderr_hex\":\"");hex(e.prefix,e.kept);printf("\",\"stdout_bytes\":%llu,\"stderr_bytes\":%llu,\"stdout_eof\":%s,\"stderr_eof\":%s}\n",o.total,e.total,o.eof?"true":"false",e.eof?"true":"false");
}

int main(void) {
    setvbuf(stdout,NULL,_IONBF,0);setvbuf(stderr,NULL,_IONBF,0);
    FILE *token=fopen("/run-nonce","r");if(!token||!fgets(nonce,sizeof(nonce),token))fatal("nonce");fclose(token);nonce[strcspn(nonce,"\r\n")]=0;
    abi=syscall(SYS_landlock_create_ruleset,NULL,0,LANDLOCK_CREATE_RULESET_VERSION);if(abi<3)fatal("landlock_abi");
    directory("/proc",0755);directory("/sys",0755);directory("/sys/fs",0755);directory("/sys/fs/cgroup",0755);
    if(mount("proc","/proc","proc",MS_NOSUID|MS_NODEV|MS_NOEXEC,NULL))fatal("proc");
    if(mount("cgroup2","/sys/fs/cgroup","cgroup2",MS_NOSUID|MS_NODEV|MS_NOEXEC,NULL))fatal("cgroup");
    put("/sys/fs/cgroup/cgroup.subtree_control","+cpu +memory +pids");directory(job,0755);
    put("/sys/fs/cgroup/check/memory.max","33554432");put("/sys/fs/cgroup/check/memory.swap.max","0");
    put("/sys/fs/cgroup/check/pids.max","16");put("/sys/fs/cgroup/check/cpu.max","20000 100000");
    directory("/work",0755);directory("/work/project",0755);directory("/work/scratch",0755);
    if(mount("tmpfs","/work/project","tmpfs",MS_NOSUID|MS_NODEV|MS_NOEXEC,"size=1048576,nr_inodes=128,mode=0755"))fatal("project_tmpfs");
    directory("/work/project/scripts",0755);copy("/sealed/message.txt","/work/project/message.txt",0644);copy("/sealed/test.sh","/work/project/scripts/test.sh",0755);
    copy("/usr/bin/grep","/work/project/undeclared",0755);
    if(symlink("/outside","/work/project/outside-link"))fatal("symlink_fixture");
    if(mount(NULL,"/work/project",NULL,MS_REMOUNT|MS_RDONLY|MS_NOSUID|MS_NODEV|MS_NOEXEC,NULL))fatal("seal_project");
    if(mount("tmpfs","/work/scratch","tmpfs",MS_NOSUID|MS_NODEV|MS_NOEXEC,"size=1048576,nr_inodes=128,mode=0777"))fatal("scratch_tmpfs");
    copy("/usr/bin/grep","/work/scratch/undeclared",0755);
    int network=socket(AF_INET,SOCK_STREAM,0);if(network<0)fatal("listener");
    struct ifreq iface={0};strcpy(iface.ifr_name,"lo");iface.ifr_flags=IFF_UP|IFF_LOOPBACK|IFF_RUNNING;if(ioctl(network,SIOCSIFFLAGS,&iface))fatal("loopback");
    struct sockaddr_in addr={.sin_family=AF_INET,.sin_port=htons(17391),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if(bind(network,(void*)&addr,sizeof(addr))||listen(network,8))fatal("listen");
    printf("M2_META {\"nonce\":\"%s\",\"landlock_abi\":%d,\"project_readonly_noexec\":true,\"scratch_bytes\":1048576,\"job_memory_bytes\":%llu,\"job_pids_max\":16,\"job_cpu_quota\":\"20000 100000\"}\n",nonce,abi,number("memory.max",NULL));
#define RUN(n,m,c,...) run(n,m,c,(char*const[]){__VA_ARGS__,NULL})
    RUN("permitted-check",EXECUTE,1,"/bin/bash","/work/project/scripts/test.sh","--jobs","2");
    RUN("permitted-scratch",EXECUTE,1,"/probe","write","/work/scratch/artifact");
    RUN("outside-read",EXECUTE,1,"/probe","read","/outside/sentinel.txt");
    RUN("outside-write",EXECUTE,1,"/probe","write","/outside/denied-write");
    RUN("traversal",EXECUTE,1,"/probe","write","/work/project/../../outside/denied-traversal");
    RUN("symlink-read",EXECUTE,1,"/probe","read","/work/project/outside-link/sentinel.txt");
    RUN("symlink-write",EXECUTE,1,"/probe","write","/work/project/outside-link/denied-symlink");
    RUN("project-write",EXECUTE,1,"/probe","write","/work/project/new-file");
    RUN("undeclared-executable",EXECUTE,1,"/probe","exec","/outside/undeclared");
    RUN("project-executable",EXECUTE,1,"/probe","exec","/work/project/undeclared");
    RUN("scratch-executable",EXECUTE,1,"/probe","exec","/work/scratch/undeclared");
    RUN("loader-outside",EXECUTE,1,"/lib/ld-musl-aarch64.so.1","/outside/undeclared-dynamic","-qx","after","/work/project/message.txt");
    RUN("loader-project",EXECUTE,1,"/lib/ld-musl-aarch64.so.1","/work/project/undeclared","-qx","after","/work/project/message.txt");
    RUN("loader-scratch",EXECUTE,1,"/lib/ld-musl-aarch64.so.1","/work/scratch/undeclared","-qx","after","/work/project/message.txt");
    RUN("project-mmap-executable",MMAP_PROJECT,1,"unused");
    RUN("scratch-mmap-executable",MMAP_SCRATCH,1,"unused");
    RUN("network-denied",EXECUTE,1,"/probe","connect","17391");
    RUN("detached-orphan",ORPHAN,1,"unused");
    RUN("process-budget",PID_LIMIT,1,"unused");
    RUN("cpu-budget",CPU_LIMIT,1,"unused");
    RUN("memory-budget",MEMORY_LIMIT,1,"unused");
    RUN("wall-budget",WALL_LIMIT,1,"unused");
    RUN("output-budget",OUTPUT_LIMIT,1,"unused");
    RUN("scratch-budget",SCRATCH_LIMIT,1,"unused");
    RUN("ambient-outside-read",EXECUTE,0,"/probe","read","/outside/sentinel.txt");
    RUN("ambient-outside-write",EXECUTE,0,"/probe","write","/outside/ambient-write");
    RUN("ambient-executable",EXECUTE,0,"/probe","exec","/outside/undeclared");
    RUN("ambient-loader",EXECUTE,0,"/lib/ld-musl-aarch64.so.1","/outside/undeclared-dynamic","-qx","after","/work/project/message.txt");
    RUN("ambient-network",EXECUTE,0,"/probe","connect","17391");
    char message[64]={0},artifact[64]={0};int m=open("/work/project/message.txt",O_RDONLY),a=open("/work/scratch/artifact",O_RDONLY);
    ssize_t mn=m<0?-1:read(m,message,sizeof(message)),an=a<0?-1:read(a,artifact,sizeof(artifact));if(m>=0)close(m);if(a>=0)close(a);
    struct stat facts;int escaped=stat("/outside/denied-write",&facts)==0||stat("/outside/denied-traversal",&facts)==0||stat("/outside/denied-symlink",&facts)==0||stat("/outside/orphan-write",&facts)==0;
    printf("M2_INSPECT {\"nonce\":\"%s\",\"message_hex\":\"",nonce);if(mn>0)hex((unsigned char*)message,mn);printf("\",\"artifact_hex\":\"");if(an>0)hex((unsigned char*)artifact,an);printf("\",\"escaped_file_exists\":%s}\n",escaped?"true":"false");
    printf("M2_DONE %s\n",nonce);
    if(access("/live-timeout-fixture",F_OK)==0)
        RUN("live-timeout-witness",WALL_LIMIT,1,"unused");
    stop();
}
