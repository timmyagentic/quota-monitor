#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/cloud-env.sh"
cd "$QM_CLOUD_ROOT"
command -v git >/dev/null
command -v python3 >/dev/null
node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && minor < 12)) throw Error("Node >=22.12 required; use Node 22 LTS")'
printf 'Cloud bootstrap ready: %s\n' "$(git rev-parse HEAD)"
printf 'Next: ./qa/run-cloud.sh (portable checks only; macOS gate still required)\n'
