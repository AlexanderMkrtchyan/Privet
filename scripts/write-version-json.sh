#!/usr/bin/env bash
# Write server/public/version.json from app/pubspec.yaml (used by desktop updater).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/server/public/version.json}"

python3 - "$ROOT/app/pubspec.yaml" "$OUT" <<'PY'
import json, sys
from pathlib import Path

pubspec = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])
version = build = None
for line in pubspec.splitlines():
    if line.startswith("version:"):
        raw = line.split(":", 1)[1].strip()
        if "+" in raw:
            version, build = raw.split("+", 1)
        else:
            version, build = raw, "0"
        break
if not version:
    raise SystemExit("version not found in pubspec.yaml")

payload = {
    "app_name": "privet",
    "version": version,
    "build_number": build,
    "package_name": "privet",
    "windows_setup_url": "/downloads/Privet-Setup.exe",
    "linux_deb_url": "/downloads/privet-linux-amd64.deb",
    "linux_tar_url": "/downloads/privet-linux-x64.tar.gz",
    "windows": {"setup_url": "/downloads/Privet-Setup.exe"},
    "linux": {
        "deb_url": "/downloads/privet-linux-amd64.deb",
        "tar_url": "/downloads/privet-linux-x64.tar.gz",
    },
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(payload, indent=2) + "\n")
print(f"Wrote {out} version={version}+{build}")
PY
