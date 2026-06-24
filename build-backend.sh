#!/usr/bin/env sh
# Builds the reTasker AppLoad backend (aarch64 executable, SQLite statically
# linked) inside the toolchain container. Output lands in build/. Source tree is
# left untouched (build runs in /tmp).
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$REPO/build"

docker run --rm -v "$REPO:/repo" retasker-toolchain:latest sh -lc '
    set -e
    . "$RM_ENV"
    rm -rf /tmp/be && cp -r /repo/src/backend /tmp/be
    cd /tmp/be
    make
    file retasker-backend
    cp retasker-backend /repo/build/retasker-backend
'

echo "built: $REPO/build/retasker-backend"
echo "deploy: scp to <device>:/home/root/xovi/exthome/appload/retasker/backend/entry"
