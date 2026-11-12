#!/usr/bin/env bash
# Build the dashboard, start the integrated app, and verify its web and API routes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
SERVER=""
PASSED=0

cleanup() {
    if [ -n "$SERVER" ] && kill -0 "$SERVER" 2>/dev/null; then
        kill "$SERVER" 2>/dev/null || true
        wait "$SERVER" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

pass() {
    echo "  PASS  $1"
    PASSED=$((PASSED + 1))
}

for tool in node npm python3 curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing required tool: $tool" >&2
        exit 1
    fi
done

if ! python3 -c "import fastapi, sqlalchemy, uvicorn" 2>/dev/null; then
    echo "Activate the project venv and install requirements.txt before running this check." >&2
    exit 1
fi

echo "1. Dashboard tests and production build"
bash "$ROOT/check_phase5.sh"

echo
echo "2. Start the integrated backend"
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
DB="$WORK/phase6.db"
(cd "$WORK" && env PROCESSX_DATABASE_URL="sqlite:///$DB" python3 -m uvicorn --app-dir "$ROOT" backend.main:app --host 127.0.0.1 --port "$PORT") >"$WORK/server.log" 2>&1 &
SERVER=$!
READY=no
for _ in $(seq 1 60); do
    if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" -o "$WORK/health.json"; then
        READY=yes
        break
    fi
    if ! kill -0 "$SERVER" 2>/dev/null; then
        break
    fi
    sleep 0.25
done
if [ "$READY" != yes ]; then
    echo "Backend did not start. Server log:" >&2
    cat "$WORK/server.log" >&2
    exit 1
fi
pass "backend starts and /health responds"

curl -fsS --max-time 3 "http://127.0.0.1:$PORT/" -o "$WORK/index.html"
if ! grep -q '<title>ProcessX — Behavior dashboard</title>' "$WORK/index.html"; then
    echo "The root route did not serve the built dashboard index." >&2
    exit 1
fi
pass "GET / serves the dashboard HTML"

python3 - "$WORK/index.html" "$PORT" <<'PY'
import re
import sys
import urllib.error
import urllib.request

html_path, port = sys.argv[1:]
html = open(html_path, encoding="utf-8").read()
assets = re.findall(r'(?:src|href)="(/assets/[^"]+)"', html)
if len(assets) < 2:
    raise SystemExit("Built dashboard HTML does not reference its JS and CSS assets.")
for asset in assets:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{asset}", timeout=3) as response:
        if response.status != 200 or not response.read(64):
            raise SystemExit(f"Dashboard asset did not load: {asset}")

with urllib.request.urlopen(f"http://127.0.0.1:{port}/baselines", timeout=3) as response:
    if response.status != 200 or b'"baselines"' not in response.read():
        raise SystemExit("The /baselines API route did not respond with baseline data.")

with urllib.request.urlopen(f"http://127.0.0.1:{port}/docs", timeout=3) as response:
    if response.status != 200 or b"ProcessX" not in response.read():
        raise SystemExit("The API documentation route stopped working.")

request = urllib.request.Request(
    f"http://127.0.0.1:{port}/",
    headers={"Host": "attacker.invalid"},
)
try:
    urllib.request.urlopen(request, timeout=3)
except urllib.error.HTTPError as error:
    if error.code != 400:
        raise SystemExit(f"Untrusted Host returned {error.code}, expected 400.")
else:
    raise SystemExit("Untrusted Host was unexpectedly accepted.")

request = urllib.request.Request(
    f"http://127.0.0.1:{port}/baselines/demo/compare",
    data=b"",
    method="POST",
    headers={"Origin": "http://attacker.invalid"},
)
try:
    urllib.request.urlopen(request, timeout=3)
except urllib.error.HTTPError as error:
    if error.code != 403:
        raise SystemExit(f"Foreign page Origin returned {error.code}, expected 403.")
else:
    raise SystemExit("Foreign page Origin was unexpectedly accepted.")
PY
pass "built JS/CSS assets load and /baselines remains an API endpoint"
pass "API documentation and browser Origin protections still work"
pass "TrustedHostMiddleware still rejects an untrusted Host"

echo
echo "ALL $PASSED PHASE 6 CHECKS PASSED."
