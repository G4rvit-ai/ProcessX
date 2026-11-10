"""runs.py - run a saved baseline's own command once and compare the run with the baseline.

Step 3. Only the command saved inside a baseline you built yourself is ever run. Nothing in a
web request (its body, its parameters) can change that command.
It reuses the Phase 3 code: run_traced/record_run (runner.py), compare_features (compare.py), score_run (score.py).
"""
import os
import shutil
import threading

from backend import store      # also makes the Phase 1-3 code in src/ importable
from compare import ORDER, compare_features, explain          # noqa: E402
from runner import controlled_env, make_run_dir, record_run, shown_environment   # noqa: E402
from score import score_run    # noqa: E402
from stability import flatten  # noqa: E402

os.chdir(store.PROJECT_DIR)    # a saved command such as test_programs/demo.sh is relative to the project folder

MAX_DIFFERENCES = 200          # the answer lists at most this many differences (outside_range says how many there are)
_one_at_a_time = threading.Lock()


class Busy(Exception):
    """Another comparison is already running."""


class RunFailed(Exception):
    """The saved command could not be run. The message is safe to show; status is the HTTP status that fits."""

    def __init__(self, message, status=500):
        super().__init__(message)
        self.status = status


def why_it_failed(stopped):
    """Turn the runner's sys.exit(...) into a RunFailed with a message that shows no file paths."""
    text = str(stopped.code)
    if text.startswith("strace is not installed"):
        return RunFailed("strace is not installed on the computer that runs the server.", 503)
    if text.startswith("The program was still running after"):
        return RunFailed(text)
    return RunFailed("The saved command could not be run under strace (does the program still exist?).")


def describe(baseline, record, run):
    """Compare one run's record with the baseline and put everything into one dictionary."""
    checked, deviations = compare_features(flatten(record), baseline)
    score = score_run(deviations)
    warnings = []
    if baseline["environment"] != shown_environment():
        warnings.append("This baseline was built with different environment settings than this run uses, "
                        "so the comparison may be unreliable. Rebuild the baseline.")
    return {
        "baseline": baseline["name"],
        "command": baseline["command"],
        "run": run,                                   # the folder name inside traces/runs/
        "matches": not deviations,                    # every feature inside the range the baseline saw
        "score": score.total,
        "level": score.level,
        "findings": [{"points": f.points, "text": f.text} for f in score.findings],   # where the points come from
        "unscored": score.unscored,                   # differences that add no points of their own
        "features_compared": checked,
        "outside_range": len(deviations),
        "outside_by_kind": {kind: sum(1 for d in deviations if d.kind == kind) for kind in ORDER},
        "differences": [{"kind": d.kind, "feature": d.feature, "what": explain(d), "value": d.value,
                         "baseline_low": d.low, "baseline_high": d.high} for d in deviations[:MAX_DIFFERENCES]],
        "warnings": warnings,
    }


def compare_baseline(name):
    """Run the command saved in baseline `name` once and compare. Raises store.NotFound, store.Unreadable, Busy or RunFailed."""
    baseline = store.get_baseline(name)          # checks the name too
    if not _one_at_a_time.acquire(blocking=False):
        raise Busy()
    try:
        run_dir = make_run_dir("compare", baseline["name"])
        try:
            record = record_run(baseline["command"], os.path.join(run_dir, "run"), controlled_env())
        except SystemExit as stopped:             # the Phase 3 code stops with sys.exit; a server must not
            shutil.rmtree(run_dir, ignore_errors=True)
            raise why_it_failed(stopped) from None
    finally:
        _one_at_a_time.release()
    return describe(baseline, record, os.path.basename(run_dir))
