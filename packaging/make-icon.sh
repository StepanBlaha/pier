#!/usr/bin/env bash
# Generates packaging/AppIcon.icns (16..1024px) from packaging/icon-source.png (the full-res mascot, transparent).
# The rounded-rect cream tile + gull artwork are drawn by packaging/make-assets.py (needs Pillow: pip3 install pillow).
#   packaging/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="packaging/icon-source.png"
OUT="packaging/AppIcon.icns"
[ -f "$SRC" ] || { echo "make-icon: $SRC not found" >&2; exit 1; }

python3 packaging/make-assets.py icon   # -> packaging/AppIcon-1024.png

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SET="$WORK/AppIcon.iconset"; mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" packaging/AppIcon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s*2))" "$((s*2))" packaging/AppIcon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$OUT"
rm -f packaging/AppIcon-1024.png
echo "wrote $OUT"
