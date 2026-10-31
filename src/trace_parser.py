"""trace_parser.py - turn a raw strace trace file into structured Python data.

Works on traces captured with:  strace -f -tt -T -o <file> <program>
Each line then looks like this:

    5646  10:07:08.839816 openat(AT_FDCWD, "/tmp/x.txt", O_RDONLY) = 3 <0.000174>
    PID   timestamp       name(arguments)                          = result <seconds>
"""
import re
import sys
from dataclasses import dataclass, field


@dataclass
class Syscall:
    """One system call made by one process."""
    pid: int                       # which process made the call
    timestamp: str                 # when it started, e.g. "10:07:08.839816"
    name: str                      # e.g. "openat"
    args: str                      # the arguments, kept as raw text for now
    ret: str | None = None         # return value as text: "3", "0x7f...", "-1", "?"
    error: str | None = None       # error name if the call failed, e.g. "ENOENT"
    duration: float | None = None  # seconds the call took (from -T)
    split: bool = False            # True if strace printed it in two halves


@dataclass
class Event:
    """Something that is not a system call: a process exit or a signal."""
    pid: int
    timestamp: str
    kind: str                      # "exit" or "signal"
    text: str                      # e.g. "exited with 0"


@dataclass
class Trace:
    """Everything we got out of one trace file."""
    syscalls: list[Syscall] = field(default_factory=list)
    events: list[Event] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)      # lines strace wrote about itself
    unparsed: list[str] = field(default_factory=list)   # lines we did not understand
    second_halves: int = 0                              # split calls we joined back together


# Every line is: PID, timestamp, then the "body" (the part after the timestamp).
LINE_RE = re.compile(r"^(\d+)\s+(\d\d:\d\d:\d\d\.\d+)\s+(.*)$")

# The shapes a body can have:
EXIT_RE = re.compile(r"^\+\+\+ (.*) \+\+\+$")                  # +++ exited with 0 +++
SIGNAL_RE = re.compile(r"^--- (.*) ---$")                       # --- SIGCHLD {...} ---
UNFINISHED_RE = re.compile(r"^(\w+)\((.*?)\s*<unfinished \.\.\.>$")  # wait4(5647 <unfinished ...>
RESUMED_RE = re.compile(r"^<\.\.\. (\w+) resumed>(.*)\)\s+=\s+(.*)$")  # <... wait4 resumed>, NULL) = 5647
CALL_RE = re.compile(r"^(\w+)\((.*)\)\s+=\s+(.*)$")             # openat(...) = 3 <0.000174>


def parse_tail(tail):
    """Split the text after '=' into (return value, error name, duration).

    "3 <0.000174>"                                    -> ("3", None, 0.000174)
    "-1 ENOENT (No such file or directory) <0.0001>"  -> ("-1", "ENOENT", 0.0001)
    "?"                                               -> ("?", None, None)
    """
    words = tail.split()
    ret = words[0] if words else "?"
    error = None
    if len(words) > 1 and re.fullmatch(r"E[A-Z0-9_]+", words[1]):
        error = words[1]
    m = re.search(r"<(\d+\.\d+)>\s*$", tail)
    duration = float(m[1]) if m else None
    return ret, error, duration


def parse_trace(path):
    """Read a trace file and return a Trace."""
    trace = Trace()
    waiting = {}  # pid -> call whose first half we saw, still waiting for its second half

    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")

            if line.startswith("strace:"):      # e.g. "strace: Process 5647 attached"
                trace.notes.append(line)
                continue

            m = LINE_RE.match(line)
            if not m:
                trace.unparsed.append(line)
                continue
            pid, ts, body = int(m[1]), m[2], m[3]

            if m := EXIT_RE.match(body):
                trace.events.append(Event(pid, ts, "exit", m[1]))
            elif m := SIGNAL_RE.match(body):
                trace.events.append(Event(pid, ts, "signal", m[1]))
            elif m := UNFINISHED_RE.match(body):    # first half of a split call
                call = Syscall(pid, ts, m[1], m[2], split=True)
                trace.syscalls.append(call)
                waiting[pid] = call
            elif m := RESUMED_RE.match(body):       # second half: finish the waiting call
                call = waiting.pop(pid, None)
                if call is None:
                    trace.unparsed.append(line)
                    continue
                first, second = call.args.strip(), m[2].strip()
                glue = " " if first.endswith(",") else ""   # strace versions put the comma in different places
                call.args = first + glue + second
                call.ret, call.error, call.duration = parse_tail(m[3])
                trace.second_halves += 1
            elif m := CALL_RE.match(body):          # an ordinary one-line call
                ret, error, duration = parse_tail(m[3])
                trace.syscalls.append(Syscall(pid, ts, m[1], m[2], ret, error, duration))
            else:
                trace.unparsed.append(line)

    return trace


def short(text, limit=60):
    """Shorten long text for display."""
    return text if len(text) <= limit else text[:limit - 3] + "..."


def seconds(value):
    """Format a duration for display."""
    return "-" if value is None else f"{value:.6f} s"


def show(title, call):
    """Print one record, field by field."""
    print(f"\n{title}")
    if call is None:
        print("    (none in this trace)")
        return
    print(f"    pid       {call.pid}")
    print(f"    time      {call.timestamp}")
    print(f"    name      {call.name}")
    print(f"    args      {short(call.args)}")
    print(f"    ret       {call.ret}")
    print(f"    error     {call.error or '-'}")
    print(f"    duration  {seconds(call.duration)}")


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "traces/sample_basic_ops.trace"
    trace = parse_trace(path)

    with open(path, encoding="utf-8", errors="replace") as f:
        lines_in_file = sum(1 for _ in f)
    accounted = (len(trace.syscalls) + len(trace.events) + len(trace.notes)
                 + len(trace.unparsed) + trace.second_halves)

    print(f"Parsed {path}\n")
    print(f"Lines in file ............ {lines_in_file}")
    print(f"  system calls ........... {len(trace.syscalls)}")
    print(f"  exit/signal events ..... {len(trace.events)}")
    print(f"  second halves joined ... {trace.second_halves}")
    if trace.notes:
        print(f"  strace notes ........... {len(trace.notes)}")
    print(f"  not understood ......... {len(trace.unparsed)}")
    if accounted == lines_in_file and not trace.unparsed:
        print("PASS: every line was understood")
    else:
        print("FAIL: some lines were not understood. First few:")
        for line in trace.unparsed[:5]:
            print("   ", line)

    print(f"\nProcesses seen: {sorted({c.pid for c in trace.syscalls})}")
    show("First call:", trace.syscalls[0] if trace.syscalls else None)
    show("First failed call:", next((c for c in trace.syscalls if c.error), None))

    splits = [c for c in trace.syscalls if c.split]
    print("\nCalls strace printed in two halves (now joined):")
    if not splits:
        print("    (none in this trace)")
    for c in splits[:5]:
        print(f"    pid {c.pid}  {c.name}({short(c.args, 40)}) = {c.ret}   [{seconds(c.duration)}]")
