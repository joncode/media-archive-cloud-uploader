#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BISCO_ENV_FILE="${BISCO_ENV_FILE:-$ROOT/.env}"
[[ -f "$BISCO_ENV_FILE" ]] || { printf 'Copy .env.example to .env and fill in your local configuration first.\n' >&2; exit 1; }
swift run --package-path "$ROOT" --build-system native BiscoArchiveUploader
