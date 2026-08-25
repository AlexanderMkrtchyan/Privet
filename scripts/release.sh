#!/usr/bin/env bash
# One-command release:
#   1. Bump version in app/pubspec.yaml (patch|minor|major, default patch).
#   2. Build Linux packages + Android APK locally.
#   3. Deploy web + downloads (incl. Android APK) to production.
#   4. Commit release files, tag vX.Y.Z, push branch + tag to GitHub.
#
# The tag push triggers .github/workflows/release.yml, which compiles the
# Windows installer with the bumped version automatically (it reads the
# version straight from app/pubspec.yaml).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUMP="${1:-patch}"
case "$BUMP" in
  patch|minor|major) ;;
  *)
    echo "Usage: $0 [patch|minor|major]" >&2
    exit 1
    ;;
esac

VERSION_INFO="$(python3 - "$ROOT/app/pubspec.yaml" "$BUMP" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
bump = sys.argv[2]
text = path.read_text()
m = re.search(r"^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)(?:\+([0-9]+))?", text, re.M)
if not m:
    raise SystemExit("version not found in app/pubspec.yaml")

major, minor, patch = (int(g) for g in m.groups()[:3])
build = int(m.group(4) or 0)
old_full = f"{major}.{minor}.{patch}+{build}"

if bump == "major":
    major, minor, patch = major + 1, 0, 0
elif bump == "minor":
    minor, patch = minor + 1, 0
else:
    patch += 1

new_full = f"{major}.{minor}.{patch}+{build + 1}"
text = re.sub(r"^version:\s*[^\n]+", f"version: {new_full}", text, count=1, flags=re.M)
path.write_text(text)
print(f"{old_full} {new_full}")
PY
)"

read -r OLD_FULL NEW_FULL <<< "$VERSION_INFO"
NEW_VERSION="${NEW_FULL%%+*}"
TAG="v${NEW_VERSION}"

echo "=== Privet release: ${OLD_FULL} -> ${NEW_FULL} (tag ${TAG}) ==="
echo ""

echo "==> [1/4] Building Linux packages"
"$ROOT/scripts/build-linux.sh"
echo ""

echo "==> [2/4] Building Android APK"
"$ROOT/scripts/build-android.sh"
echo ""

echo "==> [3/4] Deploying web + downloads to production"
"$ROOT/scripts/deploy-prod.sh"
echo ""

echo "==> [4/4] Committing, tagging and pushing to GitHub"
git add -u app/pubspec.yaml server/public/
if git diff --cached --quiet; then
  echo "Nothing staged to commit."
else
  git commit -m "Release v${NEW_VERSION}"
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "Tag ${TAG} already exists — skipping."
else
  git tag -a "${TAG}" -m "Privet v${NEW_VERSION}"
fi

git push origin HEAD
git push origin "${TAG}"
echo ""

STAMP="$(cat "$ROOT/server/public/BUILD_STAMP.txt" 2>/dev/null || echo "?")"
echo "=== Done: Privet ${NEW_FULL} ==="
echo "Tag pushed:            ${TAG}"
echo "Production web:        https://messenger.banderdog.com/app/?v=${STAMP}"
echo "Production Android:    https://messenger.banderdog.com/downloads/privet-android-${NEW_VERSION}.apk"
echo "GitHub Release (Windows .exe) will be published by CI automatically."
echo "Note: uncommitted changes outside app/pubspec.yaml and server/public/ were left untouched."
