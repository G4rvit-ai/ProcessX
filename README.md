# ProcessX: System Call Behavior Analyzer

Runs a program on Linux, records its system calls with strace, learns what "normal" looks like
for that program, and explains how a new run differs from it.
An unusual run is a reason to look closer, not proof of malware. This is not an antivirus.

## Status
- Phase 1 done: run a program, capture its system calls, parse them, print statistics.
- Phase 2 done: turn every run into a feature record (JSON) and measure how repeatable the features are.
- Phase 3 done: a baseline of normal behavior, a comparison against it, and a simple, explainable score.
- Phase 4 done: a backend (FastAPI) with a database. It answers /health, shows the
  saved baselines, runs a comparison, saves it and shows the saved history.
- Phase 5 done: a React dashboard for status, baselines, filtered history, comparison details and running comparisons.
- Phase 6 done: FastAPI serves the production dashboard build from the same local-only server.

## Requirements
Linux, strace, gcc, Python 3.10 or newer, and Node.js/npm for the dashboard build.
Phases 1 to 3 need no extra Python packages. The backend needs `requirements.txt`;
the dashboard dependencies are in `dashboard/package.json`.

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

## Backend and dashboard (Phases 4-6)

Install the Python and JavaScript packages once:

    source venv/bin/activate
    pip install -r requirements.txt
    npm --prefix dashboard install

The dashboard lockfile is machine-local and ignored by Git; each system generates its own with
`npm install`.

Start the integrated app from the project folder:

    ./start_processx.sh

The script builds the React dashboard and starts FastAPI on `127.0.0.1:8000`. Open
http://127.0.0.1:8000 for the dashboard or http://127.0.0.1:8000/docs for the API. Stop the
server with Ctrl+C. To use the dashboard from your Mac browser while the app runs in the Ubuntu VM,
run this in a Mac terminal and keep it open:

    ssh -N -L 8000:127.0.0.1:8000 garvit@192.168.64.9

Then open http://127.0.0.1:8000 on the Mac. The server remains local-only inside the VM.

For frontend development with Vite's live reload, run the backend as above and use another VM
terminal for `cd dashboard && npm run dev`; access port 5173 through a separate SSH tunnel.

- `GET /health`: `{"status": "ok", "strace": true, "baselines": 4}`: alive, is strace installed,
  how many baselines are saved in `baselines/`.
- `GET /baselines`: every usable baseline in short (name, program, command, runs, number of features),
  and a list of the files in `baselines/` that cannot be used, with the reason.
- `GET /baselines/<name>`: one baseline in full: for every feature, the lowest and highest value seen
  in its normal runs. Unknown name: 404. Unusable file: 500 with the reason. Read-only: nothing can be
  changed over HTTP.
- `POST /baselines/<name>/compare`: runs the program saved in that baseline once, in the same fixed
  environment, and answers with the score, the level, every point with its reason, and every feature
  that left the baseline's range. The run is saved in `traces/runs/`, and the comparison in the
  database (the answer's `id` is its number there; `null` if it could not be saved). Only the saved
  command is ever run, never one from the request; one comparison at a time (409 if one is running);
  a request that another web page made your browser send is refused (403).
  Try it from a second terminal: `curl -X POST http://127.0.0.1:8000/baselines/demo/compare`
- `GET /comparisons`: the saved comparisons, newest first, without their long details: `total` (how many
  match), then for each one its `id`, `created_at` (UTC), `baseline`, `run`, `score`, `level`, `matches`,
  `features_compared` and `outside_range`. Options: `baseline=<name>` (only that baseline),
  `min_score=<0-100>` (only that score or more), `limit=<1-100>` (the page size, default 20) and
  `offset=<n>` (skip the newest n, to get the next page). A wrong option is refused with 422.
  Try it: `curl -s "http://127.0.0.1:8000/comparisons?limit=3" | python3 -m json.tool`
- `GET /comparisons/<id>`: one saved comparison in full: exactly the answer the comparison gave
  (score, findings, differences...), plus its `id` and `created_at`. Unknown id: 404. Both are
  read-only: the history cannot be changed over HTTP.

### Database
Every comparison is saved in `processx.db`: one SQLite file in the project folder (not committed).
Its table `comparisons` has the columns `id`, `created_at` (UTC), `baseline_name`, `run`, `score`,
`level`, `matches`, `features_compared`, `outside_range` and `result` (the whole answer, as JSON).
To look inside:

    python3 -c "import sqlite3; [print(r) for r in sqlite3.connect('processx.db').execute('select id, created_at, baseline_name, score, level from comparisons')]"

The environment variable `PROCESSX_DATABASE_URL` picks another database (for SQLite, use a full path:
`sqlite:////full/path/x.db`). The tables are made when the server starts; a database that already
exists is left alone, so if a column ever changes, delete `processx.db` (or use a migration tool).

## Dashboard (Phase 5)

The dashboard shows whether the backend and `strace` are available, the latest saved comparison,
and saved baselines with expandable feature ranges. Comparison history can be filtered by baseline
and minimum score, paged with a selectable page size, and opened to view its findings, out-of-range
features, and warnings. Step 5.4 adds **Run comparison** on a baseline to run its saved command once under
`strace`; the dashboard shows progress, adds the result to history, and opens its details. Only
commands in saved baselines can be run. Build baselines only for programs that are safe to run.

The Vite-only development workflow is available for frontend iteration:

    cd dashboard
    npm run dev

It listens at http://127.0.0.1:5173 and proxies `/api` to the backend at `127.0.0.1:8000`.
For normal use, prefer `./start_processx.sh` above.

## Checks

    bash check_phase1.sh
    bash check_phase2.sh
    bash check_variants.sh     # six deliberately odd behaviors against a baseline
    bash check_phase3.sh       # all of Phase 3, using grep and awk on the raw traces; runs the others too
    bash check_phase4.sh       # starts the real backend, checks it with curl; runs check_phase3.sh too
    bash check_phase5.sh       # dashboard unit tests and production build
    bash check_phase6.sh       # starts the integrated app and checks dashboard/API/Host behavior

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
A program that starts with SIGINT, SIGQUIT or SIGTERM ignored (what a background job in a script gets)
makes one system call fewer if it is a shell. That is not part of the fixed environment, so build
baselines and start the server from a normal terminal, not from a script.

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
- `backend/`: the web server (`main.py`: the endpoints; `store.py`: where the baselines come from;
  `runs.py`: runs a comparison; `models.py`: the tables; `db.py`: the database connection, saving
  and reading the history); `requirements.txt` lists its packages
- `dashboard/`: the React dashboard (Vite development server, API client, view components and tests)
- `start_processx.sh`: builds the dashboard and starts the integrated local-only server
- `check_phase1.sh`, `check_phase2.sh`, `check_variants.sh`, `check_phase3.sh`, `check_phase4.sh`,
  `check_phase5.sh`, `check_phase6.sh`: phase checks
