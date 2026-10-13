#!/usr/bin/env bash
# Builds release binaries and assembles dist/Pier.app + dist/pier-<version>-macos-<arch>.zip (ad-hoc signed)
# for GitHub Releases. Regenerates the icon first when the .icns is missing.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f packaging/icon-source.png ] && [ ! -f packaging/AppIcon.icns ]; then
  packaging/make-icon.sh
fi

swift build -c release --product pier
swift build -c release --product PierApp

rm -rf dist
mkdir -p dist
.build/release/pier app install --to dist --no-open

VERSION="$(.build/release/pier --version | head -1 | awk '{print $NF}')"
ARCH="$(uname -m)"
ZIP="dist/pier-${VERSION}-macos-${ARCH}.zip"
# ditto keeps the bundle's signature, xattrs and symlinks intact (plain zip does not).
ditto -c -k --keepParent dist/Pier.app "$ZIP"

codesign -dv dist/Pier.app 2>&1 | sed 's/^/  /'
echo "Built dist/Pier.app and $ZIP"
echo "Users: unzip, move Pier.app to ~/Applications, then: xattr -dr com.apple.quarantine ~/Applications/Pier.app"
