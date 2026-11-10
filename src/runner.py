"""runner.py - run a program under strace in a fixed environment and keep its feature record.

Used by the baseline step and the steps after it. The environment is fixed on
purpose: the same program makes a different number of system calls under
different locale settings (LANG, LC_*), so every run we compare must use the
same settings.
"""
import os
import shutil
import subprocess
import sys
from datetime import datetime

from analyze import RUNS_DIR
from feature_record import build_record, save_record
from trace_parser import parse_trace

RUN_TIMEOUT = 60   # seconds one run may take

# The settings every run gets (the same on every machine).
SETTINGS = {
    "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "LANG": "C",
    "LC_ALL": "C",
}


def shown_environment():
    """The fixed settings, safe to write into a file (HOME is passed on too, but it is personal)."""
    return dict(SETTINGS)


def controlled_env():
    """The complete environment a traced program gets: the fixed settings plus HOME, nothing else."""
    env = dict(SETTINGS)
    env["HOME"] = os.environ.get("HOME", "/")
    return env


def make_run_dir(prefix, name):
    """Create a fresh folder inside traces/runs/ (which git ignores) and return its path."""
    base = os.path.join(RUNS_DIR, f"{prefix}_{name}_{datetime.now().strftime('%Y%m%d-%H%M%S')}")
    path, n = base, 1
    while True:
        try:
            os.makedirs(path)
            return path
        except FileExistsError:             # two experiments in the same second
            n += 1
            path = f"{base}-{n}"


def run_traced(command, trace_path, env=None, timeout=RUN_TIMEOUT):
    """Run the command under strace once, save the raw trace, and return the finished process."""
    strace = shutil.which("strace")
    if strace is None:
        sys.exit("strace is not installed. Install it with: sudo apt install strace")
    try:
        # --kill-on-exit: when the time is up, subprocess kills strace, and this makes the kernel stop the program too
        # (without it the program keeps running in the background, which a server cannot afford).
        result = subprocess.run(
            [strace, "--kill-on-exit", "-f", "-tt", "-T", "-o", trace_path, "--"] + command,
            capture_output=True, text=True, errors="replace", stdin=subprocess.DEVNULL,
            timeout=timeout, env=env,
        )
    except subprocess.TimeoutExpired:
        sys.exit(f"The program was still running after {timeout} seconds, so I stopped.")
    if not os.path.exists(trace_path) or os.path.getsize(trace_path) == 0:
        sys.exit("strace could not run that command:\n" + result.stderr.strip())
    return result


def record_run(command, base, env=None):
    """Run the command once; save <base>.trace and <base>.json; return the feature record."""
    run_traced(command, base + ".trace", env)
    trace = parse_trace(base + ".trace")
    if not trace.syscalls:
        sys.exit(f"No system calls found in {base}.trace")
    record = build_record(trace, base + ".trace")
    save_record(record, base + ".json")
    return record
