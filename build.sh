#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# The bundle takes the display name, spaces and all — that is what Finder shows.
# The executable inside it does not, so `ps`, `pkill` and the crash reporter all
# still name a single word.
APP_NAME="Claude Battery"
EXEC_NAME="ClaudeBattery"
# Unchanged on purpose: the bundle id is the app's identity to LaunchServices and
# to every permission the user has already granted the deployed copy. Renaming
# the app is cosmetic; renaming its id is not.
BUNDLE_ID="com.izu.claudeusagebar"
VERSION="1.0"
APP="dist/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$EXEC_NAME"

echo "==> selftest"
"$BIN" --selftest

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>          <string>en</string>
    <key>CFBundleExecutable</key>                 <string>$EXEC_NAME</string>
    <key>CFBundleIdentifier</key>                 <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
    <key>CFBundleName</key>                       <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>                <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>                <string>APPL</string>
    <key>CFBundleShortVersionString</key>         <string>$VERSION</string>
    <key>CFBundleVersion</key>                    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>             <string>14.0</string>
    <key>LSUIElement</key>                        <true/>
    <key>NSHighResolutionCapable</key>            <true/>
    <key>NSPrincipalClass</key>                   <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign (ad-hoc)"
codesign --force --deep -s - "$APP"
codesign --verify "$APP"

echo "==> built $ROOT/$APP"
