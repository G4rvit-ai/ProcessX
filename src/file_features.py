"""file_features.py - which files did the program touch, and how?

Step 2: look at the calls that open, delete, rename or otherwise change files.
It counts what the program did with files and groups the paths by where they
live (libraries, /etc, /tmp, home directories, ...).

Usage:  python3 src/file_features.py traces/sample_basic_ops.trace
"""
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass, field

from trace_parser import parse_trace

# Calls that open a file (they return a file descriptor, or fail).
OPEN_CALLS = {"open", "openat", "openat2", "creat"}

# Calls that change files or directories, and the word we print for each.
CHANGE_CALLS = {
    "unlink": "delete", "unlinkat": "delete", "rmdir": "delete",
    "rename": "rename", "renameat": "rename", "renameat2": "rename",
    "mkdir": "mkdir", "mkdirat": "mkdir",
    "chmod": "chmod", "fchmodat": "chmod", "fchmodat2": "chmod",
    "chown": "chown", "lchown": "chown", "fchownat": "chown",
    "truncate": "truncate",
}

# Where a path lives. The first group whose prefix matches wins, so specific
# places (like /dev/shm) come before general ones (like /dev).
LOCATIONS = [
    ("temp", ("/tmp/", "/var/tmp/", "/dev/shm/")),
    ("proc/sys", ("/proc/", "/sys/")),
    ("devices", ("/dev/",)),
    ("home", ("/home/", "/root/")),
    # libraries also covers shared data that nearly every program reads (locale files, timezones)
    ("libraries", ("/lib/", "/lib64/", "/usr/lib/", "/usr/lib64/", "/usr/local/lib/",
                   "/usr/share/", "/etc/ld.so.")),
    ("config", ("/etc/",)),
    ("programs", ("/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/local/bin/")),
]
# "relative" = a path that does not start with "/" (relative to the working directory)
LOCATION_NAMES = [name for name, _ in LOCATIONS] + ["relative", "other"]

QUOTED_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')   # a "quoted string" (\" inside is allowed)
FLAG_RE = re.compile(r"\bO_[A-Z_]+")              # O_RDONLY, O_CREAT, ...


def location_of(path):
    """Which place a path lives in: "temp", "config", "libraries", ..."""
    if not path:
        return "other"
    if not path.startswith("/"):
        return "relative"
    path = os.path.normpath(path) + "/"      # so /tmp/../etc/passwd counts as /etc
    for name, prefixes in LOCATIONS:
        if path.startswith(prefixes):
            return name
    return "other"


def succeeded(call):
    """True if the call returned without an error (a call that never returned counts as failed)."""
    return call.error is None and call.ret not in (None, "?") and not call.ret.startswith("-")


def describe_open(call):
    """Return (path, can_write, can_create) for an open-style call."""
    m = QUOTED_RE.search(call.args)
    path = m[1] if m else ""                 # no quoted path, e.g. a bad pointer: path unknown
    if call.name == "creat":
        flags = {"O_WRONLY", "O_CREAT", "O_TRUNC"}      # creat() always means these
    else:
        flags = set(FLAG_RE.findall(call.args[m.end():] if m else call.args))
    return path, bool(flags & {"O_WRONLY", "O_RDWR"}), "O_CREAT" in flags


def change_path(call):
    """The path a changing call works on (for rename: "old -> new")."""
    paths = QUOTED_RE.findall(call.args)
    if CHANGE_CALLS[call.name] == "rename":
        return " -> ".join(paths[:2])
    return paths[0] if paths else ""


@dataclass
class FileFeatures:
    opens: int = 0           # every open-style call
    opens_failed: int = 0    # ...that returned an error
    read_only: int = 0       # successful opens that can only read
    for_write: int = 0       # successful opens that can write (O_WRONLY or O_RDWR)
    with_create: int = 0     # successful opens that were allowed to create the file (O_CREAT)
    by_location: dict = field(default_factory=lambda: dict.fromkeys(LOCATION_NAMES, 0))  # successful opens
    read_files: list = field(default_factory=list)  # sorted unique paths opened read-only (library files left out)
    written: list = field(default_factory=list)   # sorted unique paths opened for writing
    failed: list = field(default_factory=list)    # (error, path) for each failed open
    changes: list = field(default_factory=list)   # (action, path, error or None), in order


def file_features(trace):
    """Collect the file-access features of a parsed trace (all processes together)."""
    f = FileFeatures()
    written = set()
    read = set()
    for call in trace.syscalls:
        if call.name in OPEN_CALLS:
            path, can_write, can_create = describe_open(call)
            f.opens += 1
            if not succeeded(call):
                f.opens_failed += 1
                f.failed.append((call.error or "unknown", path))
                continue
            place = location_of(path)
            f.by_location[place] += 1
            if can_write:
                f.for_write += 1
                written.add(path)
            else:
                f.read_only += 1
                if place != "libraries":    # every program loads libraries; that is not interesting
                    read.add(path)
            if can_create:
                f.with_create += 1
        elif call.name in CHANGE_CALLS:
            error = None if succeeded(call) else (call.error or "unknown")
            f.changes.append((CHANGE_CALLS[call.name], change_path(call), error))
    f.read_files = sorted(read)
    f.written = sorted(written)
    return f


def section(title, rows, limit=10):
    """Print a titled list; say "(none)" when empty so a missing thing is visible."""
    print(f"\n{title}")
    if not rows:
        print("  (none)")
    for row in rows[:limit]:
        print(f"  {row}")
    if len(rows) > limit:
        print(f"  ... and {len(rows) - limit} more")


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "traces/sample_basic_ops.trace"
    if not os.path.isfile(path):
        sys.exit(f"Trace file not found: {path}")
    trace = parse_trace(path)
    if not trace.syscalls:
        sys.exit(f"No system calls found in {path}")

    f = file_features(trace)
    ok = f.opens - f.opens_failed
    print(f"File access: {path}\n")
    print(f"OPENS: {f.opens} total, {ok} succeeded, {f.opens_failed} failed")
    print(f"  read-only:   {f.read_only}")
    print(f"  for writing: {f.for_write}   ({f.with_create} of the successful opens allowed creating the file)")

    ranked = sorted(LOCATION_NAMES, key=lambda n: (-f.by_location[n], LOCATION_NAMES.index(n)))
    section("SUCCESSFUL OPENS, BY LOCATION",
            [f"{n:<10} {f.by_location[n]:>4}" for n in ranked if f.by_location[n]])
    section("OPENED FOR READING (library files not listed)", [p or "(unknown path)" for p in f.read_files])
    section("OPENED FOR WRITING", [p or "(unknown path)" for p in f.written])
    section("CHANGES (delete, rename, mkdir, chmod, ...)",
            [f"{action:<9} {p or '(unknown path)'}" + (f"   FAILED ({err})" if err else "")
             for action, p, err in f.changes])
    failed_rows = sorted(Counter(f.failed).items(), key=lambda item: (-item[1], item[0]))
    section("FAILED OPENS",
            [f"{err:<8} {p or '(unknown path)'}" + (f"   x{n}" if n > 1 else "")
             for (err, p), n in failed_rows])

    placed = sum(f.by_location.values())
    print(f"\n  (check: {ok} succeeded = {f.read_only} read-only + {f.for_write} for writing"
          f" = {placed} placed in a location)")
