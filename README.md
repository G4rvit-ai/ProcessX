# ProcessX: System Call Behavior Analyzer

Runs a program on Linux, records its system calls with strace, learns what "normal" looks like
for that program, and explains how a new run differs from it.
An unusual run is a reason to look closer, not proof of malware. This is not an antivirus.

## Status
- Phase 1 done: run a program, capture its system calls, parse them, print statistics.
- Phase 2 done: turn every run into a feature record (JSON) and measure how repeatable the features are.
- Phase 3 done: a baseline of normal behavior, a comparison against it, and a simple, explainable score.
- Next: Phase 4, a backend (FastAPI) and a database to keep runs, baselines and scores.

## Requirements
Linux, strace, gcc and Python 3.10 or newer. No extra Python packages are needed yet.

## Try it

    gcc -Wall -o test_programs/basic_ops.out test_programs/basic_ops.c
    python3 src/analyze.py run ./test_programs/basic_ops.out
    python3 src/analyze.py show traces/sample_basic_ops.trace
    python3 src/feature_record.py traces/sample_basic_ops.trace
    python3 src/stability.py --runs 5 ./test_programs/basic_ops.out

`run` traces a program, prints a report and saves a feature record (JSON) next to the trace.
`show` reports on a saved trace and writes nothing. `stability.py` runs a program several
times and shows which features stay the same.

## Baseline, compare, score (Phase 3)

    python3 src/baseline.py build test_programs/demo.sh          # 10 runs -> baselines/demo.json
    python3 src/baseline.py show demo                            # what "normal" looks like
    python3 src/compare.py demo                                  # run it once more and compare
    python3 src/compare.py demo test_programs/demo.sh odd        # compare a different run
    python3 src/compare.py --record traces/runs/<run>.json demo  # compare a saved record

- `baseline.py build [--runs N] [--name NAME] program [args]` runs the program N times (3 to 50,
  default 10) in a fixed environment (PATH, LANG=C, LC_ALL=C and HOME only) and saves the range
  of every feature. Only build baselines from programs that are safe to run many times.
- `compare.py` runs one more time in the same environment and lists every feature that left the
  baseline's range: never seen, more, less, or missing.
- The score is the sum of a few rules, and every point is listed with its reason. The weights are
  the tables at the top of `src/score.py`; change them to change what counts as serious.

| Score | Words |
|-------|-------|
| 0 to 2 | normal |
| 3 to 9 | slightly unusual |
| 10 to 24 | unusual |
| 25 and more | very unusual (the score stops at 100) |

What earns points: reading or writing files the baseline never touched (more for sensitive files
such as /etc/passwd, /etc/shadow, ~/.ssh), starting new programs, opening an internet socket,
powerful system calls (ptrace, mount, setuid...), new signals, processes that crash or exit with
an error, and failed attempts to open a file or start a program (worse for "permission denied").
Plain counts (more `openat` calls, more processes) add nothing, except the total number of
system calls compared with the baseline's busiest run.
Local sockets (a program talking to another program on this computer) are not "the network".

## Checks

    bash check_phase1.sh
    bash check_phase2.sh
    bash check_variants.sh     # six deliberately odd behaviors against a baseline
    bash check_phase3.sh       # all of Phase 3, using grep and awk on the raw traces; runs the others too

## What is in a feature record
Call counts, call categories (file, process, memory, network, signal), how many sockets were
internet and how many local, files opened and changed, processes and programs started, failed
calls, and timing. It has no process ids and no clock times, so the same trace always gives the
same record.

## Good to know
Traced programs behave a little differently under different locale settings (LANG, LC_*):
the same program made 81, 97 or 155 calls in different settings. That is why baselines and
comparisons always run in the same fixed environment.
Baselines built before Phase 3 step 5 do not know the internet/local socket split. They still
work; rebuild one (same `build` command) to get the split.

## Layout
- `test_programs/`: small programs that we trace (`variants.c` has a normal mode and six odd ones)
- `traces/`: raw strace output (`sample_basic_ops.trace` and its record `sample_basic_ops.json`
  are saved samples; `traces/runs/` holds new runs and is not committed)
- `baselines/`: saved baselines, one JSON file per program
- `src/`: Python code
  - Phase 1: `trace_parser.py`, `trace_stats.py`, `analyze.py`
  - Phase 2: `features.py` (categories, socket kinds), `file_features.py`, `process_features.py`,
    `failure_timing.py`, `feature_record.py` (one JSON record per run), `stability.py`
  - Phase 3: `runner.py` (fixed-environment runs), `baseline.py`, `compare.py`, `score.py`
- `check_phase1.sh`, `check_phase2.sh`, `check_variants.sh`, `check_phase3.sh`: end-to-end checks
