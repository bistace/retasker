#!/usr/bin/env sh
# Builds the three aarch64 artifacts and bundles them with the static app files
# into the release tarball the vellum package (packages/retasker/VELBUILD) sources.
# Output: build/retasker-<version>-aarch64.tar.gz, plus the sha512sums line to paste
# into the VELBUILD. Upload the tarball to the matching GitHub Release tag (v<version>).
set -e

VERSION="${1:-0.1.0}"
REPO="$(cd "$(dirname "$0")" && pwd)"
STAGE="$REPO/build/retasker-$VERSION-aarch64"
TARBALL="$REPO/build/retasker-$VERSION-aarch64.tar.gz"

"$REPO/build.sh"
"$REPO/build-backend.sh"
"$REPO/build-viewer.sh"

rm -rf "$STAGE"
mkdir -p "$STAGE"

cp "$REPO/build/retasker-capture.so" "$STAGE/"
cp "$REPO/build/retasker-backend" "$STAGE/"
cp "$REPO/build/retasker-viewer.rcc" "$STAGE/"
cp "$REPO/src/viewer/manifest.json" "$STAGE/"
cp "$REPO/src/viewer/assets/icon.png" "$STAGE/"
cp "$REPO/src/viewer/config.example.json" "$STAGE/"
cp "$REPO/src/selection/retasker-selection.qmd" "$STAGE/"
cp "$REPO/src/selection/retasker-toolbar.qmd" "$STAGE/"
cp "$REPO/src/selection/retasker-toast.qmd" "$STAGE/"
cp "$REPO/src/newnote/retasker-newnote.qmd" "$STAGE/"
cp "$REPO/src/appload/retasker-window.qmd" "$STAGE/"
cp "$REPO/src/launchbar/retasker-launchbar.qmd" "$STAGE/"

tar czf "$TARBALL" -C "$STAGE" .
rm -rf "$STAGE"

echo "built: $TARBALL"
echo "paste into packages/retasker/VELBUILD (sha512sums of THIS tarball):"
shasum -a 512 "$TARBALL" | sed "s|$REPO/build/||"
