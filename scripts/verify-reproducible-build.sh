#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
FIRST_MANIFEST=$(mktemp -t threadlight-build-1)
SECOND_MANIFEST=$(mktemp -t threadlight-build-2)
trap 'rm -f "$FIRST_MANIFEST" "$SECOND_MANIFEST"' EXIT

cd "$PROJECT_DIR"

file_manifest() {
    (
        cd build
        find ThreadLight.app -type f -print0 | sort -z | xargs -0 shasum -a 256
    )
}

./scripts/build-app.sh --development >/dev/null
file_manifest > "$FIRST_MANIFEST"
./scripts/build-app.sh --development >/dev/null
file_manifest > "$SECOND_MANIFEST"

if ! diff -u "$FIRST_MANIFEST" "$SECOND_MANIFEST"; then
    echo "ThreadLight ad-hoc app files differ between identical builds." >&2
    exit 1
fi

echo "ThreadLight ad-hoc app file hashes are reproducible for this checkout and toolchain."
