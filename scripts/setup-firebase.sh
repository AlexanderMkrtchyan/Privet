#!/usr/bin/env bash
# One-time Firebase setup for Privet Android push (Telegram-style).
#
# Prerequisites: Node.js, a Google account
#
# Usage:
#   scripts/setup-firebase.sh
#
# Creates:
#   app/firebase.env          — client dart-defines (safe to commit placeholders)
#   app/android/app/google-services.json (if firebase CLI succeeds)
#
# Then add PRIVET_FCM_SERVER_KEY to server/.env and redeploy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/app"
ENV_FILE="$APP/firebase.env"
GS_JSON="$APP/android/app/google-services.json"

echo "==> Privet Firebase / FCM setup"
echo ""

if ! command -v npx >/dev/null; then
  echo "Need npx (Node.js). Install Node first." >&2
  exit 1
fi

echo "Step 1: Log into Firebase (browser opens)"
npx --yes firebase-tools@14.3.1 login

PROJECT_ID="${PRIVET_FIREBASE_PROJECT:-privet-messenger-$(date +%Y%m%d)}"
echo ""
echo "Step 2: Create Firebase project: $PROJECT_ID"
if ! npx --yes firebase-tools@14.3.1 projects:create "$PROJECT_ID" --display-name "Privet Messenger" 2>/dev/null; then
  echo "Project may already exist — continuing with $PROJECT_ID"
fi
npx --yes firebase-tools@14.3.1 use "$PROJECT_ID"

echo ""
echo "Step 3: Register Android app com.privet.privet"
npx --yes firebase-tools@14.3.1 apps:create android \
  com.privet.privet \
  --project "$PROJECT_ID" \
  --display-name "Privet Android" || true

echo ""
echo "Step 4: Download google-services.json"
mkdir -p "$(dirname "$GS_JSON")"
npx --yes firebase-tools@14.3.1 apps:sdkconfig android \
  --project "$PROJECT_ID" \
  --out "$GS_JSON" || {
  echo "Could not auto-download google-services.json."
  echo "Download manually from Firebase console → Project settings → Your apps → Android"
}

echo ""
echo "Step 5: Read client config from google-services.json"
python3 - "$GS_JSON" "$ENV_FILE" <<'PY'
import json, sys
from pathlib import Path
gs_path, env_path = Path(sys.argv[1]), Path(sys.argv[2])
if not gs_path.is_file():
    print(f"Missing {gs_path} — fill {env_path} manually from Firebase console.", file=sys.stderr)
    sys.exit(1)
data = json.loads(gs_path.read_text())
client = data["client"][0]["client_info"]
project = data["project_info"]
api_key = data["client"][0]["api_key"][0]["current_key"]
lines = [
    f"PRIVET_FCM_API_KEY={api_key}",
    f"PRIVET_FCM_APP_ID={client['mobilesdk_app_id']}",
    f"PRIVET_FCM_SENDER_ID={project['project_number']}",
    f"PRIVET_FCM_PROJECT_ID={project['project_id']}",
    "",
    "# Server-only — Cloud Messaging → Cloud Messaging API (Legacy) → Server key",
    "# PRIVET_FCM_SERVER_KEY=",
]
env_path.write_text("\n".join(lines) + "\n")
print(f"Wrote {env_path}")
PY

echo ""
echo "Step 6: Server key (legacy FCM)"
echo "  1. Open https://console.firebase.google.com/project/$PROJECT_ID/settings/cloudmessaging"
echo "  2. Enable Cloud Messaging API (Legacy) if needed"
echo "  3. Copy the Server key → add to server/.env:"
echo "       PRIVET_FCM_SERVER_KEY=<your-server-key>"
echo "  4. Run: scripts/deploy-prod.sh"
echo ""
echo "Step 7: Rebuild Android APK"
echo "       scripts/build-android.sh"
echo ""
echo "Done. firebase.env is ready for the next Android build."
