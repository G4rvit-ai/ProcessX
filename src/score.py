"""score.py - turn the differences from a baseline into one simple, explainable score.

Phase 3, step 3: every difference that matters is worth a few points, and every
point comes with a reason in plain words. Nothing is learned or hidden: the
weights are the tables below, and you can change them.

How it works
  - Something the baseline never did (reading a sensitive file, starting a new
    program, using the network...) is worth points that depend on what it is
    and where it happened.
  - Plain counts (more 'openat' calls, more processes...) mostly follow from
    those, so they add no points of their own. The one exception is the total
    number of system calls, which is scored by how far it is from the baseline.
  - The score is the sum, at most 100. A score of 0 to 2 counts as "normal".

compare.py prints the score; this file has no command of its own.
"""
import re
from dataclasses import dataclass, field

from features import category_of
from file_features import location_of

# The kinds of difference compare.py finds.
NEVER, ABOVE, BELOW, MISSING = "never", "above", "below", "missing"

# ---- the weights: change these to change what counts as serious -------------

# Reading or writing these is routine, so it never adds points.
HARMLESS_PATHS = {"/dev/null", "/dev/zero", "/dev/urandom", "/dev/random"}

# Reading a file the baseline never read.
SENSITIVE_PATHS = ("/etc/passwd", "/etc/shadow", "/etc/gshadow", "/etc/sudoers",
                   "/.ssh/", "/.gnupg/", "/.aws/", "/.bash_history")
SENSITIVE_READ = 8
READ_POINTS = {"home": 3, "config": 2, "proc/sys": 2, "other": 2,
               "devices": 1, "programs": 1, "libraries": 1, "temp": 1, "relative": 1}

# Writing a file the baseline never wrote. Changing one (delete, rename, chmod...) is worth half.
SENSITIVE_WRITE = 10
WRITE_POINTS = {"config": 10, "programs": 10, "libraries": 8, "home": 6, "proc/sys": 6,
                "other": 5, "temp": 2, "devices": 2, "relative": 2}

# Starting a program the baseline never started. From a temp or home folder is worse.
PROGRAM_POINTS, PROGRAM_FROM_TEMP_OR_HOME = 4, 10

# Opening an internet socket (to other computers) when the baseline never did.
# A local socket (to another program on this computer) is not "the network" and is only a new system call.
NETWORK_POINTS = 10

# Powerful system calls: worth points the first time they appear.
RISKY_CALL_POINTS = 8
RISKY_CALLS = {"ptrace", "mount", "umount2", "chroot", "pivot_root", "unshare", "setns",
               "setuid", "setgid", "setreuid", "setregid", "setresuid", "setresgid", "capset",
               "init_module", "finit_module", "delete_module", "kexec_load", "bpf",
               "process_vm_readv", "process_vm_writev"}

# Other system calls the baseline never used: 1 point each, at most 5 in total.
NEW_CALL_POINTS, NEW_CALL_CAP = 1, 5

# Things that happened in every baseline run but not this time: 2 points each, at most 6 in total.
MISSING_POINTS, MISSING_CAP = 2, 6

# A signal the baseline never got (SIGCHLD only means a child process ended, so it is free),
# and processes that end badly. A process killed by a signal (a crash) is serious, and the
# signal that killed it is not counted a second time.
SIGNAL_POINTS, HARMLESS_SIGNALS = 3, {"SIGCHLD"}
KILLED_POINTS, BAD_EXIT_POINTS = 10, 3

# Calls and programs that failed in a way the baseline never saw. "Permission denied" is worse.
FAILED_POINTS, DENIED_POINTS, DENIED_ERRORS = 2, 4, {"EACCES", "EPERM"}

# The total number of system calls compared with the busiest (or quietest) baseline run:
# (up to this many times as far outside, points). Beyond the last row it is VOLUME_MAX.
VOLUME = [(1.2, 1), (2, 2), (5, 3)]
VOLUME_MAX = 5

# Score -> words. A score above the last limit is TOP_LEVEL.
LEVELS = [(2, "normal"), (9, "slightly unusual"), (24, "unusual")]
TOP_LEVEL = "very unusual"
SCORE_MAX = 100

PLACES = {"temp": "in a temp folder", "home": "in your home folder", "config": "in /etc",
          "programs": "in a program folder", "libraries": "in a library folder",
          "proc/sys": "in /proc or /sys", "devices": "in /dev", "other": "somewhere else",
          "relative": "at a relative path"}

# ---- the machinery ---------------------------------------------------------


@dataclass
class Finding:
    points: int
    text: str


@dataclass
class Score:
    total: int = 0
    level: str = "normal"
    findings: list = field(default_factory=list)   # Finding, biggest first
    unscored: int = 0                              # differences that add no points of their own


def level_of(total):
    for limit, name in LEVELS:
        if total <= limit:
            return name
    return TOP_LEVEL


def is_sensitive(path):
    return any(part in path for part in SENSITIVE_PATHS)


def write_points(path):
    return SENSITIVE_WRITE if is_sensitive(path) else WRITE_POINTS[location_of(path)]


def _read(rest):
    if rest in HARMLESS_PATHS:
        return None
    if is_sensitive(rest):
        return Finding(SENSITIVE_READ, f"read {rest} (a sensitive file)")
    place = location_of(rest)
    return Finding(READ_POINTS[place], f"read {rest} ({PLACES[place]})")


def _write(rest):
    if rest in HARMLESS_PATHS:
        return None
    return Finding(write_points(rest), f"wrote to {rest} ({PLACES[location_of(rest)]})")


def _change(rest):
    """rest looks like "delete /tmp/x", "rename /a -> /b" or "delete ENOENT /tmp/x"."""
    action, _, remainder = rest.partition(" ")
    error = None
    found = re.match(r"(E[A-Z0-9]+) (.*)$", remainder)
    if found:
        error, remainder = found.groups()
    path = remainder.split(" -> ")[0]
    failed = f" - failed: {error}" if error else ""
    return Finding(max(1, (write_points(path) + 1) // 2),
                   f"file change: {action} {remainder}{failed} ({PLACES[location_of(path)]})")


def _program(rest):
    where = location_of(rest)
    if where in ("temp", "home"):
        return Finding(PROGRAM_FROM_TEMP_OR_HOME, f"started {rest} (from {'a temp' if where == 'temp' else 'your home'} folder)")
    return Finding(PROGRAM_POINTS, f"started {rest}")


def _failed(verb):
    def rule(rest):
        error, _, path = rest.partition(" ")
        return Finding(DENIED_POINTS if error in DENIED_ERRORS else FAILED_POINTS,
                       f"failed to {verb} {path} ({error})")
    return rule


def _signal(rest):
    return None if rest in HARMLESS_SIGNALS else Finding(SIGNAL_POINTS, f"received the signal {rest}")


def _exit(rest):
    if rest == "exited with 0":
        return None
    if rest.startswith("killed"):
        return Finding(KILLED_POINTS, f"a process was {rest}")
    return Finding(BAD_EXIT_POINTS, f"a process {rest}")


# Things the baseline never did: (feature prefix, rule). Anything else adds no points.
NEVER_RULES = [
    ("files.read_files: ", _read),
    ("files.written: ", _write),
    ("files.changes: ", _change),
    ("processes.programs.", _program),
    ("files.failed_opens: ", _failed("open")),
    ("processes.failed_execs: ", _failed("start")),
    ("processes.signals.", _signal),
    ("processes.exits.", _exit),
]
# Things that always happened in the baseline and did not this time: (feature prefix, verb).
MISSING_WORDS = [("files.written: ", "wrote to"), ("files.read_files: ", "read"),
                 ("processes.programs.", "started"), ("files.changes: ", "file change:")]


def volume_finding(d):
    """Points for the total number of system calls being outside the baseline's range."""
    ratio = d.value / d.high if d.kind == ABOVE else d.low / d.value
    points = next((p for limit, p in VOLUME if ratio <= limit), VOLUME_MAX)
    if d.kind == ABOVE:
        return Finding(points, f"{d.value} system calls, {ratio:.1f}x the busiest baseline run ({d.high})")
    return Finding(points, f"only {d.value} system calls; the quietest baseline run had {d.low}")


def score_run(deviations):
    """Score the differences found by compare_features. Returns a Score."""
    findings, new_calls, missing, scored = [], [], [], 0
    network_is_new = any(d.feature == "calls.sockets.internet" and d.kind == NEVER for d in deviations)
    killed_by = {d.feature.rsplit(" ", 1)[-1] for d in deviations
                 if d.kind == NEVER and d.feature.startswith("processes.exits.killed by ")}

    for d in deviations:
        f = d.feature
        finding = None
        if d.kind == NEVER:
            if f == "calls.sockets.internet":
                finding = Finding(NETWORK_POINTS, f"used the network ({d.value} internet socket{'s' if d.value != 1 else ''})")
            elif f.startswith("processes.signals.") and f.rsplit(".", 1)[-1] in killed_by:
                pass                                 # the crash is already counted
            elif f.startswith("calls.by_name."):
                name = f[len("calls.by_name."):]
                if name in RISKY_CALLS:
                    finding = Finding(RISKY_CALL_POINTS, f"used a powerful system call: {name}")
                elif not (network_is_new and category_of(name) == "network"):   # socket, connect... are already counted as "used the network"
                    new_calls.append(name)
                    scored += 1
            else:
                for prefix, rule in NEVER_RULES:
                    if f.startswith(prefix):
                        finding = rule(f[len(prefix):])
                        break
        elif d.kind == MISSING:
            for prefix, verb in MISSING_WORDS:
                if f.startswith(prefix):
                    missing.append(f"{verb} {f[len(prefix):]}")
                    scored += 1
        elif f == "calls.total":
            finding = volume_finding(d)

        if finding:
            findings.append(finding)
            scored += 1

    if new_calls:
        names = ", ".join(sorted(new_calls)[:5]) + (", ..." if len(new_calls) > 5 else "")
        noun = "system call" if len(new_calls) == 1 else "system calls"
        findings.append(Finding(min(NEW_CALL_CAP, NEW_CALL_POINTS * len(new_calls)),
                                f"{len(new_calls)} other {noun} the baseline never used: {names}"))
    if missing:
        words = "; ".join(sorted(missing)[:3]) + ("; ..." if len(missing) > 3 else "")
        noun = "thing" if len(missing) == 1 else "things"
        findings.append(Finding(min(MISSING_CAP, MISSING_POINTS * len(missing)),
                                f"{len(missing)} {noun} that happened in every baseline run did not happen: {words}"))

    findings = [f for f in findings if f.points > 0]
    findings.sort(key=lambda f: (-f.points, f.text))
    total = min(SCORE_MAX, sum(f.points for f in findings))
    return Score(total, level_of(total), findings, len(deviations) - scored)


def print_score(s, limit=12):
    print(f"\nSCORE: {s.total} of {SCORE_MAX} - {s.level}")
    if s.findings:
        print("  Where the points come from (biggest first):")
        for f in s.findings[:limit]:
            print(f"    {f.points:>3}  {f.text}")
        if len(s.findings) > limit:
            print(f"         ... and {len(s.findings) - limit} more")
    if s.unscored:
        one = s.unscored == 1
        if s.findings:
            print(f"  {s.unscored} other {'difference' if one else 'differences'} (more calls, more processes, ...) "
                  f"{'follows' if one else 'follow'} from these and {'adds' if one else 'add'} no points.")
        elif one:
            print("  The 1 difference is a plain count that adds no points on its own.")
        else:
            print(f"  The {s.unscored} differences are plain counts that add no points on their own.")
    if s.total > 2:
        print("  \"Unusual\" only means different from the baseline. It does not mean harmful.")
