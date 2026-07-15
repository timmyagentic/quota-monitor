#!/usr/bin/env python3
import pathlib
import plistlib
import os
import re
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class DeveloperIDReleaseTests(unittest.TestCase):
    def read_text(self, relative_path: str) -> str:
        return (REPO_ROOT / relative_path).read_text(encoding="utf-8")

    def workflow_job(
        self,
        workflow: str,
        name: str,
        next_name=None,
    ) -> str:
        start_marker = f"  {name}:"
        start = workflow.index(start_marker)
        if next_name is None:
            return workflow[start:]
        end = workflow.index(f"  {next_name}:", start + len(start_marker))
        return workflow[start:end]

    def workflow_step(
        self,
        job: str,
        name: str,
        next_name=None,
    ) -> str:
        start_marker = f"      - name: {name}"
        start = job.index(start_marker)
        if next_name is None:
            return job[start:]
        end = job.index(
            f"      - name: {next_name}",
            start + len(start_marker),
        )
        return job[start:end]

    def test_quota_monitor_distribution_urls_use_current_repository_owner(self):
        legacy_repo = "systemoutprintlnnnn" + "/quota-monitor"
        current_repo = "timmyagentic/quota-monitor"
        distribution_files = [
            ".github/workflows/release.yml",
            "README.md",
            "Resources/Info.plist",
            "appcast.xml",
            "tools/release-sparkle.sh",
        ]

        for relative_path in distribution_files:
            with self.subTest(path=relative_path):
                contents = self.read_text(relative_path)
                self.assertNotIn(legacy_repo, contents)
                self.assertIn(current_repo, contents)

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
            "https://raw.githubusercontent.com/timmyagentic/quota-monitor/main/appcast.xml",
        )
        self.assertEqual(
            info["SUPublicEDKey"],
            "QzgtY6kPCCK/S98RMT5u03HVx8PTd+cahlHQti+Fmak=",
        )

    def test_make_dmg_can_package_pre_signed_bundle_without_rebuilding(self):
        make_dmg = self.read_text("tools/make-dmg.sh")

        self.assertIn("QM_MAKE_DMG_SKIP_BUILD", make_dmg)
        self.assertIn("Skipping build", make_dmg)

    def test_developer_id_release_builds_do_not_inherit_app_store_distribution(self):
        release = self.read_text("tools/release.sh")
        make_dmg = self.read_text("tools/make-dmg.sh")

        self.assertIn("QM_DISTRIBUTION=developer-id ./build.sh", release)
        self.assertIn('QM_DISTRIBUTION="developer-id" ./build.sh', make_dmg)

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

    def test_shared_gate_checks_every_required_release_secret_before_checkout(self):
        workflow = self.read_text(".github/workflows/release.yml")
        shared_job = self.workflow_job(
            workflow,
            "test",
            "release-quota-monitor",
        )

        self.assertIn(
            "    steps:\n      - name: Validate required release secrets\n",
            shared_job,
        )
        preflight_end = shared_job.index("      - uses: actions/checkout")
        preflight = shared_job[:preflight_end]
        required = (
            "DEVELOPER_ID_CERTIFICATE_BASE64",
            "DEVELOPER_ID_CERTIFICATE_PASSWORD",
            "APPLE_ID",
            "APPLE_TEAM_ID",
            "APPLE_APP_SPECIFIC_PASSWORD",
            "SPARKLE_PRIVATE_KEY",
            "CODEX_MONITOR_PAT",
        )
        required_block_start = preflight.index("required=(")
        required_block_end = preflight.index(")", required_block_start)
        required_block = preflight[required_block_start:required_block_end]
        required_entries = tuple(
            line.strip()
            for line in required_block.splitlines()[1:]
            if line.strip()
        )

        for secret in required:
            with self.subTest(secret=secret):
                self.assertIn(
                    f"          {secret}: ${{{{ secrets.{secret} }}}}",
                    preflight,
                )
                self.assertIn(secret, required_block)

        self.assertEqual(required_entries, required)
        self.assertNotIn("DEVELOPER_ID_APPLICATION", preflight)
        self.assertIn('for name in "${required[@]}"; do', preflight)
        self.assertIn(
            'echo "::error::required release secret ${name} is missing"',
            preflight,
        )
        self.assertIn("missing=0", preflight)
        self.assertIn("missing=1", preflight)
        self.assertLess(preflight.index("done"), preflight.index('exit "${missing}"'))

        quota_job = self.workflow_job(
            workflow,
            "release-quota-monitor",
            "release-codex-monitor",
        )
        codex_job = self.workflow_job(workflow, "release-codex-monitor")
        self.assertIn("    needs: test", quota_job)
        self.assertIn("    needs: test", codex_job)

    def test_release_workflow_scopes_write_permissions_to_quota_job(self):
        workflow = self.read_text(".github/workflows/release.yml")
        shared_job = self.workflow_job(
            workflow,
            "test",
            "release-quota-monitor",
        )
        quota_job = self.workflow_job(
            workflow,
            "release-quota-monitor",
            "release-codex-monitor",
        )
        codex_job = self.workflow_job(workflow, "release-codex-monitor")

        permissions_start = workflow.index("permissions:")
        permissions_end = workflow.index("\n\n", permissions_start)
        self.assertEqual(
            workflow[permissions_start:permissions_end],
            "permissions:\n  contents: read",
        )
        self.assertNotRegex(shared_job, r"(?m)^    permissions:")

        permission_pattern = re.compile(
            r"(?m)^    permissions:\n(?:^      [a-z-]+: (?:read|write)\n)+"
        )
        quota_permissions = permission_pattern.search(quota_job)
        codex_permissions = permission_pattern.search(codex_job)
        self.assertIsNotNone(quota_permissions)
        self.assertIsNotNone(codex_permissions)
        self.assertEqual(
            quota_permissions.group(0).strip(),
            "permissions:\n"
            "      contents: write\n"
            "      pull-requests: write",
        )
        self.assertEqual(
            codex_permissions.group(0).strip(),
            "permissions:\n      contents: read",
        )
        self.assertEqual(
            re.findall(r"(?m)^      contents: write$", workflow),
            ["      contents: write"],
        )
        self.assertEqual(
            re.findall(r"(?m)^      pull-requests: write$", workflow),
            ["      pull-requests: write"],
        )

    def test_release_workflow_never_skips_required_appcast_publication(self):
        workflow = self.read_text(".github/workflows/release.yml")

        self.assertNotIn("skip=true", workflow)
        self.assertNotIn("skipping appcast signing", workflow.lower())
        self.assertNotIn("steps.appcast.outputs.skip", workflow)

    def test_each_brand_signs_the_final_dmg_before_uploading_the_same_paths(self):
        workflow = self.read_text(".github/workflows/release.yml")
        jobs = (
            (
                "quota-monitor",
                self.workflow_job(
                    workflow,
                    "release-quota-monitor",
                    "release-codex-monitor",
                ),
                "QuotaMonitor",
                "Create GitHub Release",
                "Open appcast PR",
            ),
            (
                "codex-monitor",
                self.workflow_job(workflow, "release-codex-monitor"),
                "CodexMonitor",
                "Create GitHub Release on codex-monitor repo",
                "Publish appcast entry to codex-monitor",
            ),
        )

        for brand, job, app_name, create_name, publish_name in jobs:
            with self.subTest(brand=brand):
                for step_name in (
                    "Run release pipeline",
                    "Extract CHANGELOG section for this release",
                    "Sign release DMG + build appcast entry",
                    create_name,
                    publish_name,
                ):
                    self.assertIn(f"      - name: {step_name}", job)
                pipeline = job.index("      - name: Run release pipeline")
                notes = job.index(
                    "      - name: Extract CHANGELOG section for this release"
                )
                sign = job.index(
                    "      - name: Sign release DMG + build appcast entry"
                )
                create = job.index(f"      - name: {create_name}")
                publish = job.index(f"      - name: {publish_name}")
                self.assertLess(pipeline, notes)
                self.assertLess(notes, sign)
                self.assertLess(sign, create)
                self.assertLess(create, publish)

                sign_step = self.workflow_step(
                    job,
                    "Sign release DMG + build appcast entry",
                    create_name,
                )
                release_step = self.workflow_step(job, create_name, publish_name)
                self.assertIn("        id: appcast", sign_step)
                self.assertIn(
                    f'DMG="dist/{app_name}-${{VERSION}}.dmg"',
                    sign_step,
                )
                self.assertIn('SHA="${DMG}.sha256"', sign_step)
                self.assertIn('! -f "${DMG}"', sign_step)
                self.assertIn('! -f "${SHA}"', sign_step)
                self.assertIn('EXPECTED_SHA="$(awk', sign_step)
                self.assertIn('PRE_SIGN_SHA="$(shasum -a 256 "${DMG}"', sign_step)
                self.assertIn('"${EXPECTED_SHA}" != "${PRE_SIGN_SHA}"', sign_step)
                self.assertIn("./tools/verify-signing-key.sh", sign_step)
                self.assertIn('./tools/release-sparkle.sh "${DMG}"', sign_step)
                self.assertIn('POST_SIGN_SHA="$(shasum -a 256 "${DMG}"', sign_step)
                self.assertIn('"${PRE_SIGN_SHA}" != "${POST_SIGN_SHA}"', sign_step)
                self.assertIn(
                    'echo "dmg=${DMG}" >> "${GITHUB_OUTPUT}"',
                    sign_step,
                )
                self.assertIn(
                    'echo "sha=${SHA}" >> "${GITHUB_OUTPUT}"',
                    sign_step,
                )
                self.assertIn('"${{ steps.appcast.outputs.dmg }}"', release_step)
                self.assertIn('"${{ steps.appcast.outputs.sha }}"', release_step)

    def test_codex_publication_is_canonical_but_bundled_feed_stays_legacy(self):
        workflow = self.read_text(".github/workflows/release.yml")
        codex_job = self.workflow_job(workflow, "release-codex-monitor")
        sparkle = self.read_text("tools/release-sparkle.sh")
        legacy_feed = (
            "https://raw.githubusercontent.com/systemoutprintlnnnn/"
            "codex-monitor/main/appcast.xml"
        )

        self.assertEqual(codex_job.count(legacy_feed), 1)
        self.assertIn("--repo timmyagentic/codex-monitor", codex_job)
        self.assertIn('RELEASE_REPO="timmyagentic/codex-monitor"', codex_job)
        self.assertIn(
            'NOTES_BASE_URL="https://raw.githubusercontent.com/'
            'timmyagentic/codex-monitor/main"',
            codex_job,
        )
        self.assertIn(
            "@github.com/timmyagentic/codex-monitor.git",
            codex_job,
        )
        self.assertNotIn("--repo systemoutprintlnnnn/codex-monitor", codex_job)
        self.assertNotIn(
            'RELEASE_REPO="systemoutprintlnnnn/codex-monitor"',
            codex_job,
        )
        self.assertNotIn(
            'NOTES_BASE_URL="https://raw.githubusercontent.com/'
            'systemoutprintlnnnn/codex-monitor/main"',
            codex_job,
        )
        self.assertNotIn(
            "@github.com/systemoutprintlnnnn/codex-monitor.git",
            codex_job,
        )
        self.assertIn(
            "RELEASE_REPO=timmyagentic/codex-monitor",
            sparkle,
        )
        self.assertNotIn(
            "RELEASE_REPO=systemoutprintlnnnn/codex-monitor",
            sparkle,
        )

    def test_update_feed_health_workflow_is_read_only_and_checks_both_brands(self):
        workflow_path = REPO_ROOT / ".github/workflows/update-feed-health.yml"
        self.assertTrue(
            workflow_path.is_file(),
            "expected the scheduled update-feed health workflow",
        )
        workflow = workflow_path.read_text(encoding="utf-8")

        self.assertRegex(workflow, r"(?m)^  schedule:\n    - cron: .+$")
        self.assertRegex(workflow, r"(?m)^  workflow_dispatch:\s*$")
        permissions_start = workflow.index("permissions:")
        jobs_start = workflow.index("jobs:", permissions_start)
        permissions = workflow[permissions_start:jobs_start].strip()
        self.assertEqual(permissions, "permissions:\n  contents: read")
        self.assertNotRegex(workflow, r"(?m)^\s+[A-Za-z-]+:\s*write\s*$")

        pairs = tuple(
            (repo.strip('"\''), feed.strip('"\''))
            for repo, feed in re.findall(
                r"(?m)^\s+- release_repo:\s*(\S+)\s*$\n"
                r"^\s+feed_url:\s*(\S+)\s*$",
                workflow,
            )
        )
        self.assertEqual(
            pairs,
            (
                (
                    "timmyagentic/quota-monitor",
                    "https://raw.githubusercontent.com/timmyagentic/"
                    "quota-monitor/main/appcast.xml",
                ),
                (
                    "timmyagentic/codex-monitor",
                    "https://raw.githubusercontent.com/systemoutprintlnnnn/"
                    "codex-monitor/main/appcast.xml",
                ),
            ),
        )
        self.assertIn("    timeout-minutes: 10", workflow)
        self.assertIn("      fail-fast: false", workflow)
        self.assertIn("uses: actions/checkout@v6.0.2", workflow)
        self.assertIn("python3 tools/check-update-feed-health.py", workflow)
        self.assertIn('--repo "${{ matrix.release_repo }}"', workflow)
        self.assertIn('--feed-url "${{ matrix.feed_url }}"', workflow)
        self.assertIn("--max-bytes 100000", workflow)
        self.assertIn("--token-env GITHUB_TOKEN", workflow)
        self.assertIn("GITHUB_TOKEN: ${{ github.token }}", workflow)

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
