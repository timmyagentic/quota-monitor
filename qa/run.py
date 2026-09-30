#!/usr/bin/env python3
"""Run one isolated UI check; stop the owned app and remove its profile on exit."""

from __future__ import annotations

import argparse
import base64
from contextlib import closing, contextmanager
import json
from pathlib import Path
import plistlib
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid


REPO = Path(__file__).resolve().parents[1]
INSTALLED_DOMAIN = "dev.tjzhou.QuotaMonitor"
DATABASE = Path("Library/Application Support/QuotaMonitor/quotamonitor.sqlite")
VIEWS = {
    "dashboard": "open-dashboard",
    "settings": "open-settings",
    "popover": "show-popover",
    "widget": "show-codex-overlay-details",
    "permissions": "show-codex-accessibility-guide",
    "whats-new": "open-whats-new",
}


def copy_database(source: Path, destination: Path) -> None:
    """SQLite backup includes committed WAL data without opening the source writable."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True)) as src:
        with closing(sqlite3.connect(destination)) as dst:
            src.backup(dst)


def seed_fixtures(home: Path) -> None:
    fixtures = REPO / "qa/fixtures"
    codex = home / ".codex/sessions/qa"
    claude = home / ".claude/projects/qa"
    codex.mkdir(parents=True)
    claude.mkdir(parents=True)
    for name, filename in [
        ("qa-codex-session.jsonl", "rollout-2026-06-01T00-00-00-019aa0fd-1111-7000-8000-aaaaaaaaaaaa.jsonl"),
        ("qa-codex-project-only.jsonl", "rollout-2026-06-01T00-03-00-019aa0fd-2222-7000-8000-bbbbbbbbbbbb.jsonl"),
    ]:
        shutil.copyfile(fixtures / name, codex / filename)
    for name in ("qa-claude-session.jsonl", "qa-claude-project-only.jsonl"):
        shutil.copyfile(fixtures / name, claude / name)


def prepare_profile(root: Path, data: str, view: str, language: str | None,
                    source_home: Path) -> tuple[dict, dict]:
    home = root / "home"
    home.mkdir()
    output = home / "QA"
    output.mkdir()
    preferences = {
        "app.language": "en",
        "onboarding.providersDone": True,
        "onboarding.lastVersion": (REPO / "Resources/VERSION").read_text().strip(),
        "discoverability.firstRunPresentationShown": True,
        "settings.enabledProviders": ["codex", "claude"],
        "settings.menuBarIconProviders": ["codex", "claude"],
        "settings.showDockIconForWindows": True,
    }
    if data == "snapshot":
        copy_database(source_home / DATABASE, home / DATABASE)
        source = source_home / "Library/Preferences" / f"{INSTALLED_DOMAIN}.plist"
        with source.open("rb") as handle:
            saved = plistlib.load(handle)
        # Copy product settings, never Keychain data, tokens, or provider home dirs.
        preferences.update({k: v for k, v in saved.items()
                            if k.startswith("settings.") or k == "app.language"})
    else:
        seed_fixtures(home)
    # Widget QA steps opt in after startup; never attach to a real Codex window
    # while an unrelated view or a copied profile is being initialized.
    preferences["settings.codexSidebarQuotaEnabled"] = False
    if language:
        preferences["app.language"] = language
    steps = []
    if data == "fixture" and view in {"dashboard", "popover"}:
        steps = ["seed-quota-cycles", "refresh-all"]
    steps += [VIEWS[view], "snapshot"]
    config = {
        "mode": True,
        "home": str(home),
        "defaultsSuite": f"{INSTALLED_DOMAIN}.QA.{uuid.uuid4().hex}",
        "codexHome": str(home / ".codex"),
        "outputDirectory": str(output),
        "steps": steps,
        "mockCodexResetCredits": data == "fixture",
    }
    return config, preferences


def prepare_app(source: Path, root: Path, suite: str) -> Path:
    app = root / "QuotaMonitorQA.app"
    subprocess.run(["/usr/bin/ditto", str(source), str(app)], check=True)
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    info.update(CFBundleIdentifier=suite, CFBundleName="QuotaMonitor QA",
                CFBundleDisplayName="QuotaMonitor QA")
    info.pop("CFBundleURLTypes", None)
    with info_path.open("wb") as handle:
        plistlib.dump(info, handle)
    subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)],
                   check=True)
    return app


def stop_app(process: subprocess.Popen | None) -> None:
    # A retained child handle identifies this run. Never kill by name/bundle ID.
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def remove_preferences(suite: str) -> None:
    if not suite.startswith(f"{INSTALLED_DOMAIN}.QA."):
        raise ValueError("refusing to remove a non-QA preferences domain")
    subprocess.run(["/usr/bin/defaults", "delete", suite],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    # defaults delete can leave an empty plist behind in the user's Preferences.
    (Path.home() / "Library/Preferences" / f"{suite}.plist").unlink(missing_ok=True)


def wait_until_ready(process: subprocess.Popen, config: dict, timeout: float = 30) -> dict:
    state_path = Path(config["outputDirectory"]) / "app-state.json"
    deadline = time.monotonic() + timeout
    while process.poll() is None and time.monotonic() < deadline:
        if state_path.exists():
            state = json.loads(state_path.read_text())
            if (state["pid"] != process.pid
                    or state["bundleIdentifier"] != config["defaultsSuite"]
                    or Path(state["databasePath"]).resolve()
                    != (Path(config["home"]) / DATABASE).resolve()):
                raise RuntimeError("QA app identity or database isolation mismatch")
            return state
        time.sleep(0.1)
    raise RuntimeError("QA app exited or did not become ready within 30 seconds")


@contextmanager
def launch(data: str, view: str, language: str | None):
    with tempfile.TemporaryDirectory(prefix="quotamonitor-qa-") as directory:
        root = Path(directory).resolve()
        config = None
        process = None
        try:
            config, preferences = prepare_profile(root, data, view, language, Path.home())
            suite = config["defaultsSuite"]
            app = prepare_app(REPO / ".build/QuotaMonitor.app", root, suite)
            defaults_file = root / "preferences.plist"
            with defaults_file.open("wb") as handle:
                plistlib.dump(preferences, handle)
            subprocess.run(["/usr/bin/defaults", "import", suite, str(defaults_file)], check=True)
            payload = base64.b64encode(json.dumps(config).encode()).decode()
            with (root / "app.log").open("w") as log:
                process = subprocess.Popen(
                    [str(app / "Contents/MacOS/QuotaMonitor"),
                     "--quotamonitor-qa-config-base64", payload],
                    stdout=log, stderr=log, start_new_session=True)
                wait_until_ready(process, config)
                print(f"QA app: {app}\nView: {view}; data: {data}; PID: {process.pid}", flush=True)
                print(f"State: {config['outputDirectory']}/app-state.json", flush=True)
                print("Inspect only the affected behavior. Quit the QA app or press Ctrl-C to clean up.",
                      flush=True)
                yield process
        finally:
            stop_app(process)
            if config is not None:
                remove_preferences(config["defaultsSuite"])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", choices=["fixture", "snapshot"], default="fixture",
                        help="synthetic data (default) or a read-only backup of the installed DB")
    parser.add_argument("--view", choices=VIEWS, default="dashboard")
    parser.add_argument("--language", choices=["en", "zh-Hans"])
    parser.add_argument("--no-build", action="store_true", help="reuse this worktree's latest build")
    parser.add_argument("--seconds", type=float, help="automatically stop after a bounded smoke run")
    args = parser.parse_args(argv)
    if args.seconds is not None and not (0 < args.seconds < float("inf")):
        parser.error("--seconds must be a positive finite number")

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        if not args.no_build:
            subprocess.run([str(REPO / "build.sh"), "debug"], cwd=REPO, check=True)
        with launch(args.data, args.view, args.language) as process:
            deadline = time.monotonic() + args.seconds if args.seconds else float("inf")
            while process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.2)
            if process.poll() not in (None, 0):
                raise RuntimeError(f"QA app exited with status {process.returncode}")
    except KeyboardInterrupt:
        return 130
    except (OSError, RuntimeError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
