#!/usr/bin/env python3
"""Pack Noto Color Emoji bitmaps into app/assets/emoji/noto_color_emoji.bin.

Windows DirectWrite cannot paint the CBDT/CBLC system font, so the Flutter
client draws these PNGs instead. The bytes are the same 109px strikes Linux
uses, shaped with HarfBuzz against Unicode emoji-test sequences.

Usage:
  python3 scripts/extract-noto-color-emoji.py
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FONT = Path("/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf")
EMOJI_TEST = Path("/tmp/emoji-test.txt")
OUT = ROOT / "app/assets/emoji/noto_color_emoji.bin"
EMOJI_TEST_URL = "https://www.unicode.org/Public/emoji/16.0/emoji-test.txt"


def _need(mod: str, pip_name: str) -> None:
    try:
        __import__(mod)
    except ImportError:
        sys.exit(f"Missing {pip_name}. Use a venv: pip install {pip_name}")


def main() -> None:
    _need("fontTools", "fonttools")
    _need("uharfbuzz", "uharfbuzz")
    from fontTools.ttLib import TTFont
    import uharfbuzz as hb

    if not FONT.is_file():
        sys.exit(f"Noto Color Emoji not found at {FONT}")

    if not EMOJI_TEST.is_file():
        import urllib.request

        print(f"Downloading {EMOJI_TEST_URL}")
        urllib.request.urlretrieve(EMOJI_TEST_URL, EMOJI_TEST)

    tt = TTFont(FONT)
    pngs = {name: bmp.imageData for name, bmp in tt["CBDT"].strikeData[0].items()}
    glyph_order = tt.getGlyphOrder()

    blob = hb.Blob.from_file_path(str(FONT))
    face = hb.Face(blob)
    hbfont = hb.Font(face)

    def shape_glyph(text: str) -> str | None:
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(hbfont, buf)
        infos = buf.glyph_infos
        if len(infos) != 1:
            return None
        gid = infos[0].codepoint
        if gid >= len(glyph_order):
            return None
        return glyph_order[gid]

    atlas: dict[str, bytes] = {}
    for line in EMOJI_TEST.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or ";" not in line:
            continue
        cps = line.split(";", 1)[0]
        try:
            text = "".join(chr(int(p, 16)) for p in cps.split())
        except ValueError:
            continue
        name = shape_glyph(text)
        if name is None:
            continue
        data = pngs.get(name)
        if not data:
            continue
        atlas[text] = data
        stripped = text.replace("\uFE0F", "")
        if stripped and stripped not in atlas:
            atlas[stripped] = data

    uniq: dict[bytes, list[str]] = {}
    for text, data in atlas.items():
        uniq.setdefault(data, []).append(text)
    blob_list = list(uniq.keys())
    blob_ix = {data: i for i, data in enumerate(blob_list)}

    buf = bytearray(b"NCE1")
    buf.extend(struct.pack("<I", len(blob_list)))
    for data in blob_list:
        buf.extend(struct.pack("<I", len(data)))
        buf.extend(data)
    items = [(text, blob_ix[data]) for text, data in atlas.items()]
    buf.extend(struct.pack("<I", len(items)))
    for text, ix in items:
        raw = text.encode("utf-8")
        buf.extend(struct.pack("<H", len(raw)))
        buf.extend(raw)
        buf.extend(struct.pack("<I", ix))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(buf)
    print(
        f"wrote {OUT} ({len(buf)} bytes, {len(blob_list)} images, {len(items)} keys)"
    )


if __name__ == "__main__":
    main()
