#ifndef PTY_SHIM_H
#define PTY_SHIM_H

#include <sys/ioctl.h>
#include <termios.h>

/// Fork a new process with a pseudo-terminal.
/// Returns child PID to parent (>0), 0 to child, -1 on error.
int relay_forkpty(int *master_fd, struct winsize *ws);

/// Set terminal window size on the given master fd.
int relay_set_winsize(int fd, unsigned short rows, unsigned short cols);

/// Read the terminal window size currently held by the kernel for `fd`.
/// Writes rows/cols through the out-params. Returns 0 on success, -1 on error
/// with errno set. Both pointers are required; neither may be NULL.
///
/// Why callers read the size from here rather than from a shell: see
/// `PTYSession._testOnly_kernelWindowSize()`.
int relay_get_winsize(int fd, unsigned short *rows, unsigned short *cols);

/// Get the foreground process group ID for the given fd via tcgetpgrp.
/// Returns the PGID, or -1 on error.
int relay_get_foreground_pgid(int fd);

/// Get the executable name for the given PID via sysctl(KERN_PROCARGS2).
/// Writes into `buf` (max `bufsize` bytes). Returns 0 on success, -1 on error.
int relay_get_process_name(int pid, char *buf, int bufsize);

/// Get argv[1] (typically the script path for node/python/ruby scripts) for
/// the given PID via sysctl(KERN_PROCARGS2). Writes the basename into `buf`
/// (max `bufsize` bytes). Returns 0 on success, -1 on error or if argv[1]
/// is absent. Used to detect script-based agents whose executable is an
/// interpreter (e.g. `node /opt/homebrew/bin/codex` → returns "codex").
int relay_get_process_script_name(int pid, char *buf, int bufsize);

/// Get the parent PID of the given PID via sysctl(KERN_PROC).
/// Returns the PPID, or -1 on error.
int relay_get_parent_pid(int pid);

/// Get the start time of the given PID, packed as microseconds since the
/// Unix epoch, via sysctl(KERN_PROC). Used by PTYSession.terminate to detect
/// PID reuse before sending SIGKILL — see C-10. Returns -1 on error
/// (process gone, sysctl failed, etc.).
long long relay_get_process_start_time(int pid);

/// Get the current working directory of the given PID via
/// proc_pidinfo(PROC_PIDVNODEPATHINFO). Writes the path into `buf` (max
/// `buflen` bytes, NUL-terminated). Returns 0 on success, -1 on error
/// (process gone, path longer than `buflen`, or proc_pidinfo failed).
///
/// NOTE: proc_pidinfo(PROC_PIDVNODEPATHINFO) returns EPERM for sugid-tainted
/// processes when the caller is not root — which includes shells spawned via
/// setuid `login`. Use `relay_proc_cwd_descendant` for the login-shell case.
int relay_proc_cwd(int pid, char *buf, int buflen);

/// Like `relay_proc_cwd`, but robust to the setuid-`login` shell layering used
/// by PTYSession: if `pid` itself is not readable (EPERM on a sugid `login`
/// process), it descends to the first readable child (the real interactive
/// shell) and returns ITS cwd. Walks up to a small fixed depth. Returns 0 on
/// success (writing into `buf`), -1 if no descendant cwd is readable.
int relay_proc_cwd_descendant(int pid, char *buf, int buflen);

#endif /* PTY_SHIM_H */
