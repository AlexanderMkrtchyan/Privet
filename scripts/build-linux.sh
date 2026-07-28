#!/usr/bin/env bash
# Build native Flutter Linux desktop (GTK), tarball, .deb, and local install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/development/flutter/bin:${PATH}"

OUT="$ROOT/server/public/downloads"
INSTALL_DIR="${PRIVET_INSTALL_DIR:-$HOME/Apps/privet}"
VERSION="$(python3 - "$ROOT/app/pubspec.yaml" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
for line in text.splitlines():
    if line.startswith("version:"):
        print(line.split(":",1)[1].strip().split("+",1)[0])
        break
else:
    raise SystemExit("version not found")
PY
)"
STAMP="${PRIVET_BUILD:-$(date -u +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

# PRIVET_SKIP_DOWNLOADS=1 → install ~/Apps/privet only (skip .deb/.tar.gz).
# Desktop app MUST always use production API — never localhost (breaks web peers).
SKIP_DOWNLOADS="${PRIVET_SKIP_DOWNLOADS:-0}"
PRIVET_API_DEFINE="${PRIVET_API:-https://messenger.banderdog.com}"
case "$PRIVET_API_DEFINE" in
  *127.0.0.1*|*localhost*)
    echo "Refusing Linux build with localhost API ($PRIVET_API_DEFINE)." >&2
    echo "The Ubuntu app must use https://messenger.banderdog.com so it sees web users." >&2
    echo "Omit PRIVET_API (production is the default). Local web stays on deploy-web.sh :7777." >&2
    exit 1
    ;;
esac

cd "$ROOT/app"
# tray_manager needs ayatana-appindicator3 headers. Prefer system -dev;
# otherwise use the repo-local extract under .local-build-deps (no sudo).
if ! pkg-config --exists ayatana-appindicator3-0.1 2>/dev/null && \
   ! pkg-config --exists appindicator3-0.1 2>/dev/null; then
  LOCAL_PC="$ROOT/.local-build-deps/pkgconfig"
  if [[ -d "$LOCAL_PC" ]]; then
    export PKG_CONFIG_PATH="$LOCAL_PC${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    echo "Using local ayatana-appindicator pkg-config at $LOCAL_PC"
  else
    echo "Missing ayatana-appindicator3 for tray_manager." >&2
    echo "Install: sudo apt-get install -y libayatana-appindicator3-dev" >&2
    echo "Or recreate .local-build-deps (see agent notes)." >&2
    exit 1
  fi
fi
flutter pub get

# Linux flutter_webrtc: cache receiver tracks on getTransceivers/OnTrack so
# mediaStreamAddTrack can resolve mid-call camera upgrades. Do not look up via
# receivers() inside MediaTrackForId — that re-entrant path crashed the app.
WEBRTC_CC="$(find "$HOME/.pub-cache/hosted" -path '*flutter_webrtc-*/common/cpp/src/flutter_peerconnection.cc' 2>/dev/null | sort | tail -1 || true)"
if [[ -n "$WEBRTC_CC" ]]; then
  python3 - "$WEBRTC_CC" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
changed = False

# 1) Cache tracks in GetTransceivers
old_gt = """void FlutterPeerConnection::GetTransceivers(
    RTCPeerConnection* pc,
    std::unique_ptr<MethodResultProxy> result) {
  std::shared_ptr<MethodResultProxy> result_ptr(result.release());
  EncodableMap map;
  EncodableList info;
  auto transceivers = pc->transceivers();
  for (scoped_refptr<RTCRtpTransceiver> transceiver :
       transceivers.std_vector()) {
    info.push_back(EncodableValue(transceiverToMap(transceiver)));
  }
  map[EncodableValue("transceivers")] = EncodableValue(info);
  result_ptr->Success(EncodableValue(map));
}"""
new_gt = """void FlutterPeerConnection::GetTransceivers(
    RTCPeerConnection* pc,
    std::unique_ptr<MethodResultProxy> result) {
  std::shared_ptr<MethodResultProxy> result_ptr(result.release());
  EncodableMap map;
  EncodableList info;
  auto transceivers = pc->transceivers();
  for (scoped_refptr<RTCRtpTransceiver> transceiver :
       transceivers.std_vector()) {
    info.push_back(EncodableValue(transceiverToMap(transceiver)));
    // Cache receiver tracks so mediaStreamAddTrack can resolve them later.
    // Unified-plan mid-call upgrades often never put these in remote_streams_,
    // and looking them up via receivers() inside MediaTrackForId can crash.
    if (transceiver.get() != nullptr) {
      auto receiver = transceiver->receiver();
      if (receiver.get() != nullptr) {
        auto track = receiver->track();
        if (track.get() != nullptr) {
          base_->local_tracks_[track->id().std_string()] = track;
        }
      }
    }
  }
  map[EncodableValue("transceivers")] = EncodableValue(info);
  result_ptr->Success(EncodableValue(map));
}"""
if 'Cache receiver tracks so mediaStreamAddTrack' not in text and old_gt in text:
    text = text.replace(old_gt, new_gt, 1)
    changed = True

# 2) Register OnTrack streams + cache track
old_ot = """void FlutterPeerConnectionObserver::OnTrack(
    scoped_refptr<RTCRtpTransceiver> transceiver) {
  auto receiver = transceiver->receiver();
  EncodableMap params;
  EncodableList streams_info;
  auto streams = receiver->streams();
  for (scoped_refptr<RTCMediaStream> item : streams.std_vector()) {
    streams_info.push_back(EncodableValue(mediaStreamToMap(item, id_)));
  }
  params[EncodableValue("event")] = "onTrack";
  params[EncodableValue("streams")] = EncodableValue(streams_info);
  params[EncodableValue("track")] =
      EncodableValue(mediaTrackToMap(receiver->track()));
  params[EncodableValue("receiver")] =
      EncodableValue(rtpReceiverToMap(receiver));
  params[EncodableValue("transceiver")] =
      EncodableValue(transceiverToMap(transceiver));

  event_channel_->Success(EncodableValue(params));
}"""
new_ot = """void FlutterPeerConnectionObserver::OnTrack(
    scoped_refptr<RTCRtpTransceiver> transceiver) {
  auto receiver = transceiver->receiver();
  EncodableMap params;
  EncodableList streams_info;
  auto streams = receiver->streams();
  for (scoped_refptr<RTCMediaStream> item : streams.std_vector()) {
    // Register so videoRendererSetSrcObject / MediaTrackForId can resolve them.
    remote_streams_[item->id().std_string()] = item;
    streams_info.push_back(EncodableValue(mediaStreamToMap(item, id_)));
  }
  auto track = receiver->track();
  if (track.get() != nullptr && base_ != nullptr) {
    base_->local_tracks_[track->id().std_string()] = track;
  }
  params[EncodableValue("event")] = "onTrack";
  params[EncodableValue("streams")] = EncodableValue(streams_info);
  params[EncodableValue("track")] =
      EncodableValue(mediaTrackToMap(track));
  params[EncodableValue("receiver")] =
      EncodableValue(rtpReceiverToMap(receiver));
  params[EncodableValue("transceiver")] =
      EncodableValue(transceiverToMap(transceiver));

  event_channel_->Success(EncodableValue(params));
}"""
if 'Register so videoRendererSetSrcObject' not in text and old_ot in text:
    text = text.replace(old_ot, new_ot, 1)
    changed = True

# 3) Strip any receivers()-inside-MediaTrackForId crash patch
crash = """  // Unified-plan: receiver tracks from a SendOnly→SendRecv upgrade often
  // never land in remote_streams_ (onTrack may not re-fire). Android resolves
  // these via getTransceiversTrack — mirror that here so mediaStreamAddTrack
  // can bind mid-call camera enable on Linux/desktop.
  if (peerconnection_ != nullptr) {
    auto receivers = peerconnection_->receivers();
    for (scoped_refptr<RTCRtpReceiver> receiver : receivers.std_vector()) {
      auto track = receiver->track();
      if (track != nullptr && track->id().std_string() == id) {
        return track;
      }
    }
  }
"""
safe = """  // Receiver tracks are cached into base_->local_tracks_ from OnTrack /
  // GetTransceivers (see those sites). Do not call receivers() here — that
  // re-entrant lookup during mediaStreamAddTrack crashed the Linux app.
"""
if crash in text:
    text = text.replace(crash, safe, 1)
    changed = True

if changed:
    path.write_text(text)
    print(f'patched {path}')
else:
    print(f'flutter_webrtc already patched ({path})')
PY
else
  echo "WARNING: could not locate flutter_webrtc to patch" >&2
fi

flutter build linux --release \
  --dart-define=PRIVET_BUILD="$STAMP" \
  --dart-define=PRIVET_API="$PRIVET_API_DEFINE"

BUNDLE="$ROOT/app/build/linux/x64/release/bundle"
test -x "$BUNDLE/privet"

# Brand app icon (not the default Flutter logo).
ICON_SRC=""
for candidate in \
  "$ROOT/packaging/assets/privet-app.png" \
  "$ROOT/server/public/icons/privet-app.png" \
  "$ROOT/app/web/icons/privet-app.png" \
  "$INSTALL_DIR/privet.png"
do
  if [[ -f "$candidate" ]]; then ICON_SRC="$candidate"; break; fi
done
if [[ -z "$ICON_SRC" ]]; then
  echo "Missing privet-app.png — generate one before packaging." >&2
  exit 1
fi

install_icon_theme() {
  local src="$1"
  python3 - "$src" <<'PY'
import os, sys
from PIL import Image
src = sys.argv[1]
img = Image.open(src).convert('RGBA')
home = os.path.expanduser('~')
for s in (16, 24, 32, 48, 64, 128, 256, 512):
    d = os.path.join(home, f'.local/share/icons/hicolor/{s}x{s}/apps')
    os.makedirs(d, exist_ok=True)
    img.resize((s, s), Image.Resampling.LANCZOS).save(os.path.join(d, 'privet.png'), 'PNG')
os.makedirs(os.path.join(home, '.local/share/icons'), exist_ok=True)
img.save(os.path.join(home, '.local/share/icons/privet.png'), 'PNG')
os.makedirs(os.path.join(home, '.local/share/pixmaps'), exist_ok=True)
img.save(os.path.join(home, '.local/share/pixmaps/privet.png'), 'PNG')
PY
}

# --- Relocatable tarball for /downloads ---
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/privet"
cp -a "$BUNDLE/." "$STAGE/privet/"
cp "$ICON_SRC" "$STAGE/privet/privet.png"
cat >"$STAGE/privet/README.txt" <<EOF
Privet for Linux (native) v${VERSION}
=====================================
Run: ./privet

This is a native GTK desktop app (not a browser window).
Talks to https://messenger.banderdog.com by default.

Optional menu launcher:
  mkdir -p ~/.local/share/applications
  cp privet.png ~/.local/share/icons/privet.png 2>/dev/null || true
  cat > ~/.local/share/applications/privet.desktop <<DESK
[Desktop Entry]
Name=Privet
Comment=Privet messenger
Exec=\$(pwd)/privet
Icon=\$(pwd)/privet.png
Terminal=false
Type=Application
Categories=Network;InstantMessaging;
StartupWMClass=com.privet.privet
DESK
  chmod +x ~/.local/share/applications/privet.desktop
EOF

TAR_OUT="$OUT/privet-linux-x64.tar.gz"
DEB_OUT="$OUT/privet_${VERSION}_amd64.deb"
DEB_STABLE="$OUT/privet-linux-amd64.deb"

if [[ "$SKIP_DOWNLOADS" != "1" ]]; then
tar -C "$STAGE" -czf "$TAR_OUT" privet
rm -rf "$STAGE"
echo "Wrote $TAR_OUT ($(du -h "$TAR_OUT" | cut -f1))"

# --- Debian package ---
DEB_ROOT="$(mktemp -d)"
PKG_DIR="$DEB_ROOT/privet_${VERSION}_amd64"
mkdir -p \
  "$PKG_DIR/DEBIAN" \
  "$PKG_DIR/usr/lib/privet" \
  "$PKG_DIR/usr/bin" \
  "$PKG_DIR/usr/share/applications" \
  "$PKG_DIR/usr/share/icons/hicolor/512x512/apps" \
  "$PKG_DIR/usr/share/doc/privet"

cp -a "$BUNDLE/." "$PKG_DIR/usr/lib/privet/"
cp "$ICON_SRC" "$PKG_DIR/usr/share/icons/hicolor/512x512/apps/privet.png"
# Smaller icon sizes for menus
python3 - "$ICON_SRC" "$PKG_DIR/usr/share/icons/hicolor" <<'PY'
import os, sys
from PIL import Image
src, root = sys.argv[1], sys.argv[2]
img = Image.open(src).convert('RGBA')
for s in (16, 24, 32, 48, 64, 128, 256):
    d = os.path.join(root, f'{s}x{s}/apps')
    os.makedirs(d, exist_ok=True)
    img.resize((s, s), Image.Resampling.LANCZOS).save(os.path.join(d, 'privet.png'), 'PNG')
PY

cat >"$PKG_DIR/usr/bin/privet" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="/usr/lib/privet"
# Conda/Anaconda injects Mesa-only EGL vendor dirs → llvmpipe (software GL).
# That makes Flutter paint at a few fps on an otherwise fine NVIDIA GPU.
unset __EGL_VENDOR_LIBRARY_DIRS
unset LIBGL_ALWAYS_SOFTWARE
unset GDK_GL
# Prefer X11 when on Wayland+NVIDIA (Flutter EGL often fails to show first frame).
if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] && [[ -e /proc/driver/nvidia/version || -e /dev/nvidia0 ]]; then
  export GDK_BACKEND="${GDK_BACKEND:-x11}"
fi
if [[ -e /dev/nvidia0 ]]; then
  export __GLX_VENDOR_LIBRARY_NAME=nvidia
  export __EGL_VENDOR_LIBRARY_DIRS=/usr/share/glvnd/egl_vendor.d
  # Threaded GL opts + Flutter vsync double-wait (avgVsyncMs~30). Off by default.
  export __GL_THREADED_OPTIMIZATIONS="${__GL_THREADED_OPTIMIZATIONS:-0}"
  export __GL_SYNC_TO_VBLANK="${__GL_SYNC_TO_VBLANK:-0}"
  unset __GL_MaxFramesAllowed
fi
# MUST use OpenGL: Flutter's software backend has no external-texture GL
# callback, so flutter_webrtc RTCVideoView (screen share / camera) paints black.
# Prefer OpenGL even if NVIDIA+X11 present is ~20–30fps — invisible video is worse.
# Override only for debugging: FLUTTER_LINUX_RENDERER=software.
export FLUTTER_LINUX_RENDERER="${FLUTTER_LINUX_RENDERER:-opengl}"
cd "$APP_DIR"
exec "$APP_DIR/privet" "$@"
EOF
chmod 755 "$PKG_DIR/usr/bin/privet"
chmod 755 "$PKG_DIR/usr/lib/privet/privet"

cat >"$PKG_DIR/usr/share/applications/privet.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Name=Privet
Comment=Privet messenger
Exec=privet
Icon=privet
Terminal=false
Type=Application
Categories=Network;InstantMessaging;
StartupWMClass=com.privet.privet
EOF

cat >"$PKG_DIR/usr/share/doc/privet/copyright" <<'EOF'
Privet messenger
Copyright (c) Privet contributors
EOF

cat >"$PKG_DIR/DEBIAN/control" <<EOF
Package: privet
Version: ${VERSION}
Section: net
Priority: optional
Architecture: amd64
Maintainer: Privet <privet@local>
Depends: libgtk-3-0 | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64, libstdc++6, libc6, libayatana-appindicator3-1 | libappindicator3-1
Description: Privet messenger (native Linux desktop)
 Native Flutter/GTK client for Privet. Connects to
 https://messenger.banderdog.com by default.
 Close hides to the system tray; use Quit Privet to exit.
EOF

# Ensure RPATH-friendly permissions on bundled libs
find "$PKG_DIR/usr/lib/privet" -type f -name '*.so*' -exec chmod 755 {} +
find "$PKG_DIR/usr/lib/privet" -type d -exec chmod 755 {} +

fakeroot dpkg-deb --build "$PKG_DIR" "$DEB_OUT"
cp -f "$DEB_OUT" "$DEB_STABLE"
rm -rf "$DEB_ROOT"
echo "Wrote $DEB_OUT ($(du -h "$DEB_OUT" | cut -f1))"
echo "Wrote $DEB_STABLE"
else
  rm -rf "$STAGE"
  echo "Skipped download packages (PRIVET_SKIP_DOWNLOADS=1, API=$PRIVET_API_DEFINE)"
fi

# --- Local install under ~/Apps/privet ---
mkdir -p "$INSTALL_DIR"
rsync -a --delete \
  --exclude 'README.txt' \
  --exclude 'privet.png' \
  --exclude 'privet-launch.sh' \
  "$BUNDLE/" "$INSTALL_DIR/"
cp "$ICON_SRC" "$INSTALL_DIR/privet.png"
cat >"$INSTALL_DIR/README.txt" <<EOF
Privet for Linux (native) v${VERSION}
=====================================
Run: $INSTALL_DIR/privet
Build: $STAMP
EOF
chmod +x "$INSTALL_DIR/privet"

install_icon_theme "$INSTALL_DIR/privet.png"

# Small wrapper so NVIDIA+Wayland hosts get a reliable X11 window.
cat >"$INSTALL_DIR/privet-launch.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$INSTALL_DIR"
# Always drop Conda/Mesa-swrast EGL overrides — they force llvmpipe.
unset __EGL_VENDOR_LIBRARY_DIRS
unset LIBGL_ALWAYS_SOFTWARE
unset GDK_GL
# Prefer X11 when on Wayland+NVIDIA (Flutter EGL often fails to show first frame).
if [[ "\${XDG_SESSION_TYPE:-}" == "wayland" ]] && [[ -e /proc/driver/nvidia/version || -e /dev/nvidia0 ]]; then
  export GDK_BACKEND="\${GDK_BACKEND:-x11}"
fi
if [[ -e /dev/nvidia0 ]]; then
  export __GLX_VENDOR_LIBRARY_NAME=nvidia
  export __EGL_VENDOR_LIBRARY_DIRS=/usr/share/glvnd/egl_vendor.d
  # Threaded GL opts + Flutter vsync double-wait (avgVsyncMs~30). Off by default.
  export __GL_THREADED_OPTIMIZATIONS="\${__GL_THREADED_OPTIMIZATIONS:-0}"
  export __GL_SYNC_TO_VBLANK="\${__GL_SYNC_TO_VBLANK:-0}"
  unset __GL_MaxFramesAllowed
fi
# MUST use OpenGL: Flutter's software backend has no external-texture GL
# callback, so flutter_webrtc RTCVideoView (screen share / camera) paints black.
# Prefer OpenGL even if NVIDIA+X11 present is ~20–30fps — invisible video is worse.
# Override only for debugging: FLUTTER_LINUX_RENDERER=software.
export FLUTTER_LINUX_RENDERER="\${FLUTTER_LINUX_RENDERER:-opengl}"
exec "$INSTALL_DIR/privet" "\$@"
EOF
chmod +x "$INSTALL_DIR/privet-launch.sh"

# Shadow /usr/bin/privet (stale .deb) so `privet` on PATH runs this install.
# ~/.local/bin is ahead of /usr/bin on typical Ubuntu PATHs.
mkdir -p "$HOME/.local/bin"
cat >"$HOME/.local/bin/privet" <<EOF
#!/usr/bin/env bash
exec "$INSTALL_DIR/privet-launch.sh" "\$@"
EOF
chmod +x "$HOME/.local/bin/privet"

# Absolute Icon= path so GNOME never falls back to a generic gear.
mkdir -p "$HOME/.local/share/applications"
cat >"$HOME/.local/share/applications/privet.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Privet
Comment=Privet messenger
Exec=$INSTALL_DIR/privet-launch.sh
Icon=$INSTALL_DIR/privet.png
Terminal=false
Type=Application
Categories=Network;InstantMessaging;
StartupWMClass=com.privet.privet
EOF
chmod +x "$HOME/.local/share/applications/privet.desktop"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

echo "Installed native app → $INSTALL_DIR/privet (v${VERSION}, build ${STAMP}, API=$PRIVET_API_DEFINE)"
echo "Menu entry → ~/.local/share/applications/privet.desktop"
if [[ "$SKIP_DOWNLOADS" != "1" ]]; then
  # Dart defines land in libapp.so (not the thin privet launcher ELF).
  APP_SO="$BUNDLE/lib/libapp.so"
  if [[ ! -f "$APP_SO" ]]; then
    echo "ERROR: missing $APP_SO" >&2
    exit 1
  fi
  # Avoid `rg -q` / `grep -q` under `pipefail`: early exit SIGPIPEs strings
  # and the pipeline can fail even when the needle is present.
  if strings "$APP_SO" | grep -F '127.0.0.1:7777' >/dev/null; then
    echo "ERROR: libapp.so contains 127.0.0.1:7777 — refusing to publish." >&2
    exit 1
  fi
  if ! strings "$APP_SO" | grep -F 'messenger.banderdog.com' >/dev/null; then
    echo "ERROR: libapp.so missing production host — refusing to publish." >&2
    exit 1
  fi
  ls -lah "$TAR_OUT" "$DEB_OUT" "$DEB_STABLE" "$INSTALL_DIR/privet" "$INSTALL_DIR/privet.png"
  chmod +x "$ROOT/scripts/write-version-json.sh"
  "$ROOT/scripts/write-version-json.sh"
else
  ls -lah "$INSTALL_DIR/privet" "$INSTALL_DIR/privet.png"
fi
