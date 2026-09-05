#if defined(__linux__)
#define _GNU_SOURCE 1   /* POSIX_SPAWN_SETSID in <spawn.h> */
#endif
#include "pty_shim.h"
#include <assert.h>
#include <spawn.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>

// The PTY primitives (forkpty, winsize, tcgetpgrp) are POSIX and shared. The
// process-introspection helpers are not: Darwin answers them with sysctl and
// libproc, Linux with /proc. Each platform's implementations live behind its
// own guard — Darwin's below, Linux's in pty_shim_linux.c — so one C target
// compiles for macOS, iOS, and Linux from the same header.
#if defined(__APPLE__)
#include <util.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <TargetConditionals.h>
// libproc (proc_pidinfo / proc_listallpids) is macOS-only — absent from the
// iOS SDK. The cwd helpers below are used only by the macOS server, but this
// shim also compiles into the iOS app, so guard the include + implementations.
#if TARGET_OS_OSX
#include <libproc.h>
#endif
#elif defined(__linux__)
#include <pty.h>
#endif

int relay_forkpty(int *master_fd, struct winsize *ws) {
    return forkpty(master_fd, NULL, NULL, ws);
}

int relay_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

int relay_get_winsize(int fd, unsigned short *rows, unsigned short *cols) {
    // The header states both out-params are required; assert rather than leaving
    // that unenforced, since the alternative is a NULL write after a *successful*
    // ioctl. Not a NULL-return path: a caller passing NULL is a programming error,
    // and there is no sensible way to report a size without somewhere to put it.
    // Compiled out under NDEBUG, so release builds keep the bare ioctl.
    assert(rows != NULL && cols != NULL);
    struct winsize ws;
    if (ioctl(fd, TIOCGWINSZ, &ws) < 0) return -1;
    *rows = ws.ws_row;
    *cols = ws.ws_col;
    return 0;
}

int relay_get_foreground_pgid(int fd) {
    return tcgetpgrp(fd);
}

short relay_posix_spawn_setsid_flag(void) {
    return (short)POSIX_SPAWN_SETSID;
}

#if defined(__APPLE__)

int relay_get_process_name(int pid, char *buf, int bufsize) {
    if (bufsize <= 0) return -1;
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) < 0) return -1;
    char *args = malloc(size);
    if (!args) return -1;
    if (sysctl(mib, 3, args, &size, NULL, 0) < 0) { free(args); return -1; }
    // KERN_PROCARGS2: first 4 bytes = argc, then the executable path as a C string.
    if (size < sizeof(int) + 2) { free(args); return -1; }
    const char *path = args + sizeof(int);
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    strncpy(buf, name, bufsize - 1);
    buf[bufsize - 1] = '\0';
    free(args);
    return 0;
}

int relay_get_process_script_name(int pid, char *buf, int bufsize) {
    if (bufsize <= 0) return -1;
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) < 0) return -1;
    char *args = malloc(size);
    if (!args) return -1;
    if (sysctl(mib, 3, args, &size, NULL, 0) < 0) { free(args); return -1; }
    // KERN_PROCARGS2 layout:
    //   int argc
    //   char exec_path[]    (null-terminated executable path)
    //   char[] padding of \0 bytes
    //   char argv[0][]      (null-terminated)
    //   char argv[1][]      (null-terminated)  ← we want this
    //   ...
    if (size < sizeof(int) + 2) { free(args); return -1; }
    int argc = *(int *)args;
    if (argc < 2) { free(args); return -1; }

    const char *cursor = args + sizeof(int);
    const char *end = args + size;

    // Skip the executable path (first null-terminated string).
    while (cursor < end && *cursor != '\0') cursor++;
    if (cursor >= end) { free(args); return -1; }
    cursor++;

    // Skip any padding nulls between exec_path and argv[0].
    while (cursor < end && *cursor == '\0') cursor++;
    if (cursor >= end) { free(args); return -1; }

    // Now at argv[0]. Skip to the end of it.
    while (cursor < end && *cursor != '\0') cursor++;
    if (cursor >= end) { free(args); return -1; }
    cursor++;

    // Now at argv[1], if present.
    if (cursor >= end || *cursor == '\0') { free(args); return -1; }

    const char *argv1 = cursor;
    const char *name = strrchr(argv1, '/');
    name = name ? name + 1 : argv1;
    strncpy(buf, name, bufsize - 1);
    buf[bufsize - 1] = '\0';
    free(args);
    return 0;
}

int relay_get_parent_pid(int pid) {
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &info, &size, NULL, 0) < 0) return -1;
    if (size == 0) return -1;
    return (int)info.kp_eproc.e_ppid;
}

int relay_get_session_members(int sid, int *out, int max_out) {
    assert(out != NULL && max_out > 0);

    // KERN_PROC_SESSION (the filter that would do this in one call) returns
    // ENOENT on macOS 15 for a session that demonstrably exists — verified
    // against a live PTY session leader, with and without the NULL sizing pass.
    // So enumerate every process and filter with getsid(2) instead.
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) < 0) return -1;

    // Processes can be created between the sizing call and the fetch, which
    // makes the second sysctl fail with ENOMEM. Ask for headroom and retry a
    // couple of times rather than treating a busy machine as an error — a
    // failed enumeration here means a session's strays are never signalled.
    struct kinfo_proc *procs = NULL;
    size_t capacity = 0;
    for (int attempt = 0; attempt < 3; attempt++) {
        capacity = size + (sizeof(struct kinfo_proc) * 64);
        struct kinfo_proc *grown = realloc(procs, capacity);
        if (grown == NULL) { free(procs); return -1; }
        procs = grown;
        size = capacity;
        if (sysctl(mib, 3, procs, &size, NULL, 0) == 0) break;
        if (errno != ENOMEM) { free(procs); return -1; }
        // Re-size and try again.
        if (sysctl(mib, 3, NULL, &size, NULL, 0) < 0) { free(procs); return -1; }
        if (attempt == 2) { free(procs); return -1; }
    }

    size_t count = size / sizeof(struct kinfo_proc);
    int found = 0;
    for (size_t i = 0; i < count && found < max_out; i++) {
        pid_t candidate = procs[i].kp_proc.p_pid;
        // Never report pid 0/1: signalling them is either meaningless or fatal,
        // and neither can be in our session anyway.
        if (candidate <= 1) continue;
        // getsid() is the authority rather than kp_eproc.e_sess, which is a
        // kernel pointer, not a session id.
        if (getsid(candidate) == sid) out[found++] = (int)candidate;
    }

    free(procs);
    return found;
}

long long relay_get_process_start_time(int pid) {
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &info, &size, NULL, 0) < 0) return -1;
    if (size == 0) return -1;
    // kp_proc.p_starttime is a struct timeval (seconds + microseconds).
    // Returning seconds is more than enough for PID-reuse discrimination:
    // the race window we're protecting against is 2 seconds, and PID reuse
    // within the same wall-clock second is indistinguishable without the
    // microsecond component — so include both, packed into microseconds.
    long long secs = (long long)info.kp_proc.p_starttime.tv_sec;
    long long usecs = (long long)info.kp_proc.p_starttime.tv_usec;
    return secs * 1000000LL + usecs;
}

#if TARGET_OS_OSX

int relay_proc_cwd(int pid, char *buf, int buflen) {
    struct proc_vnodepathinfo vpi;
    int ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
    if (ret <= 0) return -1;
    size_t len = strlen(vpi.pvi_cdir.vip_path);
    if ((int)len + 1 > buflen) return -1;
    memcpy(buf, vpi.pvi_cdir.vip_path, len + 1);
    return 0;
}

// Parent PID of `pid` via sysctl (same mechanism as relay_get_parent_pid).
static int relay_ppid(int pid) {
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &info, &size, NULL, 0) < 0 || size == 0) return -1;
    return (int)info.kp_eproc.e_ppid;
}

// Recursive helper: try `pid`; else scan all live pids for children of `pid`
// and recurse. Uses proc_listallpids + a parent check rather than
// proc_listchildpids, which proved unreliable (returns a bogus size and 0
// children for setuid `login` processes). `depth` bounds the descent.
static int relay_proc_cwd_walk(int pid, char *buf, int buflen, int depth) {
    if (relay_proc_cwd(pid, buf, buflen) == 0) return 0;
    if (depth <= 0) return -1;

    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return -1;
    int cap = n + 64;   // headroom for pids spawned between sizing and fill
    pid_t *all = (pid_t *)calloc((size_t)cap, sizeof(pid_t));
    if (!all) return -1;
    // proc_listallpids returns the NUMBER OF PIDS written (the libproc wrapper
    // already divides the kernel's byte count by sizeof(int)), so `filled` is a
    // count — do NOT divide again, or only ~1/4 of the array is scanned.
    int filled = proc_listallpids(all, (int)(cap * sizeof(pid_t)));
    int count = filled > 0 ? filled : 0;
    if (count > cap) count = cap;   // never read past the allocation
    int result = -1;
    for (int i = 0; i < count; i++) {
        if (all[i] <= 0) continue;
        if (relay_ppid(all[i]) != pid) continue;
        if (relay_proc_cwd_walk(all[i], buf, buflen, depth - 1) == 0) { result = 0; break; }
    }
    free(all);
    return result;
}

int relay_proc_cwd_descendant(int pid, char *buf, int buflen) {
    // Depth 4 covers login → -zsh → (agent/subshell) with headroom.
    return relay_proc_cwd_walk(pid, buf, buflen, 4);
}

#else  // !TARGET_OS_OSX — libproc unavailable (iOS). The server never runs on
       // iOS, so these are stubs that report "cwd unknown".

int relay_proc_cwd(int pid, char *buf, int buflen) {
    (void)pid; (void)buf; (void)buflen;
    return -1;
}

int relay_proc_cwd_descendant(int pid, char *buf, int buflen) {
    (void)pid; (void)buf; (void)buflen;
    return -1;
}

#endif

#endif /* __APPLE__ */
