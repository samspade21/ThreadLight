#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
BUILD_MODE=${THREADLIGHT_BUILD_MODE:-development}
(( $# <= 1 )) || {
    print -u2 "Usage: ./scripts/build-app.sh [--development|--release]"
    exit 2
}
case "${1:-}" in
    --development) BUILD_MODE=development ;;
    --release) BUILD_MODE=release ;;
    --help|-h)
        print "Usage: ./scripts/build-app.sh [--development|--release]"
        print "  --development  Ad-hoc test build with development-only storage (default)"
        print "  --release      Developer ID signed and Apple-notarized production build"
        print "  THREADLIGHT_BUILD_MODE may set the default to development or release"
        exit 0
        ;;
    "") ;;
    *)
        print -u2 "Usage: ./scripts/build-app.sh [--development|--release]"
        exit 2
        ;;
esac
[[ "$BUILD_MODE" == development || "$BUILD_MODE" == release ]] || {
    print -u2 "THREADLIGHT_BUILD_MODE must be development or release."
    exit 2
}
CONFIGURATION=${CONFIGURATION:-release}
if [[ "$BUILD_MODE" == release && "$CONFIGURATION" != release ]]; then
    print -u2 -- "--release requires CONFIGURATION=release."
    exit 2
fi
APP_DIR="$PROJECT_DIR/build/ThreadLight.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
IDENTITY=${CODE_SIGN_IDENTITY:--}
VERSION=$(<"$PROJECT_DIR/VERSION")
"$PROJECT_DIR/scripts/check-version.sh" "$VERSION" >/dev/null

if [[ "$BUILD_MODE" == release ]]; then
    source "$PROJECT_DIR/scripts/signing-env.sh"
    IDENTITY=${CODE_SIGN_IDENTITY:--}
    [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] || {
        print -u2 -- "--release requires CODE_SIGN_IDENTITY for a Developer ID Application certificate."
        print -u2 -- "Set it in .signing.env (see .signing.env.example) or export it."
        exit 2
    }
    [[ -n "${NOTARY_PROFILE:-}" ]] || {
        print -u2 -- "--release requires NOTARY_PROFILE; ThreadLight will not emit an unnotarized production app."
        print -u2 -- "Set it in .signing.env (see .signing.env.example) or export it."
        exit 2
    }
elif [[ "$IDENTITY" != "-" ]]; then
    print -u2 "A development build must use ad-hoc signing. Pass --release for a production build."
    exit 2
fi

# Keep Swift/Clang compiler state inside the checkout. This makes nested builds
# work in sandboxed developer tools and avoids touching a user's global caches.
export CLANG_MODULE_CACHE_PATH=${CLANG_MODULE_CACHE_PATH:-"$PROJECT_DIR/.build/clang-module-cache"}
export SWIFTPM_MODULECACHE_OVERRIDE=${SWIFTPM_MODULECACHE_OVERRIDE:-"$CLANG_MODULE_CACHE_PATH"}
mkdir -p "$CLANG_MODULE_CACHE_PATH"

cd "$PROJECT_DIR"
if [[ "$BUILD_MODE" == development ]]; then
    swift build --configuration "$CONFIGURATION" -Xswiftc -DTHREADLIGHT_DEVELOPMENT
    BIN_DIR=$(swift build --configuration "$CONFIGURATION" -Xswiftc -DTHREADLIGHT_DEVELOPMENT --show-bin-path)
else
    swift build --configuration "$CONFIGURATION"
    BIN_DIR=$(swift build --configuration "$CONFIGURATION" --show-bin-path)
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/ThreadLight" "$MACOS_DIR/ThreadLight"
cp "Config/Info.plist" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$CONTENTS_DIR/Info.plist"
cp "Config/ThreadLight.icns" "$RESOURCES_DIR/ThreadLight.icns"
cp "Config/AppIcon.iconset/icon_512x512.png" "$RESOURCES_DIR/SlackAppIcon.png"
cp "Sources/ThreadLightApp/Resources/setup-journey.png" "$RESOURCES_DIR/setup-journey.png"
cp -R "$BIN_DIR/SQLCipher.framework" "$FRAMEWORKS_DIR/SQLCipher.framework"
cp "LICENSE" "$RESOURCES_DIR/LICENSE"
cp "THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/ThreadLight"

for bundle in "$BIN_DIR"/*.bundle; do
    [[ -e "$bundle" ]] || continue
    cp -R "$bundle" "$RESOURCES_DIR/"
done

ENTITLEMENTS="Config/ThreadLight.entitlements"
if [[ "$BUILD_MODE" == development ]]; then
    ENTITLEMENTS="Config/ThreadLight.development.entitlements"
fi
codesign --force --sign "$IDENTITY" --timestamp --options runtime "$FRAMEWORKS_DIR/SQLCipher.framework"
codesign --force --sign "$IDENTITY" --timestamp --options runtime --entitlements "$ENTITLEMENTS" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if [[ "$BUILD_MODE" == release ]]; then
    "$PROJECT_DIR/scripts/verify-release-app.sh" --pre-notarization "$APP_DIR"
    NOTARIZATION_ZIP="$PROJECT_DIR/build/ThreadLight-notarization.zip"
    NOTARIZATION_RESULT="$PROJECT_DIR/build/ThreadLight-notarization-result.json"
    rm -f "$NOTARIZATION_ZIP" "$NOTARIZATION_RESULT"
    ditto -c -k --keepParent "$APP_DIR" "$NOTARIZATION_ZIP"
    if ! xcrun notarytool submit "$NOTARIZATION_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --timeout 30m \
        --output-format json > "$NOTARIZATION_RESULT"
    then
        cat "$NOTARIZATION_RESULT"
        exit 3
    fi
    cat "$NOTARIZATION_RESULT"
    NOTARIZATION_STATUS=$(plutil -extract status raw -o - "$NOTARIZATION_RESULT")
    if [[ "$NOTARIZATION_STATUS" != "Accepted" ]]; then
        NOTARIZATION_ID=$(plutil -extract id raw -o - "$NOTARIZATION_RESULT")
        xcrun notarytool log "$NOTARIZATION_ID" --keychain-profile "$NOTARY_PROFILE" || true
        print -u2 "Apple notarization was not accepted: $NOTARIZATION_STATUS"
        exit 4
    fi
    xcrun stapler staple "$APP_DIR"
    "$PROJECT_DIR/scripts/verify-release-app.sh" "$APP_DIR"
fi

echo "$APP_DIR"
