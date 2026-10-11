from contextlib import closing
import importlib.util
import fcntl
import os
import signal
import sys
import time
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

    def test_cleanup_removes_owned_system_residue_but_preserves_formal_and_siblings(self):
        suite = f"{qa.INSTALLED_DOMAIN}.QA." + "a" * 32
        sibling = f"{qa.INSTALLED_DOMAIN}.QA." + "b" * 32
        cache = self.root / "darwin-cache"
        user = self.root / "user"
        expected = []
        for parent in [user / "Library/Caches", user / "Library/HTTPStorages",
                       user / "Library/WebKit", user / "Library/Saved Application State",
                       cache]:
            for name in [suite, sibling, qa.INSTALLED_DOMAIN]:
                path = parent / name
                path.mkdir(parents=True)
                (path / "data").write_text("keep unless owned")
                if name == suite:
                    expected.append(path)
        cookies = user / "Library/HTTPStorages" / f"{suite}.binarycookies"
        cookies.write_text("cookies")
        expected.append(cookies)
        with patch.object(qa, "remove_preferences"), patch.object(qa.subprocess, "run"):
            qa.remove_system_residue(suite, self.root / "QuotaMonitorQA.app", user, cache, self.root / "tmp")
        self.assertTrue(all(not p.exists() for p in expected))
        self.assertTrue((cache / sibling / "data").exists())
        self.assertTrue((user / "Library/Caches" / qa.INSTALLED_DOMAIN / "data").exists())

    def test_cleanup_rejects_path_traversal_before_running_commands(self):
        with patch.object(qa.subprocess, "run") as command:
            for suite in [qa.INSTALLED_DOMAIN, f"{qa.INSTALLED_DOMAIN}.QA.../../victim"]:
                with self.assertRaises(ValueError):
                    qa.remove_system_residue(suite, self.root / "QuotaMonitorQA.app",
                                             self.root, self.root, self.root)
            command.assert_not_called()

    def test_cleanup_unlinks_residue_symlink_without_following_it(self):
        suite = f"{qa.INSTALLED_DOMAIN}.QA." + "a" * 32
        cache = self.root / "cache"
        cache.mkdir()
        victim = self.root / "formal-data"
        victim.mkdir()
        (victim / "keep").write_text("real")
        (cache / suite).symlink_to(victim, target_is_directory=True)
        with patch.object(qa, "remove_preferences"), patch.object(qa.subprocess, "run"):
            qa.remove_system_residue(suite, self.root / "QuotaMonitorQA.app", self.root, cache, self.root / "tmp")
        self.assertEqual((victim / "keep").read_text(), "real")
        self.assertFalse((cache / suite).is_symlink())

    def test_recovery_cleans_only_unlocked_versioned_owned_profiles(self):
        abandoned = self.root / (qa.RUN_PREFIX + "a" * 32)
        active = self.root / (qa.RUN_PREFIX + "b" * 32)
        invalid = self.root / (qa.RUN_PREFIX + "c" * 32)
        for root in [abandoned, active, invalid]:
            root.mkdir()
            suite = f"{qa.INSTALLED_DOMAIN}.QA.{root.name.removeprefix(qa.RUN_PREFIX)}"
            (root / "session.json").write_text(json.dumps({"version": 1, "suite": suite}))
        (invalid / "session.json").write_text(json.dumps({"version": 1, "suite": qa.INSTALLED_DOMAIN}))
        with (active / "session.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with patch.object(qa.subprocess, "check_output", return_value=""), \
                 patch.object(qa, "remove_system_residue") as clean:
                self.assertEqual(qa.recover_abandoned_profiles(self.root), 1)
                clean.assert_called_once()
        self.assertFalse(abandoned.exists())
        self.assertTrue(active.exists())
        self.assertTrue(invalid.exists())

    def test_recovery_does_not_remove_a_surviving_apps_profile(self):
        root = self.root / (qa.RUN_PREFIX + "a" * 32)
        root.mkdir()
        suite = f"{qa.INSTALLED_DOMAIN}.QA." + "a" * 32
        (root / "session.json").write_text(json.dumps({"version": 1, "suite": suite}))
        executable = root / "QuotaMonitorQA.app/Contents/MacOS/QuotaMonitor"
        with patch.object(qa.subprocess, "check_output", return_value=str(executable) + "\n"), \
             patch.object(qa, "remove_system_residue") as clean:
            self.assertEqual(qa.recover_abandoned_profiles(self.root), 0)
            clean.assert_not_called()
        self.assertTrue(root.exists())

    def test_failed_system_cleanup_keeps_manifest_for_retry(self):
        profiles = []
        original = qa.prepare_profile
        def prepare(root, *args):
            profiles.append(root)
            return original(root, *args)
        with patch.object(qa, "prepare_profile", side_effect=prepare), \
             patch.object(qa, "prepare_app", side_effect=RuntimeError("build failed")), \
             patch.object(qa, "remove_system_residue", side_effect=OSError("cleanup failed")):
            with self.assertRaisesRegex(OSError, "cleanup failed"):
                with qa.launch("fixture", "settings", None):
                    pass
        self.assertTrue((profiles[0] / "session.json").exists())
        qa.remove_path(profiles[0])

    def test_supervisor_cleans_owned_child_when_outer_launcher_is_killed(self):
        script = self.root / "supervisor_fixture.py"
        marker = self.root / "live"
        done = self.root / "cleaned"
        script.write_text(f"""
import importlib.util, subprocess, sys, time
from pathlib import Path
from contextlib import contextmanager
spec = importlib.util.spec_from_file_location('qa', {str(REPO / 'qa/run.py')!r})
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)
qa.__file__ = __file__
qa.recover_abandoned_profiles = lambda: 0
@contextmanager
def fake_launch(*args):
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
    Path({str(marker)!r}).write_text(str(child.pid))
    try:
        yield child
    finally:
        qa.stop_app(child)
        Path({str(marker)!r}).unlink()
        Path({str(done)!r}).write_text('cleaned')
qa.launch = fake_launch
raise SystemExit(qa.main())
""")
        outer = subprocess.Popen([sys.executable, str(script), "--no-build"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 10
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(marker.exists())
            child_pid = int(marker.read_text())
            outer.kill()
            outer.wait(timeout=5)
            while not done.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(done.exists())
            self.assertFalse(marker.exists())
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            if outer.poll() is None:
                outer.terminate()
                outer.wait(timeout=10)

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
                     patch.object(qa, "remove_system_residue") as remove:
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
             patch.object(qa, "remove_system_residue") as remove, patch("builtins.print"):
            with qa.launch("fixture", "widget", None) as running:
                self.assertIs(running, process)
        process.terminate.assert_called_once()
        remove.assert_called_once()
        self.assertFalse(profiles[0].exists())
        self.assertEqual(sentinel.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
