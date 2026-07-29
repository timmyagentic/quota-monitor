#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

OPSAIL_VERSION="0.2.0"
OPSAIL_RELEASE_BASE="https://github.com/lencx/opsail/releases/download/v${OPSAIL_VERSION}"
OPSAIL_CACHE_ROOT="${OPSAIL_HELPER_CACHE_DIR:-.build/vendor/opsail/v${OPSAIL_VERSION}}"
OPSAIL_MACHINE="${OPSAIL_HELPER_ARCH:-$(uname -m)}"

case "${OPSAIL_MACHINE}" in
    arm64|aarch64)
        OPSAIL_TARGET="aarch64-apple-darwin"
        OPSAIL_ARCHIVE="opsail-aarch64-apple-darwin.tar.gz"
        OPSAIL_SHA256="32e3c00cd5548807df6d1264c2ed902c275c8550b76313f96802a964e83ac94a"
        ;;
    x86_64|amd64)
        OPSAIL_TARGET="x86_64-apple-darwin"
        OPSAIL_ARCHIVE="opsail-x86_64-apple-darwin.tar.gz"
        OPSAIL_SHA256="9db8807ffa8110e3c690ce08c2e6bb46a7d44767f1d677ca9eb45ac5e191a999"
        ;;
    *)
        echo "error: unsupported Opsail helper architecture ${OPSAIL_MACHINE}" >&2
        exit 2
        ;;
esac

OPSAIL_CACHE_DIR="${OPSAIL_CACHE_ROOT}/${OPSAIL_TARGET}"
OPSAIL_BINARY="${OPSAIL_CACHE_DIR}/opsail"

if [[ -x "${OPSAIL_BINARY}" ]] \
    && [[ "$("${OPSAIL_BINARY}" --version 2>/dev/null)" == "opsail ${OPSAIL_VERSION}" ]]; then
    printf '%s\n' "${OPSAIL_BINARY}"
    exit 0
fi

OPSAIL_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quotamonitor-opsail.XXXXXX")"
trap 'rm -rf "${OPSAIL_TEMP_DIR}"' EXIT

OPSAIL_ARCHIVE_PATH="${OPSAIL_TEMP_DIR}/${OPSAIL_ARCHIVE}"
OPSAIL_ARCHIVE_URL="${OPSAIL_RELEASE_BASE}/${OPSAIL_ARCHIVE}"

echo "==> Fetching Opsail v${OPSAIL_VERSION} (${OPSAIL_TARGET})" >&2
curl --fail --location --silent --show-error \
    "${OPSAIL_ARCHIVE_URL}" \
    --output "${OPSAIL_ARCHIVE_PATH}"

OPSAIL_ACTUAL_SHA256="$(shasum -a 256 "${OPSAIL_ARCHIVE_PATH}" | awk '{print $1}')"
if [[ "${OPSAIL_ACTUAL_SHA256}" != "${OPSAIL_SHA256}" ]]; then
    echo "error: Opsail archive checksum mismatch" >&2
    exit 1
fi

tar -xzf "${OPSAIL_ARCHIVE_PATH}" -C "${OPSAIL_TEMP_DIR}"
OPSAIL_EXTRACTED="${OPSAIL_TEMP_DIR}/opsail-${OPSAIL_TARGET}/opsail"
if [[ ! -x "${OPSAIL_EXTRACTED}" ]]; then
    echo "error: Opsail release archive did not contain the expected executable" >&2
    exit 1
fi
if [[ "$("${OPSAIL_EXTRACTED}" --version 2>/dev/null)" != "opsail ${OPSAIL_VERSION}" ]]; then
    echo "error: Opsail executable version does not match v${OPSAIL_VERSION}" >&2
    exit 1
fi

mkdir -p "${OPSAIL_CACHE_DIR}"
cp "${OPSAIL_EXTRACTED}" "${OPSAIL_BINARY}.new"
chmod 755 "${OPSAIL_BINARY}.new"
mv "${OPSAIL_BINARY}.new" "${OPSAIL_BINARY}"

printf '%s\n' "${OPSAIL_BINARY}"
