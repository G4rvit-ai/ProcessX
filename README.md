# ProcessX: System Call Behavior Analyzer

Runs a program on Linux, records its system calls with strace, and analyzes the pattern of calls.
An unusual pattern is a reason to look closer, not proof of malware. This is not an antivirus.

## Status
Phase 1 complete: run a program, capture its system calls, parse them, and print statistics.
Next: Phase 2 (features and a baseline of normal behavior).

## Requirements
Linux, strace, gcc and Python 3.10 or newer. No extra Python packages are needed yet.

## Try it

    gcc -Wall -o test_programs/basic_ops.out test_programs/basic_ops.c
    python3 src/analyze.py run ./test_programs/basic_ops.out
    python3 src/analyze.py show traces/sample_basic_ops.trace
    bash check_phase1.sh

`run` traces a program and prints a report, `show` reports on a saved trace, and
`check_phase1.sh` tests the whole pipeline end to end.

## Layout
- `test_programs/`: small C programs that we trace
- `traces/`: raw strace output (`sample_basic_ops.trace` is the saved sample; `traces/runs/` is created when you run a program and is not committed)
- `src/`: Python code (`trace_parser.py`, `trace_stats.py`, `analyze.py`)
- `check_phase1.sh`: end-to-end check of the pipeline
