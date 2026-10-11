#!/bin/zsh
# Builds Tokometer.app into ./build.
#   ./build.sh            build only
#   ./build.sh --install  also copy to ~/Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

NAME=Tokometer
VERSION=${VERSION:-0.1.0}
APP=build/$NAME.app

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$NAME" "$APP/Contents/MacOS/$NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>io.github.dzeveckij.tokometer</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x "$NAME" || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/$NAME.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/$NAME.app
  echo "Installed to ~/Applications/$NAME.app"
fi
