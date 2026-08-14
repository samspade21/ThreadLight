#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
VERSION_FILE="$PROJECT_DIR/VERSION"
PLIST_FILE="$PROJECT_DIR/Config/Info.plist"
NEXT_VERSION=${1:-}

print -r -- "$NEXT_VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || {
    print -u2 "Usage: ./scripts/bump-version.sh MAJOR.MINOR.PATCH"
    exit 2
}

CURRENT_VERSION=$(<"$VERSION_FILE")
autoload -Uz is-at-least
is-at-least "$CURRENT_VERSION" "$NEXT_VERSION" && [[ "$NEXT_VERSION" != "$CURRENT_VERSION" ]] || {
    print -u2 "New version must be greater than $CURRENT_VERSION."
    exit 3
}

print -r -- "$NEXT_VERSION" > "$VERSION_FILE"
plutil -replace CFBundleShortVersionString -string "$NEXT_VERSION" "$PLIST_FILE"
plutil -replace CFBundleVersion -string "$NEXT_VERSION" "$PLIST_FILE"
print "ThreadLight version: $CURRENT_VERSION → $NEXT_VERSION"
print "Review and commit VERSION and Config/Info.plist before releasing."
