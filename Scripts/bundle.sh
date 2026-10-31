#!/usr/bin/env bash
set -euo pipefail

# Build, assemble, and optionally package FlipStack as a macOS app bundle.
# Usage: Scripts/bundle.sh [--dmg]
#
# Environment:
#   MARKETING_VERSION   CFBundleShortVersionString (default: 1.0.0)
#   BUILD_NUMBER        CFBundleVersion (default: 1)
#   CODESIGN_IDENTITY   Developer ID identity; defaults to ad-hoc "-"
#   SKIP_SIGN=1         Do not sign the app (CI packaging only)
#   BUILD_ARCHS         Space-separated architectures, e.g. "arm64 x86_64"
#   MAKE_DMG=1          Also create a compressed DMG (same as --dmg)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
APP="$DIST/FlipStack.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
INFO_TEMPLATE="$ROOT/Resources/Info.plist"
ENTITLEMENTS="$ROOT/Resources/FlipStack.entitlements"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MAKE_DMG="${MAKE_DMG:-0}"
SKIP_SIGN="${SKIP_SIGN:-0}"
IDENTITY="${CODESIGN_IDENTITY:--}"

usage() {
    cat <<'EOF'
Usage: Scripts/bundle.sh [--dmg]

Build a release FlipStack app bundle in dist/FlipStack.app.

Options:
  --dmg    Also create dist/FlipStack-<version>.dmg
  -h, --help
           Show this help

Environment:
  MARKETING_VERSION   Version string (default: 1.0.0)
  BUILD_NUMBER        Build number (default: 1)
  CODESIGN_IDENTITY   Signing identity (default: ad-hoc "-")
  SKIP_SIGN=1         Leave the app unsigned
  BUILD_ARCHS         Architectures, for example "arm64 x86_64"
  MAKE_DMG=1          Same as --dmg
EOF
}

for argument in "$@"; do
    case "$argument" in
        --dmg)
            MAKE_DMG=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $argument" >&2
            usage >&2
            exit 64
            ;;
    esac
done

case "$MAKE_DMG" in
    0|1) ;;
    *)
        echo "error: MAKE_DMG must be 0 or 1" >&2
        exit 64
        ;;
esac

case "$SKIP_SIGN" in
    0|1) ;;
    *)
        echo "error: SKIP_SIGN must be 0 or 1" >&2
        exit 64
        ;;
esac

if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "error: MARKETING_VERSION must look like 1.0.0 (got: $MARKETING_VERSION)" >&2
    exit 64
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "error: BUILD_NUMBER must be numeric (got: $BUILD_NUMBER)" >&2
    exit 64
fi

if [[ ! -f "$INFO_TEMPLATE" ]]; then
    echo "error: missing $INFO_TEMPLATE" >&2
    exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "error: missing $ENTITLEMENTS" >&2
    exit 1
fi

for tool in swift ditto codesign plutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool is required" >&2
        exit 1
    fi
done

ARCH_ARGS=()
if [[ -n "${BUILD_ARCHS:-}" ]]; then
    for architecture in $BUILD_ARCHS; do
        case "$architecture" in
            arm64|x86_64)
                ARCH_ARGS+=(--arch "$architecture")
                ;;
            *)
                echo "error: unsupported architecture: $architecture (use arm64 or x86_64)" >&2
                exit 64
                ;;
        esac
    done
fi

echo "==> Building FlipStack $MARKETING_VERSION ($BUILD_NUMBER)"
if (( ${#ARCH_ARGS[@]} > 0 )); then
    swift build -c release --product FlipStack "${ARCH_ARGS[@]}"
    BIN_DIR="$(swift build -c release --show-bin-path "${ARCH_ARGS[@]}")"
else
    swift build -c release --product FlipStack
    BIN_DIR="$(swift build -c release --show-bin-path)"
fi
BINARY="$BIN_DIR/FlipStack"

if [[ ! -x "$BINARY" ]]; then
    echo "error: built executable not found at $BINARY" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
install -m 0755 "$BINARY" "$MACOS_DIR/FlipStack"
cp "$INFO_TEMPLATE" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Apply the requested version. PlistBuddy writes the keys added in Info.plist;
# fail loudly if the template no longer has them.
"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$CONTENTS/Info.plist" >/dev/null
"$PLIST_BUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist" >/dev/null

ICON_DEST="$RESOURCES_DIR/AppIcon.icns"
ICON_SOURCE="$ROOT/Resources/AppIcon.icns"
GENERATED_ICON="$DIST/AppIcon.icns"

if [[ -f "$ICON_SOURCE" ]]; then
    cp "$ICON_SOURCE" "$ICON_DEST"
elif [[ -f "$ROOT/Resources/AppIcon.svg" && -f "$ROOT/Scripts/make-icon.sh" ]]; then
    echo "==> AppIcon.icns is missing; generating it"
    if bash "$ROOT/Scripts/make-icon.sh" "$GENERATED_ICON"; then
        cp "$GENERATED_ICON" "$ICON_DEST"
    else
        echo "warning: could not generate AppIcon.icns; the app will use the generic icon" >&2
    fi
else
    echo "warning: no app icon source found; the app will use the generic icon" >&2
fi

if [[ ! -f "$ICON_DEST" ]]; then
    "$PLIST_BUDDY" -c "Delete :CFBundleIconFile" "$CONTENTS/Info.plist" >/dev/null 2>&1 || true
fi

if [[ -f "$ROOT/LICENSE" ]]; then
    cp "$ROOT/LICENSE" "$RESOURCES_DIR/LICENSE"
fi

# Make the bundle readable regardless of the caller's umask. This matters when
# the release job protects temporary credentials with a restrictive umask.
chmod -R u=rwX,go=rX "$APP"

plutil -lint "$CONTENTS/Info.plist" >/dev/null

if [[ "$SKIP_SIGN" == "1" ]]; then
    echo "==> Signing skipped (SKIP_SIGN=1)"
else
    if [[ "$IDENTITY" == "-" ]]; then
        echo "==> Signing app ad hoc"
    else
        echo "==> Signing app with $IDENTITY"
    fi

    SIGN_ARGS=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY")
    if [[ "$IDENTITY" != "-" ]]; then
        SIGN_ARGS+=(--timestamp)
    fi
    codesign "${SIGN_ARGS[@]}" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null
fi

if command -v lipo >/dev/null 2>&1; then
    echo "Architectures: $(lipo -archs "$MACOS_DIR/FlipStack" 2>/dev/null || echo unknown)"
fi

DMG_PATH=""
DMG_STAGING=""
cleanup() {
    if [[ -n "$DMG_STAGING" ]]; then
        rm -rf "$DMG_STAGING"
    fi
}
trap cleanup EXIT

if [[ "$MAKE_DMG" == "1" ]]; then
    if ! command -v hdiutil >/dev/null 2>&1; then
        echo "error: hdiutil is required to create a DMG" >&2
        exit 1
    fi

    DMG_PATH="$DIST/FlipStack-${MARKETING_VERSION}.dmg"
    DMG_STAGING="$(mktemp -d "$DIST/.dmg-staging.XXXXXX")"
    chmod 755 "$DMG_STAGING"

    echo "==> Creating $DMG_PATH"
    rm -rf "$DMG_STAGING/FlipStack.app"
    ditto "$APP" "$DMG_STAGING/FlipStack.app"
    ln -s /Applications "$DMG_STAGING/Applications"
    if [[ -f "$ROOT/LICENSE" ]]; then
        cp "$ROOT/LICENSE" "$DMG_STAGING/LICENSE"
    fi
    cat > "$DMG_STAGING/Read Me.txt" <<EOF
FlipStack $MARKETING_VERSION

Drag FlipStack to Applications, then open it from Applications.
FlipStack lives in the menu bar and does not show a Dock icon.

Requires macOS 13 or later.

License: MIT. See LICENSE.
EOF
    chmod 644 "$DMG_STAGING/Read Me.txt"
    if [[ -f "$DMG_STAGING/LICENSE" ]]; then
        chmod 644 "$DMG_STAGING/LICENSE"
    fi
    rm -f "$DMG_PATH"
    hdiutil create -quiet \
        -volname "FlipStack $MARKETING_VERSION" \
        -srcfolder "$DMG_STAGING" \
        -ov \
        -format UDZO \
        "$DMG_PATH" >/dev/null

    if [[ "$SKIP_SIGN" != "1" && "$IDENTITY" != "-" ]]; then
        echo "==> Signing DMG with $IDENTITY"
        codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
        codesign --verify --verbose=2 "$DMG_PATH" >/dev/null
    fi

    rm -rf "$DMG_STAGING"
    DMG_STAGING=""
fi

echo
echo "App: $APP"
if [[ -n "$DMG_PATH" ]]; then
    echo "DMG: $DMG_PATH"
fi
