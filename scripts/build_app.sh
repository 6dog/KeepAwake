#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Keep Awake"
BUNDLE_ID="com.jesseyun.KeepAwake"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
EXECUTABLE_SOURCE="$ROOT_DIR/.build/release/KeepAwake"
EXECUTABLE_DEST="$APP_PATH/Contents/MacOS/$APP_NAME"
ICON_SOURCE="$ROOT_DIR/Resources/KeepAwake.icns"
ICON_DEST="$APP_PATH/Contents/Resources/KeepAwake.icns"
BATTERY_SCRIPT_SOURCE="$ROOT_DIR/Resources/check_logi_battery.py"
BATTERY_SCRIPT_DEST="$APP_PATH/Contents/Resources/check_logi_battery.py"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$EXECUTABLE_SOURCE" "$EXECUTABLE_DEST"
cp "$ICON_SOURCE" "$ICON_DEST"
cp "$BATTERY_SCRIPT_SOURCE" "$BATTERY_SCRIPT_DEST"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>KeepAwake</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_PATH" >/dev/null
rm -rf "$ROOT_DIR/$APP_NAME.app"
cp -R "$APP_PATH" "$ROOT_DIR/$APP_NAME.app"

echo "$ROOT_DIR/$APP_NAME.app"
