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

cd "$ROOT/app"
flutter pub get
flutter build linux --release \
  --dart-define=PRIVET_BUILD="$STAMP"

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
Talks to https://messanger.banderdog.com by default.

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
# Prefer X11 when on Wayland+NVIDIA (Flutter EGL often fails to show first frame).
if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] && [[ -e /proc/driver/nvidia/version || -e /dev/nvidia0 ]]; then
  export GDK_BACKEND="${GDK_BACKEND:-x11}"
fi
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
Depends: libgtk-3-0 | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64, libstdc++6, libc6
Description: Privet messenger (native Linux desktop)
 Native Flutter/GTK client for Privet. Connects to
 https://messanger.banderdog.com by default.
EOF

# Ensure RPATH-friendly permissions on bundled libs
find "$PKG_DIR/usr/lib/privet" -type f -name '*.so*' -exec chmod 755 {} +
find "$PKG_DIR/usr/lib/privet" -type d -exec chmod 755 {} +

DEB_OUT="$OUT/privet_${VERSION}_amd64.deb"
# Also publish a stable filename for the install page
DEB_STABLE="$OUT/privet-linux-amd64.deb"
fakeroot dpkg-deb --build "$PKG_DIR" "$DEB_OUT"
cp -f "$DEB_OUT" "$DEB_STABLE"
rm -rf "$DEB_ROOT"
echo "Wrote $DEB_OUT ($(du -h "$DEB_OUT" | cut -f1))"
echo "Wrote $DEB_STABLE"

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
# Prefer X11 when on Wayland+NVIDIA (Flutter EGL often fails to show first frame).
if [[ "\${XDG_SESSION_TYPE:-}" == "wayland" ]] && [[ -e /proc/driver/nvidia/version || -e /dev/nvidia0 ]]; then
  export GDK_BACKEND="\${GDK_BACKEND:-x11}"
fi
exec "$INSTALL_DIR/privet" "\$@"
EOF
chmod +x "$INSTALL_DIR/privet-launch.sh"

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

echo "Installed native app → $INSTALL_DIR/privet (v${VERSION}, build ${STAMP})"
echo "Menu entry → ~/.local/share/applications/privet.desktop"
ls -lah "$TAR_OUT" "$DEB_OUT" "$DEB_STABLE" "$INSTALL_DIR/privet" "$INSTALL_DIR/privet.png"
