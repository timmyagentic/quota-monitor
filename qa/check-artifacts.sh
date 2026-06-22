#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "${ROOT_DIR}/qa/lib/common.sh"

usage() {
    echo "usage: $0 <qa-artifact-directory> [expected-language] [comma-separated-steps]" >&2
}

if [[ $# -lt 1 || $# -gt 3 ]]; then
    usage
    exit 2
fi

qm_require_command plutil
if [[ -f "$1/real-data-protection.txt" ]]; then
    qm_assert_real_data_artifact_contract "$1"
else
    qm_assert_artifact_contract \
        "$1" \
        "${2:-en}" \
        "${3:-exercise-settings}"
fi
echo "QA artifact contract ok: $1"
