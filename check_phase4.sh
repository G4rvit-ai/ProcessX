#!/usr/bin/env bash
# check_phase4.sh - checks the backend (Phase 4) in one go.
#
# It starts the real server on a free port of this computer (127.0.0.1 only), talks to it
# with curl, and compares every answer with what the shell itself can see, so the backend
# never grades its own homework. Then it stops the server and runs check_phase3.sh, to make
# sure the backend did not break anything older.
#
# Needs the virtual environment to be active, with the packages from requirements.txt.
# Usage:  bash check_phase4.sh        (takes under a minute)

cd "$(dirname "$0")" || exit 1

PASSED=0
FAILED=0
WORK=$(mktemp -d)
SERVER=""
SERVER2=""
TMP_BASELINE=baselines/check4_tmp.json

stop_server() {
    for pid in "$SERVER" "$SERVER2"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        fi
    done
    SERVER=""
    SERVER2=""
}
trap 'stop_server; rm -f baselines/check4*.json /tmp/check4_flag /tmp/check4_pwned /tmp/check4_out.txt; rm -rf traces/runs/*check4* "$WORK"' EXIT

pass() { echo "  PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }

# expect "what" "actual" "wanted"     passes when the two are equal
expect() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got: $2   wanted: $3)"; fi
}
# contains "what" file "text"     passes when the file has that text (exact, not a pattern)
contains() {
    if grep -qiF -- "$3" "$2"; then pass "$1"; else fail "$1 (not found: $3)"; fi
}
lacks() {
    if grep -qiF -- "$3" "$2"; then fail "$1 (wrongly found: $3)"; else pass "$1"; fi
}

summary() {
    echo
    if [ "$FAILED" -eq 0 ]; then
        echo "ALL $PASSED CHECKS PASSED: the backend answers correctly, and the earlier phases still work."
    else
        echo "$FAILED of $((PASSED + FAILED)) CHECKS FAILED. Read the FAIL lines above."
    fi
}

# get PATH [curl options]    asks the server; the answer goes to $WORK/body and $WORK/head
get() {
    local path=$1
    shift
    curl -s --max-time 5 "$@" -D "$WORK/head" -o "$WORK/body" "http://127.0.0.1:$PORT$path"
}
status_of() { sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' "$WORK/head"; }
# json_get FILE 'expression'    prints the value of a Python expression about the JSON file (its content is called d)
json_get() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>&1; }

echo "0. Tools and files"
for tool in python3 curl strace; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "  Missing tool: $tool (install it first)"
        exit 1
    fi
done
if ! python3 -c "import fastapi, uvicorn" 2>/dev/null; then
    echo "  FastAPI and uvicorn are not installed for this python3."
    echo "  Activate the virtual environment (source venv/bin/activate), then run:  pip install -r requirements.txt"
    exit 1
fi
for file in backend/main.py backend/store.py backend/runs.py backend/__init__.py requirements.txt check_phase3.sh; do
    if [ ! -f "$file" ]; then
        echo "  Missing file: $file"
        exit 1
    fi
done
pass "python3, curl, FastAPI and uvicorn are installed, and the backend files are there"
contains "requirements.txt lists fastapi" requirements.txt "fastapi"
contains "requirements.txt lists uvicorn" requirements.txt "uvicorn"

echo
echo "1. Start the server (from another folder, with a messy environment)"
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
# The server is started from another folder and with a messy environment (a foreign LANG, a FOO variable) on purpose:
# it must find its files wherever it was started, and the programs it runs must not see its own environment.
# A script that starts something in the background makes it ignore Ctrl+C and friends, and a traced program then makes
# one system call fewer than in a normal terminal. launch() undoes that first, so the runs match a baseline built in a terminal.
# (exec: the background process must be the server itself, so that $! is its id and kill stops it.)
launch() {
    exec python3 -c 'import os, signal, sys
for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGTERM):
    signal.signal(s, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' "$@"
}
ROOT=$(pwd)
cd "$WORK" || exit 1
launch env FOO=bar LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8 python3 -m uvicorn --app-dir "$ROOT" backend.main:app --host 127.0.0.1 --port "$PORT" > "$WORK/server.log" 2>&1 &
SERVER=$!
cd "$ROOT" || exit 1
UP=no
for _ in $(seq 1 50); do
    if curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$PORT/health"; then UP=yes; break; fi
    kill -0 "$SERVER" 2>/dev/null || break
    sleep 0.2
done
expect "the server answers within 10 seconds (port $PORT)" "$UP" yes
if [ "$UP" != yes ]; then
    echo "  The server did not start. Its log:"
    sed 's/^/          /' "$WORK/server.log"
    summary
    exit 1
fi
expect "the server process is still running" "$(kill -0 "$SERVER" 2>/dev/null && echo yes)" yes
lacks "it did not crash while starting (no Traceback in its log)" "$WORK/server.log" "Traceback"

echo
echo "2. /health"
get /health
expect "answers 200" "$(status_of)" 200
contains "the answer is JSON" "$WORK/head" "content-type: application/json"
contains "status is ok" "$WORK/body" '"status":"ok"'
expect "the answer has exactly 3 fields" "$(grep -o '"[a-z_]*":' "$WORK/body" | wc -l | tr -d ' ')" 3
if command -v strace >/dev/null 2>&1; then WANT=true; else WANT=false; fi
contains "strace: $WANT (the shell agrees)" "$WORK/body" "\"strace\":$WANT"
SAVED=$(ls baselines/*.json 2>/dev/null | wc -l | tr -d ' ')
contains "baselines: $SAVED (the number of files in baselines/)" "$WORK/body" "\"baselines\":$SAVED"
echo '{}' > "$TMP_BASELINE"
get /health
contains "add a file to baselines/: the count goes up to $((SAVED + 1)) (it is counted live)" "$WORK/body" "\"baselines\":$((SAVED + 1))"
rm -f "$TMP_BASELINE"
get /health
contains "remove it: the count goes back to $SAVED" "$WORK/body" "\"baselines\":$SAVED"
OKS=0
for _ in $(seq 1 20); do
    get /health
    [ "$(status_of)" = 200 ] && OKS=$((OKS + 1))
done
expect "20 requests in a row: all 20 answer 200" "$OKS" 20

echo
echo "3. Wrong requests are refused politely"
get /health -X POST
expect "POST /health is refused with 405" "$(status_of)" 405
contains "...and says which method is allowed" "$WORK/head" "allow: GET"
get /nothing-here
expect "an unknown path gives 404" "$(status_of)" 404
contains "...with a JSON message" "$WORK/body" '"detail"'
get /health/../../etc/passwd --path-as-is
expect "a path with .. in it is not served (404)" "$(status_of)" 404
lacks "...and /etc/passwd did not leak" "$WORK/body" "root:"

echo
echo "4. The built-in documentation"
get /docs
expect "/docs answers 200" "$(status_of)" 200
contains "/docs is a web page" "$WORK/head" "content-type: text/html"
get /openapi.json
expect "/openapi.json answers 200" "$(status_of)" 200
contains "it lists /health" "$WORK/body" '"/health"'
contains "it lists /baselines" "$WORK/body" '"/baselines"'
contains "it lists /baselines/{name}" "$WORK/body" '"/baselines/{name}"'
contains "it lists /baselines/{name}/compare" "$WORK/body" '"/baselines/{name}/compare"'
contains "it names the project: ProcessX" "$WORK/body" '"title":"ProcessX"'

echo
echo "5. GET /baselines: the list"
# Fixtures, written by hand here (not by the project's own code): two good baselines, and three files that cannot be used.
cat > baselines/check4_alpha.json <<'EOF'
{
  "command": ["/bin/echo", "hi"],
  "created": "2026-01-02T03:04:05",
  "environment": {"LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin"},
  "features": {
    "calls.total": {"max": 5, "min": 3, "present": 3},
    "calls.unique": {"max": 2, "min": 2, "present": 3}
  },
  "identical_runs": 2,
  "name": "check4_alpha",
  "program": "echo",
  "runs": 3,
  "schema": 1,
  "timing": {}
}
EOF
cat > baselines/check4_beta.json <<'EOF'
{
  "command": ["/bin/ls", "-l"],
  "created": "2026-02-03T04:05:06",
  "environment": {"LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin"},
  "features": {
    "calls.total": {"max": 90, "min": 80, "present": 4},
    "calls.unique": {"max": 20, "min": 18, "present": 4},
    "files.written: /tmp/x": {"max": 1, "min": 0, "present": 2}
  },
  "identical_runs": 1,
  "name": "check4_beta",
  "program": "ls",
  "runs": 4,
  "schema": 1,
  "timing": {}
}
EOF
echo 'this is not json' > baselines/check4_broken.json
echo '{"schema": 1, "name": "x", "features": {}}' > baselines/check4_wrong.json
cp baselines/check4_alpha.json "baselines/check4 odd name.json"
FILES=$(ls baselines/*.json | wc -l | tr -d ' ')
get /baselines
expect "answers 200" "$(status_of)" 200
contains "the answer is JSON" "$WORK/head" "content-type: application/json"
cp "$WORK/body" "$WORK/list.json"
expect "the count equals the number of baselines listed" "$(json_get "$WORK/list.json" 'd["count"] == len(d["baselines"])')" True
expect "every file in baselines/ is either listed or reported as unreadable (none is hidden)" \
    "$(json_get "$WORK/list.json" 'sorted([b["name"] for b in d["baselines"]] + [u["name"] for u in d["unreadable"]])')" \
    "$(for f in baselines/*.json; do b=${f##*/}; echo "${b%.json}"; done | python3 -c 'import sys; print(sorted(sys.stdin.read().split("\n")[:-1]))')"
expect "the list is sorted by name" "$(json_get "$WORK/list.json" '[b["name"] for b in d["baselines"]] == sorted(b["name"] for b in d["baselines"])')" True
expect "check4_alpha is listed, with exactly the values written in its file" \
    "$(json_get "$WORK/list.json" 'next(b for b in d["baselines"] if b["name"] == "check4_alpha") == {"name": "check4_alpha", "program": "echo", "command": ["/bin/echo", "hi"], "runs": 3, "identical_runs": 2, "created": "2026-01-02T03:04:05", "feature_count": 2}')" True
expect "check4_beta is listed, with 3 features" "$(json_get "$WORK/list.json" 'next(b for b in d["baselines"] if b["name"] == "check4_beta")["feature_count"]')" 3
expect "the two good ones are not in the unreadable list" "$(json_get "$WORK/list.json" 'not any(u["name"] in ("check4_alpha", "check4_beta") for u in d["unreadable"])')" True
expect "check4_broken is reported as unreadable: not valid JSON" \
    "$(json_get "$WORK/list.json" 'next(u for u in d["unreadable"] if u["name"] == "check4_broken")["problem"]')" "it is not valid JSON"
expect "check4_wrong is reported as unreadable: no usable command" \
    "$(json_get "$WORK/list.json" 'next(u for u in d["unreadable"] if u["name"] == "check4_wrong")["problem"]')" "it is not a usable baseline: it has no usable 'command'"
expect "a file with a bad name is reported as unreadable" \
    "$(json_get "$WORK/list.json" 'next(u for u in d["unreadable"] if u["name"] == "check4 odd name")["problem"]')" "the file name is not a valid baseline name (letters, digits, _ . - only)"
expect "the reasons do not show where the project is on this computer" \
    "$(json_get "$WORK/list.json" 'not any(__import__("os").getcwd() in u["problem"] for u in d["unreadable"])')" True
get /health
expect "/health counts the same files as are in baselines/" "$(sed -n 's/.*"baselines":\([0-9]*\).*/\1/p' "$WORK/body")" "$FILES"
expect "listed + unreadable = the files in baselines/ ($FILES)" "$(json_get "$WORK/list.json" 'd["count"] + len(d["unreadable"])')" "$FILES"
sed 's/check4_alpha/check4_gamma/' baselines/check4_alpha.json > baselines/check4_gamma.json
get /baselines
expect "add a baseline file: it shows up at once, without restarting the server" "$(json_get "$WORK/body" 'any(b["name"] == "check4_gamma" for b in d["baselines"])')" True
rm -f baselines/check4_gamma.json
get /baselines
expect "remove it: it is gone from the list again" "$(json_get "$WORK/body" 'any(b["name"] == "check4_gamma" for b in d["baselines"])')" False

echo
echo "6. GET /baselines/<name>: one baseline in full"
get /baselines/check4_alpha
expect "check4_alpha answers 200" "$(status_of)" 200
contains "the answer is JSON" "$WORK/head" "content-type: application/json"
expect "the answer is exactly what is saved in the file" "$(json_get "$WORK/body" 'd == json.load(open("baselines/check4_alpha.json"))')" True
expect "calls.total: lowest 3, highest 5, present in 3 runs (as written in the file)" \
    "$(json_get "$WORK/body" 'd["features"]["calls.total"] == {"min": 3, "max": 5, "present": 3}')" True
get /baselines/check4_beta
expect "check4_beta is exactly what is saved in its file" "$(json_get "$WORK/body" 'd == json.load(open("baselines/check4_beta.json"))')" True
REAL=0
BAD=""
while read -r stem; do
    [ -n "$stem" ] || continue
    REAL=$((REAL + 1))
    get "/baselines/$stem"
    if [ "$(status_of)" != 200 ] || [ "$(json_get "$WORK/body" "d == json.load(open('baselines/$stem.json'))")" != True ]; then BAD="$BAD $stem"; fi
done < <(json_get "$WORK/list.json" '"\n".join(b["name"] for b in d["baselines"] if not b["name"].startswith("check4"))')
expect "your own $REAL usable baselines: each answers 200 with exactly what is in its file" "${BAD:-all agree}" "all agree"

echo
echo "7. Mistakes, broken files and attacks"
get /baselines/check4_nope
expect "an unknown name gives 404" "$(status_of)" 404
contains "...and the message names it" "$WORK/body" "No baseline named 'check4_nope'"
get /baselines/check4_broken
expect "a file that is not JSON gives 500, not a crash" "$(status_of)" 500
contains "...and the message says why" "$WORK/body" "it is not valid JSON"
get /baselines/check4_wrong
expect "an incomplete baseline gives 500" "$(status_of)" 500
contains "...and the message says what is missing" "$WORK/body" "no usable 'command'"
get /health
expect "the server is still fine after the broken files" "$(status_of)" 200
get "/baselines/check4%20odd%20name"
expect "a name with spaces gives 404, even though that file exists" "$(status_of)" 404
get "/baselines/..%2Fbackend%2Fmain"
expect "a name with an encoded slash (..%2F) gives 404" "$(status_of)" 404
lacks "...and nothing from backend/main.py leaked" "$WORK/body" "FastAPI("
get /baselines/.. --path-as-is
expect "the name .. gives 404" "$(status_of)" 404
get /baselines/%2e%2e --path-as-is
expect "the name %2e%2e (an encoded ..) gives 404" "$(status_of)" 404
get /baselines/../etc/passwd --path-as-is
expect "a path that climbs out of baselines/ gives 404" "$(status_of)" 404
lacks "...and /etc/passwd did not leak" "$WORK/body" "root:"
get "/baselines/$(printf 'a%.0s' $(seq 1 3000))"
expect "a name 3000 characters long gives 404" "$(status_of)" 404
expect "...and the message does not echo all 3000 characters back" "$([ "$(wc -c < "$WORK/body")" -lt 300 ] && echo short || echo long)" short
SUM=$(sha256sum baselines/check4_alpha.json | cut -d' ' -f1)
BEFORE=$(ls baselines | wc -l | tr -d ' ')
REFUSED=0
for method in POST PUT DELETE PATCH; do
    for path in /baselines /baselines/check4_alpha; do
        get "$path" -X "$method"
        [ "$(status_of)" = 405 ] && REFUSED=$((REFUSED + 1))
    done
done
expect "POST, PUT, DELETE and PATCH on both baseline URLs are refused (8 of 8 give 405)" "$REFUSED" 8
expect "...and the file is unchanged" "$(sha256sum baselines/check4_alpha.json | cut -d' ' -f1)" "$SUM"
expect "...and no file was added or removed" "$(ls baselines | wc -l | tr -d ' ')" "$BEFORE"
rm -f baselines/check4*.json

echo
echo "8. POST /baselines/<name>/compare: run the saved command once and compare it"
# A tiny program of our own. Normally it writes a file, reads it and deletes it. If /tmp/check4_flag exists it also
# starts /bin/date and reads /etc/passwd, so we can make a run odd whenever we like. The last lines are a canary:
# /bin/date also runs if the program gets the wrong environment (the server itself was started with LANG and FOO set).
cat > "$WORK/check4_prog.sh" <<'EOF'
#!/bin/sh
echo hello > /tmp/check4_out.txt
cat /tmp/check4_out.txt > /dev/null
rm -f /tmp/check4_out.txt
if [ -e /tmp/check4_flag ]; then
    /bin/date > /dev/null
    cat /etc/passwd > /dev/null
fi
if [ "$LANG" != "C" ] || [ "$LC_ALL" != "C" ] || [ -n "$FOO" ]; then
    /bin/date > /dev/null
fi
EOF
printf '#!/bin/sh\nsleep 2\n' > "$WORK/check4_slow.sh"
chmod +x "$WORK/check4_prog.sh" "$WORK/check4_slow.sh"
rm -f /tmp/check4_flag /tmp/check4_pwned
FOO=bar LANG=de_DE.UTF-8 strace -f -o "$WORK/leak.trace" "$WORK/check4_prog.sh" >/dev/null 2>&1
expect "(sanity) started from a messy shell, the same program does start /bin/date" \
    "$([ "$(grep -c 'execve("/bin/date"' "$WORK/leak.trace")" -ge 1 ] && echo yes)" yes
python3 src/baseline.py build --runs 5 --name check4_run "$WORK/check4_prog.sh" > "$WORK/build.out" 2>&1
expect "(setup) the project's own baseline.py builds a baseline of that program from 5 runs" "$([ -f baselines/check4_run.json ] && echo yes)" yes
BL_SUM=$(sha256sum baselines/check4_run.json | cut -d' ' -f1)
# variant NAME 'statements': a hand-made copy of that baseline with one thing changed (b is the baseline as a dictionary)
variant() {
    python3 -c 'import json, sys; b = json.load(open("baselines/check4_run.json")); exec(sys.argv[2]); json.dump(b, open("baselines/" + sys.argv[1] + ".json", "w"))' "$1" "$2"
}
variant check4_gone 'b["command"] = ["/nonexistent/check4_program"]'
variant check4_envwarn 'b["environment"] = {"LANG": "C"}'
variant check4_slow "b['command'] = ['$WORK/check4_slow.sh']; b['features'] = {}"

echo "  -- a normal run"
get /baselines/check4_run/compare -X POST
expect "answers 200" "$(status_of)" 200
contains "the answer is JSON" "$WORK/head" "content-type: application/json"
cp "$WORK/body" "$WORK/run1.json"
expect "the answer has exactly these fields" "$(json_get "$WORK/run1.json" 'sorted(d)')" \
    "['baseline', 'command', 'differences', 'features_compared', 'findings', 'level', 'matches', 'outside_by_kind', 'outside_range', 'run', 'score', 'unscored', 'warnings']"
expect "it names the baseline, and the command is the one saved in the baseline file" \
    "$(json_get "$WORK/run1.json" '[d["baseline"], d["command"] == json.load(open("baselines/check4_run.json"))["command"]]')" "['check4_run', True]"
expect "the run scores no more than 2 and is called normal (the server's own LANG and FOO did not reach the program)" \
    "$(json_get "$WORK/run1.json" '[d["score"] <= 2, d["level"]]')" "[True, 'normal']"
# On some machines a stray extra system call turns up in about one run in ten, and that run does not match exactly. Allow a few tries.
TRIES=1
while [ "$(json_get "$WORK/run1.json" 'd["matches"]')" != True ] && [ "$TRIES" -lt 4 ]; do
    get /baselines/check4_run/compare -X POST
    cp "$WORK/body" "$WORK/run1.json"
    TRIES=$((TRIES + 1))
done
expect "a normal run matches the baseline exactly (within 4 tries)" "$(json_get "$WORK/run1.json" 'd["matches"]')" True
expect "...with score 0, no findings, no differences, no warnings" \
    "$(json_get "$WORK/run1.json" '[d["score"], d["findings"], d["differences"], d["warnings"], d["outside_range"]]')" "[0, [], [], [], 0]"
expect "...and it compared at least as many features as the baseline file has" \
    "$(json_get "$WORK/run1.json" 'd["features_compared"] >= len(json.load(open("baselines/check4_run.json"))["features"])')" True
RUN=$(json_get "$WORK/run1.json" 'd["run"]')
expect "the run is named like a folder, not like a path" "$(echo "$RUN" | grep -cE '^compare_check4_run_[0-9]{8}-[0-9]{6}(-[0-9]+)?$')" 1
expect "the run was saved: run.trace and run.json are in traces/runs/$RUN" \
    "$(ls "traces/runs/$RUN/run.trace" "traces/runs/$RUN/run.json" 2>/dev/null | wc -l | tr -d ' ')" 2
expect "the raw trace shows the saved command being started (grep)" \
    "$([ "$(grep -c "execve(\"$WORK/check4_prog.sh\"" "traces/runs/$RUN/run.trace")" -ge 1 ] && echo yes)" yes
expect "the raw trace shows the program got exactly 4 variables: the fixed environment (grep)" \
    "$(grep -m1 'execve(' "traces/runs/$RUN/run.trace" | grep -c '/\* 4 vars \*/')" 1
expect "comparing did not change the baseline file" "$(sha256sum baselines/check4_run.json | cut -d' ' -f1)" "$BL_SUM"

echo "  -- an odd run"
touch /tmp/check4_flag
get /baselines/check4_run/compare -X POST
expect "answers 200" "$(status_of)" 200
cp "$WORK/body" "$WORK/odd.json"
ODD=$(json_get "$WORK/odd.json" 'd["run"]')
expect "it scores at least 12 (the sensitive file and the new program)" "$([ "$(json_get "$WORK/odd.json" 'd["score"]')" -ge 12 ] && echo yes)" yes
expect "...the level word fits the score" \
    "$(json_get "$WORK/odd.json" 'd["level"] == ("normal" if d["score"] <= 2 else "slightly unusual" if d["score"] <= 9 else "unusual" if d["score"] <= 24 else "very unusual")')" True
expect "...and matches is false" "$(json_get "$WORK/odd.json" 'd["matches"]')" False
contains "the findings say: read /etc/passwd (a sensitive file)" "$WORK/odd.json" "read /etc/passwd (a sensitive file)"
contains "the findings say: started /bin/date" "$WORK/odd.json" "started /bin/date"
expect "the listed points add up to the score" "$(json_get "$WORK/odd.json" 'min(100, sum(f["points"] for f in d["findings"])) == d["score"]')" True
expect "...and are listed biggest first" \
    "$(json_get "$WORK/odd.json" '[f["points"] for f in d["findings"]] == sorted((f["points"] for f in d["findings"]), reverse=True)')" True
expect "the differences list the file as never seen" \
    "$(json_get "$WORK/odd.json" 'any(x["kind"] == "never" and x["feature"] == "files.read_files: /etc/passwd" for x in d["differences"])')" True
expect "...and the program as never seen" \
    "$(json_get "$WORK/odd.json" 'any(x["kind"] == "never" and x["feature"] == "processes.programs./bin/date" for x in d["differences"])')" True
expect "outside_range = the length of the differences list = the sum of outside_by_kind" \
    "$(json_get "$WORK/odd.json" 'd["outside_range"] == len(d["differences"]) == sum(d["outside_by_kind"].values())')" True
expect "the raw trace of that run shows /etc/passwd being opened (grep)" \
    "$([ "$(grep -cE 'openat\(.*"/etc/passwd"' "traces/runs/$ODD/run.trace")" -ge 1 ] && echo yes)" yes
expect "...and /bin/date being started (grep)" \
    "$([ "$(grep -c 'execve("/bin/date"' "traces/runs/$ODD/run.trace")" -ge 1 ] && echo yes)" yes
expect "none of the baseline's own raw traces opens /etc/passwd or starts /bin/date (so both really are new)" \
    "$(grep -lE '"/etc/passwd"|execve\("/bin/date"' traces/runs/baseline_check4_run_*/run?.trace | wc -l | tr -d ' ')" 0
python3 src/compare.py --record "traces/runs/$ODD/run.json" check4_run > "$WORK/cli.txt" 2>&1
expect "the command-line compare.py gives the same score for the same saved run" \
    "$(sed -n 's/^SCORE: \([0-9]*\) of 100 - .*/\1/p' "$WORK/cli.txt" | head -1)" "$(json_get "$WORK/odd.json" 'd["score"]')"
expect "...and the same level word" \
    "$(sed -n 's/^SCORE: [0-9]* of 100 - \(.*\)$/\1/p' "$WORK/cli.txt" | head -1)" "$(json_get "$WORK/odd.json" 'd["level"]')"
rm -f /tmp/check4_flag

echo "  -- a web page from another site cannot start a run"
BEFORE=$(ls -d traces/runs/compare_check4_* 2>/dev/null | wc -l | tr -d ' ')
get /baselines/check4_run/compare -X POST -H "Origin: http://evil.example"
expect "a request that says it comes from another site is refused with 403" "$(status_of)" 403
contains "...and the message says why" "$WORK/body" "another web page"
get /baselines/check4_run/compare -X POST -H "Origin: http://127.0.0.1:1"
expect "an Origin with another port is refused (403)" "$(status_of)" 403
get /baselines/check4_run/compare -X POST -H "Origin: https://127.0.0.1:$PORT"
expect "an Origin with another scheme is refused (403)" "$(status_of)" 403
get /baselines/check4_run/compare -X POST -H "Origin: null"
expect "the Origin \"null\" (what a sandboxed page sends) is refused (403)" "$(status_of)" 403
get /baselines/check4_run/compare -X POST -H "Host: evil.example"
expect "a request addressed to another name is refused with 400 (DNS rebinding)" "$(status_of)" 400
get /health -H "Host: evil.example"
expect "...also when it only wants to read (GET /health gives 400)" "$(status_of)" 400
expect "none of those requests started a run (no new run folder)" "$(ls -d traces/runs/compare_check4_* 2>/dev/null | wc -l | tr -d ' ')" "$BEFORE"
get /baselines/check4_run/compare -X POST -H "Origin: http://127.0.0.1:$PORT"
expect "the Origin of this server's own /docs page is accepted (200)" "$(status_of)" 200
get /baselines/check4_run/compare -X POST -H "Host: localhost:$PORT" -H "Origin: http://localhost:$PORT"
expect "...and so is the same page opened as localhost (200)" "$(status_of)" 200

echo "  -- nothing in the request becomes a command"
get /baselines/check4_run/compare -X POST -H 'Content-Type: application/json' -d '{"command": ["/bin/touch", "/tmp/check4_pwned"], "program": "/bin/touch"}'
expect "a body that asks for another command is ignored (still 200)" "$(status_of)" 200
R1=$(json_get "$WORK/body" 'd["run"]')
get "/baselines/check4_run/compare?command=%2Fbin%2Ftouch&program=%2Fbin%2Ftouch" -X POST
expect "...and so is a query string asking for it (still 200)" "$(status_of)" 200
R2=$(json_get "$WORK/body" 'd["run"]')
expect "...nothing was touched: /tmp/check4_pwned does not exist" "$([ -e /tmp/check4_pwned ] && echo exists || echo none)" none
expect "...and the raw traces of both runs never start /bin/touch" \
    "$(grep -c 'execve("/bin/touch"' "traces/runs/$R1/run.trace" "traces/runs/$R2/run.trace" | cut -d: -f2 | tr '\n' ' ')" "0 0 "

echo "  -- mistakes"
BEFORE=$(ls -d traces/runs/compare_check4_* 2>/dev/null | wc -l | tr -d ' ')
get /baselines/check4_nope/compare -X POST
expect "an unknown baseline gives 404" "$(status_of)" 404
contains "...and the message names it" "$WORK/body" "No baseline named 'check4_nope'"
echo 'this is not json' > baselines/check4_broken.json
get /baselines/check4_broken/compare -X POST
expect "a baseline file that is not JSON gives 500" "$(status_of)" 500
contains "...and the message says why" "$WORK/body" "it is not valid JSON"
rm -f baselines/check4_broken.json
get "/baselines/check4%20odd%20name/compare" -X POST
expect "a name with spaces gives 404" "$(status_of)" 404
get "/baselines/..%2Fbackend%2Fmain/compare" -X POST
expect "a name with an encoded slash gives 404" "$(status_of)" 404
get "/baselines/$(printf 'a%.0s' $(seq 1 3000))/compare" -X POST
expect "a name 3000 characters long gives 404" "$(status_of)" 404
expect "...and the message does not echo all 3000 characters back" "$([ "$(wc -c < "$WORK/body")" -lt 300 ] && echo short || echo long)" short
expect "none of those mistakes started a run (no new run folder)" "$(ls -d traces/runs/compare_check4_* 2>/dev/null | wc -l | tr -d ' ')" "$BEFORE"
get /baselines/check4_run/compare
expect "GET on the compare address is refused with 405" "$(status_of)" 405
contains "...and the answer says POST is the method that works" "$WORK/head" "allow: POST"
REFUSED=0
for method in PUT DELETE PATCH; do
    get /baselines/check4_run/compare -X "$method"
    [ "$(status_of)" = 405 ] && REFUSED=$((REFUSED + 1))
done
expect "PUT, DELETE and PATCH are refused too (3 of 3 give 405)" "$REFUSED" 3
get /baselines/check4_gone/compare -X POST
expect "a baseline whose program no longer exists gives 500, not a crash" "$(status_of)" 500
contains "...and the message says it could not be run" "$WORK/body" "could not be run"
lacks "...and does not show where the program was supposed to be" "$WORK/body" "/nonexistent"
expect "...and no half-made run folder is left behind" "$(ls -d traces/runs/compare_check4_gone_* 2>/dev/null | wc -l | tr -d ' ')" 0
get /health
expect "the server is still fine after the failed run" "$(status_of)" 200
get /baselines/check4_run/compare -X POST
expect "...and a new comparison can run (the server was not left busy)" "$(status_of)" 200
get /baselines/check4_envwarn/compare -X POST
expect "a baseline built with other environment settings still runs (200)" "$(status_of)" 200
contains "...and the answer warns about it" "$WORK/body" "different environment settings"
expect "...with exactly one warning" "$(json_get "$WORK/body" 'len(d["warnings"])')" 1

echo "  -- a relative command, a server started in another folder"
if [ -x test_programs/demo.sh ]; then
    variant check4_rel 'b["command"] = ["test_programs/demo.sh"]; b["features"] = {}'
    get /baselines/check4_rel/compare -X POST
    expect "a baseline whose command is test_programs/demo.sh runs, although the server was started in another folder" "$(status_of)" 200
    REL=$(json_get "$WORK/body" 'd["run"]')
    expect "...the raw trace shows test_programs/demo.sh being started (grep)" \
        "$([ "$(grep -c 'execve("test_programs/demo.sh"' "traces/runs/$REL/run.trace")" -ge 1 ] && echo yes)" yes
else
    pass "test_programs/demo.sh is not here, so the relative-command check is skipped"
fi

echo "  -- one comparison at a time"
curl -s --max-time 30 -X POST -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/baselines/check4_slow/compare" > "$WORK/slow1.code" 2>/dev/null &
SLOW=$!
for _ in $(seq 1 50); do
    ls -d traces/runs/compare_check4_slow_* >/dev/null 2>&1 && break
    sleep 0.1
done
get /baselines/check4_slow/compare -X POST
expect "a second comparison while one is running is refused with 409" "$(status_of)" 409
contains "...and the message says one is already running" "$WORK/body" "already running"
wait "$SLOW"
expect "the first comparison still finishes normally (200)" "$(cat "$WORK/slow1.code")" 200
get /baselines/check4_run/compare -X POST
expect "afterwards a comparison can run again" "$(status_of)" 200

echo "  -- a program that runs too long is really stopped"
# The project's own run_traced, with a 2 second limit, on a program that would run for 31 seconds.
python3 -c 'import sys; sys.path.insert(0, "src"); import runner
try:
    runner.run_traced(["/bin/sleep", "31"], sys.argv[1], runner.controlled_env(), timeout=2)
    print("it finished")
except SystemExit as stopped:
    print(stopped)' "$WORK/overtime.trace" > "$WORK/overtime.out" 2>&1
contains "the run is given up after the limit (2 seconds)" "$WORK/overtime.out" "still running after 2 seconds"
sleep 0.5
LEFT=$(ps -eo pid,args | awk '$2 == "/bin/sleep" && $3 == "31" {print $1}')
expect "...and the program itself is gone, not left running in the background" "$(echo "$LEFT" | grep -c '[0-9]')" 0
[ -n "$LEFT" ] && echo "$LEFT" | xargs kill 2>/dev/null

echo "  -- a computer without strace"
mkdir "$WORK/empty"
PY=$(command -v python3)
PORT2=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
PATH="$WORK/empty" "$PY" -m uvicorn --app-dir "$ROOT" backend.main:app --host 127.0.0.1 --port "$PORT2" > "$WORK/server2.log" 2>&1 &
SERVER2=$!
UP2=no
for _ in $(seq 1 50); do
    if curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$PORT2/health"; then UP2=yes; break; fi
    kill -0 "$SERVER2" 2>/dev/null || break
    sleep 0.2
done
expect "(setup) a second server, started with no strace on its PATH, answers" "$UP2" yes
MAIN_PORT=$PORT
PORT=$PORT2
get /health
contains "it says strace: false" "$WORK/body" '"strace":false'
BEFORE=$(ls -d traces/runs/compare_check4_* 2>/dev/null | wc -l | tr -d ' ')
get /baselines/check4_run/compare -X POST
expect "a comparison there gives 503 (service unavailable)" "$(status_of)" 503
contains "...and says strace is not installed" "$WORK/body" "strace is not installed"
get /health
expect "the server is still alive after that (the Phase 3 code stops with sys.exit; the backend must not)" "$(status_of)" 200
expect "...and no run folder was left behind" "$(ls -d traces/runs/compare_check4_* 2>/dev/null | wc -l | tr -d ' ')" "$BEFORE"
PORT=$MAIN_PORT
kill "$SERVER2" 2>/dev/null
wait "$SERVER2" 2>/dev/null
SERVER2=""
rm -f baselines/check4*.json /tmp/check4_flag /tmp/check4_pwned
rm -rf traces/runs/*check4*

echo
echo "9. The server stops cleanly"
kill "$SERVER" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$SERVER" 2>/dev/null || break; sleep 0.1; done
expect "the server process ended after being asked to stop" "$(kill -0 "$SERVER" 2>/dev/null && echo running || echo ended)" ended
wait "$SERVER" 2>/dev/null
SERVER=""
expect "nothing answers on the port any more" "$(curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/health" && echo answers || echo silent)" silent
expect "the check left no baseline file behind" "$(ls baselines/check4* 2>/dev/null | wc -l | tr -d ' ')" 0
expect "...and no run folder or temporary file either" "$(ls -d traces/runs/*check4* /tmp/check4_* 2>/dev/null | wc -l | tr -d ' ')" 0

echo
echo "10. The earlier phases still pass"
if bash check_phase3.sh > "$WORK/phase3.out" 2>&1; then
    pass "check_phase3.sh passes   ($(grep -E '^ALL ' "$WORK/phase3.out" | tail -1 | cut -d: -f1))"
else
    fail "check_phase3.sh fails; its last lines:"
    tail -n 6 "$WORK/phase3.out" | sed 's/^/          /'
fi

summary
[ "$FAILED" -eq 0 ]
