#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
PRE_NOTARIZATION=false
if [[ "${1:-}" == "--pre-notarization" ]]; then
    PRE_NOTARIZATION=true
    shift
fi
RELEASE_APP=${1:-"$PROJECT_DIR/build/ThreadLight.app"}

[[ -d "$RELEASE_APP" ]] || {
    print -u2 "Release app not found: $RELEASE_APP"
    exit 2
}

codesign --verify --deep --strict --verbose=2 "$RELEASE_APP"

APP_SIGNATURE=$(codesign -d --verbose=4 "$RELEASE_APP" 2>&1)
[[ "$APP_SIGNATURE" == *"Authority=Developer ID Application:"* ]] || {
    print -u2 "ThreadLight is not signed with a Developer ID Application certificate."
    exit 3
}
[[ "$APP_SIGNATURE" == *"runtime"* && "$APP_SIGNATURE" != *"Signature=adhoc"* ]] || {
    print -u2 "ThreadLight is not a hardened-runtime production signature."
    exit 4
}

APP_TEAM=$(print -r -- "$APP_SIGNATURE" | sed -n 's/^TeamIdentifier=//p' | head -1)
[[ -n "$APP_TEAM" && "$APP_TEAM" != "not set" ]] || {
    print -u2 "ThreadLight has no signing team identifier."
    exit 5
}

FRAMEWORK="$RELEASE_APP/Contents/Frameworks/SQLCipher.framework"
FRAMEWORK_SIGNATURE=$(codesign -d --verbose=4 "$FRAMEWORK" 2>&1)
FRAMEWORK_TEAM=$(print -r -- "$FRAMEWORK_SIGNATURE" | sed -n 's/^TeamIdentifier=//p' | head -1)
[[ "$FRAMEWORK_TEAM" == "$APP_TEAM" ]] || {
    print -u2 "SQLCipher and ThreadLight were not signed by the same Apple team."
    exit 6
}

ENTITLEMENTS_FILE=$(mktemp /tmp/threadlight-release-entitlements.XXXXXX.plist)
trap 'rm -f "$ENTITLEMENTS_FILE"' EXIT
codesign -d --entitlements :- "$RELEASE_APP" > "$ENTITLEMENTS_FILE" 2>/dev/null

for entitlement in \
    com.apple.security.app-sandbox \
    com.apple.security.network.client \
    com.apple.security.files.user-selected.read-write
do
    [[ "$(plutil -extract "$entitlement" raw -o - "$ENTITLEMENTS_FILE")" == "true" ]] || {
        print -u2 "Required production entitlement is missing: $entitlement"
        exit 7
    }
done

for forbidden in \
    com.apple.security.cs.disable-library-validation \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.cs.allow-dyld-environment-variables \
    com.apple.security.get-task-allow
do
    if plutil -extract "$forbidden" raw -o - "$ENTITLEMENTS_FILE" >/dev/null 2>&1; then
        print -u2 "Forbidden production entitlement is present: $forbidden"
        exit 8
    fi
done

EXECUTABLE="$RELEASE_APP/Contents/MacOS/ThreadLight"
if strings "$EXECUTABLE" | grep -E -- '--threadlight-demo|Northstar Preservation|THREADLIGHT_DEVELOPMENT|Development mode' >/dev/null; then
    print -u2 "Development/demo behavior is present in the production executable."
    exit 9
fi

[[ "$(plutil -extract LSMinimumSystemVersion raw -o - "$RELEASE_APP/Contents/Info.plist")" == "26.0" ]] || {
    print -u2 "The release no longer targets macOS 26 only."
    exit 10
}

if [[ "$PRE_NOTARIZATION" == false ]]; then
    xcrun stapler validate "$RELEASE_APP"
    spctl --assess --type execute --verbose=4 "$RELEASE_APP"
fi

if [[ "$PRE_NOTARIZATION" == true ]]; then
    print "THREADLIGHT_PRE_NOTARIZATION_VALID"
else
    print "THREADLIGHT_RELEASE_VALID"
fi
print "TEAM_ID=$APP_TEAM"
