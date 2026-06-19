#!/usr/bin/env python3
import pathlib
import plistlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class MacAppStoreReadinessTests(unittest.TestCase):
    def read_text(self, relative_path: str) -> str:
        return (REPO_ROOT / relative_path).read_text(encoding="utf-8")

    def read_plist(self, relative_path: str) -> dict:
        with (REPO_ROOT / relative_path).open("rb") as plist_file:
            return plistlib.load(plist_file)

    def test_app_store_entitlements_enable_sandbox_without_developer_id_exceptions(self):
        entitlements = self.read_plist("Resources/QuotaMonitor-AppStore.entitlements")

        self.assertIs(entitlements["com.apple.security.app-sandbox"], True)
        self.assertIs(entitlements["com.apple.security.network.client"], True)
        self.assertNotIn(
            "com.apple.security.cs.allow-dyld-environment-variables",
            entitlements,
        )
        self.assertFalse(
            any(key.startswith("com.apple.security.temporary-exception")
                for key in entitlements),
            entitlements,
        )

    def test_build_script_has_repeatable_app_store_smoke_path(self):
        build = self.read_text("build.sh")

        self.assertIn("QM_DISTRIBUTION", build)
        self.assertIn("app-store", build)
        self.assertIn("Resources/QuotaMonitor-AppStore.entitlements", build)
        self.assertIn("QMDistributionChannel", build)
        self.assertIn("Delete :SUFeedURL", build)
        self.assertIn("Delete :SUPublicEDKey", build)
        self.assertIn("Delete :SUEnableAutomaticChecks", build)
        self.assertIn("--entitlements", build)

    def test_runtime_has_distribution_channel_and_disables_sparkle_for_app_store(self):
        channel = self.read_text("QuotaMonitor/Core/DistributionChannel.swift")
        updater = self.read_text("QuotaMonitor/Core/Updater/UpdaterController.swift")
        settings = self.read_text("QuotaMonitor/Features/Settings/AdvancedSettingsTab.swift")

        self.assertIn("QMDistributionChannel", channel)
        self.assertIn("app-store", channel)
        self.assertIn("DistributionChannel.current == .appStore", updater)
        self.assertIn("Sparkle disabled for App Store build", updater)
        self.assertIn("if DistributionChannel.current != .appStore", settings)

    def test_readiness_doc_records_submission_boundary_and_remaining_risks(self):
        doc = self.read_text("docs/mac-app-store-readiness.md")

        self.assertIn("QM_DISTRIBUTION=app-store CONFIG=release ./build.sh", doc)
        self.assertIn("codesign -dvvv --entitlements :- .build/QuotaMonitor.app", doc)
        self.assertIn("App Store Connect", doc)
        self.assertIn("not uploaded", doc)
        self.assertIn("security-scoped bookmarks", doc)
        self.assertIn("Sparkle", doc)


if __name__ == "__main__":
    unittest.main()
