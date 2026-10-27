#!/bin/sh
# Build the app and wrap it in a macOS app bundle: build/Bridge.app.
# Copy it to /Applications to launch it from Spotlight, Launchpad or the Dock.
# Run scripts/build-ghostty.sh first (once, and after updating vendor/ghostty).
# Builds for Apple Silicon (run it on an Apple Silicon Mac).
#
# Optional, for releases:
#   DEVELOPER_ID        a "Developer ID Application: …" identity in the keychain: the app is
#                       signed with it and the hardened runtime, ready to notarize
#                       (scripts/package.sh notarizes). Without it the app is ad-hoc signed.
#   SPARKLE_PUBLIC_KEY  the EdDSA public key updates are signed with (Sparkle's generate_keys).
#                       Without it the app doesn't look for updates.
set -eu

cd "$(dirname "$0")/.."
name="Bridge"
version=$(cat version.txt)

[ -d vendor/GhosttyKit.xcframework ] || { echo "No libghostty; run scripts/build-ghostty.sh first." >&2; exit 1; }

# Exactly the dependency versions in Package.resolved.
swift build -c release --arch arm64 --force-resolved-versions
bin=$(swift build -c release --arch arm64 --show-bin-path)

app="build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers" "$app/Contents/Frameworks"
cp "$bin/Bridge" "$app/Contents/MacOS/Bridge"
# Sparkle, for updates.
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Bridge"
# SwiftPM records the deployment target (macOS 15) as the SDK the app was built with, and macOS
# gives apps built with an SDK older than 26 the old look instead of Liquid Glass. Record the SDK
# it really was built with.
sdk=$(xcrun --sdk macosx --show-sdk-version)
vtool -set-build-version macos 15.0 "$sdk" -replace -output "$app/Contents/MacOS/Bridge" "$app/Contents/MacOS/Bridge"
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
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>dev.arish.bridge.pane</string>
            <key>UTTypeDescription</key>
            <string>Bridge terminal</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.data</string></array>
        </dict>
    </array>
    <key>SUFeedURL</key>
    <string>https://github.com/ArishSultan/bridge/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_KEY:-}</string>
</dict>
</plist>
PLIST

# Signed inside out: Sparkle's helpers, Sparkle, the helper, then the app. With a Developer ID
# the hardened runtime is on (no injected libraries, no debugger) and a secure timestamp is
# added, as notarization requires. Otherwise an ad-hoc signature, so macOS treats each build as
# the same app.
if [ -n "${DEVELOPER_ID:-}" ]; then
    sign() { codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$@"; }
else
    sign() { codesign --force --sign - "$@"; }
fi
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign "$app/Contents/Helpers/bridge-helper"
sign "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
