#!/usr/bin/env bash
set -euo pipefail

# Build an .icns from Resources/AppIcon.svg using only tools included with macOS.
# Usage: Scripts/make-icon.sh [output.icns]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="${ICON_SOURCE:-$ROOT/Resources/AppIcon.svg}"
OUTPUT="${1:-${ICON_OUTPUT:-$ROOT/Resources/AppIcon.icns}}"

if [[ ! -f "$SOURCE" ]]; then
    echo "error: icon source not found: $SOURCE" >&2
    exit 1
fi

for tool in sips iconutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool is required to build the app icon" >&2
        exit 1
    fi
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flipstack-icon.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

MASTER="$WORK_DIR/AppIcon-1024.png"
ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"

echo "==> Rendering icon from $SOURCE"
if [[ -x "$ROOT/Scripts/render-icon.swift" ]] || [[ -f "$ROOT/Scripts/render-icon.swift" ]]; then
    if ! swift "$ROOT/Scripts/render-icon.swift" "$SOURCE" "$MASTER" 1024; then
        echo "warning: AppKit renderer failed; falling back to sips" >&2
        sips -s format png "$SOURCE" --out "$MASTER" >/dev/null
    fi
else
    echo "warning: render-icon.swift is missing; falling back to sips" >&2
    sips -s format png "$SOURCE" --out "$MASTER" >/dev/null
fi

if [[ ! -f "$MASTER" ]]; then
    echo "error: the icon renderer did not produce $MASTER" >&2
    exit 1
fi

# Normalize the master image in case a fallback rasterizer chose a different size.
sips -z 1024 1024 "$MASTER" >/dev/null

make_size() {
    local pixels="$1"
    local name="$2"
    sips -z "$pixels" "$pixels" "$MASTER" --out "$ICONSET/$name" >/dev/null
}

make_size 16 "icon_16x16.png"
make_size 32 "icon_16x16@2x.png"
make_size 32 "icon_32x32.png"
make_size 64 "icon_32x32@2x.png"
make_size 128 "icon_128x128.png"
make_size 256 "icon_128x128@2x.png"
make_size 256 "icon_256x256.png"
make_size 512 "icon_256x256@2x.png"
make_size 512 "icon_512x512.png"
make_size 1024 "icon_512x512@2x.png"

echo "==> Building $OUTPUT"
iconutil -c icns "$ICONSET" -o "$OUTPUT"

if [[ ! -s "$OUTPUT" ]]; then
    echo "error: iconutil did not create a usable icon" >&2
    exit 1
fi

echo "Icon: $OUTPUT"
