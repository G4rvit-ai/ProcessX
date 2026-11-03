"""baseline.py - what does "normal" look like for a program?

Phase 3, step 1: run a program several times in the same fixed environment,
build a feature record for every run, and save the range of every feature as
that program's baseline. The next steps compare new runs against it.

Usage:
  python3 src/baseline.py build [--runs N] [--name NAME] <program> [program arguments...]
  python3 src/baseline.py show <baseline name or file>

  build        run the program N times and save baselines/<name>.json
  show         print what a saved baseline says is normal
  --runs N     how many runs to base it on (3 to 50, default 10)
  --name NAME  name for the baseline (default: the program's file name without its extension)

Careful: the program really runs N times. Only use programs that are safe to repeat.
"""
import json
import os
import re
import shlex
import shutil
import sys
from datetime import datetime

from analyze import PROJECT_DIR
from file_features import section
from runner import controlled_env, make_run_dir, record_run, shown_environment
from stability import compare_runs
from trace_parser import short

BASELINES_DIR = os.path.join(PROJECT_DIR, "baselines")
SCHEMA = 1                                        # change this whenever the layout of a baseline changes
DEFAULT_RUNS, MIN_RUNS, MAX_RUNS = 10, 3, 50
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")

# What "show" prints: (heading, features). A feature ending in "." or ": " stands for
# every feature that starts with it; any other entry is one exact feature.
GROUPS = [
    ("SYSTEM CALLS", ["calls.total", "calls.unique"]),
    ("CATEGORIES", ["categories."]),
    ("FILES", ["files.opens", "files.opens_failed", "files.written: ", "files.read_files: ",
               "files.changes: ", "files.failed_opens: "]),
    ("PROCESSES", ["processes.count", "processes.created", "processes.threads_created",
                   "processes.programs.", "processes.exits.", "processes.signals."]),
    ("FAILURES", ["failures.failed", "failures.by_error."]),
]
SET_LIKE = ("files.written: ", "files.read_files: ")   # shown as "every run", not as a count


def build_baseline(records, command, name):
    """Turn the feature records of several runs into a baseline: the range of every feature."""
    s = compare_runs(records)
    features = {
        feature: {"min": min(values), "max": max(values), "present": sum(1 for v in values if v)}
        for feature, values in s.features.items()       # present = in how many runs it was not 0
    }
    timing = {key: {"mean": round(mean, 6), "min": round(lo, 6), "max": round(hi, 6)}
              for key, (mean, lo, hi) in s.timing.items()}
    return {
        "schema": SCHEMA,
        "name": name,
        "program": records[0]["program"],
        "command": list(command),
        "runs": len(records),
        "identical_runs": s.same_runs,
        "created": datetime.now().isoformat(timespec="seconds"),
        "environment": shown_environment(),
        "features": features,
        "timing": timing,
    }


def save_baseline(baseline, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(baseline, f, indent=2, sort_keys=True)
        f.write("\n")


def load_baseline(path):
    """Read a baseline back. Raises ValueError if the file is not a ProcessX baseline."""
    with open(path, encoding="utf-8") as f:
        baseline = json.load(f)
    if not isinstance(baseline, dict) or baseline.get("schema") != SCHEMA or "features" not in baseline:
        raise ValueError(f"{path} is not a ProcessX baseline (schema {SCHEMA})")
    return baseline


def find_baseline(arg):
    """A baseline's file: either a path, or the name of a baseline in baselines/."""
    if os.path.isfile(arg):
        return arg
    if NAME_RE.match(arg):
        path = os.path.join(BASELINES_DIR, arg if arg.endswith(".json") else arg + ".json")
        if os.path.isfile(path):
            return path
    saved = sorted(f[:-5] for f in os.listdir(BASELINES_DIR) if f.endswith(".json")) if os.path.isdir(BASELINES_DIR) else []
    sys.exit(f"Baseline not found: {arg}\nSaved baselines: " + (", ".join(saved) if saved else "(none yet)"))


def matches(feature, pattern):
    return feature.startswith(pattern) if pattern.endswith((".", ": ")) else feature == pattern


def label(feature):
    """"files.written: /tmp/x" -> "written: /tmp/x";  "processes.exits.exited with 0" -> "exits: exited with 0"."""
    rest = feature.split(".", 1)[1]
    if ": " not in rest and "." in rest:
        rest = rest.replace(".", ": ", 1)
    return rest


def describe(feature, entry, runs):
    """The range of one feature, e.g. "36", "34..37" or "every run"."""
    if feature.startswith(SET_LIKE):
        return "every run" if entry["present"] == runs else f"{entry['present']} of {runs} runs"
    text = str(entry["min"]) if entry["min"] == entry["max"] else f"{entry['min']}..{entry['max']}"
    if 0 < entry["present"] < runs:
        text += f"   (in {entry['present']} of {runs} runs)"
    return text


def print_baseline(b):
    runs, features = b["runs"], b["features"]
    varied = sorted(((n, e) for n, e in features.items() if e["min"] != e["max"]),
                    key=lambda item: (-(item[1]["max"] - item[1]["min"]), item[0]))
    env = "  ".join(f"{k}={v}" for k, v in sorted(b["environment"].items()))
    print(f"Baseline: {b['name']}   ({runs} runs, {b['identical_runs']} of them identical)")
    print(f"  command      {shlex.join(b['command'])}")
    print(f"  environment  {env}  (and your HOME)")
    print(f"  built        {b['created']}")
    print(f"  features     {len(features)}: {len(features) - len(varied)} identical in every run, {len(varied)} varied")

    for heading, patterns in GROUPS:
        rows = []
        for pattern in patterns:
            for name in sorted(n for n in features if matches(n, pattern)):
                rows.append(f"{short(label(name), 58):<58} {describe(name, features[name], runs)}")
        section(heading, rows, limit=12)

    section(f"VARIED IN THE BASELINE RUNS ({len(varied)})",
            [f"{short(n, 58):<58} {describe(n, e, runs)}" for n, e in varied], limit=10)
    print("\nTIMING (for information; never an alarm on its own)")
    names = {"total_seconds": "inside system calls", "elapsed_seconds": "first call to last"}
    for key, t in b["timing"].items():
        print(f"  {names[key]:<20} mean {t['mean']:.6f} s   from {t['min']:.6f} to {t['max']:.6f} s")


def usage():
    print(__doc__)
    sys.exit(2)


def default_name(program):
    name = re.sub(r"[^A-Za-z0-9_.-]", "_", os.path.splitext(os.path.basename(program))[0]).lstrip("_.-")
    if not name:
        sys.exit("I could not make a name from that program. Give one with --name NAME.")
    return name


def parse_build_args(argv):
    """Return (runs, name, command) from the arguments after "build"."""
    args, runs, name = list(argv), DEFAULT_RUNS, None
    while args and args[0] in ("--runs", "--name"):
        if len(args) < 2:
            usage()
        flag, value = args[0], args[1]
        if flag == "--runs":
            if not (value.isascii() and value.isdigit() and MIN_RUNS <= int(value) <= MAX_RUNS):
                usage()
            runs = int(value)
        else:
            if not NAME_RE.match(value):
                sys.exit(f"A baseline name may only use letters, digits, _ . - and must start with a letter or digit: {value}")
            name = value
        args = args[2:]
    if not args:
        usage()
    return runs, name or default_name(args[0]), args


def cmd_build(argv):
    runs, name, command = parse_build_args(argv)
    env = controlled_env()
    run_dir = make_run_dir("baseline", name)
    print(f"Building baseline '{name}' from {runs} runs of: {shlex.join(command)}")
    print("Every run gets the same fixed environment (LANG, LC_ALL, PATH and HOME only).\n")

    records, width = [], len(str(runs))
    try:
        for i in range(1, runs + 1):
            record = record_run(command, os.path.join(run_dir, f"run{i:0{width}d}"), env)
            records.append(record)
            print(f"  run {i:>{width}}/{runs}  {record['calls']['total']:>5} calls")
    except SystemExit:
        if not records:                     # the very first run failed: don't leave an empty folder behind
            shutil.rmtree(run_dir, ignore_errors=True)
        raise

    baseline = build_baseline(records, command, name)
    os.makedirs(BASELINES_DIR, exist_ok=True)
    path = os.path.join(BASELINES_DIR, name + ".json")
    replaced = os.path.exists(path)
    save_baseline(baseline, path)
    print()
    print_baseline(baseline)
    print(f"\nSaved: {os.path.relpath(path)}" + ("   (replaced the previous baseline)" if replaced else ""))
    print(f"The raw runs (traces and records) are in {os.path.relpath(run_dir)}/")


def cmd_show(arg):
    path = find_baseline(arg)
    try:
        baseline = load_baseline(path)
    except (ValueError, OSError) as error:      # json.JSONDecodeError is a ValueError
        sys.exit(f"Could not read {path}: {error}")
    print_baseline(baseline)


def main():
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == "build":
        cmd_build(args[1:])
    elif len(args) == 2 and args[0] == "show":
        cmd_show(args[1])
    else:
        usage()


if __name__ == "__main__":
    main()
