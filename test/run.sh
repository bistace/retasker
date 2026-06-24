#!/usr/bin/env sh
# Run the reTasker unit tests: the viewer's pure JS helpers (node) and the
# capture extension's pure C helpers (cc). No device or cross-toolchain needed.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== JS helpers =="
node "$ROOT/test/js/run.js"

echo ""
echo "== C helpers =="
bin="$(mktemp -d)/retasker_ctest"
cc -D_GNU_SOURCE -Wall -o "$bin" "$ROOT/test/c/test_helpers.c"
"$bin"
