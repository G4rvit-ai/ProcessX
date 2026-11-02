"""features.py - turn a parsed trace into simple, explainable features.

Step 1: group system calls into categories (file, process, memory, ...).

Usage:  python3 src/features.py traces/sample_basic_ops.trace
"""
import os
import sys
from collections import Counter

from trace_parser import parse_trace

# What each system call is for. A name that is not listed here counts as "other".
# The lists include both the older x86 names (open, stat, fork...) and the newer
# ones used on ARM (openat, newfstatat, clone...), so traces from either work.
CATEGORIES = {
    # files, directories, and anything else you read/write through a file descriptor
    "file": """
        open openat openat2 creat close close_range
        read pread64 readv preadv preadv2 write pwrite64 writev pwritev pwritev2 lseek _llseek
        stat fstat lstat newfstatat statx statfs fstatfs access faccessat faccessat2
        unlink unlinkat rename renameat renameat2 mkdir mkdirat rmdir
        link linkat symlink symlinkat readlink readlinkat
        chmod fchmod fchmodat chown fchown lchown fchownat
        truncate ftruncate fsync fdatasync sync syncfs
        getdents getdents64 getcwd chdir fchdir umask utimensat utimes futimesat
        dup dup2 dup3 pipe pipe2 fcntl ioctl flock sendfile copy_file_range splice
        poll ppoll select pselect6 epoll_create epoll_create1 epoll_ctl epoll_wait epoll_pwait
        eventfd eventfd2 inotify_init inotify_init1 inotify_add_watch inotify_rm_watch
        getxattr lgetxattr fgetxattr setxattr lsetxattr fsetxattr listxattr llistxattr flistxattr
        removexattr lremovexattr fremovexattr
        fadvise64 readahead fallocate sync_file_range mknod mknodat
    """,
    # creating, running and ending processes and threads; who the process is; its limits
    "process": """
        fork vfork clone clone3 execve execveat exit exit_group wait4 waitid
        kill tkill tgkill getpid getppid gettid
        set_tid_address set_robust_list get_robust_list rseq futex
        prctl arch_prctl setsid setpgid getpgid getpgrp
        sched_yield sched_getaffinity sched_setaffinity sched_getparam sched_setscheduler
        sched_getscheduler sched_get_priority_max sched_get_priority_min
        getuid geteuid getgid getegid getgroups setuid setgid setreuid setregid setresuid setresgid
        capget capset prlimit64 getrlimit setrlimit getrusage times unshare setns ptrace
    """,
    # the process's address space: loading libraries, allocating memory
    "memory": """
        mmap mmap2 munmap mprotect mremap brk madvise mlock mlock2 munlock msync mincore
        remap_file_pages membarrier
    """,
    # talking over the network or between local programs through sockets
    "network": """
        socket socketpair bind listen accept accept4 connect getsockname getpeername
        sendto recvfrom sendmsg recvmsg sendmmsg recvmmsg setsockopt getsockopt shutdown
    """,
    # signals: the kernel's way of telling a process that something happened
    "signal": """
        rt_sigaction rt_sigprocmask rt_sigreturn rt_sigsuspend rt_sigpending rt_sigtimedwait
        rt_sigqueueinfo sigaltstack signalfd signalfd4 sigaction sigprocmask sigreturn pause
    """,
}

CATEGORY_NAMES = list(CATEGORIES) + ["other"]
CATEGORY_OF = {name: cat for cat, names in CATEGORIES.items() for name in names.split()}


def category_of(syscall_name):
    """Which category a system call belongs to ("other" if we have not listed it)."""
    return CATEGORY_OF.get(syscall_name, "other")


def category_counts(trace):
    """Count the calls in each category.

    Returns (counts, others): counts maps every category name to a number
    (zero if there were none); others counts the individual call names that
    landed in "other", so a gap in the lists above is easy to spot.
    """
    counts = Counter({name: 0 for name in CATEGORY_NAMES})
    others = Counter()
    for call in trace.syscalls:
        cat = category_of(call.name)
        counts[cat] += 1
        if cat == "other":
            others[call.name] += 1
    return counts, others


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "traces/sample_basic_ops.trace"
    if not os.path.isfile(path):
        sys.exit(f"Trace file not found: {path}")
    trace = parse_trace(path)
    total = len(trace.syscalls)
    if total == 0:
        sys.exit(f"No system calls found in {path}")

    counts, others = category_counts(trace)
    # Biggest first; categories with equal counts keep the order of CATEGORY_NAMES.
    ranked = sorted(CATEGORY_NAMES, key=lambda name: (-counts[name], CATEGORY_NAMES.index(name)))

    print(f"Calls by category: {path}")
    print(f"{total} system calls in total\n")
    for name in ranked:
        n = counts[name]
        bar = "#" * max(1, round(n / total * 30)) if n else ""
        print(f"  {name:<8} {n:>5}  {n / total * 100:5.1f}%  {bar}")

    if others:
        by_count = sorted(others.items(), key=lambda item: (-item[1], item[0]))
        print("\n  'other' holds: " + ", ".join(f"{name} x{n}" for name, n in by_count))
    print(f"\n  (check: {sum(counts.values())} categorized = {total} total)")
