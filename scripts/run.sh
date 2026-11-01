#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The app now guides setup and saves selections locally; no .env is required.
swift run --package-path "$ROOT" --build-system native MediaArchiveCloudUploader
