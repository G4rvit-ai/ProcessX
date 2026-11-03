#!/usr/bin/env bash
# check_phase2.sh - end-to-end check of the ProcessX Phase 2 pipeline.
#
#   trace -> features (categories, files, processes, failures, timing)
#         -> one JSON record per run -> repeated runs -> stability report
#
# Usage:  bash check_phase2.sh
# Every number in the feature records is compared with a count made by plain
# shell tools (grep/awk), so Python is never grading its own homework.

cd "$(dirname "$0")" || exit 1

PASSED=0
FAILED=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() { echo "  PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }

# check "what" command...     passes when the command succeeds
check() {
    local what=$1
    shift
    if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}

# expect "what" "actual" "wanted"     passes when the two are equal
expect() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got: $2   wanted: $3)"; fi
}

summary() {
    echo
    if [ "$FAILED" -eq 0 ]; then
        echo "ALL $PASSED CHECKS PASSED: the Phase 2 feature pipeline works end to end."
    else
        echo "$FAILED of $((PASSED + FAILED)) CHECKS FAILED. Read the FAIL lines above."
    fi
}

# ---- independent counts straight from a raw trace file (no Python involved) ----
CALLS='^[0-9]+ +[0-9:.]+ [a-z_0-9]+\('
OPENS='^[0-9]+ +[0-9:.]+ (open|openat|openat2|creat)\('
MADE='^[0-9]+ +[0-9:.]+ (clone3?|fork|vfork)\(.*\) += [1-9]|<\.\.\. (clone3?|fork|vfork) resumed>.*\) += [1-9]'
EXECOK='^[0-9]+ +[0-9:.]+ execve\(.*\) += 0 |<\.\.\. execve resumed>.*\) += 0 '
count_calls()  { grep -cE "$CALLS" "$1"; }
count_unique() { grep -oE "$CALLS" "$1" | awk '{print $NF}' | sort -u | wc -l | tr -d ' '; }
count_failed() { grep -cE ' = [^ ]+ E[A-Z0-9_]+( |$)' "$1"; }
count_opens()  { grep -cE "$OPENS" "$1"; }
count_pids()   { awk '{print $1}' "$1" | sort -u | wc -l | tr -d ' '; }   # fine for programs without threads
count_made()   { grep -cE "$MADE" "$1"; }
count_execok() { grep -cE "$EXECOK" "$1"; }
count_timed()  { grep -cE '<[0-9]+\.[0-9]+>$' "$1"; }

# ---- read a feature record (JSON) ----
rec_get() { python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
rec_ok()  { python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2"; }

# The numbers on a module's "(check: ...)" line.
nums() { grep '(check:' | grep -oE '[0-9]+' | tr '\n' ' '; }

# check_record RECORD TRACE LABEL: compare one record with independent counts from its trace
check_record() {
    local rec=$1 trace=$2 label=$3
    check "$label: the record is valid JSON" python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$rec"
    expect "$label: total calls match grep" "$(rec_get "$rec" 'r["calls"]["total"]')" "$(count_calls "$trace")"
    expect "$label: unique calls match grep" "$(rec_get "$rec" 'r["calls"]["unique"]')" "$(count_unique "$trace")"
    check "$label: calls by name add up to the total" rec_ok "$rec" 'sum(r["calls"]["by_name"].values()) == r["calls"]["total"]'
    check "$label: categories add up to the total" rec_ok "$rec" 'sum(r["categories"].values()) == r["calls"]["total"]'
    expect "$label: failed calls match grep" "$(rec_get "$rec" 'r["failures"]["failed"]')" "$(count_failed "$trace")"
    expect "$label: open calls match grep" "$(rec_get "$rec" 'r["files"]["opens"]')" "$(count_opens "$trace")"
    check "$label: failed + read-only + write opens add up" rec_ok "$rec" \
        'r["files"]["opens_failed"] + r["files"]["read_only"] + r["files"]["for_write"] == r["files"]["opens"]'
    expect "$label: process count matches the distinct pids" "$(rec_get "$rec" 'r["processes"]["count"]')" "$(count_pids "$trace")"
    expect "$label: processes created match grep" "$(rec_get "$rec" 'r["processes"]["created"]')" "$(count_made "$trace")"
    expect "$label: programs started match grep" "$(rec_get "$rec" 'sum(r["processes"]["programs"].values())')" "$(count_execok "$trace")"
    check "$label: exits account for every process" rec_ok "$rec" \
        'r["processes"]["exited_ok"] + r["processes"]["exited_badly"] + r["processes"]["no_exit_seen"] == r["processes"]["count"]'
    expect "$label: timed calls match grep" "$(rec_get "$rec" 'r["timing"]["timed_calls"]')" "$(count_timed "$trace")"
    check "$label: the record shows basic_ops wrote one file and deleted it" rec_ok "$rec" \
        'r["files"]["written"] == ["/tmp/processx_demo.txt"] and [(c["action"], c["path"]) for c in r["files"]["changes"]] == [("delete", "/tmp/processx_demo.txt")]'
    check "$label: the record shows basic_ops ran /bin/echo as its one child" rec_ok "$rec" \
        'r["processes"]["count"] == 2 and r["processes"]["created"] == 1 and "/bin/echo" in r["processes"]["programs"] and any(p.endswith("basic_ops.out") for p in r["processes"]["programs"])'
}

echo "1. Tools and project files"
check "python3 is installed" command -v python3
check "Python is 3.10 or newer" python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'
check "strace is installed" command -v strace
check "gcc is installed" command -v gcc
for f in test_programs/basic_ops.c traces/sample_basic_ops.trace check_phase1.sh \
         src/trace_parser.py src/trace_stats.py src/analyze.py \
         src/features.py src/file_features.py src/process_features.py src/failure_timing.py \
         src/feature_record.py src/stability.py; do
    check "$f is present" test -s "$f"
done
if [ "$FAILED" -ne 0 ]; then summary; exit 1; fi

echo
echo "2. Run the program: analyze.py run saves a trace and a feature record"
rm -f test_programs/basic_ops.out /tmp/processx_demo.txt
if gcc -Wall -o test_programs/basic_ops.out test_programs/basic_ops.c; then
    pass "basic_ops.c compiled"
else
    fail "basic_ops.c did not compile"; summary; exit 1
fi
OUT=$(python3 src/analyze.py run ./test_programs/basic_ops.out 2>&1)
STATUS=$?
expect "analyze.py run finished with exit code 0" "$STATUS" 0
expect "no Python crash (Traceback) in the output" "$(echo "$OUT" | grep -c 'Traceback')" 0
TRACE=$(echo "$OUT" | sed -n 's/^ Trace file: //p')
RECORD=$(echo "$OUT" | sed -n 's/^ Feature record: //p')
check "the raw trace was saved ($TRACE)" test -s "$TRACE"
check "the feature record was saved ($RECORD)" test -s "$RECORD"
expect "the record sits next to its trace, with the same name" "${RECORD%.json}" "${TRACE%.trace}"

echo
echo "3. The record of that fresh run agrees with independent shell counts"
check_record "$RECORD" "$TRACE" "fresh run"

echo
echo "4. The same checks on the saved sample trace"
SAMPLE=traces/sample_basic_ops.trace
python3 src/feature_record.py "$SAMPLE" "$WORK/sample.json" >/dev/null 2>&1
check "feature_record.py wrote a record for the sample" test -s "$WORK/sample.json"
check_record "$WORK/sample.json" "$SAMPLE" "sample"

echo
echo "5. Each feature module agrees with the others"
TOTAL=$(count_calls "$SAMPLE")
for m in features file_features process_features failure_timing feature_record; do
    if [ "$m" = feature_record ]; then ARGS=("$SAMPLE" "$WORK/again.json"); else ARGS=("$SAMPLE"); fi
    OUT=$(python3 "src/$m.py" "${ARGS[@]}" 2>&1)
    STATUS=$?
    expect "$m.py finished with exit code 0" "$STATUS" 0
    expect "$m.py printed no Traceback" "$(echo "$OUT" | grep -c 'Traceback')" 0
    printf -v "OUT_$m" '%s' "$OUT"
done
expect "features.py: categories add up to all $TOTAL calls" \
    "$(echo "$OUT_features" | nums | awk -v t="$TOTAL" '{print ($1 == $2 && $1 == t) ? "ok" : "bad"}')" ok
expect "file_features.py: successful opens = read-only + for writing = placed" \
    "$(echo "$OUT_file_features" | nums | awk '{print ($1 == $2 + $3 && $1 == $4) ? "ok" : "bad"}')" ok
expect "process_features.py: exits account for every process" \
    "$(echo "$OUT_process_features" | nums | awk '{print ($1 + $2 + $3 == $4 && $4 == $5) ? "ok" : "bad"}')" ok
expect "failure_timing.py: timed + untimed calls = all $TOTAL calls" \
    "$(echo "$OUT_failure_timing" | nums | awk -v t="$TOTAL" '{print ($1 + $2 == $3 && $3 == t) ? "ok" : "bad"}')" ok
expect "failure_timing.py reports the same failed calls as grep" \
    "$(echo "$OUT_failure_timing" | sed -n 's/^FAILED CALLS: \([0-9]*\) of.*/\1/p')" "$(count_failed "$SAMPLE")"
expect "process_features.py reports the same process count as grep" \
    "$(echo "$OUT_process_features" | sed -n 's/^PROCESSES: //p')" "$(count_pids "$SAMPLE")"

echo
echo "6. Records are repeatable"
python3 src/feature_record.py "$SAMPLE" "$WORK/a.json" >/dev/null 2>&1
python3 src/feature_record.py "$SAMPLE" "$WORK/b.json" >/dev/null 2>&1
check "the same trace gives a byte-identical record twice" cmp "$WORK/a.json" "$WORK/b.json"
python3 src/feature_record.py "$TRACE" "$WORK/rebuilt.json" >/dev/null 2>&1
check "rebuilding the fresh run's record gives the saved record" cmp "$WORK/rebuilt.json" "$RECORD"

echo
echo "7. Running the program several times (stability.py)"
before=$(ls -d traces/runs/stability_* 2>/dev/null | wc -l | tr -d ' ')
OUT=$(python3 src/stability.py --runs 3 ./test_programs/basic_ops.out 2>&1)
STATUS=$?
expect "stability.py finished with exit code 0" "$STATUS" 0
expect "no Python crash (Traceback) in the output" "$(echo "$OUT" | grep -c 'Traceback')" 0
DIR=$(echo "$OUT" | sed -n 's/^Traces and records are saved in \(.*\)\/$/\1/p')
expect "it saved 3 traces" "$(ls "$DIR"/run*.trace 2>/dev/null | wc -l | tr -d ' ')" 3
expect "it saved 3 feature records" "$(ls "$DIR"/run*.json 2>/dev/null | wc -l | tr -d ' ')" 3
for n in 1 2 3; do
    expect "run $n: the printed call count matches grep" \
        "$(echo "$OUT" | sed -n "s/^  run $n\/3 *\([0-9]*\) calls.*/\1/p")" "$(count_calls "$DIR/run$n.trace")"
done
SAME=$(echo "$OUT" | sed -n 's/^  runs identical to each other (timing aside): \([0-9]*\) of 3/\1/p')
check "at least 2 of the 3 runs were identical to each other (basic_ops is deterministic)" test "${SAME:-0}" -ge 2
check "the report lists the sections and the timing spread" bash -c 'echo "$1" | grep -q "^BY SECTION" && echo "$1" | grep -q "^TIMING"' _ "$OUT"
case "$DIR" in traces/runs/stability_*) rm -rf "$DIR" ;; esac
expect "(cleanup) the experiment folder was removed" "$(ls -d traces/runs/stability_* 2>/dev/null | wc -l | tr -d ' ')" "$before"

echo
echo "8. Mistakes are reported clearly, not with a crash"
for m in features file_features process_features failure_timing feature_record; do
    OUT=$(python3 "src/$m.py" no_such_file.trace 2>&1)
    STATUS=$?
    expect "$m.py: a missing trace gives exit code 1" "$STATUS" 1
    expect "$m.py: ...with a readable message and no Traceback" \
        "$(echo "$OUT" | grep -c 'Trace file not found: no_such_file.trace')$(echo "$OUT" | grep -c 'Traceback')" 10
done
OUT=$(python3 src/feature_record.py "$SAMPLE" "$WORK/not_json.txt" 2>&1)
STATUS=$?
expect "feature_record.py refuses an output name that does not end in .json" "$STATUS" 1
check "...and creates nothing" test ! -e "$WORK/not_json.txt"
OUT=$(python3 src/stability.py 2>&1)
STATUS=$?
expect "stability.py with no program shows usage (exit code 2)" "$STATUS" 2
expect "...and the usage text" "$(echo "$OUT" | grep -c 'Usage:')" 1
before=$(ls -d traces/runs/stability_* 2>/dev/null | wc -l | tr -d ' ')
OUT=$(python3 src/stability.py --runs 2 ./no_such_program_xyz 2>&1)
STATUS=$?
check "stability.py with a program that does not exist fails cleanly" test "$STATUS" -ne 0
expect "...without a Traceback" "$(echo "$OUT" | grep -c 'Traceback')" 0
expect "...and without leaving a folder behind" "$(ls -d traces/runs/stability_* 2>/dev/null | wc -l | tr -d ' ')" "$before"

echo
echo "9. Phase 1 still works"
check "check_phase1.sh still passes" bash check_phase1.sh

summary
[ "$FAILED" -eq 0 ]
