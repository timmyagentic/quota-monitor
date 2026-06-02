#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "${ROOT_DIR}/qa/lib/common.sh"

usage() {
    echo "usage: $0 <qa-artifact-directory>" >&2
}

if [[ $# -ne 1 ]]; then
    usage
    exit 2
fi

qm_require_command plutil
qm_assert_artifact_contract "$1"
echo "QA artifact contract ok: $1"
