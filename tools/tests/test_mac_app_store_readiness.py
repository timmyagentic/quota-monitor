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
        self.assertIs(
            entitlements["com.apple.security.files.user-selected.read-only"],
            True,
        )
        self.assertIs(
            entitlements["com.apple.security.files.bookmarks.app-scope"],
            True,
        )
        self.assertNotIn(
            "com.apple.security.files.user-selected.read-write",
            entitlements,
        )
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
        self.assertRegex(updater, r"distribution:\s*\.current")
        self.assertRegex(
            updater,
            r"let\s+isAppStore\s*=\s*distribution\s*==\s*\.appStore",
        )
        self.assertRegex(updater, r"persistenceEnabled:\s*!isAppStore")
        self.assertRegex(
            updater,
            r"sparkleEnabled:\s*!isAppStore\s*&&\s*!localQAActive",
        )
        self.assertRegex(
            updater,
            r"reminderPresentationEnabled:\s*!isAppStore\s*&&\s*!localQAActive",
        )
        self.assertIn("if DistributionChannel.current != .appStore", settings)

    def test_readiness_doc_records_submission_boundary_and_remaining_risks(self):
        doc = self.read_text("docs/mac-app-store-readiness.md")

        self.assertIn("QM_DISTRIBUTION=app-store CONFIG=release ./build.sh", doc)
        self.assertIn("codesign -dvvv --entitlements :- .build/QuotaMonitor.app", doc)
        self.assertIn("App Store Connect", doc)
        self.assertIn("not uploaded", doc)
        self.assertIn("security-scoped bookmarks", doc)
        self.assertIn("Sparkle", doc)

    def test_history_importers_do_not_use_network_clients(self):
        importer_sources = [
            "QuotaMonitor/Core/Importer/SessionScanner.swift",
            "QuotaMonitor/Core/Importer/ImportEngine.swift",
            "QuotaMonitor/Core/Importer/ClaudeImportEngine.swift",
            "QuotaMonitor/Core/Importer/RolloutParser.swift",
        ]
        forbidden_network_symbols = [
            "URLSession",
            "Network.framework",
            "NWConnection",
            "AppServerClient",
            "ClaudeUsageClient",
            "RateLimitPoller",
            "ClaudeUsagePoller",
        ]

        combined = "\n".join(self.read_text(path) for path in importer_sources)
        for symbol in forbidden_network_symbols:
            self.assertNotIn(symbol, combined)

    def test_database_default_stays_in_application_support_container(self):
        storage = self.read_text("QuotaMonitor/Core/Storage/DatabaseManager.swift")

        self.assertIn("applicationSupportDirectory", storage)
        self.assertIn("QuotaMonitor", storage)
        self.assertIn("quotamonitor.sqlite", storage)
        self.assertNotIn(".codex", storage)
        self.assertNotIn(".claude", storage)


if __name__ == "__main__":
    unittest.main()
