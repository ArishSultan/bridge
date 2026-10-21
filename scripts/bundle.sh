#!/bin/sh
# Build the app and wrap it in a macOS app bundle: target/release/bundle/Bridge.app.
# Copy it to /Applications to launch it from Spotlight, Launchpad or the Dock.
# Builds for Apple Silicon (run it on an Apple Silicon Mac).
set -eu

cd "$(dirname "$0")/.."
name="Bridge"
version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -n 1)

app="target/release/bundle/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cargo build --release
cp target/release/Bridge "$app/Contents/MacOS/Bridge"

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
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# An ad-hoc signature, so macOS treats each build as the same app.
codesign --force --sign - "$app"
echo "Built $app"
