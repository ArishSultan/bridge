#!/bin/sh
# Build libghostty from the pinned vendor/ghostty submodule into vendor/GhosttyKit.xcframework, plus
# Ghostty's resources (shell integration, themes, terminfo) into vendor/share. Needs Zig 0.15.2.
#
#   ./scripts/build-ghostty.sh
set -eu

cd "$(dirname "$0")/.."
git submodule update --init vendor/ghostty

(
    cd vendor/ghostty
    # Fixes from newer Ghostty that the pinned version needs, applied to the working tree.
    for patch in ../../patches/ghostty/*.patch; do
        if git apply --reverse --check "$patch" 2>/dev/null; then
            continue # already applied
        fi
        git apply "$patch"
    done

    zig build \
        -Doptimize=ReleaseFast \
        -Demit-xcframework=true \
        -Demit-macos-app=false \
        -Dxcframework-target=native
)

rm -rf vendor/GhosttyKit.xcframework vendor/share
cp -R vendor/ghostty/macos/GhosttyKit.xcframework vendor/GhosttyKit.xcframework
# The app bundle copies these into Contents/Resources: libghostty finds its resources by looking
# for Contents/Resources/terminfo next to Contents/Resources/ghostty.
mkdir -p vendor/share
cp -R vendor/ghostty/zig-out/share/ghostty vendor/ghostty/zig-out/share/terminfo vendor/share/
echo "Built vendor/GhosttyKit.xcframework"
