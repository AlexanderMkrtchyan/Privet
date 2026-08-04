#!/usr/bin/env bash
# Build native Flutter Android APK for sideload / downloads.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-$HOME/.local/opt/jdk-17}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export PATH="${JAVA_HOME}/bin:${HOME}/development/flutter/bin:${ANDROID_HOME}/platform-tools:${PATH}"

OUT="$ROOT/server/public/downloads"
mkdir -p "$OUT"

VERSION="$(python3 - "$ROOT/app/pubspec.yaml" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
for line in text.splitlines():
    if line.startswith("version:"):
        print(line.split(":", 1)[1].strip().split("+", 1)[0])
        break
else:
    raise SystemExit("version not found")
PY
)"
STAMP="${PRIVET_BUILD:-$(date -u +%Y%m%d-%H%M%S)}"
PRIVET_API_DEFINE="${PRIVET_API:-https://messenger.banderdog.com}"
case "$PRIVET_API_DEFINE" in
  *127.0.0.1*|*localhost*)
    echo "Refusing Android build with localhost API ($PRIVET_API_DEFINE)." >&2
    echo "The Android app must use https://messenger.banderdog.com so it sees web users." >&2
    exit 1
    ;;
esac

if [[ ! -x "$JAVA_HOME/bin/java" ]]; then
  echo "Missing JDK at $JAVA_HOME (set JAVA_HOME or install Temurin 17)." >&2
  exit 1
fi
if [[ ! -d "$ANDROID_HOME" ]]; then
  echo "Missing Android SDK at $ANDROID_HOME (set ANDROID_HOME)." >&2
  exit 1
fi

flutter config --android-sdk "$ANDROID_HOME" >/dev/null

# Launcher icons from the shared brand asset.
ICON_SRC=""
for candidate in \
  "$ROOT/packaging/assets/privet-app.png" \
  "$ROOT/server/public/icons/privet-app.png" \
  "$ROOT/app/web/icons/privet-app.png"
do
  if [[ -f "$candidate" ]]; then ICON_SRC="$candidate"; break; fi
done
if [[ -z "$ICON_SRC" ]]; then
  echo "Missing privet-app.png for launcher icons." >&2
  exit 1
fi
python3 - "$ICON_SRC" "$ROOT/app/android/app/src/main/res" <<'PY'
import sys
from pathlib import Path
from PIL import Image
src, res = Path(sys.argv[1]), Path(sys.argv[2])
img = Image.open(src).convert('RGBA')
for name, size in [
    ('mipmap-mdpi', 48), ('mipmap-hdpi', 72), ('mipmap-xhdpi', 96),
    ('mipmap-xxhdpi', 144), ('mipmap-xxxhdpi', 192),
]:
    d = res / name
    d.mkdir(parents=True, exist_ok=True)
    img.resize((size, size), Image.Resampling.LANCZOS).save(d / 'ic_launcher.png', 'PNG')
print(f'Launcher icons from {src}')
PY

cd "$ROOT/app"
flutter pub get

FCM_DEFINES=()
FIREBASE_ENV="$ROOT/app/firebase.env"
if [[ -f "$FIREBASE_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$FIREBASE_ENV"
  if [[ -n "${PRIVET_FCM_API_KEY:-}" ]]; then
    FCM_DEFINES+=(
      --dart-define=PRIVET_FCM_API_KEY="$PRIVET_FCM_API_KEY"
      --dart-define=PRIVET_FCM_APP_ID="${PRIVET_FCM_APP_ID:-}"
      --dart-define=PRIVET_FCM_SENDER_ID="${PRIVET_FCM_SENDER_ID:-}"
      --dart-define=PRIVET_FCM_PROJECT_ID="${PRIVET_FCM_PROJECT_ID:-}"
    )
    echo "FCM client config loaded from firebase.env"
  fi
else
  echo "No app/firebase.env — push when app is killed needs: scripts/setup-firebase.sh" >&2
fi

flutter build apk --release \
  --dart-define=PRIVET_BUILD="$STAMP" \
  --dart-define=PRIVET_API="$PRIVET_API_DEFINE" \
  "${FCM_DEFINES[@]}"

APK="$ROOT/app/build/app/outputs/flutter-apk/app-release.apk"
test -f "$APK"

VERSIONED="$OUT/privet-android-${VERSION}.apk"
STABLE="$OUT/privet-android.apk"
cp -f "$APK" "$VERSIONED"
cp -f "$APK" "$STABLE"

echo "Wrote $VERSIONED ($(du -h "$VERSIONED" | cut -f1))"
echo "Wrote $STABLE"
echo "Android build v${VERSION} stamp=${STAMP} API=$PRIVET_API_DEFINE"

chmod +x "$ROOT/scripts/write-version-json.sh"
"$ROOT/scripts/write-version-json.sh"

ls -lah "$STABLE" "$VERSIONED"
