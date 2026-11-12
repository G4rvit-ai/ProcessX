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

# dbq 'expression'    asks the database file ($DB) directly, with Python's plain sqlite3 (not the backend's own SQLAlchemy).
# The expression can use c (the connection) and json.
dbq() { python3 -c 'import json, sqlite3, sys; c = sqlite3.connect(sys.argv[1]); print(eval(sys.argv[2]))' "$DB" "$1" 2>&1; }
rows() { dbq 'c.execute("select count(*) from comparisons").fetchone()[0]'; }
# row_agrees ANSWER.json    does the row with that answer's id hold exactly that answer? (prints True or False)
row_agrees() {
    python3 -c 'import json, sqlite3, sys
d = json.load(open(sys.argv[2]))
r = sqlite3.connect(sys.argv[1]).execute("select baseline_name, run, score, level, matches, features_compared, outside_range, result from comparisons where id = ?", (d["id"],)).fetchone()
want = (d["baseline"], d["run"], d["score"], d["level"], int(d["matches"]), d["features_compared"], d["outside_range"])
print(r is not None and r[:7] == want and json.loads(r[7]) == {k: v for k, v in d.items() if k != "id"})' "$DB" "$1" 2>&1
}
# items_agree LIST.json    does every comparison of that answer agree with its row in the database file? (prints True or False)
items_agree() {
    python3 -c 'import json, sqlite3, sys
from datetime import datetime, timezone
d = json.load(open(sys.argv[2]))
db = sqlite3.connect(sys.argv[1])
ok = True
for item in d["comparisons"]:
    r = db.execute("select baseline_name, run, score, level, matches, features_compared, outside_range, created_at from comparisons where id = ?", (item["id"],)).fetchone()
    if r is None:
        ok = False
        continue
    when = datetime.strptime(r[7], "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=timezone.utc)
    ok = ok and (item["baseline"], item["run"], item["score"], item["level"], item["matches"], item["features_compared"], item["outside_range"]) == (r[0], r[1], r[2], r[3], bool(r[4]), r[5], r[6]) and datetime.fromisoformat(item["created_at"]) == when
print(ok)' "$DB" "$1" 2>&1
}
# ask 'PATH' 'expression'    asks the server, and prints the value of a Python expression about its JSON answer (called d)
ask() { get "$1"; json_get "$WORK/body" "$2"; }
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
# start_second URL    starts one more server (SERVER2) on a free port with that database URL; sets PORT2, and UP2 to yes or no
start_second() {
    PORT2=$(free_port)
    cd "$WORK" || exit 1
    launch env PROCESSX_DATABASE_URL="$1" python3 -m uvicorn --app-dir "$ROOT" backend.main:app --host 127.0.0.1 --port "$PORT2" > "$WORK/server2.log" 2>&1 &
    SERVER2=$!
    cd "$ROOT" || exit 1
    UP2=no
    for _ in $(seq 1 50); do
        if curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$PORT2/health"; then UP2=yes; break; fi
        kill -0 "$SERVER2" 2>/dev/null || break
        sleep 0.2
    done
}
stop_second() {
    kill "$SERVER2" 2>/dev/null
    wait "$SERVER2" 2>/dev/null
    SERVER2=""
}

echo "0. Tools and files"
for tool in python3 curl strace; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "  Missing tool: $tool (install it first)"
        exit 1
    fi
done
if ! python3 -c "import fastapi, uvicorn, sqlalchemy" 2>/dev/null; then
    echo "  FastAPI, uvicorn and SQLAlchemy are not all installed for this python3."
    echo "  Activate the virtual environment (source venv/bin/activate), then run:  pip install -r requirements.txt"
    exit 1
fi
for file in backend/main.py backend/store.py backend/runs.py backend/db.py backend/models.py backend/__init__.py requirements.txt check_phase3.sh; do
    if [ ! -f "$file" ]; then
        echo "  Missing file: $file"
        exit 1
    fi
done
pass "python3, curl, FastAPI, uvicorn and SQLAlchemy are installed, and the backend files are there"
contains "requirements.txt lists fastapi" requirements.txt "fastapi"
contains "requirements.txt lists uvicorn" requirements.txt "uvicorn"
contains "requirements.txt lists sqlalchemy" requirements.txt "sqlalchemy"

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
# Every server of this check uses a database file of its own in the temporary folder, never the real processx.db.
DB="$WORK/check4.db"
ROOT=$(pwd)
cd "$WORK" || exit 1
launch env FOO=bar LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8 PROCESSX_DATABASE_URL="sqlite:///$DB" python3 -m uvicorn --app-dir "$ROOT" backend.main:app --host 127.0.0.1 --port "$PORT" > "$WORK/server.log" 2>&1 &
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
contains "it lists /comparisons" "$WORK/body" '"/comparisons"'
contains "it lists /comparisons/{comparison_id}" "$WORK/body" '"/comparisons/{comparison_id}"'
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
echo "8. POST /baselines/<name>/compare: run the saved command once, compare it, and save the comparison"
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
expect "the answer has exactly these fields (the new one: id)" "$(json_get "$WORK/run1.json" 'sorted(d)')" \
    "['baseline', 'command', 'differences', 'features_compared', 'findings', 'id', 'level', 'matches', 'outside_by_kind', 'outside_range', 'run', 'score', 'unscored', 'warnings']"
expect "the first comparison saved in a new database gets id 1 (a whole number)" "$(json_get "$WORK/run1.json" '[type(d["id"]).__name__, d["id"]]')" "['int', 1]"
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
ROWS0=$(rows)
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
expect "...and none of them was saved in the database" "$(rows)" "$ROWS0"
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
ROWS0=$(rows)
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
expect "...and none of them was saved in the database" "$(rows)" "$ROWS0"
get /baselines/check4_run/compare
expect "GET on the compare address is refused with 405" "$(status_of)" 405
contains "...and the answer says POST is the method that works" "$WORK/head" "allow: POST"
REFUSED=0
for method in PUT DELETE PATCH; do
    get /baselines/check4_run/compare -X "$method"
    [ "$(status_of)" = 405 ] && REFUSED=$((REFUSED + 1))
done
expect "PUT, DELETE and PATCH are refused too (3 of 3 give 405)" "$REFUSED" 3
ROWS0=$(rows)
get /baselines/check4_gone/compare -X POST
expect "a baseline whose program no longer exists gives 500, not a crash" "$(status_of)" 500
expect "...and nothing was saved in the database for it" "$(rows)" "$ROWS0"
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

echo "  -- every comparison is saved (read straight from the database file, with plain sqlite3)"
expect "the database file exists" "$([ -f "$DB" ] && echo yes)" yes
expect "the table comparisons has exactly the expected columns" \
    "$(dbq 'sorted(r[1] for r in c.execute("pragma table_info(comparisons)"))')" \
    "['baseline_name', 'created_at', 'features_compared', 'id', 'level', 'matches', 'outside_range', 'result', 'run', 'score']"
FOLDERS=$(ls -d traces/runs/compare_check4_* 2>/dev/null | wc -l | tr -d ' ')
expect "one row for every comparison that ran: rows = run folders ($FOLDERS)" "$(rows)" "$FOLDERS"
expect "every row names a run folder that exists, and every run folder has a row" \
    "$(dbq 'sorted(r[0] for r in c.execute("select run from comparisons"))')" \
    "$(ls traces/runs | grep '^compare_check4_' | python3 -c 'import sys; print(sorted(sys.stdin.read().split()))')"
expect "the ids are 1, 2, 3 ... with no gaps" \
    "$(dbq '[r[0] for r in c.execute("select id from comparisons order by id")] == list(range(1, c.execute("select count(*) from comparisons").fetchone()[0] + 1))')" True
expect "the normal run's row holds exactly its answer (every column, and the whole answer as JSON)" "$(row_agrees "$WORK/run1.json")" True
expect "the odd run's row holds exactly its answer too" "$(row_agrees "$WORK/odd.json")" True
expect "the odd run was saved after the normal one (a bigger id)" \
    "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"] > json.load(open(sys.argv[2]))["id"])' "$WORK/odd.json" "$WORK/run1.json")" True
expect "the time saved is UTC and recent (within 2 minutes of now)" \
    "$(dbq 'abs(__import__("datetime").datetime.now(__import__("datetime").timezone.utc).replace(tzinfo=None) - __import__("datetime").datetime.strptime(c.execute("select created_at from comparisons order by id desc limit 1").fetchone()[0], "%Y-%m-%d %H:%M:%S.%f")) < __import__("datetime").timedelta(minutes=2)')" True

echo "  -- the history survives a server restart"
OLDCOUNT=$(rows)
OLDMAX=$(dbq 'c.execute("select max(id) from comparisons").fetchone()[0]')
start_second "sqlite:///$DB"
expect "(setup) a second server on the same database file starts" "$UP2" yes
expect "starting it did not wipe the history (the same number of rows)" "$(rows)" "$OLDCOUNT"
MAIN_PORT=$PORT
PORT=$PORT2
get /baselines/check4_run/compare -X POST
expect "a comparison there answers 200" "$(status_of)" 200
expect "...and its id continues the numbering ($((OLDMAX + 1)))" "$(json_get "$WORK/body" 'd["id"]')" "$((OLDMAX + 1))"
PORT=$MAIN_PORT
stop_second
expect "...and the database has exactly one more row" "$(rows)" "$((OLDCOUNT + 1))"

echo "  -- a database that cannot be opened"
PORT2=$(free_port)
cd "$WORK" || exit 1
launch env PROCESSX_DATABASE_URL="sqlite:////nonexistent_check4_folder/x.db" python3 -m uvicorn --app-dir "$ROOT" backend.main:app --host 127.0.0.1 --port "$PORT2" > "$WORK/server2.log" 2>&1 &
SERVER2=$!
cd "$ROOT" || exit 1
for _ in $(seq 1 75); do kill -0 "$SERVER2" 2>/dev/null || break; sleep 0.2; done
expect "a server whose database cannot be opened stops by itself, instead of starting half-broken" "$(kill -0 "$SERVER2" 2>/dev/null && echo running || echo stopped)" stopped
contains "...and its log says why" "$WORK/server2.log" "unable to open database file"
expect "...and nothing answers on its port" "$(curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$PORT2/health" && echo answers || echo silent)" silent
stop_second

echo "  -- a database that fails while the server is running"
start_second "sqlite:///$WORK/check4_b.db"
expect "(setup) a server with its own empty database starts" "$UP2" yes
python3 -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("drop table comparisons"); c.commit()' "$WORK/check4_b.db"
PORT=$PORT2
get /baselines/check4_run/compare -X POST
expect "with the table gone, the comparison still runs and answers 200 (it did run, so its answer is still given)" "$(status_of)" 200
expect "...the id is null, because nothing was saved" "$(json_get "$WORK/body" 'd["id"]')" None
contains "...the answer warns that it was not saved" "$WORK/body" "could not be saved in the database"
contains "...and the server's log says why" "$WORK/server2.log" "no such table"
get /health
expect "the server is still alive after that" "$(status_of)" 200
get /comparisons
expect "reading the history gives 503 (service unavailable), not a crash" "$(status_of)" 503
contains "...and the message says the database could not be read" "$WORK/body" "could not be read"
contains "...and the server's log says why" "$WORK/server2.log" "could not read the comparisons"
get /comparisons/1
expect "reading one comparison gives 503 as well" "$(status_of)" 503
contains "...and the server's log says why" "$WORK/server2.log" "could not read comparison 1:"
get /health
expect "the server is still alive after those reads" "$(status_of)" 200
PORT=$MAIN_PORT
stop_second

echo "  -- a computer without strace"
mkdir "$WORK/empty"
PY=$(command -v python3)
PORT2=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
PROCESSX_DATABASE_URL="sqlite:///$WORK/check4_nostrace.db" PATH="$WORK/empty" "$PY" -m uvicorn --app-dir "$ROOT" backend.main:app --host 127.0.0.1 --port "$PORT2" > "$WORK/server2.log" 2>&1 &
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
expect "...and nothing was saved in its database" "$(python3 -c 'import sqlite3, sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from comparisons").fetchone()[0])' "$WORK/check4_nostrace.db")" 0
PORT=$MAIN_PORT
kill "$SERVER2" 2>/dev/null
wait "$SERVER2" 2>/dev/null
SERVER2=""
echo
echo "9. GET /comparisons and GET /comparisons/<id>: reading the history back"
echo "  -- the newest comparisons (the ones saved above)"
ROWS=$(rows)
get /comparisons
expect "answers 200" "$(status_of)" 200
contains "the answer is JSON" "$WORK/head" "content-type: application/json"
cp "$WORK/body" "$WORK/hist.json"
expect "the answer has exactly these fields" "$(json_get "$WORK/hist.json" 'sorted(d)')" "['comparisons', 'limit', 'offset', 'total']"
expect "total is the number of rows in the database ($ROWS, counted with plain sqlite3)" "$(json_get "$WORK/hist.json" 'd["total"]')" "$ROWS"
expect "without options it is a page of 20, starting at the newest" "$(json_get "$WORK/hist.json" '[d["limit"], d["offset"]]')" "[20, 0]"
expect "it gives as many comparisons as there are, up to 20" "$(json_get "$WORK/hist.json" 'len(d["comparisons"])')" "$([ "$ROWS" -lt 20 ] && echo "$ROWS" || echo 20)"
expect "newest first: the ids are the biggest ones in the database file, falling" \
    "$(json_get "$WORK/hist.json" '[c["id"] for c in d["comparisons"]]')" \
    "$(dbq '[r[0] for r in c.execute("select id from comparisons order by id desc limit 20")]')"
expect "every item has exactly these fields (the long result is left out)" \
    "$(json_get "$WORK/hist.json" 'all(sorted(c) == ["baseline", "created_at", "features_compared", "id", "level", "matches", "outside_range", "run", "score"] for c in d["comparisons"])')" True
expect "matches is true or false (not 1 or 0)" "$(json_get "$WORK/hist.json" 'all(type(c["matches"]) is bool for c in d["comparisons"])')" True
expect "every item agrees with its row in the database file (every column and the time)" "$(items_agree "$WORK/hist.json")" True
expect "every time says it is UTC (it ends with +00:00)" "$(json_get "$WORK/hist.json" 'all(c["created_at"].endswith("+00:00") for c in d["comparisons"])')" True

echo "  -- a new comparison shows up at the top, and can be read back exactly"
get /baselines/check4_run/compare -X POST
expect "(setup) a comparison runs and is saved" "$(status_of)" 200
cp "$WORK/body" "$WORK/new.json"
NEWID=$(json_get "$WORK/new.json" 'd["id"]')
get "/comparisons?limit=1"
cp "$WORK/body" "$WORK/top.json"
expect "it is the first item of the list now, and total went up by one" \
    "$(json_get "$WORK/top.json" "[d['comparisons'][0]['id'] == $NEWID, d['total']]")" "[True, $((ROWS + 1))]"
get "/comparisons/$NEWID"
expect "GET /comparisons/$NEWID answers 200" "$(status_of)" 200
cp "$WORK/body" "$WORK/detail.json"
expect "...it is exactly the answer the comparison gave, plus created_at" \
    "$(json_get "$WORK/detail.json" "{k: v for k, v in d.items() if k != 'created_at'} == json.load(open('$WORK/new.json'))")" True
expect "...and its time is the one the list shows" \
    "$(json_get "$WORK/detail.json" "d['created_at'] == json.load(open('$WORK/top.json'))['comparisons'][0]['created_at']")" True
ODD_ID=$(json_get "$WORK/odd.json" 'd["id"]')
get "/comparisons/$ODD_ID"
expect "the odd run from earlier (id $ODD_ID) is still there, exactly as it was answered, plus created_at" \
    "$(json_get "$WORK/body" "{k: v for k, v in d.items() if k != 'created_at'} == json.load(open('$WORK/odd.json'))")" True
contains "...with its findings" "$WORK/body" "read /etc/passwd (a sensitive file)"

echo "  -- pages and filters (on rows made by hand in the database file: 30 for check4_hist_a, 3 for check4_hist_b)"
python3 - "$DB" <<'EOF'
import json
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

db = sqlite3.connect(sys.argv[1])
moment = datetime.now(timezone.utc).replace(tzinfo=None)


def level(score):
    return "normal" if score <= 2 else "slightly unusual" if score <= 9 else "unusual" if score <= 24 else "very unusual"


def add(baseline, run, score):
    global moment
    moment += timedelta(seconds=1)
    answer = {"baseline": baseline, "run": run, "matches": score == 0, "score": score, "level": level(score),
              "features_compared": 10, "outside_range": score, "marker": "hand-made " + run, "warnings": []}
    db.execute("insert into comparisons (created_at, baseline_name, run, score, level, matches, features_compared, outside_range, result)"
               " values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
               (moment.strftime("%Y-%m-%d %H:%M:%S.%f"), baseline, run, score, level(score), int(score == 0), 10, score, json.dumps(answer)))


for score in range(30):
    add("check4_hist_a", "hist_a_%02d" % score, score)
for score in (40, 60, 100):
    add("check4_hist_b", "hist_b_%d" % score, score)
db.commit()
EOF
NOW=$(rows)
expect "(setup) 33 rows were added by hand" "$NOW" "$((ROWS + 1 + 33))"
SUM=$(sha256sum "$DB" | cut -d' ' -f1)
# a_ids '[5:10]'   the ids of the check4_hist_a rows, newest first, cut with a Python slice (asked of the database file directly)
a_ids() { dbq '[r[0] for r in c.execute("select id from comparisons where baseline_name = ? order by id desc", ("check4_hist_a",))]'"$1"; }
expect "the new rows show up at once, without restarting the server (total is $NOW)" "$(ask /comparisons 'd["total"]')" "$NOW"
expect "?baseline=check4_hist_a: total is 30" "$(ask '/comparisons?baseline=check4_hist_a' 'd["total"]')" 30
expect "...the first page is its 20 newest rows (ids checked in the database file)" "$(ask '/comparisons?baseline=check4_hist_a' '[c["id"] for c in d["comparisons"]]')" "$(a_ids '[:20]')"
expect "...and every one of them is of that baseline" "$(ask '/comparisons?baseline=check4_hist_a' 'all(c["baseline"] == "check4_hist_a" for c in d["comparisons"])')" True
expect "&limit=5: the 5 newest, and the page size is reported back" \
    "$(ask '/comparisons?baseline=check4_hist_a&limit=5' '[[c["id"] for c in d["comparisons"]], d["limit"], d["offset"]]')" "[$(a_ids '[:5]'), 5, 0]"
expect "&limit=5&offset=5: the next 5, and the offset is reported back" \
    "$(ask '/comparisons?baseline=check4_hist_a&limit=5&offset=5' '[[c["id"] for c in d["comparisons"]], d["limit"], d["offset"]]')" "[$(a_ids '[5:10]'), 5, 5]"
expect "&limit=100&offset=25: the last 5 (only 30 exist), total still 30" \
    "$(ask '/comparisons?baseline=check4_hist_a&limit=100&offset=25' '[[c["id"] for c in d["comparisons"]], d["total"]]')" "[$(a_ids '[25:]'), 30]"
expect "&offset=30 (past the end): no comparisons, but total is still 30" "$(ask '/comparisons?baseline=check4_hist_a&offset=30' '[len(d["comparisons"]), d["total"]]')" "[0, 30]"
ALL=""
for off in 0 10 20; do
    ALL="$ALL $(ask "/comparisons?baseline=check4_hist_a&limit=10&offset=$off" '" ".join(str(c["id"]) for c in d["comparisons"])')"
done
expect "three pages of 10 laid end to end are all 30 comparisons, newest first, none twice" "$(echo $ALL)" "$(a_ids '' | tr -d '[],')"
expect "limit=100 is allowed (200)" "$(get '/comparisons?limit=100'; status_of)" 200
REFUSED=0
for q in limit=0 limit=101 limit=-1 limit=abc offset=-1 offset=abc min_score=101 min_score=-1 min_score=abc; do
    get "/comparisons?$q"
    [ "$(status_of)" = 422 ] && REFUSED=$((REFUSED + 1))
done
expect "a wrong limit, offset or min_score is refused with 422 (9 of 9)" "$REFUSED" 9
expect "?min_score=40: total is the number of rows scoring 40 or more in the database file" \
    "$(ask '/comparisons?min_score=40' 'd["total"]')" "$(dbq 'c.execute("select count(*) from comparisons where score >= 40").fetchone()[0]')"
expect "...and every item scores 40 or more" "$(ask '/comparisons?min_score=40' 'all(c["score"] >= 40 for c in d["comparisons"])')" True
expect "?baseline=check4_hist_b&min_score=60: the two scoring 60 or more, newest first (60 itself counts)" \
    "$(ask '/comparisons?baseline=check4_hist_b&min_score=60' '[c["score"] for c in d["comparisons"]]')" "[100, 60]"
expect "...min_score=61 leaves only the 100" "$(ask '/comparisons?baseline=check4_hist_b&min_score=61' '[c["score"] for c in d["comparisons"]]')" "[100]"
expect "?baseline=check4_hist_a&min_score=25: the five scoring 25 to 29, newest first" \
    "$(ask '/comparisons?baseline=check4_hist_a&min_score=25' '[c["score"] for c in d["comparisons"]]')" "[29, 28, 27, 26, 25]"
expect "?min_score=0 filters nothing: total is every row ($NOW)" "$(ask '/comparisons?min_score=0' 'd["total"]')" "$NOW"
expect "an unknown baseline is not an error: 200, total 0, no comparisons" "$(ask '/comparisons?baseline=check4_nope' '[d["total"], d["comparisons"]]')" "[0, []]"
expect "a name made of SQL (x' OR '1'='1) finds nothing: it is a name, not code" "$(ask '/comparisons?baseline=x%27%20OR%20%271%27%3D%271' 'd["total"]')" 0
expect "a % in the name is not a wildcard" "$(ask '/comparisons?baseline=%25' 'd["total"]')" 0
expect "a part of a name finds nothing: the name must be exactly right" "$(ask '/comparisons?baseline=check4_hist' 'd["total"]')" 0
expect "a name that tries to drop the table finds nothing..." "$(ask '/comparisons?baseline=x%27%3B%20DROP%20TABLE%20comparisons%3B%20--' 'd["total"]')" 0
expect "...and the table and all its rows are still there" "$(rows)" "$NOW"
OKS=0
for q in %00 %F0%9F%98%80 %ff; do
    get "/comparisons?baseline=$q"
    [ "$(status_of)" = 200 ] && OKS=$((OKS + 1))
done
expect "odd characters in the name (a NUL, an emoji, a broken byte) do not crash it (3 of 3 answer 200)" "$OKS" 3

echo "  -- one comparison in full"
HID=$(dbq 'c.execute("select id from comparisons where run = ?", ("hist_a_17",)).fetchone()[0]')
get "/comparisons/$HID"
expect "a row made by hand: GET /comparisons/$HID answers 200" "$(status_of)" 200
cp "$WORK/body" "$WORK/detail.json"
expect "...it is the answer saved in that row, plus id and created_at (nothing else)" \
    "$(json_get "$WORK/detail.json" 'sorted(d)')" "['baseline', 'created_at', 'features_compared', 'id', 'level', 'marker', 'matches', 'outside_range', 'run', 'score', 'warnings']"
expect "...with the right id and the marker of that very row" "$(json_get "$WORK/detail.json" '[d["id"], d["marker"], d["score"]]')" "[$HID, 'hand-made hist_a_17', 17]"
get "/comparisons?baseline=check4_hist_a&limit=1&offset=12"
expect "the list item 12 places from the newest of that baseline is the same comparison, with the same time" \
    "$(json_get "$WORK/body" "[d['comparisons'][0]['id'] == $HID, d['comparisons'][0]['created_at'] == json.load(open('$WORK/detail.json'))['created_at']]")" "[True, True]"
get /comparisons/99999999
expect "an id that does not exist gives 404" "$(status_of)" 404
contains "...and the message names it" "$WORK/body" "No comparison with id 99999999"
NOTFOUND=0
for id in 0 -1 99999999999999999999; do
    get "/comparisons/$id"
    [ "$(status_of)" = 404 ] && NOTFOUND=$((NOTFOUND + 1))
done
expect "ids that cannot exist (0, -1 and 99999999999999999999) give 404 as well (3 of 3)" "$NOTFOUND" 3
get "/comparisons/$(printf '9%.0s' $(seq 1 3000))"
expect "an id 3000 digits long gives 404" "$(status_of)" 404
expect "...and the message does not echo all 3000 digits back" "$([ "$(wc -c < "$WORK/body")" -lt 300 ] && echo short || echo long)" short
REFUSED=0
for id in abc 1.5; do
    get "/comparisons/$id"
    [ "$(status_of)" = 422 ] && REFUSED=$((REFUSED + 1))
done
expect "an id that is not a whole number is refused with 422 (2 of 2)" "$REFUSED" 2

echo "  -- read-only, and only for this computer"
REFUSED=0
for method in POST PUT DELETE PATCH; do
    for path in /comparisons "/comparisons/$NEWID"; do
        get "$path" -X "$method"
        [ "$(status_of)" = 405 ] && REFUSED=$((REFUSED + 1))
    done
done
expect "POST, PUT, DELETE and PATCH on both history URLs are refused (8 of 8 give 405)" "$REFUSED" 8
expect "...and no comparison was added or removed" "$(rows)" "$NOW"
get /comparisons -H "Host: evil.example"
expect "a request addressed to another name is refused with 400, for the history too (DNS rebinding)" "$(status_of)" 400
get "/comparisons/$NEWID" -H "Host: evil.example"
expect "...also for one comparison" "$(status_of)" 400
get /comparisons -H "Origin: http://evil.example"
lacks "a page from another site is not given permission to read the history (no access-control-allow-origin)" "$WORK/head" "access-control-allow-origin"
expect "all the reading and refusing in this section left the database file byte for byte the same" "$(sha256sum "$DB" | cut -d' ' -f1)" "$SUM"

rm -f baselines/check4*.json /tmp/check4_flag /tmp/check4_pwned
rm -rf traces/runs/*check4*

echo
echo "10. The server stops cleanly"
kill "$SERVER" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$SERVER" 2>/dev/null || break; sleep 0.1; done
expect "the server process ended after being asked to stop" "$(kill -0 "$SERVER" 2>/dev/null && echo running || echo ended)" ended
wait "$SERVER" 2>/dev/null
SERVER=""
expect "nothing answers on the port any more" "$(curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/health" && echo answers || echo silent)" silent
expect "the check left no baseline file behind" "$(ls baselines/check4* 2>/dev/null | wc -l | tr -d ' ')" 0
expect "...and no run folder or temporary file either" "$(ls -d traces/runs/*check4* /tmp/check4_* 2>/dev/null | wc -l | tr -d ' ')" 0

echo
echo "11. The earlier phases still pass"
if bash check_phase3.sh > "$WORK/phase3.out" 2>&1; then
    pass "check_phase3.sh passes   ($(grep -E '^ALL ' "$WORK/phase3.out" | tail -1 | cut -d: -f1))"
else
    fail "check_phase3.sh fails; its last lines:"
    tail -n 6 "$WORK/phase3.out" | sed 's/^/          /'
fi

summary
[ "$FAILED" -eq 0 ]
