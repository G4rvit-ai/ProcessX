#!/usr/bin/env bash
# check_phase3.sh - checks all of Phase 3 in one go: baselines, comparing, the score, sockets.
#
# It builds small test programs of its own, then checks what baseline.py, compare.py and
# score.py say against the raw strace traces, using grep and awk (not Python), so the
# project never grades its own homework. At the end it runs the earlier check scripts too.
#
# The score checks use the weights from score.py as they were delivered. If you change
# the weights on purpose, the numbers in section 8 change with them.
#
# Usage:  bash check_phase3.sh        (takes under a minute)

cd "$(dirname "$0")" || exit 1

PASSED=0
FAILED=0
WORK=$(mktemp -d)

clean_up_files() {
    rm -f baselines/check3_*.json /tmp/check3_steady.txt /tmp/check3_counter
    rm -rf traces/runs/baseline_check3_* traces/runs/compare_check3_*
}
clean_up_files
trap 'clean_up_files; rm -rf "$WORK"' EXIT

pass() { echo "  PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }

# expect "what" "actual" "wanted"     passes when the two are equal
expect() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got: $2   wanted: $3)"; fi
}
at_least() {
    if [ "$2" -ge "$3" ] 2>/dev/null; then pass "$1 ($2)"; else fail "$1 (got: ${2:-nothing}   wanted at least: $3)"; fi
}
at_most() {
    if [ "$2" -le "$3" ] 2>/dev/null; then pass "$1 ($2)"; else fail "$1 (got: ${2:-nothing}   wanted at most: $3)"; fi
}
# contains "what" file "text"     passes when the file has that text (exact, not a pattern)
contains() {
    if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (the output does not contain: $3)"; fi
}
lacks() {
    if grep -qF -- "$3" "$2"; then fail "$1 (the output wrongly contains: $3)"; else pass "$1"; fi
}

summary() {
    echo
    if [ "$FAILED" -eq 0 ]; then
        echo "ALL $PASSED CHECKS PASSED: Phase 3 works, and the earlier phases still do."
    else
        echo "$FAILED of $((PASSED + FAILED)) CHECKS FAILED. Read the FAIL lines above."
    fi
}

# ---- reading raw traces (grep and awk only) -------------------------------------------
CALLS='^[0-9]+ +[0-9:.]+ [a-z_0-9]+\('
SOCKETS='^[0-9]+ +[0-9:.]+ (socket|socketpair)\('
INTERNET="${SOCKETS}AF_(INET6?|PACKET),"
count_calls() { grep -cE "$CALLS" "$1"; }

# name_ranges TRACE...   prints "name lowest highest" for every system call name: how often it was
# called per run, lowest and highest over the traces given
name_ranges() {
    awk '
        match($0, /^[0-9]+ +[0-9:.]+ [a-z_0-9]+\(/) {
            name = substr($0, RSTART, RLENGTH - 1)
            sub(/^[0-9]+ +[0-9:.]+ /, "", name)
            seen[name] = 1; files[FILENAME] = 1; n[FILENAME, name]++
        }
        END {
            for (name in seen) {
                low = -1; high = 0
                for (f in files) { c = n[f, name] + 0; if (low < 0 || c < low) low = c; if (c > high) high = c }
                print name, low, high
            }
        }' "$@"
}

# ---- reading a baseline file (indented JSON, one feature per block) -------------------
# bl_get FILE "feature name" min|max|present
bl_get() {
    awk -v name="    \"$2\": {" -v key="\"$3\":" '
        substr($0, 1, 5) == "    \"" { on = ($0 == name) }
        on && index($0, key) { v = $2; gsub(/,/, "", v); print v; exit }' "$1"
}
bl_feature_count() {
    awk '/^  "features": \{/ {on = 1; next} on && /^  \}/ {on = 0} on && /^    "/ {n++} END {print n + 0}' "$1"
}

# ---- reading what compare.py printed --------------------------------------------------
score_of()   { sed -n 's/^SCORE: \([0-9]*\) of 100 - .*/\1/p' "$1" | head -1; }
level_of()   { sed -n 's/^SCORE: [0-9]* of 100 - \(.*\)$/\1/p' "$1" | head -1; }
trace_of()   { sed -n 's/^The raw run (trace and record) is in \(.*\)\/$/\1\/run.trace/p' "$1" | head -1; }
score_block() {
    awk '/^SCORE:/ {on = 1} on && /^(NEVER SEEN|MORE THAN|LESS THAN|USUALLY THERE|This run matches|These are differences|The raw run)/ {exit} on' "$1"
}
# the points listed under "Where the points come from", one per line
listed_points() {
    awk '/^  Where the points come from/ {on = 1; next} on && /^ +[0-9]+  / {print $1; next} on {exit}' "$1"
}
sum_points() { listed_points "$1" | awk '{s += $1} END {print s + 0}'; }
# 1 if the listed points ever go up from one line to the next (they must never)
points_out_of_order() { listed_points "$1" | awk 'NR > 1 && $1 > prev {bad = 1} {prev = $1} END {print bad + 0}'; }

# the words for a score, from the limits in the README: 0-2 normal, 3-9, 10-24, 25 and up
words_for() {
    if [ "$1" -le 2 ]; then echo "normal"
    elif [ "$1" -le 9 ]; then echo "slightly unusual"
    elif [ "$1" -le 24 ]; then echo "unusual"
    else echo "very unusual"; fi
}

# net_rule OUTFILE "label"
# "used the network" must be said exactly when the raw trace shows an internet socket (not a local one)
net_rule() {
    local trace n said
    trace=$(trace_of "$1")
    n=$(grep -cE "$INTERNET" "$trace")
    if score_block "$1" | grep -qF "used the network"; then said=yes; else said=no; fi
    if [ "$n" -gt 0 ]; then
        expect "$2: the trace has $n internet socket(s), so the score says \"used the network\"" "$said" yes
    else
        expect "$2: the trace has no internet socket, so the score does not say \"used the network\"" "$said" no
    fi
}
# sockets_match OUTFILE "label"     the record's socket counts must equal what grep finds in the trace
sockets_match() {
    local trace rec internet local_n total
    trace=$(trace_of "$1")
    rec="${trace%.trace}.json"
    internet=$(grep -cE "$INTERNET" "$trace")
    local_n=$(grep -cE "${SOCKETS}AF_UNIX," "$trace")
    total=$(grep -cE "$SOCKETS" "$trace")
    expect "$2: the record's socket counts (internet, local, other) match grep" \
        "$(python3 -c 'import json, sys; s = json.load(open(sys.argv[1]))["calls"]["sockets"]; print(s["internet"], s["local"], s["other"])' "$rec" 2>&1)" \
        "$internet $local_n $((total - internet - local_n))"
}

# ---------------------------------------------------------------------------------------
echo "0. Tools and files"
for tool in python3 strace awk grep sed sha256sum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "  Missing tool: $tool (install it first)"
        exit 1
    fi
done
for file in src/baseline.py src/compare.py src/score.py src/runner.py check_phase1.sh check_phase2.sh check_variants.sh test_programs/variants.c; do
    if [ ! -f "$file" ]; then
        echo "  Missing file: $file (finish the earlier Phase 3 steps first)"
        exit 1
    fi
done
if ! grep -q "calls.sockets.internet" src/score.py 2>/dev/null; then
    echo "  score.py does not know about internet sockets yet. Apply the Phase 3 step 5 patch first."
    exit 1
fi
pass "python3, strace, awk and the Phase 3 files are all there"

echo
echo "1. The test programs (made here, in a temporary folder)"
cat > "$WORK/prog.sh" <<'EOF'
#!/bin/sh
echo hello > /tmp/check3_steady.txt
cat /tmp/check3_steady.txt > /dev/null
rm -f /tmp/check3_steady.txt
if [ "$LANG" != "C" ] || [ "$LC_ALL" != "C" ] || [ -n "$FOO" ]; then
    /bin/date > /dev/null        # only if the environment is NOT the fixed one: a canary
fi
if [ "$1" = "odd" ]; then
    /bin/date > /dev/null
    cat /etc/passwd > /dev/null
fi
EOF
cat > "$WORK/varying.sh" <<'EOF'
#!/bin/sh
f=/tmp/check3_counter
n=$(cat "$f" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$f"
if [ $((n % 2)) -eq 0 ]; then
    /bin/ls /tmp > /dev/null
fi
EOF
chmod +x "$WORK/prog.sh" "$WORK/varying.sh"
expect "prog.sh runs and exits 0" "$("$WORK/prog.sh" >/dev/null 2>&1; echo $?)" 0
expect "prog.sh odd runs and exits 0" "$("$WORK/prog.sh" odd >/dev/null 2>&1; echo $?)" 0
expect "prog.sh leaves no file behind" "$(ls /tmp/check3_steady.txt 2>/dev/null | wc -l | tr -d ' ')" 0

echo
echo "2. Step 1: a baseline from 5 runs agrees with the raw traces"
OUT=$(python3 src/baseline.py build --runs 5 --name check3_steady "$WORK/prog.sh" 2>&1)
expect "baseline.py build exits 0" "$?" 0
BL=baselines/check3_steady.json
RUNDIR=$(ls -d traces/runs/baseline_check3_steady_* 2>/dev/null | head -1)
expect "the baseline file was saved" "$([ -f "$BL" ] && echo yes)" yes
expect "the baseline is valid JSON" "$(python3 -c 'import json, sys; json.load(open(sys.argv[1])); print("yes")' "$BL" 2>&1)" yes
expect "the 5 raw traces were kept" "$(ls "$RUNDIR"/run?.trace 2>/dev/null | wc -l | tr -d ' ')" 5
TOTALS=$(for t in "$RUNDIR"/run?.trace; do count_calls "$t"; done | sort -n)
expect "calls.total: lowest value = the fewest calls in any raw trace" "$(bl_get "$BL" calls.total min)" "$(echo "$TOTALS" | head -1)"
expect "calls.total: highest value = the most calls in any raw trace" "$(bl_get "$BL" calls.total max)" "$(echo "$TOTALS" | tail -1)"
UNIQUES=$(for t in "$RUNDIR"/run?.trace; do grep -oE "$CALLS" "$t" | awk '{print $NF}' | sort -u | wc -l | tr -d ' '; done | sort -n)
expect "calls.unique: lowest and highest = different call names counted in the raw traces" \
    "$(bl_get "$BL" calls.unique min) $(bl_get "$BL" calls.unique max)" "$(echo "$UNIQUES" | head -1) $(echo "$UNIQUES" | tail -1)"
BAD=""
NAMES=0
while read -r name low high; do
    NAMES=$((NAMES + 1))
    got="$(bl_get "$BL" "calls.by_name.$name" min) $(bl_get "$BL" "calls.by_name.$name" max)"
    [ "$got" = "$low $high" ] || BAD="$BAD $name(baseline: $got, traces: $low $high)"
done < <(name_ranges "$RUNDIR"/run?.trace)
expect "all $NAMES call names: baseline range = counts in the raw traces" "${BAD:-all agree}" "all agree"
expect "the baseline has no call name that the traces lack" "$(grep -c '^    "calls.by_name\.' "$BL")" "$NAMES"
expect "show says how many features the baseline holds, and the file holds that many" \
    "$(python3 src/baseline.py show check3_steady | sed -n 's/^  features     \([0-9]*\):.*/\1/p')" "$(bl_feature_count "$BL")"
expect "prog.sh itself was started in all 5 runs (raw traces)" \
    "$(grep -l "execve(\"$WORK/prog.sh\"" "$RUNDIR"/run?.trace | wc -l | tr -d ' ')" 5
expect "...and the baseline says so: present in 5 runs" "$(bl_get "$BL" "processes.programs.$WORK/prog.sh" present)" 5
expect "the file it writes: present in all 5 runs (raw traces: opened for writing 5 times)" \
    "$(bl_get "$BL" "files.written: /tmp/check3_steady.txt" present) $(grep -l 'openat(.*"/tmp/check3_steady.txt".*O_WRONLY' "$RUNDIR"/run?.trace | wc -l | tr -d ' ')" "5 5"
expect "the file it deletes: present in all 5 runs (raw traces: unlink 5 times)" \
    "$(bl_get "$BL" "files.changes: delete /tmp/check3_steady.txt" present) $(grep -lE 'unlink(at)?\(.*"/tmp/check3_steady.txt"' "$RUNDIR"/run?.trace | wc -l | tr -d ' ')" "5 5"

echo
echo "3. Step 1: the environment is fixed"
expect "the first execve line says the program got exactly 4 variables" \
    "$(grep -m1 'execve(' "$RUNDIR/run1.trace" | grep -c '/\* 4 vars \*/')" 1
expect "the baseline does not store your HOME folder" "$(grep -c '"HOME"' "$BL")" 0
expect "the baseline stores LANG=C" "$(grep -c '"LANG": "C"' "$BL")" 1
OUT=$(FOO=bar LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8 python3 src/baseline.py build --runs 3 --name check3_poison "$WORK/prog.sh" 2>&1)
PDIR=$(ls -d traces/runs/baseline_check3_poison_* 2>/dev/null | head -1)
expect "with FOO=bar and a German LANG in your own shell: the program still got 4 variables in every run" \
    "$(for t in "$PDIR"/run?.trace; do grep -m1 'execve(' "$t" | grep -c '/\* 4 vars \*/'; done | sort -u | tr '\n' ' ')" "1 "
expect "...and FOO=bar never reached the program" "$(grep -l 'FOO' "$PDIR"/run?.trace | wc -l | tr -d ' ')" 0
expect "...and the program never saw another LANG or FOO either (it would have started /bin/date)" \
    "$(grep -l 'execve("/bin/date"' "$PDIR"/run?.trace | wc -l | tr -d ' ')" 0
FOO=bar LANG=de_DE.UTF-8 strace -f -o "$WORK/leak.trace" "$WORK/prog.sh" >/dev/null 2>&1
at_least "(sanity) started straight from your shell with FOO=bar, the same program does start /bin/date" \
    "$(grep -c 'execve("/bin/date"' "$WORK/leak.trace")" 1
OUTSIDE=0
for t in "$PDIR"/run?.trace; do
    c=$(count_calls "$t")
    if [ "$c" -lt "$(echo "$TOTALS" | head -1)" ] || [ "$c" -gt "$(echo "$TOTALS" | tail -1)" ]; then OUTSIDE=$((OUTSIDE + 1)); fi
done
expect "...and every run made as many calls as in the clean baseline (the same $(echo "$TOTALS" | head -1) to $(echo "$TOTALS" | tail -1))" "$OUTSIDE" 0

echo
echo "4. Step 1: a program that behaves differently from run to run"
rm -f /tmp/check3_counter
OUT=$(python3 src/baseline.py build --runs 6 --name check3_varying "$WORK/varying.sh" 2>&1)
VBL=baselines/check3_varying.json
VDIR=$(ls -d traces/runs/baseline_check3_varying_* 2>/dev/null | head -1)
expect "/bin/ls was started in 3 of the 6 runs (raw traces)" "$(grep -l 'execve("/bin/ls"' "$VDIR"/run?.trace | wc -l | tr -d ' ')" 3
expect "the baseline says: lowest 0, highest 1, present in 3 runs" \
    "$(bl_get "$VBL" "processes.programs./bin/ls" min) $(bl_get "$VBL" "processes.programs./bin/ls" max) $(bl_get "$VBL" "processes.programs./bin/ls" present)" "0 1 3"
expect "show says \"(in 3 of 6 runs)\" next to /bin/ls" "$(python3 src/baseline.py show check3_varying | grep -c '/bin/ls.*(in 3 of 6 runs)')" 1
VTOTALS=$(for t in "$VDIR"/run?.trace; do count_calls "$t"; done | sort -n)
expect "calls.total range = fewest and most calls in the raw traces" \
    "$(bl_get "$VBL" calls.total min) $(bl_get "$VBL" calls.total max)" "$(echo "$VTOTALS" | head -1) $(echo "$VTOTALS" | tail -1)"
at_least "the busiest run made more calls than the quietest (the baseline really varies)" "$(( $(echo "$VTOTALS" | tail -1) - $(echo "$VTOTALS" | head -1) ))" 1
# a normal-looking run of the varying program (with or without ls) must stay inside the range
python3 src/compare.py check3_varying > "$WORK/v1.txt" 2>&1
python3 src/compare.py check3_varying > "$WORK/v2.txt" 2>&1
at_most "two more runs of it: the first scores no more than 2" "$(score_of "$WORK/v1.txt")" 2
at_most "two more runs of it: the second scores no more than 2" "$(score_of "$WORK/v2.txt")" 2

echo
echo "5. Step 1: bad input is refused and leaves nothing behind"
BEFORE=$(ls baselines | wc -l | tr -d ' ')
expect "--runs 2 is refused (usage, exit 2)" "$(python3 src/baseline.py build --runs 2 --name check3_bad "$WORK/prog.sh" >/dev/null 2>&1; echo $?)" 2
expect "--runs 51 is refused (usage, exit 2)" "$(python3 src/baseline.py build --runs 51 --name check3_bad "$WORK/prog.sh" >/dev/null 2>&1; echo $?)" 2
expect "--runs abc is refused (usage, exit 2)" "$(python3 src/baseline.py build --runs abc --name check3_bad "$WORK/prog.sh" >/dev/null 2>&1; echo $?)" 2
expect "a name with a space is refused" "$(python3 src/baseline.py build --name 'bad name' "$WORK/prog.sh" >/dev/null 2>&1; [ $? -ne 0 ] && echo refused)" refused
expect "a name like ../evil is refused" "$(python3 src/baseline.py build --name ../evil "$WORK/prog.sh" >/dev/null 2>&1; [ $? -ne 0 ] && echo refused)" refused
expect "...and no evil.json was written outside the baselines folder" "$([ -e evil.json ] && echo written || echo none)" none
expect "a program that does not exist is refused" "$(python3 src/baseline.py build --name check3_nope /nonexistent/program >/dev/null 2>&1; [ $? -ne 0 ] && echo refused)" refused
expect "...and leaves no baseline file" "$([ -e baselines/check3_nope.json ] && echo written || echo none)" none
expect "...and no run folder" "$(ls -d traces/runs/baseline_check3_nope_* 2>/dev/null | wc -l | tr -d ' ')" 0
expect "the number of saved baselines did not change" "$(ls baselines | wc -l | tr -d ' ')" "$BEFORE"

echo
echo "6. Step 2: comparing a new run with the baseline"
BL_SUM=$(sha256sum "$BL" | cut -d' ' -f1)
for i in 1 2 3; do
    python3 src/compare.py check3_steady > "$WORK/n$i.txt" 2>&1
    at_most "a fresh normal run ($i of 3) scores no more than 2" "$(score_of "$WORK/n$i.txt")" 2
done
contains "a run that matches says so" "$WORK/n1.txt" "This run matches the baseline"
python3 src/compare.py check3_steady "$WORK/prog.sh" odd > "$WORK/odd.txt" 2>&1
OTRACE=$(trace_of "$WORK/odd.txt")
ORECORD="${OTRACE%.trace}.json"
at_least "the odd run (reads /etc/passwd, starts /bin/date) scores at least 12 (8 + 4)" "$(score_of "$WORK/odd.txt")" 12
contains "the odd run is called out as different from the baseline command" "$WORK/odd.txt" "this is not the command the baseline was built from"
contains "the score says: read /etc/passwd (a sensitive file)" "$WORK/odd.txt" "read /etc/passwd (a sensitive file)"
contains "the score says: started /bin/date" "$WORK/odd.txt" "started /bin/date"
at_least "the raw trace of the odd run shows /etc/passwd being opened" "$(grep -cE 'openat\(.*"/etc/passwd"' "$OTRACE")" 1
at_least "the raw trace of the odd run shows /bin/date being started" "$(grep -c 'execve("/bin/date"' "$OTRACE")" 1
expect "none of the baseline's raw traces opens /etc/passwd or starts /bin/date (so both really are new)" \
    "$(grep -lE '"/etc/passwd"|execve\("/bin/date"' "$RUNDIR"/run?.trace | wc -l | tr -d ' ')" 0
expect "the saved record of the odd run has the same call total as the raw trace" \
    "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["calls"]["total"])' "$ORECORD" 2>&1)" "$(count_calls "$OTRACE")"
# the same record, compared again later with --record, must give exactly the same answer
python3 src/compare.py --record "$ORECORD" check3_steady > "$WORK/odd_again.txt" 2>&1
expect "--record gives the same score as the live run" "$(score_of "$WORK/odd_again.txt")" "$(score_of "$WORK/odd.txt")"
expect "--record gives the same report as the live run (apart from the lines about running it)" \
    "$(awk '/^RESULT/ {on = 1} /^The raw run/ {on = 0} on && NF' "$WORK/odd_again.txt" | md5sum)" \
    "$(awk '/^RESULT/ {on = 1} /^The raw run/ {on = 0} on && NF' "$WORK/odd.txt" | md5sum)"

echo
echo "7. Step 2: errors, and the baseline file is never changed"
expect "compare.py with no arguments prints the usage (exit 2)" "$(python3 src/compare.py >/dev/null 2>&1; echo $?)" 2
python3 src/compare.py check3_does_not_exist > "$WORK/e1.txt" 2>&1
expect "an unknown baseline is refused" "$(grep -c 'Baseline not found' "$WORK/e1.txt")" 1
contains "...and the saved baselines are listed" "$WORK/e1.txt" "check3_steady"
python3 src/compare.py --record "$BL" check3_steady > "$WORK/e2.txt" 2>&1
contains "a baseline file is refused as a feature record" "$WORK/e2.txt" "as a feature record"
python3 src/compare.py --record /nonexistent/record.json check3_steady > "$WORK/e3.txt" 2>&1
contains "a record file that does not exist is refused" "$WORK/e3.txt" "Could not read"
expect "--record together with a program to run is refused (exit 2)" "$(python3 src/compare.py --record "$ORECORD" check3_steady "$WORK/prog.sh" >/dev/null 2>&1; echo $?)" 2
python3 -c 'import json, sys; b = json.load(open(sys.argv[1])); b["command"] = []; json.dump(b, open(sys.argv[2], "w"))' "$BL" "$WORK/nocommand.json"
python3 src/compare.py "$WORK/nocommand.json" > "$WORK/e4.txt" 2>&1
contains "a baseline with an empty command is refused" "$WORK/e4.txt" "no usable 'command'"
python3 -c 'import json, sys; b = json.load(open(sys.argv[1])); b["environment"] = {"LANG": "C"}; json.dump(b, open(sys.argv[2], "w"))' "$BL" "$WORK/otherenv.json"
python3 src/compare.py "$WORK/otherenv.json" > "$WORK/e5.txt" 2>&1
contains "a baseline built with other environment settings produces a warning" "$WORK/e5.txt" "built with different environment settings"
expect "after all these comparisons the baseline file is byte for byte unchanged" "$(sha256sum "$BL" | cut -d' ' -f1)" "$BL_SUM"

echo
echo "8. Step 3: the score is explainable"
expect "the points listed add up to the score (odd run)" "$(sum_points "$WORK/odd.txt")" "$(score_of "$WORK/odd.txt")"
expect "the points are listed biggest first (odd run)" "$(points_out_of_order "$WORK/odd.txt")" 0
expect "the level word fits the score (odd run)" "$(level_of "$WORK/odd.txt")" "$(words_for "$(score_of "$WORK/odd.txt")")"
contains "a score above 2 says that unusual does not mean harmful" "$WORK/odd.txt" "It does not mean harmful"
lacks "a score of 0 does not say it" "$WORK/n1.txt" "It does not mean harmful"
expect "a normal run is called normal" "$(level_of "$WORK/n1.txt")" "normal"
# Records made by adding files to a normal run. Written: a file in /opt is worth 5 points, one in /tmp 2 points.
# Read: a file in a library folder is worth 1 point.   a = /opt files written, b = /tmp files written, c = library files read
NORMAL_RECORD="$(trace_of "$WORK/n1.txt")"
NORMAL_RECORD="${NORMAL_RECORD%.trace}.json"
synthetic() {   # synthetic A B C   compares the normal record plus A files in /opt and B in /tmp (written), C in /usr/lib (read)
    python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
a, b, c = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
r["files"]["written"] += [f"/opt/check3_{i}" for i in range(a)] + [f"/tmp/check3_extra_{i}" for i in range(b)]
r["files"]["read_files"] += [f"/usr/lib/check3_lib_{i}" for i in range(c)]
json.dump(r, open(sys.argv[5], "w"))' "$NORMAL_RECORD" "$1" "$2" "$3" "$WORK/synthetic.json"
    python3 src/compare.py --record "$WORK/synthetic.json" check3_steady > "$WORK/synthetic.txt" 2>&1
}
while read -r a b c want_score want_words; do
    want_words=${want_words//_/ }
    synthetic "$a" "$b" "$c"
    expect "$a written in /opt (5 each), $b written in /tmp (2 each), $c read in /usr/lib (1 each): score $want_score, \"$want_words\"" \
        "$(score_of "$WORK/synthetic.txt"), $(level_of "$WORK/synthetic.txt")" "$want_score, $want_words"
done <<'EOF'
0 0 0 0 normal
0 0 2 2 normal
0 0 3 3 slightly_unusual
0 2 0 4 slightly_unusual
1 2 0 9 slightly_unusual
2 0 0 10 unusual
4 2 0 24 unusual
5 0 0 25 very_unusual
21 0 0 100 very_unusual
EOF
synthetic 21 0 0
contains "21 findings: the list is cut and says how many more" "$WORK/synthetic.txt" "... and 9 more"
expect "...and the list shows exactly 12 findings" "$(listed_points "$WORK/synthetic.txt" | wc -l | tr -d ' ')" 12
synthetic 2 0 0
expect "10 points: the listed points add up to the score" "$(sum_points "$WORK/synthetic.txt")" 10

echo
echo "9. Step 5: a local socket is not \"the network\""
PY=$(command -v python3)
python3 src/compare.py check3_steady "$PY" -c "import socket; s = socket.socket(socket.AF_INET); s.settimeout(0.5); s.connect_ex(('127.0.0.1', 9))" > "$WORK/inet.txt" 2>&1
python3 src/compare.py check3_steady "$PY" -c "import socket; s = socket.socket(socket.AF_UNIX); s.connect_ex('/tmp/check3_no_such_socket')" > "$WORK/unix.txt" 2>&1
at_least "an internet socket: the raw trace shows it" "$(grep -cE "${SOCKETS}AF_INET," "$(trace_of "$WORK/inet.txt")")" 1
contains "an internet socket: the score says it used the network" "$WORK/inet.txt" "used the network (1 internet socket)"
sockets_match "$WORK/inet.txt" "internet socket"
at_least "a local socket: the raw trace shows it" "$(grep -cE "${SOCKETS}AF_UNIX," "$(trace_of "$WORK/unix.txt")")" 1
expect "a local socket: the raw trace shows no internet socket" "$(grep -cE "$INTERNET" "$(trace_of "$WORK/unix.txt")")" 0
lacks "a local socket: the score does NOT say it used the network" "$WORK/unix.txt" "used the network"
sockets_match "$WORK/unix.txt" "local socket"
net_rule "$WORK/n1.txt" "normal run"
net_rule "$WORK/odd.txt" "odd run"
if command -v whoami >/dev/null 2>&1; then
    python3 src/compare.py check3_steady "$(command -v whoami)" > "$WORK/who.txt" 2>&1
    net_rule "$WORK/who.txt" "whoami"
else
    pass "whoami is not installed here, so that check is skipped"
fi

echo
echo "10. The earlier checks still pass"
sub() {
    local out="$WORK/$1.out"
    if bash "$1" > "$out" 2>&1; then
        pass "$1 passes   ($(grep -E '^ALL ' "$out" | tail -1 | cut -d: -f1))"
    else
        fail "$1 fails; its last lines:"
        tail -n 6 "$out" | sed 's/^/          /'
    fi
}
sub check_phase1.sh
sub check_phase2.sh
sub check_variants.sh

summary
[ "$FAILED" -eq 0 ]
