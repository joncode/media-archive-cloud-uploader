#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
APP="${APP_PATH:-$DIST_DIR/Bisco Archive Uploader.app}"
[[ -d "$APP" ]] || { printf 'Build the app first.\n' >&2; exit 1; }
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/bisco-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto --norsrc --noextattr "$APP" "$STAGING/Bisco Archive Uploader.app"
xattr -cr "$STAGING/Bisco Archive Uploader.app"
codesign --verify --strict --verbose=2 "$STAGING/Bisco Archive Uploader.app"
mkdir -p "$STAGING/artifacts" "$STAGING/image"
mv "$STAGING/Bisco Archive Uploader.app" "$STAGING/image/"
ln -s /Applications "$STAGING/image/Applications"
cp "$ROOT/QUICK-START.md" "$STAGING/image/Read me first.md"
cp "$ROOT/TESTING.md" "$STAGING/image/Testing guide.md"
hdiutil create -volname "Bisco Archive Uploader" -srcfolder "$STAGING/image" -ov -format UDZO \
    "$STAGING/artifacts/Bisco-Archive-Uploader.dmg"
ditto -c -k --norsrc --noextattr --keepParent "$STAGING/image/Bisco Archive Uploader.app" "$STAGING/artifacts/Bisco-Archive-Uploader-app.zip"
(
    cd "$STAGING/artifacts"
    shasum -a 256 Bisco-Archive-Uploader.dmg Bisco-Archive-Uploader-app.zip > SHA256SUMS.txt
)
# Publish only complete, verified containers; a failed build leaves the last good installer intact.
hdiutil verify "$STAGING/artifacts/Bisco-Archive-Uploader.dmg"
mkdir -p "$STAGING/verify"
ditto -x -k "$STAGING/artifacts/Bisco-Archive-Uploader-app.zip" "$STAGING/verify"
codesign --verify --strict --verbose=2 "$STAGING/verify/Bisco Archive Uploader.app"
for artifact in Bisco-Archive-Uploader.dmg Bisco-Archive-Uploader-app.zip SHA256SUMS.txt; do
    mv -f "$STAGING/artifacts/$artifact" "$DIST_DIR/$artifact"
done
