#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build-release}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
mkdir -p "$BUILD_ROOT/module-cache" "$DIST_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/module-cache"
for arch in arm64 x86_64; do
    swift build --package-path "$ROOT" --scratch-path "$BUILD_ROOT/$arch" --cache-path "$BUILD_ROOT/cache" \
        --disable-sandbox --build-system native -c release --triple "$arch-apple-macosx13.0"
    BIN_DIR="$(swift build --package-path "$ROOT" --scratch-path "$BUILD_ROOT/$arch" --cache-path "$BUILD_ROOT/cache" --disable-sandbox --build-system native -c release --triple "$arch-apple-macosx13.0" --show-bin-path)"
    cp "$BIN_DIR/MediaArchiveCloudUploader" "$BUILD_ROOT/MediaArchiveCloudUploader-$arch"
done
APP="$DIST_DIR/Media Archive Cloud Uploader.app"
# Only replace this script's known build output, never a user-selected source folder.
if [[ -e "$APP" ]]; then rm -rf "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$BUILD_ROOT/MediaArchiveCloudUploader-arm64" \
    "$BUILD_ROOT/MediaArchiveCloudUploader-x86_64" \
    -output "$APP/Contents/MacOS/MediaArchiveCloudUploader"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
swift "$ROOT/scripts/make-icon.swift" "$BUILD_ROOT/AppIcon.iconset"
iconutil -c icns "$BUILD_ROOT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Finder metadata can be inherited when building in an iCloud-synced Documents folder.
xattr -cr "$APP"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
lipo -archs "$APP/Contents/MacOS/MediaArchiveCloudUploader"
printf 'Built: %s\n' "$APP"
