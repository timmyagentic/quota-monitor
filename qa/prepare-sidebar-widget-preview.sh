#!/usr/bin/env bash
# Launch the shipping SwiftUI components with synthetic quota in an isolated app.
# Does not validate the external Codex AX tree or NSPanel focus/drag integration.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"${ROOT_DIR}/build.sh" debug
mkdir -p "${ROOT_DIR}/.build/qa-artifacts"
PREVIEW_ROOT="$(mktemp -d "${ROOT_DIR}/.build/qa-artifacts/sidebar-widget.XXXXXX")"
PREVIEW_APP="${PREVIEW_ROOT}/QuotaMonitorSidebarQA.app"
PREVIEW_LANGUAGE="${QM_QA_LANGUAGE:-en}"
/usr/bin/ditto "${ROOT_DIR}/.build/QuotaMonitor.app" "$PREVIEW_APP"
python3 - "$PREVIEW_ROOT" "$PREVIEW_APP" "$PREVIEW_LANGUAGE" <<'PY'
import json
import pathlib
import plistlib
import subprocess
import sys

root, app = (pathlib.Path(value) for value in sys.argv[1:3])
language = sys.argv[3]
if language not in {"en", "zh-Hans"}:
    raise SystemExit("QM_QA_LANGUAGE must be en or zh-Hans")
suite = "dev.tjzhou.QuotaMonitor.SidebarQA." + root.name.rsplit(".", 1)[-1]
info_path = app / "Contents/Info.plist"
with info_path.open("rb") as handle:
    info = plistlib.load(handle)
info.update(CFBundleIdentifier=suite, CFBundleName="QuotaMonitor Sidebar QA",
            CFBundleDisplayName="QuotaMonitor Sidebar QA")
info.pop("CFBundleURLTypes", None)
with info_path.open("wb") as handle:
    plistlib.dump(info, handle)
(root / "home").mkdir()
(root / "artifacts").mkdir()
config = {"mode": True, "home": str(root / "home"), "defaultsSuite": suite,
          "codexHome": str(root / "home/.codex"),
          "outputDirectory": str(root / "artifacts"),
          "steps": ["show-codex-overlay-details", "snapshot"],
          "mockCodexResetCredits": False}
(root / "qa-config.json").write_text(json.dumps(config, indent=2) + "\n")
preferences = {"app.language": language, "onboarding.providersDone": True,
               "onboarding.lastVersion": info["CFBundleShortVersionString"],
               "discoverability.firstRunPresentationShown": True,
               "settings.developerModeEnabled": True,
               "settings.keychainPolicy": "fallback",
               "settings.showDockIconForWindows": True,
               "settings.enabledProviders": ["codex"],
               "settings.menuBarIconProviders": ["codex"]}
with (root / "defaults.plist").open("wb") as handle:
    plistlib.dump(preferences, handle)
subprocess.run(["/usr/bin/defaults", "import", suite, str(root / "defaults.plist")], check=True)
(root / "bundle-id.txt").write_text(suite + "\n")
PY
/usr/bin/codesign --force --deep --sign - "$PREVIEW_APP"
/usr/bin/open -n "$PREVIEW_APP" --args --quotamonitor-qa-config "${PREVIEW_ROOT}/qa-config.json"
printf 'Native widget preview: %s\n' "$PREVIEW_ROOT"
