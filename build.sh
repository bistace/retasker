#!/usr/bin/env sh
# Builds the reTasker aarch64 XOVI extensions inside the toolchain container.
# Output lands in build/. Source tree is left untouched (build runs in /tmp).
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$REPO/build"

docker run --rm -v "$REPO:/repo" retasker-toolchain:latest sh -lc '
    set -e
    . "$RM_ENV"
    rm -rf /tmp/cap && cp -r /repo/src/capture /tmp/cap
    cd /tmp/cap
    make
    file retasker-capture.so
    cp retasker-capture.so /repo/build/retasker-capture.so
'

echo "built: $REPO/build/retasker-capture.so"
