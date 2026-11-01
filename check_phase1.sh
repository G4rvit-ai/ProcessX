#!/usr/bin/env bash
# check_phase1.sh - end-to-end check of the ProcessX Phase 1 pipeline.
#
#   test program -> strace -> raw trace -> parser -> statistics -> report
#
# Usage:  bash check_phase1.sh
# It rebuilds the test program from source, runs the whole chain, and prints
# PASS or FAIL for every check. Counts are double-checked with plain shell
# tools (grep/awk), so Python is never grading its own homework.

cd "$(dirname "$0")" || exit 1

PASSED=0
FAILED=0

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
        echo "ALL $PASSED CHECKS PASSED: the Phase 1 pipeline works end to end."
    else
        echo "$FAILED of $((PASSED + FAILED)) CHECKS FAILED. Read the FAIL lines above."
    fi
}

# Independent counts straight from a raw trace file (no Python involved).
CALLS='^[0-9]+ +[0-9:.]+ [a-z_0-9]+\('
count_calls()  { grep -cE "$CALLS" "$1"; }
count_unique() { grep -oE "$CALLS" "$1" | awk '{print $NF}' | sort -u | wc -l | tr -d ' '; }

# Pull numbers out of a printed report.
report_total()     { echo "$1" | awk '/Total system calls/ {print $NF}'; }
report_unique()    { echo "$1" | awk '/Unique system calls/ {print $NF}'; }
report_processes() { echo "$1" | awk '/Processes \.+/ {print $NF}'; }
report_pid_sum()   { echo "$1" | awk '/^   pid [0-9]+ +[0-9]+ calls/ {s += $3} END {print s + 0}'; }
report_matches()   { echo "$1" | grep -cE "$2"; }

echo "1. Tools and project files"
check "strace is installed" command -v strace
check "gcc is installed" command -v gcc
check "python3 is installed" command -v python3
check "Python is 3.10 or newer" python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'
for f in test_programs/basic_ops.c src/trace_parser.py src/trace_stats.py src/analyze.py traces/sample_basic_ops.trace; do
    check "$f is present" test -s "$f"
done
if [ "$FAILED" -ne 0 ]; then summary; exit 1; fi

echo
echo "2. Build the test program from source"
rm -f test_programs/basic_ops.out
if gcc -Wall -o test_programs/basic_ops.out test_programs/basic_ops.c && [ -x test_programs/basic_ops.out ]; then
    pass "basic_ops.c compiled into test_programs/basic_ops.out"
else
    fail "basic_ops.c did not compile (the gcc messages above say why)"
    summary
    exit 1
fi

echo
echo "3. Run the whole chain: program -> strace -> parser -> statistics -> report"
rm -f /tmp/processx_demo.txt
OUT=$(python3 src/analyze.py run ./test_programs/basic_ops.out 2>&1)
STATUS=$?
expect "analyze.py run finished with exit code 0" "$STATUS" 0
expect "no Python crash (Traceback) in the output" "$(report_matches "$OUT" 'Traceback')" 0
expect "the traced program itself exited with code 0" "$(report_matches "$OUT" 'PROGRAM OUTPUT \(exit code 0\)')" 1

GOT=$(echo "$OUT" | awk '/^PROGRAM OUTPUT/ {f = 1; next} /^=+$/ {f = 0} f && NF {sub(/^ +/, ""); print}')
WANT=$'file written\nfile read\nhello from the child process\nchild finished\nfile deleted'
expect "the program printed its 5 lines, in order" "$GOT" "$WANT"
check "the program deleted its own demo file" test ! -e /tmp/processx_demo.txt

TRACE=$(echo "$OUT" | sed -n 's/^ Trace file: //p')
check "the raw trace was saved ($TRACE)" test -s "$TRACE"
expect "the parser understood every line of the trace" "$(report_matches "$OUT" 'not understood: 0\)')" 1
expect "the report found 2 processes (parent and child)" "$(report_processes "$OUT")" 2
expect "the parent process is basic_ops.out" "$(report_matches "$OUT" '^   pid [0-9]+ +[0-9]+ calls   \./test_programs/basic_ops\.out$')" 1
expect "the child process is /bin/echo" "$(report_matches "$OUT" '^   pid [0-9]+ +[0-9]+ calls   /bin/echo$')" 1
expect "per-process call counts add up to the total" "$(report_pid_sum "$OUT")" "$(report_total "$OUT")"
expect "total system calls matches an independent grep count" "$(report_total "$OUT")" "$(count_calls "$TRACE")"
expect "unique system calls matches an independent grep count" "$(report_unique "$OUT")" "$(count_unique "$TRACE")"

echo
echo "4. The OS behavior is visible in the trace"
check "file creation: openat(... O_CREAT) on the demo file" grep -qE 'openat\(.*processx_demo\.txt.*O_CREAT' "$TRACE"
check "process creation: clone/fork" grep -qE ' (clone3?|fork|vfork)\(' "$TRACE"
check "program execution: the child execve's /bin/echo" grep -q 'execve("/bin/echo"' "$TRACE"
check "process waiting: wait4/waitid" grep -qE ' (wait4|waitid)\(' "$TRACE"
check "file deletion: unlink on the demo file" grep -qE 'unlink(at)?\(.*processx_demo\.txt' "$TRACE"

echo
echo "5. The saved sample trace (traces/sample_basic_ops.trace)"
SAMPLE=traces/sample_basic_ops.trace
OUT=$(python3 src/analyze.py show "$SAMPLE" 2>&1)
STATUS=$?
expect "analyze.py show finished with exit code 0" "$STATUS" 0
expect "the parser understood every line of the sample" "$(report_matches "$OUT" 'not understood: 0\)')" 1
expect "total matches an independent grep count" "$(report_total "$OUT")" "$(count_calls "$SAMPLE")"
expect "unique matches an independent grep count" "$(report_unique "$OUT")" "$(count_unique "$SAMPLE")"
expect "trace_stats.py agrees with analyze.py" "$(python3 src/trace_stats.py "$SAMPLE" | awk '/Total system calls/ {print $NF}')" "$(report_total "$OUT")"
expect "trace_parser.py reports PASS" "$(python3 src/trace_parser.py "$SAMPLE" | grep -c '^PASS: every line was understood')" 1

echo
echo "6. Mistakes are reported clearly, not with a crash"
OUT=$(python3 src/analyze.py show no_such_file.trace 2>&1)
STATUS=$?
expect "a missing trace file gives exit code 1" "$STATUS" 1
expect "...with a readable message" "$(report_matches "$OUT" 'Trace file not found: no_such_file.trace')" 1
expect "...and no Python Traceback" "$(report_matches "$OUT" 'Traceback')" 0

summary
[ "$FAILED" -eq 0 ]
