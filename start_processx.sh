#!/usr/bin/env bash
# Build the dashboard and start the local-only ProcessX server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

if ! command -v npm >/dev/null 2>&1; then
    echo "npm is required to build the dashboard. Install Node.js and npm first." >&2
    exit 1
fi

if [ ! -d "$ROOT/dashboard/node_modules" ]; then
    echo "Dashboard packages are missing. Run: npm --prefix dashboard install" >&2
    exit 1
fi

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1 || ! "$PYTHON" -c "import fastapi, sqlalchemy, uvicorn" 2>/dev/null; then
    echo "Backend packages are missing from $PYTHON." >&2
    echo "Activate the project venv and run: pip install -r requirements.txt" >&2
    exit 1
fi

npm --prefix "$ROOT/dashboard" run build
cd "$ROOT"
exec "$PYTHON" -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
