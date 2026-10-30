#!/bin/bash
# One command produces the application, DMG installer and ZIP in the repo's dist folder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/build.sh"
bash "$ROOT/scripts/package.sh"
printf 'Installer ready: %s/Bisco-Archive-Uploader.dmg\n' "${DIST_DIR:-$ROOT/dist}"
