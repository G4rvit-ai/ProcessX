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
TMP_BASELINE=baselines/check4_tmp.json

stop_server() {
    if [ -n "$SERVER" ] && kill -0 "$SERVER" 2>/dev/null; then
        kill "$SERVER" 2>/dev/null
        wait "$SERVER" 2>/dev/null
    fi
    SERVER=""
}
trap 'stop_server; rm -f baselines/check4*.json; rm -rf "$WORK"' EXIT

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
for tool in python3 curl; do
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
for file in backend/main.py backend/__init__.py requirements.txt check_phase3.sh; do
    if [ ! -f "$file" ]; then
        echo "  Missing file: $file"
        exit 1
    fi
done
pass "python3, curl, FastAPI and uvicorn are installed, and the backend files are there"
contains "requirements.txt lists fastapi" requirements.txt "fastapi"
contains "requirements.txt lists uvicorn" requirements.txt "uvicorn"

echo
echo "1. Start the server"
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m uvicorn backend.main:app --host 127.0.0.1 --port "$PORT" > "$WORK/server.log" 2>&1 &
SERVER=$!
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
echo "8. The server stops cleanly"
kill "$SERVER" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$SERVER" 2>/dev/null || break; sleep 0.1; done
expect "the server process ended after being asked to stop" "$(kill -0 "$SERVER" 2>/dev/null && echo running || echo ended)" ended
wait "$SERVER" 2>/dev/null
SERVER=""
expect "nothing answers on the port any more" "$(curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/health" && echo answers || echo silent)" silent
expect "the check left no baseline file behind" "$(ls baselines/check4* 2>/dev/null | wc -l | tr -d ' ')" 0

echo
echo "9. The earlier phases still pass"
if bash check_phase3.sh > "$WORK/phase3.out" 2>&1; then
    pass "check_phase3.sh passes   ($(grep -E '^ALL ' "$WORK/phase3.out" | tail -1 | cut -d: -f1))"
else
    fail "check_phase3.sh fails; its last lines:"
    tail -n 6 "$WORK/phase3.out" | sed 's/^/          /'
fi

summary
[ "$FAILED" -eq 0 ]
