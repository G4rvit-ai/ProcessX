"""failure_timing.py - which calls failed, and where did the time go?

Step 4: count the system calls that returned an error (by error and by call)
and, using the durations strace measured with -T, see how long the program
spent inside system calls, which kinds of calls took that time, and which
single calls were the slowest.

Usage:  python3 src/failure_timing.py traces/sample_basic_ops.trace
"""
import math
import os
import sys
from collections import Counter
from dataclasses import dataclass, field

from features import CATEGORY_NAMES, category_of
from file_features import section
from trace_parser import parse_trace, seconds, short

SLOWEST = 5   # how many slow calls to keep


@dataclass
class FailureTiming:
    total_calls: int = 0
    failed: int = 0                                      # calls that returned an error
    by_error: Counter = field(default_factory=Counter)   # "ENOENT" -> how many calls
    by_call: Counter = field(default_factory=Counter)    # ("openat", "ENOENT") -> how many calls
    timed_calls: int = 0                                 # calls that have a duration (strace -T)
    total_time: float = 0.0                              # seconds inside system calls, all processes added up
    time_by_category: dict = field(default_factory=lambda: dict.fromkeys(CATEGORY_NAMES, 0.0))
    slowest: list = field(default_factory=list)          # the slowest calls, slowest first
    elapsed: float = 0.0                                 # seconds from the first call to the last line


def clock_seconds(stamp):
    """"10:07:08.839816" -> seconds since midnight."""
    hours, minutes, secs = stamp.split(":")
    return int(hours) * 3600 + int(minutes) * 60 + float(secs)


def failure_timing(trace):
    """Collect the failure and timing features of a parsed trace."""
    f = FailureTiming()
    durations = {name: [] for name in CATEGORY_NAMES}
    for call in trace.syscalls:
        f.total_calls += 1
        if call.error:
            f.failed += 1
            f.by_error[call.error] += 1
            f.by_call[(call.name, call.error)] += 1
        if call.duration is not None:
            f.timed_calls += 1
            durations[category_of(call.name)].append(call.duration)

    f.time_by_category = {name: math.fsum(values) for name, values in durations.items()}
    f.total_time = math.fsum(d for values in durations.values() for d in values)
    timed = [c for c in trace.syscalls if c.duration is not None]
    f.slowest = sorted(timed, key=lambda c: -c.duration)[:SLOWEST]   # equal times keep trace order

    if trace.syscalls:
        first = clock_seconds(trace.syscalls[0].timestamp)
        offsets = []
        for stamp in [c.timestamp for c in trace.syscalls] + [e.timestamp for e in trace.events]:
            offset = clock_seconds(stamp) - first
            if offset < -43200:              # the clock passed midnight during the trace
                offset += 86400
            offsets.append(offset)
        f.elapsed = max(offsets) - min(offsets)
    return f


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "traces/sample_basic_ops.trace"
    if not os.path.isfile(path):
        sys.exit(f"Trace file not found: {path}")
    trace = parse_trace(path)
    if not trace.syscalls:
        sys.exit(f"No system calls found in {path}")

    f = failure_timing(trace)
    print(f"Failures and timing: {path}\n")
    print(f"FAILED CALLS: {f.failed} of {f.total_calls} ({f.failed / f.total_calls * 100:.1f}%)")
    errors = sorted(f.by_error.items(), key=lambda item: (-item[1], item[0]))
    print("  by error: " + (", ".join(f"{name} x{n}" for name, n in errors) if errors else "(none)"))
    calls = sorted(f.by_call.items(), key=lambda item: (-item[1], item[0]))
    section("WHICH CALLS FAILED", [f"{name:<10} {err:<8} x{n}" for (name, err), n in calls])

    print("\nTIME")
    if f.timed_calls == 0:
        print("  no durations in this trace (was it captured with strace -T?)")
    else:
        print(f"  inside system calls: {seconds(f.total_time)}   (all processes added up)")
        print(f"  first call to last:  {seconds(f.elapsed)}")
        ranked = sorted(CATEGORY_NAMES, key=lambda n: (-f.time_by_category[n], CATEGORY_NAMES.index(n)))
        rows = []
        for name in ranked:
            t = f.time_by_category[name]
            share = t / f.total_time * 100 if f.total_time else 0.0
            if t > 0:
                rows.append(f"{name:<8} {seconds(t)}  {share:5.1f}%")
        section("TIME BY CATEGORY", rows)
        section("SLOWEST CALLS", [f"{seconds(c.duration)}  pid {c.pid}  {c.name}({short(c.args, 40)})"
                                  for c in f.slowest])

    untimed = f.total_calls - f.timed_calls
    print(f"\n  (check: {f.timed_calls} timed + {untimed} without a duration = {f.total_calls} calls)")
