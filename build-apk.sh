#!/usr/bin/env sh
# Builds the signed reTasker .apk from packages/retasker/VELBUILD using vbuild,
# which fetches the release tarball named in the VELBUILD, verifies its sha512,
# runs package(), and signs the result. Output: dist/aarch64/retasker-<ver>-r0.apk
#
# Requires: vbuild on PATH, docker (vbuild drives abuild in a container), and the
# signing keypair at keys/retasker.rsa (private) + keys/retasker.rsa.pub.
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
ARCH=aarch64
KEY_NAME=retasker
KEY="$REPO/keys/$KEY_NAME.rsa"

command -v vbuild >/dev/null 2>&1 || {
    echo "vbuild not found on PATH (https://github.com/Eeems/vbuild/releases)" >&2
    exit 1
}
[ -f "$KEY" ] || {
    echo "missing signing key: $KEY" >&2
    exit 1
}

# vbuild signs with the keypair it finds in ~/.config/vbuild.
mkdir -p "$HOME/.config/vbuild"
cp "$KEY" "$HOME/.config/vbuild/$KEY_NAME.rsa"
cp "$KEY.pub" "$HOME/.config/vbuild/$KEY_NAME.rsa.pub"

# Reproducible builds: stamp from the package's last commit.
SDE="$(git -C "$REPO" log -1 --format=%ct -- packages/retasker 2>/dev/null || true)"

WORK="$(mktemp -d)"
cp -r "$REPO/packages/retasker/." "$WORK"
SOURCE_DATE_EPOCH="$SDE" VBUILD_KEY_NAME="$KEY_NAME" CARCH="$ARCH" vbuild -C "$WORK" all
mkdir -p "$REPO/dist"
cp -r "$WORK/dist/." "$REPO/dist/"
vbuild -C "$WORK" clean || true
rm -rf "$WORK"

ls -la "$REPO/dist/$ARCH/"*.apk
