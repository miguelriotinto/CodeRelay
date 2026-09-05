// Linux implementations of the process-introspection half of pty_shim.h.
//
// Darwin answers these with sysctl(KERN_PROC*) and libproc; Linux has no
// equivalent syscall surface, and /proc is the supported interface for all of
// it. Every helper here reads one of:
//
//   /proc/<pid>/exe      the executable that was exec'd (a symlink; readlink)
//   /proc/<pid>/cmdline  argv, NUL-separated
//   /proc/<pid>/comm     the kernel's 15-char task name (last resort only)
//   /proc/<pid>/stat     "pid (comm) state ppid ... starttime ..."
//   /proc/<pid>/cwd      the working directory (a symlink; readlink)
//   /proc                one numeric directory per live pid
//
// The semantics match the Darwin versions where the callers depend on them:
//
// - `relay_get_process_name` returns the basename of the exec'd binary, as
//   KERN_PROCARGS2's leading exec-path string does. `/proc/<pid>/exe` is the
//   closest analogue: for a login shell it yields "bash", where argv[0] would
//   be "-bash". It is unreadable for a process the caller may not ptrace
//   (EACCES) — sugid processes and other users' — so argv[0] and then `comm`
//   are fallbacks, never the primary.
// - `relay_get_process_start_time` only has to be *stable* for one pid over
//   the life of a process and *different* for a reused pid: it feeds an
//   equality check, not a clock. /proc starttime is clock ticks since boot;
//   it is scaled to microseconds so the packed value has the same units as
//   the Darwin one, but nothing derives wall-clock time from it.
// - `relay_get_session_members` filters with getsid(2) like Darwin, so the
//   "session, not group" invariant documented in the header holds unchanged.
// - The cwd walk exists on Darwin because the setuid `login` process hides
//   its cwd. Linux spawns the shell directly, so `relay_proc_cwd(childPID)`
//   succeeds first time; the descendant walk is kept for the contract and
//   costs nothing on the happy path.

#if defined(__linux__)

#include "pty_shim.h"
#include <assert.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// MARK: - /proc readers

/// Reads up to `cap - 1` bytes of `/proc/<pid>/<leaf>` into `buf`, NUL-terminated.
/// Returns the byte count, or -1 on error. Bounded: never allocates.
static ssize_t proc_read(int pid, const char *leaf, char *buf, size_t cap) {
    char path[64];
    if (snprintf(path, sizeof(path), "/proc/%d/%s", pid, leaf) >= (int)sizeof(path)) return -1;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t total = 0;
    for (;;) {
        if (total + 1 >= cap) break;
        ssize_t n = read(fd, buf + total, cap - 1 - total);
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return -1;
        }
        if (n == 0) break;
        total += (size_t)n;
    }
    close(fd);
    buf[total] = '\0';
    return (ssize_t)total;
}

/// readlink(`/proc/<pid>/<leaf>`) into `buf`, NUL-terminated. Returns 0, or -1
/// on error or when the target does not fit (the link is truncated, not the
/// caller's buffer overrun).
static int proc_readlink(int pid, const char *leaf, char *buf, size_t cap) {
    char path[64];
    if (snprintf(path, sizeof(path), "/proc/%d/%s", pid, leaf) >= (int)sizeof(path)) return -1;
    ssize_t n = readlink(path, buf, cap);
    if (n < 0) return -1;
    if ((size_t)n >= cap) return -1;
    buf[n] = '\0';
    return 0;
}

/// Copies the basename of `path` into `buf`. Strips the " (deleted)" suffix the
/// kernel appends to `exe` for a binary replaced on disk (an upgrade mid-run
/// must not turn "claude" into "claude (deleted)" and break agent detection).
static void copy_basename(const char *path, char *buf, int bufsize) {
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    strncpy(buf, name, (size_t)bufsize - 1);
    buf[bufsize - 1] = '\0';
    static const char deleted[] = " (deleted)";
    size_t len = strlen(buf);
    size_t suffix = sizeof(deleted) - 1;
    if (len > suffix && strcmp(buf + len - suffix, deleted) == 0) buf[len - suffix] = '\0';
}

/// Points `*rest` past the ")" that closes the comm field of a stat line, so
/// the fields that follow can be tokenised without tripping over spaces or
/// parentheses in the process name. Returns -1 if the line is malformed.
static int stat_after_comm(const char *stat, const char **rest) {
    const char *close = strrchr(stat, ')');
    if (!close) return -1;
    *rest = close + 1;
    return 0;
}

/// Returns the `index`-th whitespace-separated field after the comm (0 = state,
/// 1 = ppid, 19 = starttime — the proc(5) numbering minus three), parsed as a
/// long long. -1 if absent.
static long long stat_field(const char *stat, int index) {
    const char *cursor;
    if (stat_after_comm(stat, &cursor) < 0) return -1;
    for (int i = 0; ; i++) {
        while (*cursor == ' ') cursor++;
        if (*cursor == '\0') return -1;
        if (i == index) {
            char *end = NULL;
            long long value = strtoll(cursor, &end, 10);
            return end == cursor ? -1 : value;
        }
        while (*cursor != '\0' && *cursor != ' ') cursor++;
    }
}

static int read_stat(int pid, char *buf, size_t cap) {
    return proc_read(pid, "stat", buf, cap) > 0 ? 0 : -1;
}

// MARK: - pty_shim.h

int relay_get_process_name(int pid, char *buf, int bufsize) {
    if (bufsize <= 0) return -1;

    char link[PATH_MAX];
    if (proc_readlink(pid, "exe", link, sizeof(link)) == 0 && link[0] != '\0') {
        copy_basename(link, buf, bufsize);
        return 0;
    }

    // `exe` is EACCES for processes we cannot ptrace and ENOENT for kernel
    // threads; argv[0] is world-readable. A login shell's "-bash" has the
    // login marker stripped so the name still equals the Darwin exec-path form.
    char cmdline[4096];
    ssize_t n = proc_read(pid, "cmdline", cmdline, sizeof(cmdline));
    if (n > 0 && cmdline[0] != '\0') {
        const char *argv0 = cmdline[0] == '-' ? cmdline + 1 : cmdline;
        copy_basename(argv0, buf, bufsize);
        return 0;
    }

    char comm[64];
    n = proc_read(pid, "comm", comm, sizeof(comm));
    if (n <= 0) return -1;
    while (n > 0 && (comm[n - 1] == '\n' || comm[n - 1] == ' ')) comm[--n] = '\0';
    if (comm[0] == '\0') return -1;
    strncpy(buf, comm, (size_t)bufsize - 1);
    buf[bufsize - 1] = '\0';
    return 0;
}

int relay_get_process_script_name(int pid, char *buf, int bufsize) {
    if (bufsize <= 0) return -1;
    char cmdline[4096];
    ssize_t n = proc_read(pid, "cmdline", cmdline, sizeof(cmdline));
    if (n <= 0) return -1;

    // argv is NUL-separated; argv[1] starts after the first NUL, if the buffer
    // holds one and it is not the terminator of the last argument.
    const char *end = cmdline + n;
    const char *cursor = memchr(cmdline, '\0', (size_t)n);
    if (!cursor) return -1;
    cursor++;
    if (cursor >= end || *cursor == '\0') return -1;

    copy_basename(cursor, buf, bufsize);
    return 0;
}

int relay_get_parent_pid(int pid) {
    char stat[1024];
    if (read_stat(pid, stat, sizeof(stat)) < 0) return -1;
    long long ppid = stat_field(stat, 1);
    if (ppid < 0 || ppid > INT_MAX) return -1;
    return (int)ppid;
}

int relay_get_session_members(int sid, int *out, int max_out) {
    assert(out != NULL && max_out > 0);

    DIR *dir = opendir("/proc");
    if (!dir) return -1;

    int found = 0;
    struct dirent *entry;
    while (found < max_out && (entry = readdir(dir)) != NULL) {
        // Only the numeric entries are pids; everything else is /proc plumbing.
        if (!isdigit((unsigned char)entry->d_name[0])) continue;
        char *end = NULL;
        long value = strtol(entry->d_name, &end, 10);
        if (*end != '\0' || value <= 1 || value > INT_MAX) continue;
        pid_t candidate = (pid_t)value;
        // Same authority as the Darwin path: the kernel's answer for the pid,
        // not a field we parsed. A process that exited between readdir and
        // here fails getsid with ESRCH and is skipped.
        if (getsid(candidate) == sid) out[found++] = (int)candidate;
    }

    closedir(dir);
    return found;
}

long long relay_get_process_start_time(int pid) {
    char stat[1024];
    if (read_stat(pid, stat, sizeof(stat)) < 0) return -1;
    long long ticks = stat_field(stat, 19);
    if (ticks < 0) return -1;
    long hz = sysconf(_SC_CLK_TCK);
    if (hz <= 0) hz = 100;
    // Microseconds since boot: same units as Darwin's packed timeval, and
    // exact for any HZ that divides 1,000,000 (100, 250, 300, 1000 all do).
    return ticks * (1000000LL / hz);
}

int relay_proc_cwd(int pid, char *buf, int buflen) {
    if (buflen <= 0) return -1;
    char link[PATH_MAX];
    if (proc_readlink(pid, "cwd", link, sizeof(link)) < 0) return -1;
    size_t len = strlen(link);
    if ((int)len + 1 > buflen) return -1;
    memcpy(buf, link, len + 1);
    return 0;
}

/// Same shape as the Darwin walk: try `pid`, else recurse into each child,
/// bounded by `depth`. Children are found by scanning /proc for entries whose
/// ppid is `pid` — there is no child list to ask for, and a scan per level is
/// cheap next to the PTY read this sits behind.
static int proc_cwd_walk(int pid, char *buf, int buflen, int depth) {
    if (relay_proc_cwd(pid, buf, buflen) == 0) return 0;
    if (depth <= 0) return -1;

    DIR *dir = opendir("/proc");
    if (!dir) return -1;

    int result = -1;
    struct dirent *entry;
    while (result != 0 && (entry = readdir(dir)) != NULL) {
        if (!isdigit((unsigned char)entry->d_name[0])) continue;
        char *end = NULL;
        long value = strtol(entry->d_name, &end, 10);
        if (*end != '\0' || value <= 1 || value > INT_MAX) continue;
        if (relay_get_parent_pid((int)value) != pid) continue;
        if (proc_cwd_walk((int)value, buf, buflen, depth - 1) == 0) result = 0;
    }

    closedir(dir);
    return result;
}

int relay_proc_cwd_descendant(int pid, char *buf, int buflen) {
    // Depth 4 mirrors Darwin: shell → agent → subshell, with headroom.
    return proc_cwd_walk(pid, buf, buflen, 4);
}

#endif /* __linux__ */
