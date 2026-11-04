"""feature_record.py - one feature record (a small JSON file) per traced run.

Step 5: put the features from Steps 1-4 into a single dictionary, save it as
JSON, and read it back. Phase 3 will compare these records against a baseline.

Usage:  python3 src/feature_record.py traces/sample_basic_ops.trace [output.json]
        (without output.json the record is saved next to the trace, with .json)
"""
import json
import os
import sys
from collections import Counter

from failure_timing import failure_timing
from features import category_counts, socket_kinds
from file_features import file_features, succeeded
from process_features import EXEC_CALLS, describe_exec, process_features
from trace_parser import parse_trace, short
from trace_stats import compute_stats

SCHEMA = 1   # change this number whenever the layout of the record changes


def rows(counter, *names):
    """A Counter whose keys are tuples -> a sorted list of small dicts (JSON has no tuple keys).

    rows(Counter({("openat", "ENOENT"): 2}), "call", "error")
        -> [{"call": "openat", "error": "ENOENT", "count": 2}]
    """
    items = sorted(counter.items(), key=lambda item: (-item[1], item[0]))
    return [dict(zip(names, key), count=n) for key, n in items]


def first_program(trace):
    """(path, command line) of the first program that started: the one we traced."""
    for call in trace.syscalls:
        if call.name in EXEC_CALLS and succeeded(call):
            return describe_exec(call)
    return None, None


def build_record(trace, trace_path=None):
    """Combine every feature of a parsed trace into one JSON-friendly dictionary.

    Nothing in it depends on the time of the run or on process ids, so the same
    trace always gives the same record.
    """
    stats = compute_stats(trace, top_n=None)
    categories, _ = category_counts(trace)
    files = file_features(trace)
    procs = process_features(trace)
    fails = failure_timing(trace)
    program, command = first_program(trace)

    return {
        "schema": SCHEMA,
        "trace": os.path.basename(trace_path) if trace_path else None,
        "program": os.path.basename(program) if program else None,
        "command": command,
        "calls": {
            "total": stats.total,
            "unique": stats.unique,
            "by_name": dict(stats.counts),
            "sockets": socket_kinds(trace),
        },
        "categories": dict(categories),
        "files": {
            "opens": files.opens,
            "opens_failed": files.opens_failed,
            "read_only": files.read_only,
            "for_write": files.for_write,
            "with_create": files.with_create,
            "by_location": dict(files.by_location),
            "read_files": list(files.read_files),
            "written": list(files.written),
            "failed_opens": rows(Counter(files.failed), "error", "path"),
            "changes": [{"action": a, "path": p, "error": e} for a, p, e in files.changes],
        },
        "processes": {
            "count": len(procs.processes),
            "created": procs.processes_created,
            "threads_created": procs.threads_created,
            "creation_failed": procs.creation_failed,
            "programs": dict(procs.programs),
            "failed_execs": rows(Counter(procs.execs_failed), "error", "path"),
            "exits": dict(Counter(procs.exits.values())),
            "exited_ok": procs.exited_ok,
            "exited_badly": procs.exited_badly,
            "no_exit_seen": procs.no_exit_seen,
            "signals": dict(procs.signals),
        },
        "failures": {
            "failed": fails.failed,
            "rate": round(fails.failed / fails.total_calls, 6) if fails.total_calls else 0.0,
            "by_error": dict(fails.by_error),
            "by_call": rows(fails.by_call, "call", "error"),
        },
        "timing": {
            "timed_calls": fails.timed_calls,
            "total_seconds": round(fails.total_time, 6),
            "elapsed_seconds": round(fails.elapsed, 6),
            "by_category": {name: round(t, 6) for name, t in fails.time_by_category.items()},
            "slowest": [{"call": c.name, "seconds": round(c.duration, 6)} for c in fails.slowest],
        },
    }


def save_record(record, path):
    """Write the record as readable JSON (keys sorted, so the file is the same every time)."""
    with open(path, "w", encoding="utf-8") as f:
        json.dump(record, f, indent=2, sort_keys=True)
        f.write("\n")
    return path


def load_record(path):
    """Read a record back. Raises ValueError if the file is not a ProcessX feature record."""
    with open(path, encoding="utf-8") as f:
        record = json.load(f)
    if not isinstance(record, dict) or record.get("schema") != SCHEMA:
        raise ValueError(f"{path} is not a ProcessX feature record (schema {SCHEMA})")
    return record


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) > 2:
        sys.exit(__doc__)
    trace_path = args[0] if args else "traces/sample_basic_ops.trace"
    out_path = args[1] if len(args) == 2 else os.path.splitext(trace_path)[0] + ".json"

    if not os.path.isfile(trace_path):
        sys.exit(f"Trace file not found: {trace_path}")
    if not out_path.endswith(".json"):
        sys.exit(f"The output file name must end with .json (so a trace is never overwritten): {out_path}")
    if os.path.exists(out_path) and os.path.samefile(trace_path, out_path):
        sys.exit(f"The output file would overwrite the trace itself: {out_path}")
    trace = parse_trace(trace_path)
    if not trace.syscalls:
        sys.exit(f"No system calls found in {trace_path}")

    record = build_record(trace, trace_path)
    try:
        save_record(record, out_path)
    except OSError as error:
        sys.exit(f"Could not save {out_path}: {error.strerror}")
    saved = load_record(out_path)
    if saved != record:
        sys.exit(f"FAIL: {out_path} does not match what was built")

    r = saved
    by_count = sorted(r["categories"].items(), key=lambda item: (-item[1], item[0]))
    print(f"Feature record: {out_path}   ({os.path.getsize(out_path):,} bytes)\n")
    print(f"  program      {r['program'] or '(unknown)'}   {short(r['command'] or '', 50)}")
    print(f"  calls        {r['calls']['total']} total, {r['calls']['unique']} different")
    print("  categories   " + ", ".join(f"{name} {n}" for name, n in by_count))
    print(f"  files        {r['files']['opens']} opens ({r['files']['opens_failed']} failed), "
          f"{len(r['files']['written'])} written, {len(r['files']['changes'])} changed")
    print(f"  processes    {r['processes']['count']} ({r['processes']['created']} created, "
          f"{r['processes']['threads_created']} threads), {sum(r['processes']['programs'].values())} programs run")
    print(f"  failures     {r['failures']['failed']} failed calls ({r['failures']['rate'] * 100:.1f}%)")
    print(f"  timing       {r['timing']['total_seconds']:.6f} s inside system calls")
    print("\n  (check: saved, reloaded from disk, identical to what was built)")
