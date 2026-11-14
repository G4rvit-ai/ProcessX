#!/usr/bin/env bash
# Prepare a fresh Linux/WSL checkout for ProcessX.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${PYTHON:-python3}"

for tool in "$PYTHON" npm gcc strace; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is required. Install it with your Linux distribution's package manager." >&2
        exit 1
    fi
done

"$PYTHON" -m venv "$ROOT/venv"
"$ROOT/venv/bin/python" -m pip install -r "$ROOT/requirements.txt"
npm --prefix "$ROOT/dashboard" install

gcc -Wall -Wextra -o "$ROOT/test_programs/basic_ops.out" "$ROOT/test_programs/basic_ops.c"
gcc -Wall -Wextra -o "$ROOT/test_programs/variants.out" "$ROOT/test_programs/variants.c"

echo
echo "ProcessX is ready."
echo "Activate the environment with: source venv/bin/activate"
echo "Start the dashboard with: ./start_processx.sh"
