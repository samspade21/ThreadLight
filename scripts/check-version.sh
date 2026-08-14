#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
EXPECTED_VERSION=${1:-$(<"$PROJECT_DIR/VERSION")}

print -r -- "$EXPECTED_VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || {
    print -u2 "Version must be MAJOR.MINOR.PATCH without leading zeroes. Found: $EXPECTED_VERSION"
    exit 2
}
[[ "$(<"$PROJECT_DIR/VERSION")" == "$EXPECTED_VERSION" ]] || {
    print -u2 "VERSION does not match requested version $EXPECTED_VERSION."
    exit 3
}
for key in CFBundleShortVersionString CFBundleVersion; do
    actual=$(plutil -extract "$key" raw -o - "$PROJECT_DIR/Config/Info.plist")
    [[ "$actual" == "$EXPECTED_VERSION" ]] || {
        print -u2 "Config/Info.plist $key is $actual, not $EXPECTED_VERSION. Run ./scripts/bump-version.sh."
        exit 3
    }
done
print "$EXPECTED_VERSION"
