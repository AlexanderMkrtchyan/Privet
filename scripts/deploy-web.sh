#!/usr/bin/env bash
# Build Flutter web and publish into the Node static host (:7777).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/development/flutter/bin:${PATH}"

# Keep install/ + downloads/ across --delete (not produced by Flutter).
STAGE="$(mktemp -d)"
[[ -d "$ROOT/server/public/install" ]] && cp -a "$ROOT/server/public/install" "$STAGE/install"
[[ -d "$ROOT/server/public/downloads" ]] && cp -a "$ROOT/server/public/downloads" "$STAGE/downloads"

# Stamp before build so the UI badge matches the cache-bust query.
STAMP="$(date -u +%Y%m%d-%H%M%S)"

# Brand PWA icons from privet-app.png (not Flutter defaults).
python3 - <<PY
from pathlib import Path
from PIL import Image

root = Path("$ROOT/app/web")
src_path = root / "icons/privet-app.png"
if not src_path.is_file():
    raise SystemExit(f"Missing {src_path}")
src = Image.open(src_path).convert("RGBA")

def save_resize(path: Path, size: int) -> None:
    img = src if src.size == (size, size) else src.resize((size, size), Image.Resampling.LANCZOS)
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG", optimize=True)

icons = root / "icons"
for name, size in (
    ("Icon-192.png", 192),
    ("Icon-512.png", 512),
    ("Icon-maskable-192.png", 192),
    ("Icon-maskable-512.png", 512),
):
    save_resize(icons / name, size)
save_resize(root / "favicon.png", 32)
print("PWA icons refreshed from privet-app.png")
PY

cd "$ROOT/app"
flutter build web --release \
  --pwa-strategy=none \
  --dart-define=PRIVET_API=http://127.0.0.1:7777 \
  --dart-define=PRIVET_BUILD="$STAMP" \
  --no-wasm-dry-run

rsync -a --delete "$ROOT/app/build/web/" "$ROOT/server/public/"
# Ensure no SW can resurrect old bundles.
rm -f "$ROOT/server/public/flutter_service_worker.js"
[[ -d "$STAGE/install" ]] && { rm -rf "$ROOT/server/public/install"; cp -a "$STAGE/install" "$ROOT/server/public/install"; }
[[ -d "$STAGE/downloads" ]] && { rm -rf "$ROOT/server/public/downloads"; cp -a "$STAGE/downloads" "$ROOT/server/public/downloads"; }
rm -rf "$STAGE"

# Unique filename — query-string cache bust is ignored by some browsers.
MAIN_NAMED="main.${STAMP}.js"
cp -f "$ROOT/server/public/main.dart.js" "$ROOT/server/public/$MAIN_NAMED"

printf '%s\n' "$STAMP" > "$ROOT/server/public/BUILD_STAMP.txt"
python3 - <<PY
from pathlib import Path
import re
stamp = "$STAMP"
main_named = "$MAIN_NAMED"
# Bust bootstrap script URL in index.html
index = Path("$ROOT/server/public/index.html")
it = index.read_text()
it = re.sub(
    r"flutter_bootstrap\.js\?v=[^'\"]+",
    f"flutter_bootstrap.js?v={stamp}",
    it,
)
it = re.sub(
    r'(href="favicon\.png)(\?v=[^"]*)?(")',
    rf'\1?v={stamp}\3',
    it,
    count=1,
)
index.write_text(it)
# Point loader at uniquely named bundle (path change beats query-cache).
boot = Path("$ROOT/server/public/flutter_bootstrap.js")
bt = boot.read_text()
bt = bt.replace(
    '"mainJsPath":"main.dart.js"',
    f'"mainJsPath":"{main_named}"',
)
bt = re.sub(
    r'"mainJsPath":"main\.dart\.js\?v=[^"]+"',
    f'"mainJsPath":"{main_named}"',
    bt,
)
bt = re.sub(
    r'"mainJsPath":"main\.[0-9]{8}-[0-9]{6}\.js"',
    f'"mainJsPath":"{main_named}"',
    bt,
)
boot.write_text(bt)
print(f"cache-busted {main_named}")
PY

echo "Deployed to http://127.0.0.1:7777/  stamp=${STAMP}"
echo "Green badge next to Privet should show ${STAMP##*-}."
echo "Hard-reload: http://127.0.0.1:7777/?v=${STAMP}"
