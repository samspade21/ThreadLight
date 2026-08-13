#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /path/to/package.threadlight-{evidence,setup-request,setup-response}" >&2
    exit 64
fi

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
cd "$PROJECT_DIR"
swift run --configuration release threadlight-verify "$1"
