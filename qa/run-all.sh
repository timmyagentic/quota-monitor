#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${HOME}/.swiftly/env.sh" ]]; then
    # shellcheck disable=SC1090
    . "${HOME}/.swiftly/env.sh"
fi

"${ROOT_DIR}/qa/tests/common_tests.sh"
(cd "$ROOT_DIR" && swift test --disable-keychain)
"${ROOT_DIR}/qa/run-local.sh"
