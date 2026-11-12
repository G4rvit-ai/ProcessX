#!/usr/bin/env bash
# check_phase5.sh - unit tests and production build for the dashboard.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/dashboard"

for tool in node npm; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing required tool: $tool"
        exit 1
    fi
done

echo "Node: $(node --version)"
echo "npm:  $(npm --version)"
if [ ! -d node_modules ]; then
    echo "Dependencies are not installed. Run: cd dashboard && npm install"
    exit 1
fi

npm test
npm run build
echo "Phase 5 dashboard tests and production build passed."
