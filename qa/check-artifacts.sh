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
if [[ -f "$1/real-data-protection.txt" ]]; then
    qm_assert_real_data_artifact_contract "$1"
else
    qm_assert_artifact_contract "$1"
fi
echo "QA artifact contract ok: $1"
