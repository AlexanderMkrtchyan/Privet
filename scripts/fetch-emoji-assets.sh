#!/usr/bin/env bash
# Fetch / unpack Privet emoji animation assets.
#
# IconScout (primary): download the free pack zip from
#   https://iconscout.com/lottie-animation-pack/emoji-animation-pack_108754
# and place it at downloads/iconscout-emoji-pack.zip (or set ICONSCOUT_PACK_ZIP).
#
# JoyPixels (secondary): export licensed Lottie JSON from
#   https://app.joypixels.com/animations
# into downloads/joypixels-animations/ (or set JOYPIXELS_DIR).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_ASSETS="$ROOT/app/assets/emoji"
ICONSCOUT_DIR="$APP_ASSETS/iconscout"
JOYPixels_DIR="$APP_ASSETS/joypixels"
ICONSCOUT_ZIP="${ICONSCOUT_PACK_ZIP:-$ROOT/downloads/iconscout-emoji-pack.zip}"
JOYPixels_SRC="${JOYPIXELS_DIR:-$ROOT/downloads/joypixels-animations}"

python3 "$ROOT/scripts/generate-emoji-manifests.py"

mkdir -p "$ICONSCOUT_DIR" "$JOYPixels_DIR"

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_|_$//g'
}

if [[ -f "$ICONSCOUT_ZIP" ]]; then
  echo "Unpacking IconScout pack from $ICONSCOUT_ZIP"
  tmp="$(mktemp -d)"
  unzip -qo "$ICONSCOUT_ZIP" -d "$tmp"
  find "$tmp" -name '*.json' -print0 | while IFS= read -r -d '' file; do
    base="$(basename "$file" .json)"
    target="$(slugify "$base").json"
  case "$target" in
    embarressed*|embaressed*) target="embarrassed.json" ;;
    fake*smile*) target="fake_smile.json" ;;
    grindy*) target="grindy_teeth.json" ;;
    lovely_eyes*|lovely-eyes*) target="lovely_eyes.json" ;;
    shocked_emoji*|shocked-emoji*)
      if [[ ! -f "$ICONSCOUT_DIR/shocked.json" ]]; then target="shocked.json"; else target="shocked2.json"; fi ;;
  esac
    cp "$file" "$ICONSCOUT_DIR/$target"
  done
  rm -rf "$tmp"
  echo "IconScout JSON files in $ICONSCOUT_DIR: $(find "$ICONSCOUT_DIR" -name '*.json' | wc -l)"
else
  echo "IconScout zip not found ($ICONSCOUT_ZIP) — skip (Fluent/Noto still work)."
fi

if [[ -d "$JOYPixels_SRC" ]]; then
  echo "Importing JoyPixels animations from $JOYPixels_SRC"
  find "$JOYPixels_SRC" -name '*.json' -print0 | while IFS= read -r -d '' file; do
    base="$(basename "$file")"
    cp "$file" "$JOYPixels_DIR/$base"
  done
  python3 - "$JOYPixels_DIR" "$APP_ASSETS/joypixels_manifest.json" <<'PY'
import json, re, sys
from pathlib import Path

joy_dir = Path(sys.argv[1])
out = Path(sys.argv[2])
manifest = json.loads(out.read_text(encoding='utf-8'))
by_glyph = manifest.setdefault('byGlyph', {})

def codepoints(raw: str) -> str | None:
    m = re.search(r'(?:u)?([0-9a-f]{4,}(?:_[0-9a-f]{4,})*)', raw, re.I)
    if not m:
        return None
    parts = m.group(1).lower().split('_')
    try:
        return ''.join(chr(int(p, 16)) for p in parts)
    except ValueError:
        return None

for path in joy_dir.glob('*.json'):
    glyph = codepoints(path.stem)
    if glyph:
        by_glyph[glyph] = path.name

out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(f'joypixels manifest: {len(by_glyph)} glyphs')
PY
else
  echo "JoyPixels dir not found ($JOYPixels_SRC) — skip."
fi
