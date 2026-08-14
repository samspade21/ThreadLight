#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
EXPECTED_REPOSITORY=${THREADLIGHT_RELEASE_REPOSITORY:-samspade21/ThreadLight}
VERSION=${1:-$(<"$PROJECT_DIR/VERSION")}
TAG="v$VERSION"
DMG_PATH="$PROJECT_DIR/build/ThreadLight-$VERSION.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"

"$PROJECT_DIR/scripts/check-version.sh" "$VERSION" >/dev/null

cd "$PROJECT_DIR"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
    print -u2 "Release checkout is not clean. Commit or remove every change before publishing."
    exit 3
}
git rev-parse --verify HEAD >/dev/null
gh auth status --hostname github.com >/dev/null
gh repo view "$EXPECTED_REPOSITORY" >/dev/null
if gh release view "$TAG" --repo "$EXPECTED_REPOSITORY" >/dev/null 2>&1; then
    print -u2 "GitHub release $TAG already exists."
    exit 4
fi

"$PROJECT_DIR/scripts/build-release.sh"

gh release create "$TAG" \
    "$DMG_PATH#ThreadLight $VERSION DMG" \
    "$CHECKSUM_PATH#SHA-256 checksum" \
    --repo "$EXPECTED_REPOSITORY" \
    --target "$(git rev-parse HEAD)" \
    --title "ThreadLight $VERSION" \
    --generate-notes \
    --latest

print "Published https://github.com/$EXPECTED_REPOSITORY/releases/tag/$TAG"
