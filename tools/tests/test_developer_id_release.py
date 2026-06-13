#!/usr/bin/env python3
import pathlib
import plistlib
import os
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class DeveloperIDReleaseTests(unittest.TestCase):
    def read_text(self, relative_path: str) -> str:
        return (REPO_ROOT / relative_path).read_text(encoding="utf-8")

    def test_release_pipeline_supports_developer_id_without_replacing_sparkle(self):
        release = self.read_text("tools/release.sh")

        self.assertIn("QM_RELEASE_SIGNING", release)
        self.assertIn("developer-id", release)
        self.assertIn("tools/notarize.sh", release)
        self.assertIn("tools/notarize-dmg.sh", release)
        self.assertIn("QM_MAKE_DMG_SKIP_BUILD=1", release)

        app_notarize_index = release.index("tools/notarize.sh")
        dmg_build_index = release.index("tools/make-dmg.sh")
        dmg_notarize_index = release.index("tools/notarize-dmg.sh")
        self.assertLess(app_notarize_index, dmg_build_index)
        self.assertLess(dmg_build_index, dmg_notarize_index)

        plist_path = REPO_ROOT / "Resources" / "Info.plist"
        with plist_path.open("rb") as plist_file:
            info = plistlib.load(plist_file)

        self.assertEqual(info["CFBundleIdentifier"], "dev.tjzhou.QuotaMonitor")
        self.assertEqual(
            info["SUFeedURL"],
            "https://raw.githubusercontent.com/systemoutprintlnnnn/quota-monitor/main/appcast.xml",
        )
        self.assertEqual(
            info["SUPublicEDKey"],
            "QzgtY6kPCCK/S98RMT5u03HVx8PTd+cahlHQti+Fmak=",
        )

    def test_make_dmg_can_package_pre_signed_bundle_without_rebuilding(self):
        make_dmg = self.read_text("tools/make-dmg.sh")

        self.assertIn("QM_MAKE_DMG_SKIP_BUILD", make_dmg)
        self.assertIn("Skipping build", make_dmg)

    def test_ci_imports_developer_id_certificate_and_keeps_sparkle_signing(self):
        workflow = self.read_text(".github/workflows/release.yml")

        self.assertIn("DEVELOPER_ID_CERTIFICATE_BASE64", workflow)
        self.assertIn("DEVELOPER_ID_CERTIFICATE_PASSWORD", workflow)
        self.assertIn("DEVELOPER_ID_APPLICATION", workflow)
        self.assertIn("APPLE_ID", workflow)
        self.assertIn("APPLE_TEAM_ID", workflow)
        self.assertIn("APPLE_APP_SPECIFIC_PASSWORD", workflow)
        self.assertIn("QM_RELEASE_SIGNING: developer-id", workflow)

        self.assertIn("SPARKLE_PRIVATE_KEY", workflow)
        self.assertIn("./tools/verify-signing-key.sh", workflow)
        self.assertIn("./tools/release-sparkle.sh", workflow)

    def test_developer_id_helpers_are_present_and_do_not_hide_notary_status(self):
        common = self.read_text("tools/developer-id-common.sh")
        app_notary = self.read_text("tools/notarize.sh")
        dmg_notary = self.read_text("tools/notarize-dmg.sh")

        self.assertIn("qm_resolve_developer_id_identity", common)
        self.assertIn("qm_set_notary_args", common)
        self.assertIn("NOTARYTOOL_TIMEOUT", app_notary)
        self.assertIn("xcrun notarytool submit", app_notary)
        self.assertIn("xcrun stapler staple", app_notary)
        self.assertIn("NOTARYTOOL_TIMEOUT", dmg_notary)
        self.assertIn("spctl --assess --type open", dmg_notary)

    def test_notary_args_can_use_default_keychain_profile_without_apple_env(self):
        with tempfile.TemporaryDirectory() as tmp:
            mock_xcrun = pathlib.Path(tmp) / "xcrun"
            mock_xcrun.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    if [[ "$1" == "notarytool" && "$2" == "history" ]]; then
                        exit 0
                    fi
                    exit 2
                    """
                ),
                encoding="utf-8",
            )
            mock_xcrun.chmod(0o755)

            env = os.environ.copy()
            for name in (
                "APPLE_ID",
                "APPLE_TEAM_ID",
                "APPLE_APP_SPECIFIC_PASSWORD",
                "NOTARYTOOL_PROFILE",
                "PROFILE",
            ):
                env.pop(name, None)
            env["PATH"] = f"{tmp}:{env['PATH']}"

            script = textwrap.dedent(
                f"""\
                set -euo pipefail
                . "{REPO_ROOT / 'tools' / 'developer-id-common.sh'}"
                qm_set_notary_args
                printf '%s\\n' "${{QM_NOTARY_ARGS[@]}}"
                """
            )
            result = subprocess.run(
                ["bash", "-c", script],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            ["--keychain-profile", "quotamonitor-notary"],
        )


if __name__ == "__main__":
    unittest.main()
