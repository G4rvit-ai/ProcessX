"""stability.py - run a program several times and see which features stay the same.

Step 6: a baseline only works if "normal" is repeatable. This runs a program N
times under strace, builds a feature record for every run (Step 5), and reports
which features were identical in every run and which ones varied.

Usage:  python3 src/stability.py [--runs N] <program> [program arguments...]

  --runs N   how many times to run it (2 to 50, default 10)

Careful: the program really runs N times. Only use programs that are safe to repeat.
"""
import math
import os
import shlex
import shutil
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime

from analyze import RUNS_DIR
from feature_record import build_record, save_record
from file_features import section
from trace_parser import parse_trace, short

JUDGED = ("calls", "categories", "files", "processes", "failures")  # sections where "identical" makes sense
TIMED = ("total_seconds", "elapsed_seconds")                          # timing is reported separately
DERIVED = ("failures.rate",)                                           # calculated from other features, so not judged
DEFAULT_RUNS, MAX_RUNS = 10, 50
RUN_TIMEOUT = 60                                                       # seconds one run may take


@dataclass
class Stability:
    runs: int = 0
    features: dict = field(default_factory=dict)    # feature name -> list with one value per run
    identical: list = field(default_factory=list)   # features with the same value in every run
    varied: list = field(default_factory=list)      # (feature, lowest, highest, runs where non-zero), biggest spread first
    by_section: dict = field(default_factory=dict)  # section -> (number of features, number identical)
    same_runs: int = 0                              # how many runs match the most common run exactly
    timing: dict = field(default_factory=dict)      # "total_seconds" -> (mean, lowest, highest)


def item_name(item):
    """A readable name for one entry of a list in a record: a path, or a small dict's fields joined."""
    if isinstance(item, dict):
        return " ".join(str(item[key]) for key in sorted(item) if key != "count" and item[key] is not None)
    return str(item)


def flatten(record):
    """Turn a record into {feature name: number}.

    {"calls": {"total": 5}}            -> {"calls.total": 5}
    {"files": {"written": ["/tmp/x"]}} -> {"files.written: /tmp/x": 1}
    Timing is left out on purpose (durations are never exactly equal), and so is
    the failure rate (it is just failed calls divided by all calls).
    """
    flat = {}

    def walk(value, prefix):
        if isinstance(value, dict):
            for key, inner in value.items():
                walk(inner, f"{prefix}.{key}")
        elif isinstance(value, list):
            for item in value:
                weight = item.get("count", 1) if isinstance(item, dict) else 1
                name = f"{prefix}: {item_name(item)}"
                flat[name] = flat.get(name, 0) + weight
        elif isinstance(value, (int, float)) and not isinstance(value, bool) and prefix not in DERIVED:
            flat[prefix] = value

    for name in JUDGED:
        walk(record.get(name, {}), name)
    return flat


def compare_runs(records):
    """Compare the feature records of several runs of the same program."""
    s = Stability(runs=len(records))
    flats = [flatten(record) for record in records]
    names = sorted(set().union(*flats)) if flats else []

    for name in names:
        values = [flat.get(name, 0) for flat in flats]      # a feature a run never produced counts as 0
        s.features[name] = values
        if len(set(values)) == 1:
            s.identical.append(name)
        else:
            s.varied.append((name, min(values), max(values), sum(1 for v in values if v)))
    s.varied.sort(key=lambda row: (-(row[2] - row[1]), row[0]))

    identical = set(s.identical)
    for sec in JUDGED:
        in_section = [n for n in names if n.split(".", 1)[0] == sec]
        s.by_section[sec] = (len(in_section), sum(1 for n in in_section if n in identical))

    fingerprints = Counter(tuple(s.features[n][i] for n in names) for i in range(len(records)))
    s.same_runs = max(fingerprints.values()) if fingerprints else 0

    for key in TIMED:
        values = [record["timing"][key] for record in records]
        s.timing[key] = (math.fsum(values) / len(values), min(values), max(values))
    return s


def make_run_dir(name):
    """Create a fresh folder for this experiment inside traces/runs/ (which git ignores)."""
    base = os.path.join(RUNS_DIR, f"stability_{name}_{datetime.now().strftime('%Y%m%d-%H%M%S')}")
    path, n = base, 1
    while True:
        try:
            os.makedirs(path)
            return path
        except FileExistsError:             # two experiments in the same second
            n += 1
            path = f"{base}-{n}"


def run_once(command, trace_path, timeout=RUN_TIMEOUT):
    """Run the command under strace once and save the raw trace."""
    try:
        result = subprocess.run(
            ["strace", "-f", "-tt", "-T", "-o", trace_path, "--"] + command,
            capture_output=True, text=True, errors="replace", stdin=subprocess.DEVNULL, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        sys.exit(f"The program was still running after {timeout} seconds, so I stopped.")
    if not os.path.exists(trace_path) or os.path.getsize(trace_path) == 0:
        sys.exit("strace could not run that command:\n" + result.stderr.strip())


def parse_args(argv):
    """Return (number of runs, the command to run), or exit with the usage text."""
    args, runs = list(argv), DEFAULT_RUNS
    if args and args[0] == "--runs":
        if len(args) < 2 or not (args[1].isascii() and args[1].isdigit()) or not 2 <= int(args[1]) <= MAX_RUNS:
            print(__doc__)
            sys.exit(2)
        runs, args = int(args[1]), args[2:]
    if not args:
        print(__doc__)
        sys.exit(2)
    return runs, args


def print_report(s):
    total = len(s.features)
    same = len(s.identical)
    print("\nRESULT")
    print(f"  runs identical to each other (timing aside): {s.same_runs} of {s.runs}")
    print(f"  features identical in every run:             {same} of {total}"
          f"  ({same / total * 100:.0f}%)" if total else "  (no features found)")

    print("\nBY SECTION")
    for sec in JUDGED:
        count, ok = s.by_section[sec]
        print(f"  {sec:<11} {ok} of {count} identical")

    section(f"FEATURES THAT VARIED ({len(s.varied)})",
            [f"{short(name, 52):<52} {lo}..{hi}   (non-zero in {n} of {s.runs} runs)"
             for name, lo, hi, n in s.varied], limit=15)

    print("\nTIMING (never exactly equal; it depends on how busy the machine is)")
    labels = {"total_seconds": "inside system calls", "elapsed_seconds": "first call to last"}
    for key in TIMED:
        mean, lo, hi = s.timing[key]
        spread = (hi - lo) / mean * 100 if mean else 0.0
        print(f"  {labels[key]:<20} mean {mean:.6f} s   from {lo:.6f} to {hi:.6f} s   (spread {spread:.0f}% of the mean)")


def main():
    runs, command = parse_args(sys.argv[1:])
    if shutil.which("strace") is None:
        sys.exit("strace is not installed. Install it with: sudo apt install strace")

    name = os.path.splitext(os.path.basename(command[0]))[0]
    run_dir = make_run_dir(name)
    print(f"Stability: {shlex.join(command)}   ({runs} runs)")
    print(f"Traces and records are saved in {os.path.relpath(run_dir)}/\n")

    records, width = [], len(str(runs))
    try:
        for i in range(1, runs + 1):
            base = os.path.join(run_dir, f"run{i:0{width}d}")
            run_once(command, base + ".trace")
            trace = parse_trace(base + ".trace")
            if not trace.syscalls:
                sys.exit(f"No system calls found in {base}.trace")
            record = build_record(trace, base + ".trace")
            save_record(record, base + ".json")
            records.append(record)
            print(f"  run {i:>{width}}/{runs}  {record['calls']['total']:>5} calls   "
                  f"{record['timing']['total_seconds']:.6f} s inside system calls")
    except SystemExit:
        if not records:                     # the very first run failed: don't leave an empty folder behind
            shutil.rmtree(run_dir, ignore_errors=True)
        raise

    print_report(compare_runs(records))


if __name__ == "__main__":
    main()
