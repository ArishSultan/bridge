#!/bin/sh
# Build the app and wrap it in a macOS app bundle: build/Bridge.app.
# Copy it to /Applications to launch it from Spotlight, Launchpad or the Dock.
# Run scripts/build-ghostty.sh first (once, and after updating vendor/ghostty).
# Builds for Apple Silicon (run it on an Apple Silicon Mac).
set -eu

cd "$(dirname "$0")/.."
name="Bridge"
version=$(cat version.txt)

[ -d vendor/GhosttyKit.xcframework ] || { echo "No libghostty; run scripts/build-ghostty.sh first." >&2; exit 1; }

swift build -c release --arch arm64
bin=$(swift build -c release --arch arm64 --show-bin-path)

app="build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp "$bin/Bridge" "$app/Contents/MacOS/Bridge"
# Messages from bash, SSH password prompts, and the guard around child processes.
cp "$bin/bridge-helper" "$app/Contents/Helpers/bridge-helper"

# libghostty's resources: terminfo (xterm-ghostty) and the shell integration scripts. It finds
# them by looking for Contents/Resources/terminfo in the bundle it runs from.
cp -R vendor/share/ghostty vendor/share/terminfo "$app/Contents/Resources/"

# The icon: Assets.car is the Icon Composer icon for macOS 26, the .icns is the fallback for older
# versions. Both come from scripts/icon.sh.
cp assets/Assets.car assets/BridgeIcon.icns "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$name</string>
    <key>CFBundleDisplayName</key>
    <string>$name</string>
    <key>CFBundleIdentifier</key>
    <string>dev.arish.bridge</string>
    <key>CFBundleExecutable</key>
    <string>Bridge</string>
    <key>CFBundleIconFile</key>
    <string>BridgeIcon</string>
    <key>CFBundleIconName</key>
    <string>BridgeIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# An ad-hoc signature, so macOS treats each build as the same app.
codesign --force --sign - "$app/Contents/Helpers/bridge-helper"
codesign --force --sign - "$app"
echo "Built $app"
