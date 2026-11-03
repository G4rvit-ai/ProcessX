#!/bin/sh
# Test program: behaves a little differently on every run (it counts its own runs).
f=/tmp/px_flaky_counter
n=$(cat "$f" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$f"
if [ $((n % 2)) = 0 ]; then ls /etc > /dev/null; fi
if [ $((n % 3)) = 0 ]; then cat /etc/hostname > /dev/null; fi
