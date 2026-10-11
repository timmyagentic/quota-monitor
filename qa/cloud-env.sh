#!/usr/bin/env bash
# Sourced by cloud entrypoints; keep HOME and host credentials untouched.
QM_CLOUD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export npm_config_cache="${QM_CLOUD_ROOT}/.build/cloud/npm-cache"
export XDG_CONFIG_HOME="${QM_CLOUD_ROOT}/.build/cloud/config"
export XDG_CACHE_HOME="${QM_CLOUD_ROOT}/.build/cloud/cache"
export WRANGLER_LOG_PATH="${QM_CLOUD_ROOT}/.build/cloud/logs"
export WRANGLER_SEND_METRICS=false
export CI=true
mkdir -p "$npm_config_cache" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$WRANGLER_LOG_PATH"
# Neither cloud entrypoint needs Cloudflare authentication.
unset CLOUDFLARE_API_TOKEN CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL
