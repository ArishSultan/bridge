#!/bin/sh
# Package a built Bridge.app for a release: a disk image, a zip and their SHA-256 sums, in
# build/dist/. Run scripts/bundle.sh first.
#
#   ./scripts/package.sh 0.2.0
#
# With a Developer ID signed app and these set, the app and the disk image are notarized by
# Apple and the tickets stapled, so macOS opens them without warnings:
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD (an app-specific password for the Apple ID)
set -eu

cd "$(dirname "$0")/.."
version="$1"
app="build/Bridge.app"
dist="build/dist"
dmg="$dist/Bridge-$version-macos-arm64.dmg"
zip="$dist/Bridge-$version-macos-arm64.zip"

[ -d "$app" ] || { echo "No $app; run scripts/bundle.sh first." >&2; exit 1; }
rm -rf "$dist"
mkdir -p "$dist"

notarize=false
if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    notarize=true
fi
submit() {
    xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" --wait --timeout 30m
}

if $notarize; then
    # The app first, so the ticket stapled to it travels in the zip and the disk image.
    ditto -c -k --keepParent "$app" "$dist/notarize.zip"
    submit "$dist/notarize.zip"
    rm "$dist/notarize.zip"
    xcrun stapler staple "$app"
fi

# The zip keeps the bundle's signature and attributes.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

# The disk image shows the app next to an Applications link, to drag it across.
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Bridge.app"
ln -s /Applications "$staging/Applications"
# hdiutil sometimes fails with "Resource busy" on CI machines; it succeeds on a retry.
for attempt in 1 2 3 4 5; do
    if hdiutil create -volname "Bridge" -srcfolder "$staging" -ov -format UDZO "$dmg"; then
        break
    fi
    [ "$attempt" = 5 ] && exit 1
    sleep 5
done

if $notarize; then
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$dmg"
    submit "$dmg"
    xcrun stapler staple "$dmg"
fi

(cd "$dist" && shasum -a 256 ./*.dmg ./*.zip | sed 's| \./| |' > SHA256SUMS.txt)
ls -l "$dist"
