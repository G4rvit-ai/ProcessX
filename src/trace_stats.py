"""trace_stats.py - basic statistics over a parsed trace.

Usage:  python3 src/trace_stats.py traces/sample_basic_ops.trace
"""
import sys
from collections import Counter
from dataclasses import dataclass

from trace_parser import parse_trace


@dataclass
class Stats:
    """Simple counts for one trace."""
    total: int                   # how many system calls were made
    unique: int                  # how many different system calls were used
    counts: Counter              # every call name with its count, e.g. {"mmap": 25}
    top: list[tuple[str, int]]   # the most frequent calls, biggest first


def compute_stats(trace, top_n=10):
    """Count the system calls in a parsed Trace."""
    counts = Counter(call.name for call in trace.syscalls)
    # Biggest count first; calls with equal counts go in alphabetical order,
    # so the list comes out the same on every run.
    ranked = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    return Stats(
        total=len(trace.syscalls),
        unique=len(counts),
        counts=counts,
        top=ranked[:top_n],
    )


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "traces/sample_basic_ops.trace"
    stats = compute_stats(parse_trace(path))

    print(f"Total system calls ..... {stats.total}")
    print(f"Unique system calls .... {stats.unique}")
    print(f"\nTop {len(stats.top)} most frequent:")
    for name, count in stats.top:
        print(f"  {name:<20} {count}")
