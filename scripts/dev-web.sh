#!/usr/bin/env bash
# Prefer web-server over `flutter run -d chrome`.
# Chrome device uses a throwaway profile (login wiped) and often crashes on
# Wayland when WebGL is unavailable ("webGLVersion is -1").
#
# Usage:
#   ./scripts/dev-web.sh
# Then open http://127.0.0.1:8080 in your normal browser (once).
# In this terminal:  r = hot reload,  R = hot restart,  q = quit
set -euo pipefail
export PATH="${HOME}/development/flutter/bin:${PATH}"
cd "$(dirname "$0")/../app"

# Ensure API is up
if ! curl -sf http://127.0.0.1:7777/health >/dev/null 2>&1; then
  echo "Starting API on :7777…"
  (cd ../server && node src/index.js >/tmp/privet-api.log 2>&1 &)
  sleep 1
fi

exec flutter run -d web-server \
  --web-hostname 127.0.0.1 \
  --web-port 8080 \
  --dart-define=PRIVET_API=http://127.0.0.1:7777
