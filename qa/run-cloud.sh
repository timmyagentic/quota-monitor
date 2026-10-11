#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/cloud-env.sh"
cd "$QM_CLOUD_ROOT"
# Reject local developer configuration rather than loading credentials from it.
for candidate in website/.dev.vars* website/.env*; do
    if [[ -f "$candidate" ]]; then
        echo "Remove local website environment files from the cloud checkout before testing" >&2
        exit 1
    fi
done
bash -n qa/cloud-env.sh qa/bootstrap-cloud.sh qa/run-cloud.sh
python3 -m unittest discover tools/tests
python3 tools/validate-release-notes.py "$(tr -d '[:space:]' < Resources/VERSION)" CHANGELOG.md CHANGELOG.zh-Hans.md
python3 tools/validate-release-notes.py Unreleased CHANGELOG.md CHANGELOG.zh-Hans.md
git diff --check HEAD --
npm --prefix website run check
printf 'Portable checks passed on %s for %s; Swift, GUI, signing and publication remain UNVERIFIED.\n' "$(uname -s)" "$(git rev-parse HEAD)"
