#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application certificate}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool Keychain profile name}"
[[ "$SIGNING_IDENTITY" != "-" ]] || { printf 'A Developer ID identity is required.\n' >&2; exit 1; }
RELEASE_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/bisco-release.XXXXXX")"
trap 'rm -rf "$RELEASE_TEMP"' EXIT
APP="$RELEASE_TEMP/Bisco Archive Uploader.app"
ditto --norsrc --noextattr "$DIST_DIR/Bisco Archive Uploader.app" "$APP"
xattr -cr "$APP"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$DIST_DIR/notarization-upload.zip"
xcrun notarytool submit "$DIST_DIR/notarization-upload.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$DIST_DIR/notarization-app.json"
[[ "$(plutil -extract status raw -o - "$DIST_DIR/notarization-app.json")" == "Accepted" ]] || { cat "$DIST_DIR/notarization-app.json"; exit 1; }
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ditto --norsrc --noextattr "$APP" "$DIST_DIR/Bisco Archive Uploader.app"
APP_PATH="$APP" DIST_DIR="$DIST_DIR" bash "$ROOT/scripts/package.sh"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DIST_DIR/Bisco-Archive-Uploader.dmg"
xcrun notarytool submit "$DIST_DIR/Bisco-Archive-Uploader.dmg" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$DIST_DIR/notarization-dmg.json"
[[ "$(plutil -extract status raw -o - "$DIST_DIR/notarization-dmg.json")" == "Accepted" ]] || { cat "$DIST_DIR/notarization-dmg.json"; exit 1; }
xcrun stapler staple "$DIST_DIR/Bisco-Archive-Uploader.dmg"
xcrun stapler validate "$DIST_DIR/Bisco-Archive-Uploader.dmg"
spctl --assess --type execute --verbose=2 "$APP"
(
    cd "$DIST_DIR"
    shasum -a 256 Bisco-Archive-Uploader.dmg Bisco-Archive-Uploader-app.zip > SHA256SUMS.txt
)
