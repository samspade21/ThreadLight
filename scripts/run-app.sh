#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
"$SCRIPT_DIR/build-app.sh" "$@"
open "$SCRIPT_DIR/../build/ThreadLight.app"
