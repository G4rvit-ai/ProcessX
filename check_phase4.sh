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
trap 'stop_server; rm -f "$TMP_BASELINE"; rm -rf "$WORK"' EXIT

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
contains "it names the project: ProcessX" "$WORK/body" '"title":"ProcessX"'

echo
echo "5. The server stops cleanly"
kill "$SERVER" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$SERVER" 2>/dev/null || break; sleep 0.1; done
expect "the server process ended after being asked to stop" "$(kill -0 "$SERVER" 2>/dev/null && echo running || echo ended)" ended
wait "$SERVER" 2>/dev/null
SERVER=""
expect "nothing answers on the port any more" "$(curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/health" && echo answers || echo silent)" silent
expect "the check left no baseline file behind" "$([ -e "$TMP_BASELINE" ] && echo left || echo clean)" clean

echo
echo "6. The earlier phases still pass"
if bash check_phase3.sh > "$WORK/phase3.out" 2>&1; then
    pass "check_phase3.sh passes   ($(grep -E '^ALL ' "$WORK/phase3.out" | tail -1 | cut -d: -f1))"
else
    fail "check_phase3.sh fails; its last lines:"
    tail -n 6 "$WORK/phase3.out" | sed 's/^/          /'
fi

summary
[ "$FAILED" -eq 0 ]
