#!/usr/bin/env bash
# Run the focused Python unit tests for the parser, scoring, and database layers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${PYTHON:-python3}"

"$PYTHON" -m unittest discover -s "$ROOT/tests" -p 'test_*.py' -v
