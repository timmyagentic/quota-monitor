#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/cloud-env.sh"
cd "$QM_CLOUD_ROOT"
bash -n qa/cloud-env.sh qa/bootstrap-cloud.sh qa/run-cloud.sh
python3 -m unittest discover tools/tests
python3 tools/validate-release-notes.py "$(tr -d '[:space:]' < Resources/VERSION)" CHANGELOG.md CHANGELOG.zh-Hans.md
git diff --check HEAD --
printf 'Portable checks passed on %s for %s; Swift, GUI, signing and publication remain UNVERIFIED.\n' "$(uname -s)" "$(git rev-parse HEAD)"
