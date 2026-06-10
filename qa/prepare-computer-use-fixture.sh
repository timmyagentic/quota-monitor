#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cat >&2 <<'EOF'
warning: qa/prepare-computer-use-fixture.sh is a compatibility wrapper.
Use qa/prepare-computer-use-fixture-smoke.sh for deterministic fixture smoke,
or qa/prepare-computer-use-real-data.sh for local test builds with real data.
EOF

exec "${ROOT_DIR}/qa/prepare-computer-use-fixture-smoke.sh" "$@"
