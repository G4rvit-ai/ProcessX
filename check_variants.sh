#!/usr/bin/env bash
# check_variants.sh - does the score notice deliberately odd behaviour?
#
#   10 normal runs of test_programs/variants.c -> a baseline
#   normal runs must NOT raise an alarm; each of five odd modes must score clearly
#   above normal, show its own finding, and leave evidence in the raw strace trace;
#   the sixth mode (a local socket, not the network) must NOT be reported as network use.
#
# Usage:  bash check_variants.sh
# The evidence is found with grep on the raw trace, so Python never grades its own homework.

cd "$(dirname "$0")" || exit 1

PASSED=0
FAILED=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; rm -f "$HOME/processx_variant.txt" /tmp/processx_variants.txt' EXIT

pass() { echo "  PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }

# expect "what" "actual" "wanted"     passes when the two are equal
expect() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got: $2   wanted: $3)"; fi
}

# at_least "what" number minimum  /  at_most "what" number maximum
at_least() {
    if [ "$2" -ge "$3" ] 2>/dev/null; then pass "$1 ($2)"; else fail "$1 (got: ${2:-nothing}   wanted at least: $3)"; fi
}
at_most() {
    if [ "$2" -le "$3" ] 2>/dev/null; then pass "$1 ($2)"; else fail "$1 (got: ${2:-nothing}   wanted at most: $3)"; fi
}

summary() {
    echo
    if [ "$FAILED" -eq 0 ]; then
        echo "ALL $PASSED CHECKS PASSED: odd variants score clearly above normal, normal runs stay quiet, and a local socket is not mistaken for the network."
    else
        echo "$FAILED of $((PASSED + FAILED)) CHECKS FAILED. Read the FAIL lines above."
    fi
}

# ---- reading what compare.py printed -------------------------------------------------
score_of()   { sed -n 's/^SCORE: \([0-9]*\) of 100 - .*/\1/p' "$1" | head -1; }
level_of()   { sed -n 's/^SCORE: [0-9]* of 100 - \(.*\)$/\1/p' "$1" | head -1; }
trace_of()   { sed -n 's/^The raw run (trace and record) is in \(.*\)\/$/\1\/run.trace/p' "$1" | head -1; }
score_block() {   # only the SCORE part of the output, not the detailed lists below it
    awk '/^SCORE:/ {on = 1} on && /^(NEVER SEEN|MORE THAN|LESS THAN|USUALLY THERE|This run matches|These are differences|The raw run)/ {exit} on' "$1"
}

ROWS=""
# run_mode MODE   runs compare.py on the program in that mode; sets MODE OUT SCORE LEVEL TRACE
run_mode() {
    MODE=$1
    OUT="$WORK/$MODE.txt"
    python3 src/compare.py variants "$PROG" "$MODE" > "$OUT" 2>&1
    SCORE=$(score_of "$OUT")
    LEVEL=$(level_of "$OUT")
    TRACE=$(trace_of "$OUT")
    ROWS="$ROWS$(printf '  %-10s %5s   %s' "$MODE" "${SCORE:-?}" "$LEVEL")"$'\n'
}
# finding "text"     the score must give this reason     /     no_finding "text"     it must not
finding() {
    if score_block "$OUT" | grep -qF -- "$1"; then pass "$MODE: the score says \"$1\""; else fail "$MODE: the score does not say \"$1\""; fi
}
no_finding() {
    if score_block "$OUT" | grep -qF -- "$1"; then fail "$MODE: the score wrongly says \"$1\""; else pass "$MODE: the score does not say \"$1\""; fi
}
# evidence "what it shows" 'regex'     the raw trace must match this (grep, not Python)
evidence() {
    local n
    n=$(grep -cE -- "$2" "$TRACE" 2>/dev/null)
    at_least "$MODE: the raw trace shows $1" "${n:-0}" 1
}
# sockets_match     the socket counts in the saved record must equal what grep finds in the raw trace
SOCKETS='^[0-9]+ +[0-9:.]+ (socket|socketpair)\('
sockets_match() {
    local rec="${TRACE%.trace}.json" internet local_n total
    internet=$(grep -cE "${SOCKETS}AF_(INET6?|PACKET)," "$TRACE")
    local_n=$(grep -cE "${SOCKETS}AF_UNIX," "$TRACE")
    total=$(grep -cE "$SOCKETS" "$TRACE")
    expect "$MODE: the record counts sockets (internet, local, other) the way grep does" \
        "$(python3 -c 'import json, sys; s = json.load(open(sys.argv[1]))["calls"]["sockets"]; print(s["internet"], s["local"], s["other"])' "$rec" 2>&1)" \
        "$internet $local_n $((total - internet - local_n))"
}

echo "0. Tools"
for tool in gcc strace python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "  Missing tool: $tool (install it first)"
        exit 1
    fi
done
if ! grep -q "from score import" src/compare.py 2>/dev/null; then
    echo "  compare.py does not print the score yet. Finish Phase 3 step 3 first."
    exit 1
fi
pass "gcc, strace and python3 are installed, and compare.py prints the score"

echo
echo "1. The test program"
PROG=test_programs/variants.out
if [ ! -f test_programs/variants.c ]; then
    echo "  test_programs/variants.c is missing."
    exit 1
fi
expect "variants.c compiles without a single warning" "$(gcc -Wall -Wextra -o "$PROG" test_programs/variants.c 2>&1)" ""
expect "normal mode exits 0" "$("$PROG" >/dev/null 2>&1; echo $?)" 0
for mode in secret homewrite spawn net local; do
    expect "$mode mode exits 0" "$("$PROG" "$mode" >/dev/null 2>&1; echo $?)" 0
done
expect "crash mode dies with a segmentation fault (exit 139)" "$( { "$PROG" crash >/dev/null 2>&1; echo $?; } 2>/dev/null )" 139
expect "an unknown mode is refused (exit 2)" "$("$PROG" nonsense >/dev/null 2>&1; echo $?)" 2
expect "no file is left behind in /tmp or your home folder" \
    "$(ls /tmp/processx_variants.txt "$HOME/processx_variant.txt" 2>/dev/null | wc -l | tr -d ' ')" 0

echo
echo "2. A baseline from 10 normal runs"
OUT=$(python3 src/baseline.py build --name variants "$PROG" 2>&1)
expect "the baseline is built from 10 runs, all identical" \
    "$(echo "$OUT" | grep -c 'Baseline: variants   (10 runs, 10 of them identical)')" 1
expect "the normal runs never touch /etc/passwd (so reading it really is new)" \
    "$(grep -lE '"/etc/passwd"' traces/runs/baseline_variants_*/run*.trace 2>/dev/null | wc -l | tr -d ' ')" 0

echo
echo "3. Normal runs must not raise an alarm"
for i in 1 2 3 4 5; do
    python3 src/compare.py variants > "$WORK/normal$i.txt" 2>&1
    at_most "a fresh normal run ($i of 5) scores no more than 2" "$(score_of "$WORK/normal$i.txt")" 2
done
ROWS="$ROWS$(printf '  %-10s %5s   %s' "normal" "$(score_of "$WORK/normal1.txt")" "$(level_of "$WORK/normal1.txt")")"$'\n'
expect "a normal run starts exactly 2 programs (variants.out and /bin/echo)" \
    "$(grep -cE '^[0-9]+ +[0-9:.]+ execve\(' "$(trace_of "$WORK/normal1.txt")")" 2
MODE=normal
TRACE=$(trace_of "$WORK/normal1.txt")
sockets_match
expect "a normal run creates no socket at all" "$(grep -cE "$SOCKETS" "$TRACE")" 0

echo
echo "4. secret: reads /etc/passwd"
run_mode secret
at_least "secret: the score is clearly above normal" "$SCORE" 8
finding "read /etc/passwd (a sensitive file)"
no_finding "used the network"
no_finding "started /"
no_finding "killed by"
evidence "/etc/passwd being opened" 'openat\(.*"/etc/passwd"'

echo
echo "5. homewrite: writes a file in the home folder, then deletes it"
run_mode homewrite
at_least "homewrite: the score is clearly above normal" "$SCORE" 6
finding "processx_variant.txt (in your home folder)"
finding "file change: delete"
no_finding "used the network"
no_finding "sensitive file"
evidence "the file being created for writing" 'openat\(.*processx_variant\.txt.*O_WRONLY'
evidence "the file being deleted" 'unlink(at)?\(.*processx_variant\.txt'

echo
echo "6. spawn: starts three programs the normal mode never starts"
run_mode spawn
at_least "spawn: the score is clearly above normal" "$SCORE" 12
finding "started /bin/date"
finding "started /bin/uname"
finding "started /bin/true"
no_finding "used the network"
no_finding "sensitive file"
evidence "/bin/date being started" 'execve\("/bin/date"'
evidence "/bin/uname being started" 'execve\("/bin/uname"'
evidence "/bin/true being started" 'execve\("/bin/true"'
expect "spawn: 5 programs were started in all" "$(grep -cE '^[0-9]+ +[0-9:.]+ execve\(' "$TRACE")" 5

echo
echo "7. net: connects to 127.0.0.1 port 9 (this computer only)"
run_mode net
at_least "net: the score is clearly above normal" "$SCORE" 10
finding "used the network"
no_finding "started /"
no_finding "killed by"
no_finding "sensitive file"
evidence "an internet socket being created" 'socket\(AF_INET,'
evidence "a connection to port 9" 'connect\(.*htons\(9\)'
sockets_match
expect "net: exactly 1 internet socket was created" "$(grep -cE "${SOCKETS}AF_INET," "$TRACE")" 1

echo
echo "8. local: a local socket (to a program on this computer), which is not the network"
run_mode local
at_most "local: the score stays low" "$SCORE" 5
no_finding "used the network"
no_finding "started /"
no_finding "killed by"
no_finding "sensitive file"
evidence "a local socket being created" 'socket\(AF_UNIX,'
evidence "the connect failing: no such socket file" 'connect\(.*processx_no_such_socket.*ENOENT'
expect "local: the raw trace has no internet socket" "$(grep -cE "${SOCKETS}AF_(INET6?|PACKET)," "$TRACE")" 0
sockets_match
expect "local: exactly 1 local socket was created" "$(grep -cE "${SOCKETS}AF_UNIX," "$TRACE")" 1

echo
echo "9. crash: dies with a segmentation fault"
run_mode crash
at_least "crash: the score is clearly above normal" "$SCORE" 10
finding "killed by SIGSEGV"
no_finding "used the network"
no_finding "started /"
no_finding "sensitive file"
evidence "the process being killed by SIGSEGV" '\+\+\+ killed by SIGSEGV'

echo
echo "10. Nothing was left behind"
expect "no file is left in /tmp or your home folder after the odd runs" \
    "$(ls /tmp/processx_variants.txt "$HOME/processx_variant.txt" 2>/dev/null | wc -l | tr -d ' ')" 0

echo
echo "Scores (normal stays at 2 or less; the odd modes score clearly above that, except local, which is not the network):"
printf '%s' "$ROWS"

summary
[ "$FAILED" -eq 0 ]
