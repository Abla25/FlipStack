#!/usr/bin/env bash
#
# Scripts/bundle-demo.sh — build, assemble, ad-hoc sign and package the
# receipt-style Demo app (the app that actually ships as FlipStack.app).
#
# What it produces (all under dist-demo/, gitignored):
#   dist-demo/FlipStack.app            the assembled, ad-hoc signed bundle
#   dist-demo/FlipStack.dmg            optional (--dmg), UDZO, volume "FlipStack"
#   dist-demo/FlipStack.dmg.sha256     shasum -a 256 of the DMG
#
# Usage:
#   Scripts/bundle-demo.sh                 # build + assemble + sign
#   Scripts/bundle-demo.sh --dmg           # ... + DMG + sha256
#   Scripts/bundle-demo.sh --unsigned      # skip codesign (CI artifacts)
#   Scripts/bundle-demo.sh --universal     # arm64 + x86_64 (default: arm64 only)
#   Scripts/bundle-demo.sh --help
#
# Version: read from Demo/version.env (MARKETING_VERSION, BUILD_NUMBER).
# Environment overrides (win over version.env):
#   MARKETING_VERSION   e.g. 1.0.2
#   BUILD_NUMBER        e.g. 13
#   SWIFT_BUILD_FLAGS   extra flags for `swift build` (e.g. --disable-sandbox)
#   OUT_DIR             output directory (default: <repo>/dist-demo)
#   DMG_ENGINE          auto (default) | hdiutil | hybrid
#   SKIP_SIGN=1         same as --unsigned
#
# Notes:
#   * The build retries automatically with --disable-sandbox when the first
#     `swift build` fails. That flag is only needed inside restricted sandboxes
#     (some agent harnesses); a normal Terminal build does not need it.
#   * `hdiutil create -srcfolder` is the preferred DMG path. In sandboxes that
#     block it, the script falls back to a validated makehybrid → UDRW → UDZO
#     round-trip that strips the FinderInfo xattrs which would otherwise break
#     the code signature.
#   * This script never installs, pushes, tags or publishes anything.
#
# Requires: macOS 14+, Xcode command line tools (swift, codesign, hdiutil,
# ditto, plutil, shasum). sign is ad-hoc: the app is NOT notarized.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PLIST_BUDDY="/usr/libexec/PlistBuddy"
DMG_VOLUME_NAME="FlipStack"
APP_NAME="FlipStack"
EXECUTABLE_NAME="FlipStack"
TEMPLATE="$ROOT/Demo/Resources/Info.plist"
ICON="$ROOT/Demo/Assets/AppIcon.icns"
MENU_ICON="$ROOT/Demo/Assets/icon.iconset/menuicon.png"
VERSION_ENV="$ROOT/Demo/version.env"

MAKE_DMG=0
SIGN=1
UNIVERSAL=0
DMG_ENGINE="${DMG_ENGINE:-auto}"

DMG_STAGE=""
DMG_MNT=""
DMG_TMP_FILES=()

usage() {
    sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    echo "error: $*" >&2
    exit 1
}

cleanup() {
    local rc=$?
    set +e
    if [[ -n "$DMG_MNT" && -d "$DMG_MNT" ]]; then
        hdiutil detach "$DMG_MNT" >/dev/null 2>&1
    fi
    if (( ${#DMG_TMP_FILES[@]} > 0 )); then
        for f in "${DMG_TMP_FILES[@]}"; do
            rm -f "$f"
        done
    fi
    [[ -n "$DMG_STAGE" ]] && rm -rf "$DMG_STAGE"
    exit "$rc"
}
trap cleanup EXIT

for argument in "$@"; do
    case "$argument" in
        --dmg) MAKE_DMG=1 ;;
        --unsigned) SIGN=0 ;;
        --universal) UNIVERSAL=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $argument" >&2; usage >&2; exit 64 ;;
    esac
done

case "$DMG_ENGINE" in
    auto|hdiutil|hybrid) ;;
    *) die "DMG_ENGINE must be auto, hdiutil or hybrid (got: $DMG_ENGINE)" ;;
esac

# --- versions: Demo/version.env is the single source of truth; env overrides ---
_env_version="${MARKETING_VERSION:-}"
_env_build="${BUILD_NUMBER:-}"
if [[ -f "$VERSION_ENV" ]]; then
    # shellcheck disable=SC1090
    . "$VERSION_ENV"
fi
MARKETING_VERSION="${_env_version:-${MARKETING_VERSION:-}}"
BUILD_NUMBER="${_env_build:-${BUILD_NUMBER:-}}"

[[ -n "$MARKETING_VERSION" ]] || die "MARKETING_VERSION is empty (set it in Demo/version.env)"
[[ -n "$BUILD_NUMBER" ]] || die "BUILD_NUMBER is empty (set it in Demo/version.env)"
[[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
    || die "MARKETING_VERSION must look like 1.0.2 (got: $MARKETING_VERSION)"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] \
    || die "BUILD_NUMBER must be an integer (got: $BUILD_NUMBER)"

OUT_DIR="${OUT_DIR:-$ROOT/dist-demo}"
APP="$OUT_DIR/$APP_NAME.app"
BINARY_PATH=""
BUILD_PRODUCT_DIR=""

for tool in swift codesign plutil ditto shasum hdiutil lipo; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
[[ -f "$TEMPLATE" ]] || die "missing Info.plist template: $TEMPLATE"
[[ -f "$ICON" ]] || die "missing icon: $ICON"
[[ -f "$MENU_ICON" ]] || die "missing menu icon: $MENU_ICON"

mkdir -p "$OUT_DIR"

# --- 1. build ---------------------------------------------------------------
BUILD_ARGS=(-c release --product FlipStackDemo)
if [[ "$UNIVERSAL" == "1" ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

SWIFT_FLAGS=()
if [[ -n "${SWIFT_BUILD_FLAGS:-}" ]]; then
    read -r -a SWIFT_FLAGS <<< "$SWIFT_BUILD_FLAGS"
fi

echo "==> Building FlipStackDemo $MARKETING_VERSION ($BUILD_NUMBER)${UNIVERSAL:+}"
if [[ "$UNIVERSAL" == "1" ]]; then
    echo "    architectures: arm64 x86_64 (universal)"
else
    echo "    architectures: arm64 (default; use --universal for Intel too)"
fi

build_demo() {
    local -a cmd=(swift build "${BUILD_ARGS[@]}")
    # bash 3.2 (macOS) treats "${empty[@]}" as unbound under `set -u`; guard it.
    if (( ${#SWIFT_FLAGS[@]} > 0 )); then
        cmd+=("${SWIFT_FLAGS[@]}")
    fi
    ( cd "$ROOT/Demo" && "${cmd[@]}" )
}

if ! build_demo; then
    if [[ "${SWIFT_FLAGS[*]:-}" != *--disable-sandbox* ]]; then
        echo
        echo "==> swift build failed; retrying with --disable-sandbox."
        echo "    (only needed inside restricted/agent sandboxes; a normal Terminal build does not need it)"
        retry_cmd=(swift build "${BUILD_ARGS[@]}")
        if (( ${#SWIFT_FLAGS[@]} > 0 )); then
            retry_cmd+=("${SWIFT_FLAGS[@]}")
        fi
        retry_cmd+=(--disable-sandbox)
        ( cd "$ROOT/Demo" && "${retry_cmd[@]}" )
    else
        die "swift build failed (see the compiler output above)"
    fi
fi

if [[ "$UNIVERSAL" == "1" ]]; then
    BINARY_PATH="$ROOT/Demo/.build/apple/Products/Release/FlipStackDemo"
else
    BINARY_PATH="$ROOT/Demo/.build/release/FlipStackDemo"
fi
if [[ ! -x "$BINARY_PATH" ]]; then
    # Native arm64 builds may land in an arch-specific directory instead of the
    # .build/release symlink; look for the executable as a last resort.
    BINARY_PATH="$(find "$ROOT/Demo/.build" -type f -name FlipStackDemo -perm -u+x 2>/dev/null \
        | grep -v '\.dSYM' | head -n 1)"
fi
[[ -n "${BINARY_PATH:-}" && -x "$BINARY_PATH" ]] \
    || die "built executable not found (looked in Demo/.build); run 'swift build -c release' in Demo/ first"

echo "    binary: $BINARY_PATH"
echo "    arch:   $(lipo -archs "$BINARY_PATH" 2>/dev/null || echo unknown)"

# --- 2. assemble the .app bundle -------------------------------------------
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

install -m 0755 "$BINARY_PATH" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp "$MENU_ICON" "$APP/Contents/Resources/menuicon.png"

render_plist() {
    local destination="$1"
    sed -e "s|__VERSION__|$MARKETING_VERSION|g" \
        -e "s|__BUILD__|$BUILD_NUMBER|g" \
        "$TEMPLATE" > "$destination"
    if grep -q '__VERSION__\|__BUILD__' "$destination"; then
        die "Info.plist template still contains placeholders after rendering"
    fi
    plutil -lint "$destination" >/dev/null
}
render_plist "$APP/Contents/Info.plist"
echo "    Info.plist rendered from Demo/Resources/Info.plist"

# Make the bundle readable regardless of the caller's umask.
chmod -R u=rwX,go=rX "$APP"

# --- 3. ad-hoc sign (nested binary first, then the bundle) ------------------
if [[ "$SIGN" == "1" ]]; then
    echo "==> Signing ad hoc (not notarized)"
    codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/$EXECUTABLE_NAME"
    codesign --force --sign - --timestamp=none "$APP"
else
    echo "==> Signing skipped (--unsigned / SKIP_SIGN=1)"
fi

# --- 4. verify the bundle ---------------------------------------------------
verify_app() {
    local app="$1"
    local version build identifier executable arch

    plutil -lint "$app/Contents/Info.plist" >/dev/null
    [[ -x "$app/Contents/MacOS/$EXECUTABLE_NAME" ]] || die "missing executable in $app"
    [[ -f "$app/Contents/Resources/AppIcon.icns" ]] || die "missing AppIcon.icns in $app"
    [[ -f "$app/Contents/Resources/menuicon.png" ]] || die "missing menuicon.png in $app"

    version="$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
    build="$("$PLIST_BUDDY" -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
    identifier="$("$PLIST_BUDDY" -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
    executable="$("$PLIST_BUDDY" -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
    arch="$(lipo -archs "$app/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null || echo unknown)"

    [[ "$version" == "$MARKETING_VERSION" ]] || die "bundle version $version != $MARKETING_VERSION"
    [[ "$build" == "$BUILD_NUMBER" ]] || die "bundle build $build != $BUILD_NUMBER"
    [[ "$identifier" == "app.flipstack.FlipStack" ]] || die "unexpected bundle id: $identifier"
    [[ "$executable" == "$EXECUTABLE_NAME" ]] || die "unexpected CFBundleExecutable: $executable"
    [[ "$arch" == "arm64" || "$arch" == "x86_64 arm64" || "$arch" == "arm64 x86_64" ]] \
        || die "unexpected architecture: $arch"
    if [[ "$UNIVERSAL" == "0" && "$arch" != "arm64" ]]; then
        die "expected arm64-only build, got: $arch"
    fi
    if [[ "$UNIVERSAL" == "1" ]]; then
        [[ "$arch" == *arm64* && "$arch" == *x86_64* ]] || die "expected universal build, got: $arch"
    fi

    if [[ "$SIGN" == "1" ]]; then
        codesign --verify --deep --strict --verbose=2 "$app"
        codesign -dv --verbose=2 "$app" 2>&1 | grep -E 'Identifier=|Format=|Signature=' || true
        if spctl -a -vvv "$app" >/dev/null 2>&1; then
            echo "    warning: spctl accepted the app (unexpected for ad-hoc signing)" >&2
        else
            echo "    spctl: rejected (expected — ad-hoc signed, not notarized)"
        fi
    fi
}

echo "==> Verifying the bundle"
verify_app "$APP"
echo "    version $MARKETING_VERSION ($BUILD_NUMBER), $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null || echo unknown)"

# --- 5. optional DMG + sha256 ----------------------------------------------
SHA256=""
DMG_PATH=""
DMG_SIZE=""

write_readme() {
    local path="$1"
    cat > "$path" <<EOF
$APP_NAME $MARKETING_VERSION

Drag $APP_NAME to the Applications folder, then open it from there.
$APP_NAME lives in the menu bar and has no Dock icon.

First launch: this build is ad-hoc signed and NOT notarized, so macOS may
warn. Right-click the app and choose Open (macOS 15+ also offers
System Settings > Privacy & Security > Open Anyway).

Verify the download:
    shasum -a 256 $APP_NAME.dmg

Requires macOS 14 or later, Apple silicon (arm64).
License: MIT. See LICENSE.
EOF
    chmod 644 "$path"
}

create_dmg_hdiutil() {
    local log="$OUT_DIR/.dmg-hdiutil.log"
    DMG_TMP_FILES+=("$log")
    if hdiutil create -quiet -volname "$DMG_VOLUME_NAME" -srcfolder "$DMG_STAGE" \
        -ov -format UDZO "$DMG_PATH" 2>"$log"; then
        rm -f "$log"
        DMG_ENGINE_USED="hdiutil create"
        return 0
    fi
    return 1
}

create_dmg_hybrid() {
    local hybrid="$OUT_DIR/.dmg-hybrid.tmp.dmg"
    local rw="$OUT_DIR/.dmg-rw.tmp.dmg"
    local mnt="$OUT_DIR/.dmg-rw-mnt"
    DMG_TMP_FILES+=("$hybrid" "$rw")
    rm -f "$hybrid" "$rw"
    rm -rf "$mnt"; mkdir -p "$mnt"

    hdiutil makehybrid -o "$hybrid" -hfs -default-volume-name "$DMG_VOLUME_NAME" -quiet "$DMG_STAGE"
    hdiutil convert "$hybrid" -format UDRW -o "$rw" >/dev/null
    hdiutil attach -nobrowse -mountpoint "$mnt" -noverify "$rw" >/dev/null

    # makehybrid writes HFS FinderInfo xattrs; codesign treats them as detritus
    # and the app's signature would fail verification after download.
    xattr -cr "$mnt/FlipStack.app" 2>/dev/null || true
    find "$mnt" -name '._*' -delete 2>/dev/null || true
    dot_clean -m "$mnt" >/dev/null 2>&1 || true
    if [[ "$SIGN" == "1" ]]; then
        codesign --verify --deep --strict "$mnt/FlipStack.app"
    fi
    hdiutil detach "$mnt" >/dev/null

    rm -f "$DMG_PATH"
    hdiutil convert "$rw" -format UDZO -o "$DMG_PATH" >/dev/null
    rm -rf "$mnt"
    DMG_ENGINE_USED="makehybrid fallback"
}

create_dmg() {
    DMG_PATH="$OUT_DIR/$APP_NAME.dmg"
    DMG_STAGE="$OUT_DIR/.dmg-stage"
    rm -f "$DMG_PATH" "$DMG_PATH.sha256"
    rm -rf "$DMG_STAGE"
    mkdir -p "$DMG_STAGE"

    ditto "$APP" "$DMG_STAGE/$APP_NAME.app"
    ln -s /Applications "$DMG_STAGE/Applications"
    if [[ -f "$ROOT/LICENSE" ]]; then
        cp "$ROOT/LICENSE" "$DMG_STAGE/LICENSE"
        chmod 644 "$DMG_STAGE/LICENSE"
    fi
    write_readme "$DMG_STAGE/Read Me.txt"

    echo "==> Creating $DMG_PATH"
    local ok=0
    case "$DMG_ENGINE" in
        hdiutil)
            create_dmg_hdiutil || die "hdiutil create failed (see $OUT_DIR/.dmg-hdiutil.log); try DMG_ENGINE=hybrid"
            ok=1
            ;;
        hybrid)
            create_dmg_hybrid
            ok=1
            ;;
        auto)
            if create_dmg_hdiutil; then
                ok=1
            else
                echo "    hdiutil create is unavailable here; using the validated makehybrid fallback"
                rm -f "$DMG_PATH"
                create_dmg_hybrid
                ok=1
            fi
            ;;
    esac
    [[ "$ok" == "1" ]] || die "could not create the DMG"

    [[ -s "$DMG_PATH" ]] || die "DMG was not created: $DMG_PATH"
    rm -rf "$DMG_STAGE"; DMG_STAGE=""

    # Mount the finished image and re-verify what a downloader will get.
    echo "==> Verifying the finished DMG"
    DMG_MNT="$OUT_DIR/.dmg-mnt"
    rm -rf "$DMG_MNT"; mkdir -p "$DMG_MNT"
    hdiutil attach -readonly -nobrowse -mountpoint "$DMG_MNT" "$DMG_PATH" >/dev/null
    [[ -d "$DMG_MNT/$APP_NAME.app" ]] || die "DMG does not contain $APP_NAME.app"
    [[ -L "$DMG_MNT/Applications" ]] || die "DMG is missing the /Applications symlink"
    verify_app "$DMG_MNT/$APP_NAME.app"
    hdiutil detach "$DMG_MNT" >/dev/null
    rm -rf "$DMG_MNT"; DMG_MNT=""

    ( cd "$OUT_DIR" && shasum -a 256 "$APP_NAME.dmg" > "$APP_NAME.dmg.sha256" )
    ( cd "$OUT_DIR" && shasum -a 256 -c "$APP_NAME.dmg.sha256" >/dev/null )
    SHA256="$(cut -d ' ' -f 1 "$DMG_PATH.sha256")"
    DMG_SIZE="$(stat -f '%z' "$DMG_PATH")"
}

if [[ "$MAKE_DMG" == "1" ]]; then
    create_dmg
fi

# --- 6. summary -------------------------------------------------------------
APP_SIZE="$(stat -f '%z' "$APP/Contents/MacOS/$EXECUTABLE_NAME")"
APP_ARCH="$(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null || echo unknown)"

echo
echo "==> Done"
echo "App:        $APP"
echo "Version:    $MARKETING_VERSION (build $BUILD_NUMBER)"
echo "Arch:       $APP_ARCH"
echo "Executable: $APP_SIZE bytes"
if [[ "$SIGN" == "1" ]]; then
    echo "Codesign:   ad-hoc (NOT notarized)"
else
    echo "Codesign:   unsigned"
fi
if [[ "$MAKE_DMG" == "1" ]]; then
    echo "DMG:        $DMG_PATH ($DMG_SIZE bytes, engine: $DMG_ENGINE_USED)"
    echo "SHA256:     $SHA256"
    echo "SHA file:   $DMG_PATH.sha256"
fi
echo
echo "Next: verify + install with dist-demo/… (this script does not install or publish anything)."
