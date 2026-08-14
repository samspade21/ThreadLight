#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
VERSION=$(<"$PROJECT_DIR/VERSION")
DMG_PATH="$PROJECT_DIR/build/ThreadLight-$VERSION.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"

[[ -n "${CODE_SIGN_IDENTITY:-}" && "$CODE_SIGN_IDENTITY" != "-" ]] || {
    print -u2 "A release requires CODE_SIGN_IDENTITY for a Developer ID Application certificate."
    exit 2
}
[[ -n "${NOTARY_PROFILE:-}" ]] || {
    print -u2 "A release requires NOTARY_PROFILE for xcrun notarytool."
    exit 2
}

cd "$PROJECT_DIR"
swift package resolve
swift test --configuration release
"$PROJECT_DIR/scripts/build-app.sh"
"$PROJECT_DIR/scripts/package-dmg.sh" "$PROJECT_DIR/build/ThreadLight.app" "$DMG_PATH"

codesign --force --sign "$CODE_SIGN_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

NOTARIZATION_RESULT="$PROJECT_DIR/build/ThreadLight-dmg-notarization-result.json"
if ! xcrun notarytool submit "$DMG_PATH" \
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
[[ "$NOTARIZATION_STATUS" == "Accepted" ]] || {
    print -u2 "Apple did not accept the DMG notarization: $NOTARIZATION_STATUS"
    exit 4
}
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
hdiutil verify "$DMG_PATH"

cd "$PROJECT_DIR/build"
shasum -a 256 "${DMG_PATH:t}" > "${CHECKSUM_PATH:t}"
print "DMG=$DMG_PATH"
print "CHECKSUM=$CHECKSUM_PATH"
