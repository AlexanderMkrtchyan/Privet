#!/usr/bin/env bash
# Restart local Privet Flutter Chrome against the Node API on :7777.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export PATH="/home/alex/development/flutter/bin:$PATH"

pkill -f 'flutter_tools.snapshot run -d chrome' 2>/dev/null || true
sleep 1

cd "$ROOT/app"
exec flutter run -d chrome --dart-define=PRIVET_API=http://127.0.0.1:7777
