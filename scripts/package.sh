#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP="${APP_PATH:-$DIST_DIR/Bisco Archive Uploader.app}"
[[ -d "$APP" ]] || { printf 'Build the app first.\n' >&2; exit 1; }
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/bisco-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto --norsrc --noextattr "$APP" "$STAGING/Bisco Archive Uploader.app"
xattr -cr "$STAGING/Bisco Archive Uploader.app"
codesign --verify --strict --verbose=2 "$STAGING/Bisco Archive Uploader.app"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/QUICK-START.md" "$STAGING/Read me first.md"
hdiutil create -volname "Bisco Archive Uploader" -srcfolder "$STAGING" -ov -format UDZO \
    "$DIST_DIR/Bisco-Archive-Uploader.dmg"
ditto -c -k --norsrc --noextattr --keepParent "$STAGING/Bisco Archive Uploader.app" "$DIST_DIR/Bisco-Archive-Uploader-app.zip"
(
    cd "$DIST_DIR"
    shasum -a 256 Bisco-Archive-Uploader.dmg Bisco-Archive-Uploader-app.zip > SHA256SUMS.txt
)
