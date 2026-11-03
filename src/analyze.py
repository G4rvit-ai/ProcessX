"""analyze.py - ProcessX command-line report.

Runs a program under strace (or reads a trace you already have), parses the
trace, and prints basic system-call statistics.

Usage:
  python3 src/analyze.py run  [--all] <program> [program arguments...]
  python3 src/analyze.py show [--all] <trace file>

  run    trace the program with strace, save the trace in traces/runs/,
         analyze it, and save its feature record (JSON) next to the trace
  show   analyze a trace file you already have
  --all  list every system call instead of the 10 most frequent
"""
import os
import re
import shlex
import shutil
import subprocess
import sys
from collections import Counter
from datetime import datetime

from feature_record import build_record, save_record
from trace_parser import parse_trace
from trace_stats import compute_stats

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNS_DIR = os.path.join(PROJECT_DIR, "traces", "runs")   # traces made by "run" are saved here
BAR_WIDTH = 30                                           # length of the longest bar


def capture_trace(command):
    """Run a command under strace and save the raw trace.

    Returns (path of the trace file, the finished process).
    """
    if shutil.which("strace") is None:
        sys.exit("strace is not installed. Install it with: sudo apt install strace")

    os.makedirs(RUNS_DIR, exist_ok=True)
    name = os.path.splitext(os.path.basename(command[0]))[0]
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    trace_path = os.path.join(RUNS_DIR, f"{name}_{stamp}.trace")

    # -f follow child processes   -tt timestamps   -T time spent in each call
    # -o write the trace to a file instead of the screen
    result = subprocess.run(
        ["strace", "-f", "-tt", "-T", "-o", trace_path, "--"] + command,
        capture_output=True, text=True, errors="replace", stdin=subprocess.DEVNULL,
    )

    if not os.path.exists(trace_path) or os.path.getsize(trace_path) == 0:
        if os.path.exists(trace_path):
            os.remove(trace_path)       # don't leave an empty file behind
        sys.exit("strace could not run that command:\n" + result.stderr.strip())
    return trace_path, result


def print_program_output(result):
    """Show what the traced program printed."""
    code = result.returncode
    status = f"exit code {code}" if code >= 0 else f"killed by signal {-code}"
    print(f"PROGRAM OUTPUT ({status})")
    for line in result.stdout.splitlines():
        print(f"   {line}")
    for line in result.stderr.splitlines():
        print(f"   [stderr] {line}")
    print()


def row(label, value):
    """Print one 'label ..... value' line."""
    print(f"   {label + ' ':.<26} {value}")


def print_report(trace_path, trace, stats, show_all):
    """Print the analysis as a plain-text report."""
    calls = trace.syscalls
    failed = sum(1 for c in calls if c.error)
    calls_per_pid = Counter(c.pid for c in calls)    # how many calls each process made

    # Which program does each process run? Read it from its successful execve call.
    program_of = {}
    for c in calls:
        if c.name == "execve" and c.error is None:
            m = re.match(r'"([^"]*)"', c.args)
            if m:
                program_of[c.pid] = m[1]

    with open(trace_path, encoding="utf-8", errors="replace") as f:
        lines_in_file = sum(1 for _ in f)

    line = "=" * 64
    print(line)
    print(" ProcessX - System Call Report")
    print(line)
    print(f" Trace file: {os.path.relpath(trace_path)}")
    print(f" Lines read: {lines_in_file}   (not understood: {len(trace.unparsed)})")

    print("\n SUMMARY")
    row("Total system calls", stats.total)
    row("Unique system calls", stats.unique)
    row("Failed calls", f"{failed}   (the kernel returned an error, e.g. ENOENT)")
    row("Processes", len(calls_per_pid))

    print("\n PROCESSES")
    for pid, n in calls_per_pid.items():
        program = program_of.get(pid, "(no execve: forked copy of its parent)")
        print(f"   pid {pid:<7} {n:>5} calls   {program}")

    if show_all:
        print(f"\n ALL SYSTEM CALLS ({stats.unique}, most frequent first)")
    else:
        print(f"\n MOST FREQUENT SYSTEM CALLS (top {len(stats.top)} of {stats.unique})")
    biggest = stats.top[0][1]
    for name, count in stats.top:
        bar = "#" * max(1, round(count / biggest * BAR_WIDTH))
        print(f"   {name:<20} {count:>5}  {count / stats.total * 100:5.1f}%  {bar}")
    hidden = stats.unique - len(stats.top)
    if hidden > 0:
        print(f"   ... {hidden} more not shown (add --all after run/show to list every call)")

    if trace.unparsed:
        print(f"\n WARNING: {len(trace.unparsed)} lines were not understood. First few:")
        for text in trace.unparsed[:3]:
            print(f"   {text}")
    print(line)


def main():
    args = sys.argv[1:]
    if len(args) < 2 or args[0] not in ("run", "show"):
        print(__doc__)
        return 2

    mode, rest = args[0], args[1:]
    show_all = rest[0] == "--all"
    if show_all:
        rest = rest[1:]
    if not rest:
        print(__doc__)
        return 2

    result = None
    if mode == "run":
        print(f"Tracing: {shlex.join(rest)}\n")
        trace_path, result = capture_trace(rest)
    else:
        trace_path = rest[0]
        if not os.path.isfile(trace_path):
            sys.exit(f"Trace file not found: {trace_path}")

    trace = parse_trace(trace_path)
    if not trace.syscalls:
        sys.exit(f"No system calls found in {trace_path}.\n"
                 "The parser expects a trace made with:  strace -f -tt -T -o <file> <program>")

    stats = compute_stats(trace, top_n=None if show_all else 10)
    if result is not None:
        print_program_output(result)
    print_report(trace_path, trace, stats, show_all)
    if mode == "run":
        record_path = os.path.splitext(trace_path)[0] + ".json"
        save_record(build_record(trace, trace_path), record_path)
        print(f" Feature record: {os.path.relpath(record_path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
