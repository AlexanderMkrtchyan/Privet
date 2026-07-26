#!/usr/bin/env bash
# Build Flutter web (same-origin) on this machine and upload to Kamatera.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/development/flutter/bin:${PATH}"

REMOTE_HOST="${PRIVET_REMOTE_HOST:-root@213.255.227.131}"
REMOTE_DIR="${PRIVET_REMOTE_DIR:-/home/alex/privet/server}"

preserve_static_extras() {
  local stage="$1"
  rm -rf "$stage"
  mkdir -p "$stage"
  if [[ -d "$ROOT/server/public/install" ]]; then
    cp -a "$ROOT/server/public/install" "$stage/install"
  fi
  if [[ -d "$ROOT/server/public/downloads" ]]; then
    cp -a "$ROOT/server/public/downloads" "$stage/downloads"
  fi
  if [[ -f "$ROOT/server/public/version.json" ]]; then
    cp -a "$ROOT/server/public/version.json" "$stage/version.json"
  fi
}

restore_static_extras() {
  local stage="$1"
  if [[ -d "$stage/install" ]]; then
    rm -rf "$ROOT/server/public/install"
    cp -a "$stage/install" "$ROOT/server/public/install"
  fi
  if [[ -d "$stage/downloads" ]]; then
    rm -rf "$ROOT/server/public/downloads"
    cp -a "$stage/downloads" "$ROOT/server/public/downloads"
  fi
  if [[ -f "$stage/version.json" ]]; then
    cp -a "$stage/version.json" "$ROOT/server/public/version.json"
  fi
  rm -rf "$stage"
}

STAGE="$(mktemp -d)"
preserve_static_extras "$STAGE"

STAMP="$(date -u +%Y%m%d-%H%M%S)"

cd "$ROOT/app"
# Same-origin: browser uses https://messenger.banderdog.com (no localhost API).
flutter build web --release \
  --pwa-strategy=none \
  --dart-define=PRIVET_BUILD="$STAMP" \
  --no-wasm-dry-run

rsync -a --delete "$ROOT/app/build/web/" "$ROOT/server/public/"
rm -f "$ROOT/server/public/flutter_service_worker.js"
restore_static_extras "$STAGE"

printf '%s\n' "$STAMP" > "$ROOT/server/public/BUILD_STAMP.txt"
python3 - <<PY
from pathlib import Path
import re, shutil
stamp = "$STAMP"
root = Path("$ROOT/server/public")

# Ensure custom PWA assets survive Flutter publish (also copied from app/web/).
src_web = Path("$ROOT/app/web")
for name in ("sw.js", "pwa-install.js", "manifest.json"):
    src = src_web / name
    if src.is_file():
        shutil.copy2(src, root / name)

# Stamp service worker cache version.
sw = root / "sw.js"
if sw.is_file():
    sw.write_text(sw.read_text().replace("__PRIVET_BUILD__", stamp))

# The freshly built Flutter shell lands at public/index.html — relocate it to
# /app/ so the marketing landing page can own the site root.
shell = (root / "index.html").read_text()
shell = re.sub(
    r"flutter_bootstrap\.js(\?v=[^'\"]+)?",
    f"flutter_bootstrap.js?v={stamp}",
    shell,
    count=1,
)
# Prefer absolute PWA asset URLs after relocate under /app/.
shell = shell.replace('href="manifest.json"', 'href="/manifest.json"')
shell = shell.replace("href='manifest.json'", "href='/manifest.json'")
shell = re.sub(
    r'src="pwa-install\.js"',
    'src="/pwa-install.js"',
    shell,
)
shell = re.sub(
    r"src='pwa-install\.js'",
    "src='/pwa-install.js'",
    shell,
)
app_dir = root / "app"
app_dir.mkdir(exist_ok=True)
(app_dir / "index.html").write_text(shell)

# Landing page (source-controlled) becomes the public site root.
shutil.copyfile("$ROOT/server/landing/index.html", str(root / "index.html"))

# Cache-bust the Flutter engine bundle reference.
boot = root / "flutter_bootstrap.js"
bt = boot.read_text()
bt = bt.replace(
    '"mainJsPath":"main.dart.js"',
    f'"mainJsPath":"main.dart.js?v={stamp}"',
)
bt = re.sub(
    r'"mainJsPath":"main\.dart\.js\?v=[^"]+"',
    f'"mainJsPath":"main.dart.js?v={stamp}"',
    bt,
)
boot.write_text(bt)
print(f"landing at /, chat at /app/ (v={stamp})")
PY

echo "Uploading to ${REMOTE_HOST}:${REMOTE_DIR} ..."
rsync -az --delete \
  --exclude 'data/' \
  --exclude 'node_modules/' \
  --exclude '.env' \
  --exclude 'ecosystem.config.cjs' \
  "$ROOT/server/src/" "${REMOTE_HOST}:${REMOTE_DIR}/src/"

rsync -az \
  "$ROOT/server/package.json" \
  "$ROOT/server/package-lock.json" \
  "${REMOTE_HOST}:${REMOTE_DIR}/"

if [[ -f "$ROOT/server/.env" ]]; then
  rsync -az "$ROOT/server/.env" "${REMOTE_HOST}:${REMOTE_DIR}/.env"
  echo "Uploaded server/.env (GEMINI_API_KEY for AI)"
fi

rsync -az --delete \
  --exclude 'downloads/' \
  --exclude 'install/' \
  "$ROOT/server/public/" "${REMOTE_HOST}:${REMOTE_DIR}/public/"

# Always ship install + downloads + version.json explicitly (may be newer than remote).
rsync -az "$ROOT/server/public/install/" "${REMOTE_HOST}:${REMOTE_DIR}/public/install/"
rsync -az "$ROOT/server/public/downloads/" "${REMOTE_HOST}:${REMOTE_DIR}/public/downloads/"
if [[ -f "$ROOT/server/public/version.json" ]]; then
  rsync -az "$ROOT/server/public/version.json" "${REMOTE_HOST}:${REMOTE_DIR}/public/version.json"
fi

ssh -o BatchMode=yes "$REMOTE_HOST" bash -s <<REMOTE
set -euo pipefail
# Match PM2 interpreter (native modules must match Node ABI).
export PATH="/root/.nvm/versions/node/v26.2.0/bin:\${PATH}"
cd "$REMOTE_DIR"
node -v
npm ci --omit=dev
pm2 restart privet
pm2 describe privet | head -20
REMOTE

echo "Deployed to https://messenger.banderdog.com/  stamp=${STAMP}"
echo "Confirm green badge v41 next to Privet."
