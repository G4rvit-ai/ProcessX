"""store.py - where the backend gets its data from.

Step 2: baselines are the JSON files in baselines/ (made by src/baseline.py).
Later steps can put a database behind these same functions, so main.py does not change.
"""
import json
import sys
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent      # ~/processx, wherever the server was started from
BASELINES_DIR = PROJECT_DIR / "baselines"

sys.path.insert(0, str(PROJECT_DIR / "src"))   # the Phase 1-3 code lives in src/ and imports its neighbours by name
from baseline import NAME_RE, load_baseline    # noqa: E402  (a baseline's name: letters, digits, _ . -)
from compare import check_baseline             # noqa: E402  (is this baseline complete and usable?)


class NotFound(Exception):
    """There is no baseline with that name."""


class Unreadable(Exception):
    """A baseline file exists but cannot be used. The message says why, in words that are safe to show."""


def read_baseline(path):
    """The baseline saved in this file, as a dictionary whose name is the file's name."""
    name = path.stem
    if not NAME_RE.match(name):
        raise Unreadable("the file name is not a valid baseline name (letters, digits, _ . - only)")
    try:
        baseline = load_baseline(path)
    except json.JSONDecodeError:
        raise Unreadable("it is not valid JSON") from None
    except ValueError:
        raise Unreadable("it is not a ProcessX baseline (wrong layout)") from None
    except OSError:
        raise Unreadable("it could not be read") from None
    problem = check_baseline(baseline)
    if problem:
        raise Unreadable(f"it is not a usable baseline: {problem}")
    return {**baseline, "name": name}


def summary(baseline):
    """The short version of a baseline, for the list."""
    keys = ("name", "program", "command", "runs", "identical_runs", "created")
    return {**{key: baseline.get(key) for key in keys}, "feature_count": len(baseline["features"])}


def list_baselines():
    """(summaries of the usable baselines, sorted by name; [{"name", "problem"}] for files that cannot be used)."""
    good, bad = [], []
    paths = sorted(BASELINES_DIR.glob("*.json"), key=lambda p: p.stem) if BASELINES_DIR.is_dir() else []
    for path in paths:
        try:
            good.append(summary(read_baseline(path)))
        except Unreadable as problem:
            bad.append({"name": path.stem, "problem": str(problem)})
    return good, bad


def get_baseline(name):
    """One whole baseline. Raises NotFound or Unreadable."""
    if not NAME_RE.match(name):
        raise NotFound(name)
    path = BASELINES_DIR / f"{name}.json"
    try:
        found = path.is_file()
    except OSError:                      # for example a name too long for the file system
        found = False
    if not found:
        raise NotFound(name)
    return read_baseline(path)
