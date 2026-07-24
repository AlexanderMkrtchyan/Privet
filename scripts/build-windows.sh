#!/usr/bin/env bash
# Build native Flutter Windows app + Inno Setup installer.
# Must run on Windows (or CI windows-latest). On Linux this script exits with guidance.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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
OUT="$ROOT/server/public/downloads"
mkdir -p "$OUT"

if [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* && "$(uname -s)" != CYGWIN* && "${FORCE_WINDOWS_BUILD:-}" != "1" ]]; then
  # Detect real Windows via OS env commonly set in Git Bash / Actions
  if [[ "${OS:-}" != "Windows_NT" ]]; then
    echo "Windows Flutter builds require a Windows host (or GitHub Actions windows-latest)." >&2
    echo "Packaging config is ready at packaging/windows/privet.iss" >&2
    echo "On Windows / CI, run: ./scripts/build-windows.sh" >&2
    exit 2
  fi
fi

export PATH="${FLUTTER_ROOT:+$FLUTTER_ROOT/bin:}${HOME}/development/flutter/bin:${PATH}"
cd "$ROOT/app"
flutter pub get
flutter build windows --release \
  --dart-define=PRIVET_BUILD="$STAMP"

RELEASE_DIR="$ROOT/app/build/windows/x64/runner/Release"
test -f "$RELEASE_DIR/privet.exe" || test -f "$RELEASE_DIR/Privet.exe" || {
  echo "Missing Release/privet.exe under $RELEASE_DIR" >&2
  ls -la "$RELEASE_DIR" >&2 || true
  exit 1
}

# Normalize exe name if Flutter used capitalized binary
if [[ -f "$RELEASE_DIR/Privet.exe" && ! -f "$RELEASE_DIR/privet.exe" ]]; then
  cp -f "$RELEASE_DIR/Privet.exe" "$RELEASE_DIR/privet.exe"
fi

ISCC=""
for candidate in \
  "${ISCC:-}" \
  "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" \
  "/c/Program Files/Inno Setup 6/ISCC.exe" \
  "C:/Program Files (x86)/Inno Setup 6/ISCC.exe" \
  "C:/Program Files/Inno Setup 6/ISCC.exe"
do
  if [[ -n "$candidate" && -x "$candidate" ]]; then ISCC="$candidate"; break; fi
  if [[ -n "$candidate" && -f "$candidate" ]]; then ISCC="$candidate"; break; fi
done

if [[ -z "$ISCC" ]] && command -v iscc >/dev/null 2>&1; then
  ISCC="$(command -v iscc)"
fi

if [[ -z "$ISCC" ]]; then
  echo "Inno Setup ISCC.exe not found. Install Inno Setup 6, or set ISCC=..." >&2
  echo "Release folder is ready at: $RELEASE_DIR" >&2
  # Still ship a zip as fallback artifact
  ZIP_OUT="$OUT/privet-windows-x64.zip"
  (cd "$RELEASE_DIR/.." && rm -f "$ZIP_OUT" && command -v zip >/dev/null && zip -r "$ZIP_OUT" Release || powershell -NoProfile -Command "Compress-Archive -Path '$RELEASE_DIR\\*' -DestinationPath '$ZIP_OUT' -Force")
  echo "Wrote fallback zip $ZIP_OUT"
  exit 1
fi

ISS="$ROOT/packaging/windows/privet.iss"
# Convert paths for ISCC (prefer Windows-style when available)
"$ISCC" \
  "//DMyAppVersion=${VERSION}" \
  "//DSourceDir=${RELEASE_DIR}" \
  "//DOutputDir=${OUT}" \
  "//DMyAppIcon=${ROOT}/app/windows/runner/resources/app_icon.ico" \
  "$ISS"

VERSIONED="$OUT/Privet-Setup-${VERSION}.exe"
STABLE="$OUT/Privet-Setup.exe"
if [[ -f "$VERSIONED" ]]; then
  cp -f "$VERSIONED" "$STABLE"
  echo "Wrote $VERSIONED"
  echo "Wrote $STABLE"
else
  # Inno may have written differently; find newest Setup exe
  newest="$(ls -t "$OUT"/Privet-Setup*.exe 2>/dev/null | head -1 || true)"
  if [[ -n "$newest" ]]; then
    cp -f "$newest" "$STABLE"
    echo "Wrote $newest → $STABLE"
  else
    echo "Installer not found in $OUT" >&2
    exit 1
  fi
fi

ls -lah "$STABLE" "$VERSIONED" 2>/dev/null || ls -lah "$OUT"/Privet-Setup*.exe
echo "Windows build stamp=${STAMP} version=${VERSION}"
