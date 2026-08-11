#!/usr/bin/env bash
# Poll GitHub Actions release run; when done, download the Windows installer
# from the GitHub Release into server/public/downloads/ and refresh checksums.
#
# The run's overall conclusion is "failure" whenever the best-effort Linux job
# fails, even if the publish job succeeded — so we poll for the actual release
# asset rather than the run conclusion.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID=31509468705
TAG=v0.1.15
VERSION=0.1.15

echo "Polling release run ${RUN_ID} ..."
for i in $(seq 1 160); do
  STATUS="$(curl -s "https://api.github.com/repos/AlexanderMkrtchyan/Privet/actions/runs/${RUN_ID}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status'), d.get('conclusion') or '')")"
  echo "[poll $i] run status: ${STATUS}"
  case "$STATUS" in
    completed*)
      echo "Release workflow completed (conclusion=${STATUS##* })."
      break
      ;;
  esac
  if [[ "$i" == 160 ]]; then
    echo "Timed out waiting for release workflow."
    exit 1
  fi
  sleep 30
done

echo "Waiting for installer asset on release ${TAG} ..."
for i in $(seq 1 30); do
  ASSET_URL="$(curl -s "https://api.github.com/repos/AlexanderMkrtchyan/Privet/releases/tags/${TAG}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('assets', []):
    if a['name'].startswith('Privet-Setup-') and a['name'].endswith('.exe'):
        print(a['browser_download_url'])
        break
")"
  if [[ -n "$ASSET_URL" ]]; then
    break
  fi
  echo "[asset poll $i] installer not yet published"
  if [[ "$i" == 30 ]]; then
    echo "ERROR: installer asset never appeared on release ${TAG}"
    exit 1
  fi
  sleep 20
done

echo "Downloading ${ASSET_URL}"
cd "$ROOT/server/public/downloads"
curl -fL -sSL -o "Privet-Setup.exe" "$ASSET_URL"
cp -f "Privet-Setup.exe" "Privet-Setup-${VERSION}.exe"
ls -lah "Privet-Setup.exe" "Privet-Setup-${VERSION}.exe"
echo "Downloaded new Windows installer."
