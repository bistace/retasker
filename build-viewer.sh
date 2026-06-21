#!/usr/bin/env sh
# Compiles the reTasker viewer QML into resources.rcc inside the toolchain
# container (uses the SDK's Qt6 rcc). Output: build/retasker-viewer.rcc.
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$REPO/build"

docker run --rm -v "$REPO:/repo" retasker-toolchain:latest sh -lc '
    set -e
    RCC=/opt/rm-sdk/sysroots/x86_64-codexsdk-linux/usr/libexec/rcc
    cd /repo/src/viewer
    "$RCC" --binary -o /repo/build/retasker-viewer.rcc application.qrc
'

echo "built: $REPO/build/retasker-viewer.rcc"
echo "deploy: scp to <device>:/home/root/xovi/exthome/appload/retasker/resources.rcc"
