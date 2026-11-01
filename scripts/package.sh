#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
APP="${APP_PATH:-$DIST_DIR/Media Archive Cloud Uploader.app}"
[[ -d "$APP" ]] || { printf 'Build the app first.\n' >&2; exit 1; }
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/media-archive-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto --norsrc --noextattr "$APP" "$STAGING/Media Archive Cloud Uploader.app"
xattr -cr "$STAGING/Media Archive Cloud Uploader.app"
codesign --verify --strict --verbose=2 "$STAGING/Media Archive Cloud Uploader.app"
mkdir -p "$STAGING/artifacts" "$STAGING/image"
mv "$STAGING/Media Archive Cloud Uploader.app" "$STAGING/image/"
ln -s /Applications "$STAGING/image/Applications"
cp "$ROOT/QUICK-START.md" "$STAGING/image/Read me first.md"
cp "$ROOT/TESTING.md" "$STAGING/image/Testing guide.md"
hdiutil create -volname "Media Archive Cloud Uploader" -srcfolder "$STAGING/image" -ov -format UDZO \
    "$STAGING/artifacts/Media-Archive-Cloud-Uploader.dmg"
ditto -c -k --norsrc --noextattr --keepParent "$STAGING/image/Media Archive Cloud Uploader.app" "$STAGING/artifacts/Media-Archive-Cloud-Uploader-app.zip"
(
    cd "$STAGING/artifacts"
    shasum -a 256 Media-Archive-Cloud-Uploader.dmg Media-Archive-Cloud-Uploader-app.zip > SHA256SUMS.txt
)
# Publish only complete, verified containers; a failed build leaves the last good installer intact.
hdiutil verify "$STAGING/artifacts/Media-Archive-Cloud-Uploader.dmg"
mkdir -p "$STAGING/verify"
ditto -x -k "$STAGING/artifacts/Media-Archive-Cloud-Uploader-app.zip" "$STAGING/verify"
codesign --verify --strict --verbose=2 "$STAGING/verify/Media Archive Cloud Uploader.app"
for artifact in Media-Archive-Cloud-Uploader.dmg Media-Archive-Cloud-Uploader-app.zip SHA256SUMS.txt; do
    mv -f "$STAGING/artifacts/$artifact" "$DIST_DIR/$artifact"
done
