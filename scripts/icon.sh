#!/bin/sh
# Compile assets/BridgeIcon.icon (made in Icon Composer) into assets/Assets.car and
# assets/BridgeIcon.icns. Needs Xcode 26 or later; CI's Xcode is older, so the results are committed
# and bundle.sh just copies them. Run this after changing the icon.
set -eu

cd "$(dirname "$0")/.."
out=$(mktemp -d)

xcrun actool assets/BridgeIcon.icon --compile "$out" \
  --output-format human-readable-text --notices --warnings --errors \
  --output-partial-info-plist "$out/partial.plist" \
  --app-icon BridgeIcon --include-all-app-icons \
  --enable-on-demand-resources NO --development-region en \
  --target-device mac --platform macosx --minimum-deployment-target 26.0

cp "$out/Assets.car" "$out/BridgeIcon.icns" assets/
rm -rf "${out:?}"
echo "Wrote assets/Assets.car and assets/BridgeIcon.icns"
