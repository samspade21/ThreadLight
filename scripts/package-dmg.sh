#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
VERSION=$(<"$PROJECT_DIR/VERSION")
APP_PATH=${1:-"$PROJECT_DIR/build/ThreadLight.app"}
DMG_PATH=${2:-"$PROJECT_DIR/build/ThreadLight-$VERSION.dmg"}

"$PROJECT_DIR/scripts/check-version.sh" "$VERSION" >/dev/null
[[ -d "$APP_PATH" ]] || {
    print -u2 "App bundle not found: $APP_PATH"
    exit 2
}
for key in CFBundleShortVersionString CFBundleVersion; do
    APP_VERSION=$(plutil -extract "$key" raw -o - "$APP_PATH/Contents/Info.plist")
    [[ "$APP_VERSION" == "$VERSION" ]] || {
        print -u2 "App $key $APP_VERSION does not match VERSION $VERSION."
        exit 3
    }
done

STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/threadlight-dmg.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_PATH" "$STAGING_DIR/ThreadLight.app"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"
mkdir -p "${DMG_PATH:h}"
hdiutil create \
    -volname "ThreadLight $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_PATH"
hdiutil verify "$DMG_PATH"
print "$DMG_PATH"
