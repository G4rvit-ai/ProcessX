"""process_features.py - which processes did the program create and run?

Step 3: look at the calls that create processes (fork, clone), the calls that
start programs (execve), and the exit and signal lines of the trace.

Usage:  python3 src/process_features.py traces/sample_basic_ops.trace
"""
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass, field

from file_features import QUOTED_RE, section, succeeded
from trace_parser import parse_trace, short

CREATE_CALLS = {"fork", "vfork", "clone", "clone3"}   # start a new process (or thread)
EXEC_CALLS = {"execve", "execveat"}                    # replace the running program with another

ARGV_RE = re.compile(r"\[(.*?)\]\s*,")                 # the ["ls", "-la"] part of execve
WORD_RE = re.compile(r'"((?:[^"\\]|\\.)*)"(\.\.\.)?')  # one "word", plus the ... strace adds when it cut it short
SIGNAL_RE = re.compile(r"SIG[A-Z0-9]+")                # SIGCHLD, SIGSEGV, ...


@dataclass
class ProcessFeatures:
    processes: list = field(default_factory=list)       # sorted process ids (threads are not counted)
    processes_created: int = 0                          # new processes made by fork/vfork/clone
    threads_created: int = 0                            # new threads made by clone (CLONE_THREAD)
    creation_failed: int = 0                            # fork/clone calls that returned an error
    parent_of: dict = field(default_factory=dict)       # child pid -> parent pid
    children: dict = field(default_factory=dict)        # parent pid -> [child pids], in order
    programs: Counter = field(default_factory=Counter)  # program path -> times started with execve
    started_as: dict = field(default_factory=dict)      # pid -> (path, command line) of its latest execve
    execs_failed: list = field(default_factory=list)    # (error, path) for each failed execve
    exits: dict = field(default_factory=dict)           # pid -> "exited with 0" / "killed by SIGSEGV"
    exited_ok: int = 0                                  # processes that exited with code 0
    exited_badly: int = 0                               # non-zero exit code, or killed by a signal
    no_exit_seen: int = 0                               # processes with no exit line in the trace
    signals: Counter = field(default_factory=Counter)   # signal name -> times received


def is_thread(call):
    """A clone that shares the parent's process (CLONE_THREAD) makes a thread, not a new process."""
    return call.name in ("clone", "clone3") and "CLONE_THREAD" in call.args


def describe_exec(call):
    """Return (program path, command line) for an execve call."""
    m = QUOTED_RE.search(call.args)
    path = m[1] if m else ""
    argv = ARGV_RE.search(call.args[m.end():]) if m else None
    words = [w[1] + ("..." if w[2] else "") for w in WORD_RE.finditer(argv[1])] if argv else []
    return path, " ".join(words) if words else path


def process_features(trace):
    """Collect the process features of a parsed trace."""
    f = ProcessFeatures()
    seen = set()          # every process or thread id that appears in the trace
    threads = set()       # the ones that are threads
    owner = {}            # thread id -> the process it belongs to

    for call in trace.syscalls:
        seen.add(call.pid)
        if call.name in CREATE_CALLS:
            if call.ret == "0":              # the child's side of the call, not a new process
                continue
            if not succeeded(call) or not call.ret.isdigit():
                f.creation_failed += 1
                continue
            child = int(call.ret)
            seen.add(child)
            parent = owner.get(call.pid, call.pid)
            if is_thread(call):
                threads.add(child)
                owner[child] = parent
                f.threads_created += 1
            else:
                f.processes_created += 1
                f.parent_of[child] = parent
                f.children.setdefault(parent, []).append(child)
        elif call.name in EXEC_CALLS:
            path, cmdline = describe_exec(call)
            if succeeded(call):
                f.programs[path] += 1
                f.started_as[owner.get(call.pid, call.pid)] = (path, cmdline)
            else:
                f.execs_failed.append((call.error or "unknown", path))

    for event in trace.events:
        seen.add(event.pid)
        if event.kind == "signal":
            m = SIGNAL_RE.match(event.text)
            f.signals[m[0] if m else "?"] += 1

    f.processes = sorted(seen - threads)
    for event in trace.events:
        if event.kind == "exit" and event.pid not in threads:
            f.exits[event.pid] = event.text
    for pid in f.processes:
        if pid not in f.exits:
            f.no_exit_seen += 1
        elif f.exits[pid] == "exited with 0":
            f.exited_ok += 1
        else:
            f.exited_badly += 1
    return f


def tree_lines(f):
    """One line per process, children indented under their parent."""
    lines, shown = [], set()
    roots = [pid for pid in f.processes if pid not in f.parent_of]

    def label(pid):
        if pid in f.started_as:
            return short(f.started_as[pid][1], 60)
        return "(created by fork, no execve)" if pid in f.parent_of else "(program not seen)"

    def walk(start):
        stack = [(start, 0)]
        while stack:
            pid, depth = stack.pop()
            if pid in shown:                 # guards against a reused process id
                continue
            shown.add(pid)
            lines.append(f"{'  ' * depth}{pid}  {label(pid)}")
            for child in reversed(f.children.get(pid, [])):
                stack.append((child, depth + 1))

    for pid in roots:
        walk(pid)
    for pid in f.processes:                  # anything still not shown (a pid-reuse oddity)
        walk(pid)
    return lines


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "traces/sample_basic_ops.trace"
    if not os.path.isfile(path):
        sys.exit(f"Trace file not found: {path}")
    trace = parse_trace(path)
    if not trace.syscalls:
        sys.exit(f"No system calls found in {path}")

    f = process_features(trace)
    print(f"Processes: {path}\n")
    print(f"PROCESSES: {len(f.processes)}")
    print(f"  processes created (fork/clone): {f.processes_created}")
    print(f"  threads created (clone):        {f.threads_created}")
    print(f"  creation calls that failed:     {f.creation_failed}")
    print(f"  programs started (execve):      {sum(f.programs.values())} ok, {len(f.execs_failed)} failed")

    programs = sorted(f.programs.items(), key=lambda item: (-item[1], item[0]))
    section("PROGRAMS RUN", [f"{name}   x{n}" for name, n in programs])
    section("PROCESS TREE", tree_lines(f), limit=12)
    failed = sorted(Counter(f.execs_failed).items(), key=lambda item: (-item[1], item[0]))
    section("FAILED EXECVE", [f"{err:<8} {p or '(unknown path)'}" + (f"   x{n}" if n > 1 else "")
                              for (err, p), n in failed])
    print("\nEXITS")
    print(f"  exited normally (code 0):  {f.exited_ok}")
    print(f"  ended badly:               {f.exited_badly}   (non-zero code, or killed by a signal)")
    print(f"  no exit line in the trace: {f.no_exit_seen}")
    for pid in f.processes:
        if pid in f.exits and f.exits[pid] != "exited with 0":
            print(f"    pid {pid}: {f.exits[pid]}")
    signals = sorted(f.signals.items(), key=lambda item: (-item[1], item[0]))
    section("SIGNALS RECEIVED", [f"{name:<10} x{n}" for name, n in signals])

    print(f"\n  (check: {f.exited_ok} + {f.exited_badly} + {f.no_exit_seen} = "
          f"{f.exited_ok + f.exited_badly + f.no_exit_seen} accounted for, {len(f.processes)} processes)")
