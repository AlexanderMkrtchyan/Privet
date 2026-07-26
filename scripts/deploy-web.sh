#!/usr/bin/env bash
# Build Flutter web and publish into the Node static host (:7777).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/development/flutter/bin:${PATH}"

# Keep install/ + downloads/ + version.json across --delete (not produced by Flutter).
STAGE="$(mktemp -d)"
[[ -d "$ROOT/server/public/install" ]] && cp -a "$ROOT/server/public/install" "$STAGE/install"
[[ -d "$ROOT/server/public/downloads" ]] && cp -a "$ROOT/server/public/downloads" "$STAGE/downloads"
[[ -f "$ROOT/server/public/version.json" ]] && cp -a "$ROOT/server/public/version.json" "$STAGE/version.json"

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
# Drop Flutter's deprecated cleanup SW if present — we ship app/web/sw.js.
rm -f "$ROOT/server/public/flutter_service_worker.js"
[[ -d "$STAGE/install" ]] && { rm -rf "$ROOT/server/public/install"; cp -a "$STAGE/install" "$ROOT/server/public/install"; }
[[ -d "$STAGE/downloads" ]] && { rm -rf "$ROOT/server/public/downloads"; cp -a "$STAGE/downloads" "$ROOT/server/public/downloads"; }
[[ -f "$STAGE/version.json" ]] && cp -a "$STAGE/version.json" "$ROOT/server/public/version.json"
rm -rf "$STAGE"

# Stamp PWA service worker cache version (source lives in app/web/sw.js).
# Also ensure install helper + manifest are present at site root.
python3 - <<PY
from pathlib import Path
import shutil
stamp = "$STAMP"
root = Path("$ROOT/server/public")
src_web = Path("$ROOT/app/web")
for name in ("sw.js", "pwa-install.js", "manifest.json"):
    src = src_web / name
    if src.is_file():
        shutil.copy2(src, root / name)
sw = root / "sw.js"
if sw.is_file():
    sw.write_text(sw.read_text().replace("__PRIVET_BUILD__", stamp))
PY

# Unique filename — query-string cache bust is ignored by some browsers.
MAIN_NAMED="main.${STAMP}.js"
cp -f "$ROOT/server/public/main.dart.js" "$ROOT/server/public/$MAIN_NAMED"

printf '%s\n' "$STAMP" > "$ROOT/server/public/BUILD_STAMP.txt"
python3 - <<PY
from pathlib import Path
import re, shutil
stamp = "$STAMP"
main_named = "$MAIN_NAMED"
root = Path("$ROOT/server/public")

# Cache-bust the Flutter shell from the build output (never from public/
# index.html — that may already be the marketing landing page).
flutter_index = Path("$ROOT/app/build/web/index.html")
it = flutter_index.read_text()
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
app_dir = root / "app"
app_dir.mkdir(exist_ok=True)
(app_dir / "index.html").write_text(it)

# Landing page (source-controlled) becomes the public site root.
shutil.copyfile("$ROOT/server/landing/index.html", str(root / "index.html"))

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
print(f"landing at /, chat at /app/ ({main_named})")
PY

echo "Deployed to http://127.0.0.1:7777/  stamp=${STAMP}"
echo "Landing: http://127.0.0.1:7777/     Chat app: http://127.0.0.1:7777/app/"
echo "Hard-reload chat: http://127.0.0.1:7777/app/?v=${STAMP}"
echo "PWA: manifest + /sw.js (local only; prod still --pwa-strategy=none)"
