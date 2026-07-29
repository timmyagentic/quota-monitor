# Opsail helper

QuotaMonitor embeds the official `opsail` macOS executable for the optional
Codex sidebar integration.

- Release: `v0.2.0`
- Release commit: `05b8a844b1c27110ab9c66e0de4cdc5bc003a34c`
- Audited source snapshot: `4580d275d9910e68be2ebf6a524ce2ea6f98a5a9`
- Renderer asset version: `1.0.0`
- License: Apache-2.0

The audited snapshot changes only release imagery after the release commit;
`crates/opsail-refit-codex` and `crates/opsail` are identical between them.

Official release archives are fetched by `tools/fetch-opsail-helper.sh` and
verified before extraction:

| Architecture | Archive | SHA-256 |
| --- | --- | --- |
| arm64 | `opsail-aarch64-apple-darwin.tar.gz` | `32e3c00cd5548807df6d1264c2ed902c275c8550b76313f96802a964e83ac94a` |
| x86_64 | `opsail-x86_64-apple-darwin.tar.gz` | `9db8807ffa8110e3c690ce08c2e6bb46a7d44767f1d677ca9eb45ac5e191a999` |

The downloaded binary is cached under `.build/vendor/`, copied into
`QuotaMonitor.app/Contents/Helpers/opsail`, and signed as nested code during
release packaging. App Store builds do not include or expose this integration.
