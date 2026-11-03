# ProcessX: System Call Behavior Analyzer

Runs a program on Linux, records its system calls with strace, and analyzes the pattern of calls.
An unusual pattern is a reason to look closer, not proof of malware. This is not an antivirus.

## Status
- Phase 1 done: run a program, capture its system calls, parse them, print statistics.
- Phase 2 done: turn every run into a feature record (JSON) and measure how repeatable the features are.
- Next: Phase 3, a baseline of normal behavior and simple, explainable anomaly rules.

## Requirements
Linux, strace, gcc and Python 3.10 or newer. No extra Python packages are needed yet.

## Try it

    gcc -Wall -o test_programs/basic_ops.out test_programs/basic_ops.c
    python3 src/analyze.py run ./test_programs/basic_ops.out
    python3 src/analyze.py show traces/sample_basic_ops.trace
    python3 src/feature_record.py traces/sample_basic_ops.trace
    python3 src/stability.py --runs 5 ./test_programs/basic_ops.out
    bash check_phase1.sh
    bash check_phase2.sh

`run` traces a program, prints a report and saves a feature record (JSON) next to the trace.
`show` reports on a saved trace and writes nothing. `stability.py` runs a program several
times and shows which features stay the same. The check scripts test each phase end to end.

## What is in a feature record
Call counts, call categories (file, process, memory, network, signal), files opened and
changed, processes and programs started, failed calls, and timing. It has no process ids and
no clock times, so the same trace always gives the same record.

## Good to know
Traced programs behave a little differently under different locale settings (LANG, LC_*):
the same program made 81, 97 or 155 calls in different settings. Compare runs that were
recorded in the same environment.

## Layout
- `test_programs/`: small C programs that we trace
- `traces/`: raw strace output (`sample_basic_ops.trace` and its record `sample_basic_ops.json`
  are saved samples; `traces/runs/` holds new runs and is not committed)
- `src/`: Python code
  - Phase 1: `trace_parser.py`, `trace_stats.py`, `analyze.py`
  - Phase 2: `features.py` (categories), `file_features.py`, `process_features.py`,
    `failure_timing.py`, `feature_record.py` (one JSON record per run), `stability.py`
- `check_phase1.sh`, `check_phase2.sh`: end-to-end checks
