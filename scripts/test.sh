#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="${TEST_BUILD:-$(mktemp -d "${TMPDIR:-/tmp}/media-archive-tests.XXXXXX")}"
mkdir -p "$TEST_BUILD/module-cache"
export CLANG_MODULE_CACHE_PATH="$TEST_BUILD/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TEST_BUILD/module-cache"
swift test --package-path "$ROOT" --scratch-path "$TEST_BUILD/build" --cache-path "$TEST_BUILD/cache" \
    --disable-sandbox --build-system native
printf 'Test intermediates: %s\n' "$TEST_BUILD"
