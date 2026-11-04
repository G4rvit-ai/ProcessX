"""compare.py - does a new run look like the baseline?

Phase 3, step 2: run a program once, in the same fixed environment the baseline
used, and compare every feature of that run with the range the baseline saw.
Anything outside the range is listed in plain words and turned into a simple score.

Usage:
  python3 src/compare.py <baseline> [program [arguments...]]
  python3 src/compare.py --record FILE.json <baseline>

  <baseline>        a baseline name (see baselines/) or a baseline .json file
  program           what to run; without it, the command saved in the baseline runs again
  --record FILE     compare a saved feature record instead of running anything

A difference from the baseline is not proof that anything is wrong.
Careful: a baseline remembers its command and this runs it again, so only use baselines you made yourself.
"""
import os
import shlex
import shutil
import sys
from dataclasses import dataclass

from baseline import find_baseline, label, load_baseline
from feature_record import load_record
from file_features import section
from runner import controlled_env, make_run_dir, record_run, shown_environment
from score import ABOVE, BELOW, MISSING, NEVER, print_score, score_run
from stability import JUDGED, flatten

ORDER = (NEVER, ABOVE, BELOW, MISSING)
TITLES = {
    NEVER: "NEVER SEEN IN THE BASELINE",
    ABOVE: "MORE THAN THE BASELINE EVER SHOWED",
    BELOW: "LESS THAN THE BASELINE EVER SHOWED",
    MISSING: "USUALLY THERE, MISSING THIS TIME",
}
LIMITS = {NEVER: 12, ABOVE: 10, BELOW: 10, MISSING: 10}

# Features that name one specific thing, worded as what the program did.
# (prefix, wording). The wording gets what follows the prefix.
def _error_then_path(rest):
    error, _, path = rest.partition(" ")
    return f"{path} ({error})"


def _call_then_error(rest):
    call, _, error = rest.partition(" ")
    return f"{call} failed with {error}"


ACTIONS = [
    ("files.written: ", lambda r: f"wrote to {r}"),
    ("files.read_files: ", lambda r: f"read {r}"),
    ("files.changes: ", lambda r: f"file change: {r}"),
    ("files.failed_opens: ", lambda r: f"failed to open {_error_then_path(r)}"),
    ("processes.programs.", lambda r: f"started {r}"),
    ("processes.failed_execs: ", lambda r: f"failed to start {_error_then_path(r)}"),
    ("processes.signals.", lambda r: f"received the signal {r}"),
    ("processes.exits.", lambda r: f"a process {r}"),
    ("failures.by_call: ", _call_then_error),
]

# Features that are plain numbers, named in words.
NOUNS = {
    "calls.total": "system calls",
    "calls.unique": "different system calls",
    "files.opens": "files opened",
    "files.opens_failed": "failed file opens",
    "files.for_write": "files opened for writing",
    "files.read_only": "files opened read-only",
    "files.with_create": "files created",
    "processes.count": "processes",
    "processes.created": "processes created",
    "processes.threads_created": "threads created",
    "processes.creation_failed": "failed process creations",
    "processes.exited_ok": "processes that exited cleanly",
    "processes.exited_badly": "processes that exited badly",
    "processes.no_exit_seen": "processes with no exit seen",
    "failures.failed": "failed calls",
}
NOUN_PREFIXES = [
    ("calls.by_name.", "'{}' calls"),
    ("categories.", "calls in the '{}' category"),
    ("files.by_location.", "file opens in '{}'"),
    ("failures.by_error.", "{} errors"),
]


@dataclass
class Deviation:
    feature: str
    kind: str       # NEVER, ABOVE, BELOW or MISSING
    value: int      # what this run had
    low: int        # the lowest value in the baseline runs
    high: int       # the highest value in the baseline runs


def action_text(feature):
    """What the program did, in words, for a feature that names one thing; None for plain numbers."""
    for prefix, wording in ACTIONS:
        if feature.startswith(prefix):
            return wording(feature[len(prefix):])
    return None


def noun(feature):
    """A plain-number feature, named in words."""
    if feature in NOUNS:
        return NOUNS[feature]
    for prefix, template in NOUN_PREFIXES:
        if feature.startswith(prefix):
            return template.format(feature[len(prefix):])
    return label(feature)


def importance(feature):
    """0 for a named thing, 1 for a total such as calls.total, 2 for a detailed count. Lower is listed first."""
    if action_text(feature) is not None:
        return 0
    return 1 if feature in NOUNS else 2


def check_baseline(b):
    """Say what is wrong with a baseline file this step cannot use, or return None if it is fine."""
    command = b.get("command")
    if not (isinstance(command, list) and command and all(isinstance(part, str) for part in command)):
        return "it has no usable 'command'"
    if not (isinstance(b.get("runs"), int) and not isinstance(b["runs"], bool) and b["runs"] > 0):
        return "it has no usable 'runs'"
    if not (isinstance(b.get("name"), str) and isinstance(b.get("environment"), dict)):
        return "it has no usable 'name' or 'environment'"
    if not isinstance(b["features"], dict):
        return "its 'features' is not a table"
    for name, entry in b["features"].items():
        ok = isinstance(entry, dict) and all(
            isinstance(entry.get(key), (int, float)) and not isinstance(entry.get(key), bool)
            for key in ("min", "max"))
        if not ok:
            return f"the feature '{name}' is malformed"
    return None


def check_record(record):
    """Say what is wrong with a feature record this step cannot use, or return None if it is fine."""
    for name in JUDGED:
        if not isinstance(record.get(name), dict):
            return f"it has no '{name}' section"
    return None


def compare_features(flat, baseline):
    """Compare one run ({feature: number}) with a baseline. Returns (features compared, deviations)."""
    known = baseline["features"]
    names = sorted(set(known) | set(flat))
    deviations = []
    for name in names:
        entry = known.get(name, {"min": 0, "max": 0})     # never seen means always 0
        value = flat.get(name, 0)                          # not in this run means 0
        low, high = entry["min"], entry["max"]
        if low <= value <= high:
            continue
        if value > high:
            kind = NEVER if high == 0 else ABOVE
        else:
            kind = MISSING if value == 0 else BELOW
        deviations.append(Deviation(name, kind, value, low, high))
    # worst kinds first; then named things (files, programs, ...), then totals, then the detailed counts
    deviations.sort(key=lambda d: (ORDER.index(d.kind), importance(d.feature), d.feature))
    return len(names), deviations


def range_text(low, high):
    return f"always {high}" if low == high else f"{low}..{high}"


def explain(d):
    """One line of plain words for one deviation."""
    action = action_text(d.feature)
    if d.kind == NEVER:
        if action:
            return action + (f"   ({d.value} times)" if d.value > 1 else "")
        return f"{noun(d.feature)}: {d.value}   (the baseline never had any)"
    if d.kind == MISSING and action:      # it can only be missing if it happened in every baseline run
        return f"{action}   (happened in every baseline run)"
    shown = f"{action}: {d.value} times" if action else f"{noun(d.feature)}: {d.value}"
    return f"{shown}   (baseline: {range_text(d.low, d.high)})"


def print_comparison(checked, deviations, runs):
    counts = {kind: sum(1 for d in deviations if d.kind == kind) for kind in ORDER}
    print("\nRESULT")
    print(f"  features compared:      {checked}")
    print(f"  inside baseline range:  {checked - len(deviations)}")
    print(f"  outside it:             {len(deviations)}   (never seen {counts[NEVER]}, more {counts[ABOVE]}, "
          f"less {counts[BELOW]}, missing {counts[MISSING]})")
    print_score(score_run(deviations))
    for kind in ORDER:
        rows = [explain(d) for d in deviations if d.kind == kind]
        if rows:
            section(f"{TITLES[kind]} ({len(rows)})", rows, limit=LIMITS[kind])
    if deviations:
        print("\nThese are differences from the baseline, not proof that anything is wrong.")
    else:
        print(f"\nThis run matches the baseline: every feature is inside the range seen in its {runs} runs.")


def usage():
    print(__doc__)
    sys.exit(2)


def parse_args(argv):
    """Return (record file or None, baseline, command to run instead of the saved one)."""
    args, record_path = list(argv), None
    if args and args[0] == "--record":
        if len(args) < 2:
            usage()
        record_path, args = args[1], args[2:]
    if not args:
        usage()
    if record_path and len(args) > 1:       # a saved record and a program to run don't go together
        usage()
    return record_path, args[0], args[1:]


def main():
    record_path, baseline_arg, command = parse_args(sys.argv[1:])
    path = find_baseline(baseline_arg)
    try:
        baseline = load_baseline(path)
    except (ValueError, OSError) as error:
        sys.exit(f"Could not read {path}: {error}")
    problem = check_baseline(baseline)
    if problem:
        sys.exit(f"Cannot use {path}: {problem}.")
    runs = baseline["runs"]
    print(f"Baseline: {baseline['name']}   ({runs} runs of: {shlex.join(baseline['command'])})")
    if baseline["environment"] != shown_environment():
        print("Warning: this baseline was built with different environment settings than this run uses,")
        print("         so the comparison may be unreliable. Rebuild the baseline.")

    run_dir = None
    if record_path:
        try:
            record = load_record(record_path)
        except (ValueError, OSError) as error:
            sys.exit(f"Could not read {record_path}: {error}")
        problem = check_record(record)
        if problem:
            sys.exit(f"Cannot use {record_path} as a feature record: {problem}.")
        print(f"New run:  the saved feature record {record_path}")
    else:
        command = command or baseline["command"]
        print(f"New run:  {shlex.join(command)}   (run once, in the same fixed environment)")
        if command != baseline["command"]:
            print("          (this is not the command the baseline was built from)")
        run_dir = make_run_dir("compare", baseline["name"])
        try:
            record = record_run(command, os.path.join(run_dir, "run"), controlled_env())
        except SystemExit:
            shutil.rmtree(run_dir, ignore_errors=True)     # nothing worth keeping from a failed run
            raise

    checked, deviations = compare_features(flatten(record), baseline)
    print_comparison(checked, deviations, runs)
    if run_dir:
        print(f"\nThe raw run (trace and record) is in {os.path.relpath(run_dir)}/")


if __name__ == "__main__":
    main()
