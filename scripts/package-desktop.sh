#!/usr/bin/env bash
# Build desktop downloads into server/public/downloads/.
# Linux = native Flutter GTK (.tar.gz + .deb)
# Windows = native Flutter + Inno Setup installer (requires Windows host / CI)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/server/public/downloads"
mkdir -p "$OUT"

"$ROOT/scripts/build-linux.sh"

if [[ "${OS:-}" == "Windows_NT" ]] || [[ "$(uname -s 2>/dev/null || true)" == MINGW* ]]; then
  "$ROOT/scripts/build-windows.sh"
else
  echo "Skipping native Windows build on $(uname -s) — CI windows-latest will produce Privet-Setup.exe"
  echo "Legacy Go browser launcher is no longer the primary Windows artifact."
fi

echo "Desktop artifacts in $OUT:"
ls -lah "$OUT" || true
