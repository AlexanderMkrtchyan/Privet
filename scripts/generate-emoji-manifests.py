#!/usr/bin/env python3
"""Regenerate Fluent animated emoji manifest from Microsoft's open repos."""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "app" / "assets" / "emoji" / "fluent_manifest.json"
ANIMATED_TREE = (
    "https://api.github.com/repos/microsoft/fluentui-emoji-animated/git/trees/main?recursive=1"
)
META_BASE = "https://raw.githubusercontent.com/microsoft/fluentui-emoji/main/assets"
# Git LFS: raw.githubusercontent.com returns pointer text, not APNG bytes.
# media.githubusercontent.com serves the real files (with CORS).
MEDIA_BASE = (
    "https://media.githubusercontent.com/media/microsoft/fluentui-emoji-animated/main"
)


def fetch_json(url: str) -> object:
    req = urllib.request.Request(url, headers={"User-Agent": "privet-emoji-manifest"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def main() -> None:
    tree = fetch_json(ANIMATED_TREE)
    folder_urls: dict[str, str] = {}
    for entry in tree["tree"]:
        path = entry["path"]
        if "/animated/" not in path or not path.endswith("_animated.png"):
            continue
        folder = path.split("/")[1]
        url = MEDIA_BASE + "/" + "/".join(
            urllib.parse.quote(seg) for seg in path.split("/")
        )
        folder_urls[folder] = url

    manifest: dict[str, str] = {}
    for folder, url in folder_urls.items():
        meta_url = f"{META_BASE}/{urllib.parse.quote(folder)}/metadata.json"
        try:
            meta = fetch_json(meta_url)
        except Exception:
            continue
        glyph = meta.get("glyph")
        if glyph:
            manifest[glyph] = url

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(manifest, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"wrote {OUT} ({len(manifest)} glyphs, {OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
