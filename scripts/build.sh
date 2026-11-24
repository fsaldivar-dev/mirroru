#!/bin/bash
# Builds build/Mirroru.app (the `mirroru` CLI lives inside it).
#   scripts/build.sh            build
#   scripts/build.sh --install  build, then symlink the CLI into /usr/local/bin (or ~/.local/bin)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/mirroru"

APP="build/Mirroru.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/mirroru"

# Icon: assets/icon_1024.png is the master (824 px tile centred on a transparent 1024 px canvas).
# If it is missing, a placeholder is drawn by scripts/make-icon.swift.
mkdir -p assets
[[ -f assets/icon_1024.png ]] || swift scripts/make-icon.swift assets/icon_1024.png >/dev/null
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mirroru</string>
  <key>CFBundleDisplayName</key><string>Mirroru</string>
  <key>CFBundleIdentifier</key><string>dev.mirroru.app</string>
  <key>CFBundleExecutable</key><string>mirroru</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>Mirroru usa la captura de video por USB para mostrar la pantalla de tu iPhone o iPad.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "OK  $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/usr/local/bin"
  [[ -w "$DEST" ]] || DEST="$HOME/.local/bin"
  mkdir -p "$DEST"
  ln -sf "$PWD/$APP/Contents/MacOS/mirroru" "$DEST/mirroru"
  echo "OK  $DEST/mirroru"
  case ":$PATH:" in *":$DEST:"*) ;; *) echo "    (añade $DEST a tu PATH)";; esac
fi
