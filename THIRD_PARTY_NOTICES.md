# Third-party notices

## Opsail

Developer ID builds bundle the official `opsail` v0.2.0 macOS executable from
[lencx/opsail](https://github.com/lencx/opsail). QuotaMonitor invokes its
`opsail-refit-codex` lifecycle directly instead of maintaining an independent
CDP, process manager, or quota bridge.

The release is pinned to commit
`05b8a844b1c27110ab9c66e0de4cdc5bc003a34c`; the audited source snapshot at
`4580d275d9910e68be2ebf6a524ce2ea6f98a5a9` contains identical
`opsail-refit-codex` and CLI source. Official macOS archives are verified using
the SHA-256 values recorded in `Vendor/Opsail/README.md`.

Developer ID builds also include a QuotaMonitor presentation derivative of
Opsail's Apache-2.0 renderer assets. It preserves the upstream lifecycle and
local-only execution contracts while changing localized copy, compact date
formatting, visible metadata hierarchy, and theme-token CSS. Exact provenance
and file hashes are recorded in `Vendor/Opsail/README.md` and
`Vendor/Opsail/Renderer/manifest.json`.

Opsail is copyright its contributors and licensed under the
[Apache License 2.0](LICENSES/Opsail-Apache-2.0.txt).
