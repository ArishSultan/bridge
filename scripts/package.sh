#!/bin/sh
# Package a built Bridge.app for a release: a disk image, a zip and their SHA-256 sums, in
# target/release/dist/. Run scripts/bundle.sh first.
#
#   ./scripts/package.sh 0.2.0
set -eu

cd "$(dirname "$0")/.."
version="$1"
app="target/release/bundle/Bridge.app"
dist="target/release/dist"
dmg="$dist/Bridge-$version-macos-arm64.dmg"
zip="$dist/Bridge-$version-macos-arm64.zip"

[ -d "$app" ] || { echo "No $app; run scripts/bundle.sh first." >&2; exit 1; }
rm -rf "$dist"
mkdir -p "$dist"

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

(cd "$dist" && shasum -a 256 ./*.dmg ./*.zip | sed 's| \./| |' > SHA256SUMS.txt)
ls -l "$dist"
