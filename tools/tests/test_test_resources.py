import fcntl
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("test_cleanup", REPO / "qa/cleanup-tests.py")
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class TestResourceCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.root = self.parent / (cleanup.PREFIX + str(uuid.uuid4()))
        self.root.mkdir()
        (self.root / "lock").touch()
        (self.root / "preferences.json").write_text("[]")

    def test_ignores_production_domains_malformed_journals_and_symlinks(self):
        for data in ['["dev.tjzhou.QuotaMonitor"]', '{bad', '["../' + str(uuid.uuid4()) + '"]']:
            (self.root / "preferences.json").write_text(data)
            with patch.object(cleanup.subprocess, "run") as command:
                self.assertFalse(cleanup.cleanup(self.root))
                command.assert_not_called()
            self.assertTrue(self.root.exists())
        link = self.parent / (cleanup.PREFIX + str(uuid.uuid4()))
        link.symlink_to(self.root, target_is_directory=True)
        self.assertFalse(cleanup.cleanup(link))
        self.assertTrue(self.root.exists())

    def test_active_test_scope_is_preserved(self):
        with (self.root / "lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertFalse(cleanup.cleanup(self.root))
        self.assertTrue(cleanup.cleanup(self.root))
        self.assertFalse(self.root.exists())

    def test_removes_only_journaled_preferences_after_defaults_process_returns(self):
        suite = "TestResource." + str(uuid.uuid4())
        preferences = self.parent / "Library/Preferences"
        preferences.mkdir(parents=True)
        owned = preferences / f"{suite}.plist"
        formal = preferences / "dev.tjzhou.QuotaMonitor.plist"
        owned.write_text("before cleanup")
        formal.write_text("keep")
        (self.root / "preferences.json").write_text(json.dumps([suite]))
        def flush(*args, **kwargs):
            owned.write_text("late empty plist from defaults finalizer")
        with patch.object(cleanup.Path, "home", return_value=self.parent), \
             patch.object(cleanup.subprocess, "run", side_effect=flush):
            self.assertTrue(cleanup.cleanup(self.root))
        self.assertFalse(owned.exists())
        self.assertEqual(formal.read_text(), "keep")

    def test_watcher_waits_for_pipe_eof_and_owner_lock(self):
        with (self.root / "lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            watcher = subprocess.Popen([sys.executable, str(REPO / "qa/cleanup-tests.py"),
                                        "--root", str(self.root), "--watch"], stdin=subprocess.PIPE)
            try:
                watcher.stdin.close()
                with self.assertRaises(subprocess.TimeoutExpired):
                    watcher.wait(timeout=0.1)
                self.assertTrue(self.root.exists())
                fcntl.flock(lock, fcntl.LOCK_UN)
                self.assertEqual(watcher.wait(timeout=5), 0)
                self.assertFalse(self.root.exists())
            finally:
                if watcher.poll() is None:
                    watcher.kill()
                    watcher.wait()


if __name__ == "__main__":
    unittest.main()
