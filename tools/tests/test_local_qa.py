from contextlib import closing
import importlib.util
import json
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("local_qa", REPO / "qa/run.py")
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


class LocalQATests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_backup_includes_committed_wal_and_never_modifies_source(self):
        source = self.root / "source.sqlite"
        live = sqlite3.connect(source)
        self.addCleanup(live.close)
        live.execute("PRAGMA journal_mode=WAL")
        live.execute("CREATE TABLE samples(value INTEGER)")
        live.execute("INSERT INTO samples VALUES (42)")
        live.commit()
        before = {p.name: p.read_bytes() for p in [source, source.with_name("source.sqlite-wal")]}
        destination = self.root / "shadow/db.sqlite"
        qa.copy_database(source, destination)
        with closing(sqlite3.connect(destination)) as copy:
            self.assertEqual(copy.execute("SELECT value FROM samples").fetchone(), (42,))
            copy.execute("DELETE FROM samples")
            copy.commit()
        self.assertEqual(live.execute("SELECT value FROM samples").fetchone(), (42,))
        self.assertEqual({p.name: p.read_bytes() for p in [source, source.with_name("source.sqlite-wal")]}, before)

    def test_missing_snapshot_does_not_create_source_database(self):
        source = self.root / "missing.sqlite"
        with self.assertRaises(sqlite3.OperationalError):
            qa.copy_database(source, self.root / "shadow.sqlite")
        self.assertFalse(source.exists())

    def test_fixture_opens_only_requested_view_and_uses_an_isolated_profile(self):
        config, preferences = qa.prepare_profile(self.root, "fixture", "settings", "zh-Hans",
                                                 self.root / "nonexistent-user")
        self.assertEqual(config["steps"], ["open-settings", "snapshot"])
        self.assertEqual(preferences["app.language"], "zh-Hans")
        self.assertEqual(config["home"], str(self.root / "home"))
        self.assertEqual(config["codexHome"], str(self.root / "home/.codex"))
        self.assertNotEqual(config["defaultsSuite"], qa.INSTALLED_DOMAIN)
        self.assertTrue(list((self.root / "home/.codex/sessions").rglob("*.jsonl")))
        self.assertTrue(list((self.root / "home/.claude/projects").rglob("*.jsonl")))
        self.assertNotIn("settings.pollIntervalSeconds", preferences)

    def test_every_fixture_starts_with_external_widget_tracking_disabled(self):
        for view in qa.VIEWS:
            with self.subTest(view=view):
                run = self.root / view
                run.mkdir()
                _, preferences = qa.prepare_profile(run, "fixture", view, None, self.root)
                self.assertFalse(preferences.get("settings.codexSidebarQuotaEnabled", True))

    def test_snapshot_widget_preference_cannot_enable_external_tracking_at_startup(self):
        source = self.root / "source"
        db = source / qa.DATABASE
        db.parent.mkdir(parents=True)
        with closing(sqlite3.connect(db)) as connection:
            connection.execute("CREATE TABLE samples(value INTEGER)")
        prefs = source / "Library/Preferences" / f"{qa.INSTALLED_DOMAIN}.plist"
        prefs.parent.mkdir(parents=True)
        for enabled in (True, False):
            saved = plistlib.dumps({"settings.codexSidebarQuotaEnabled": enabled})
            prefs.write_bytes(saved)
            for view in qa.VIEWS:
                with self.subTest(enabled=enabled, view=view):
                    run = self.root / f"{view}-{enabled}"
                    run.mkdir()
                    _, preferences = qa.prepare_profile(run, "snapshot", view, None, source)
                    self.assertFalse(preferences.get("settings.codexSidebarQuotaEnabled", True))
                    self.assertEqual(prefs.read_bytes(), saved)

    def test_snapshot_preserves_settings_without_copying_credentials_or_provider_files(self):
        source = self.root / "source"
        db = source / qa.DATABASE
        db.parent.mkdir(parents=True)
        with closing(sqlite3.connect(db)) as connection:
            connection.execute("CREATE TABLE samples(value INTEGER)")
        prefs = source / "Library/Preferences" / f"{qa.INSTALLED_DOMAIN}.plist"
        prefs.parent.mkdir(parents=True)
        prefs.write_bytes(plistlib.dumps({"app.language": "zh-Hans", "settings.pollIntervalSeconds": 600,
                                          "unrelatedCredential": "do-not-copy"}))
        (source / ".codex").mkdir()
        (source / ".codex/auth.json").write_text("do-not-copy")
        run = self.root / "run"
        run.mkdir()
        config, preferences = qa.prepare_profile(run, "snapshot", "dashboard", None, source)
        self.assertEqual(config["steps"], ["open-dashboard", "snapshot"])
        self.assertFalse(config["mockCodexResetCredits"])
        self.assertEqual(preferences["settings.pollIntervalSeconds"], 600)
        self.assertEqual(preferences["app.language"], "zh-Hans")
        self.assertNotIn("unrelatedCredential", preferences)
        self.assertFalse((run / "home/.codex/auth.json").exists())

    def test_cleanup_refuses_the_installed_preferences_domain(self):
        with patch.object(qa.subprocess, "run") as command:
            with self.assertRaises(ValueError):
                qa.remove_preferences(qa.INSTALLED_DOMAIN)
            command.assert_not_called()

    def test_stop_owns_only_the_child_and_does_not_signal_an_exited_process(self):
        child = Mock()
        child.poll.return_value = 0
        qa.stop_app(child)
        child.terminate.assert_not_called()
        child.poll.return_value = None
        qa.stop_app(child)
        child.terminate.assert_called_once()
        child.wait.assert_called_once_with(timeout=5)
        child.kill.assert_not_called()

    def test_unresponsive_owned_child_is_reaped(self):
        child = Mock()
        child.poll.return_value = None
        child.wait.side_effect = [subprocess.TimeoutExpired("QA", 5), 0]
        qa.stop_app(child)
        child.kill.assert_called_once()
        self.assertEqual(child.wait.call_count, 2)

    def test_readiness_rejects_an_app_using_the_formal_database(self):
        process = Mock(pid=123)
        process.poll.return_value = None
        config = {"outputDirectory": str(self.root), "home": str(self.root / "home"),
                  "defaultsSuite": "dev.tjzhou.QuotaMonitor.QA.test"}
        state = {"pid": 123, "bundleIdentifier": config["defaultsSuite"],
                 "databasePath": str(Path.home() / qa.DATABASE)}
        (self.root / "app-state.json").write_text(json.dumps(state))
        with self.assertRaisesRegex(RuntimeError, "isolation mismatch"):
            qa.wait_until_ready(process, config)

    def test_profile_and_owned_process_are_cleaned_after_launch_failure_or_interruption(self):
        for failure in [RuntimeError("launch failed"), KeyboardInterrupt()]:
            with self.subTest(failure=type(failure).__name__):
                process = Mock()
                process.poll.return_value = None
                profiles = []
                original = qa.prepare_profile

                def prepare(root, *args):
                    profiles.append(root)
                    return original(root, *args)

                with patch.object(qa, "prepare_profile", side_effect=prepare), \
                     patch.object(qa, "prepare_app", return_value=self.root / "QA.app"), \
                     patch.object(qa.subprocess, "run"), \
                     patch.object(qa.subprocess, "Popen", return_value=process), \
                     patch.object(qa, "wait_until_ready", side_effect=failure), \
                     patch.object(qa, "remove_preferences") as remove:
                    with self.assertRaises(type(failure)):
                        with qa.launch("fixture", "widget", None):
                            self.fail("failed launch must not be yielded")
                process.terminate.assert_called_once()
                remove.assert_called_once()
                self.assertFalse(profiles[0].exists())

    def test_normal_run_removes_only_its_own_profile(self):
        sentinel = self.root / "formal.sqlite"
        sentinel.write_text("keep")
        process = Mock(pid=123)
        process.poll.return_value = None
        profiles = []
        original = qa.prepare_profile

        def prepare(root, *args):
            profiles.append(root)
            return original(root, *args)

        with patch.object(qa, "prepare_profile", side_effect=prepare), \
             patch.object(qa, "prepare_app", return_value=self.root / "QA.app"), \
             patch.object(qa.subprocess, "run"), \
             patch.object(qa.subprocess, "Popen", return_value=process), \
             patch.object(qa, "wait_until_ready"), \
             patch.object(qa, "remove_preferences") as remove, patch("builtins.print"):
            with qa.launch("fixture", "widget", None) as running:
                self.assertIs(running, process)
        process.terminate.assert_called_once()
        remove.assert_called_once()
        self.assertFalse(profiles[0].exists())
        self.assertEqual(sentinel.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
