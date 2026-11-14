#!/usr/bin/env bash
# Reproduce a small, explainable evaluation of normal and deliberately odd behavior.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; rm -f baselines/evaluation_variants.json baselines/evaluation_demo.json' EXIT

for tool in gcc strace python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Missing required tool: $tool" >&2
        exit 1
    }
done

gcc -Wall -Wextra -o test_programs/variants.out test_programs/variants.c
python3 src/baseline.py build --runs 40 --name evaluation_variants test_programs/variants.out >"$WORK/variants-baseline.txt"
python3 src/baseline.py build --runs 40 --name evaluation_demo test_programs/demo.sh >"$WORK/demo-baseline.txt"

score() {
    sed -n 's/^SCORE: \([0-9][0-9]*\) of 100 - .*/\1/p' "$1" | head -1
}

run_case() {
    local baseline=$1 program=$2 label=$3 minimum=$4 maximum=$5
    shift 5
    local output value first="" attempt
    for attempt in 1 2 3 4 5; do
        output="$WORK/$label-$attempt.txt"
        python3 src/compare.py "$baseline" "$program" "$@" >"$output" 2>&1
        value=$(score "$output")
        if [ -z "$value" ] || [ "$value" -lt "$minimum" ] || [ "$value" -gt "$maximum" ]; then
            echo "FAIL $label run $attempt: score ${value:-missing}, expected $minimum..$maximum" >&2
            sed -n '/^SCORE:/,/^The raw run/p' "$output" >&2
            exit 1
        fi
        if [ -z "$first" ]; then
            first=$value
        elif [ "$value" != "$first" ]; then
            echo "FAIL $label: scores were not reproducible ($first, then $value)" >&2
            exit 1
        fi
    done
    printf '%-10s %3s   %s (5 identical runs)\n' "$label" "$first" \
        "$(sed -n 's/^SCORE: [0-9][0-9]* of 100 - //p' "$WORK/$label-1.txt" | head -1)"
}

echo "ProcessX reproducible evaluation"
echo "Machine: $(uname -msr)"
echo
echo "Each baseline uses 40 normal runs on this machine. Scores can differ between machines;
the assertions check the expected ordering and behavior, not one universal exact score."
echo
run_case evaluation_variants test_programs/variants.out normal 0 2 normal
run_case evaluation_variants test_programs/variants.out spawn 12 100 spawn
run_case evaluation_variants test_programs/variants.out homewrite 6 100 homewrite
run_case evaluation_variants test_programs/variants.out net 10 100 net
run_case evaluation_variants test_programs/variants.out crash 10 100 crash
run_case evaluation_variants test_programs/variants.out secret 8 100 secret
run_case evaluation_variants test_programs/variants.out local 0 5 local
run_case evaluation_demo test_programs/demo.sh demo-normal 0 2
run_case evaluation_demo test_programs/demo.sh demo-odd 8 100 odd

echo
echo "PASS: normal behavior stays low, deliberate deviations score higher, and local sockets stay below network cases."
