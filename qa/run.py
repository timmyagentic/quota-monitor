#!/usr/bin/env python3
"""Run one isolated UI check; stop the owned app and remove its profile on exit."""

from __future__ import annotations

import argparse
import base64
from contextlib import closing, contextmanager
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import select
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
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
              "LaunchServices.framework/Support/lsregister")
RUN_PREFIX = "quotamonitor-qa-"
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
    preferences["settings.launchAtLoginEnabled"] = False
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
    validate_suite(suite)
    subprocess.run(["/usr/bin/defaults", "delete", suite],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False, timeout=10)
    # defaults delete can leave an empty plist behind in the user's Preferences.
    (Path.home() / "Library/Preferences" / f"{suite}.plist").unlink(missing_ok=True)


def validate_suite(suite: str) -> None:
    if not re.fullmatch(re.escape(INSTALLED_DOMAIN) + r"\.QA\.[0-9a-f]{32}", suite):
        raise ValueError("refusing to clean a non-owned QA preferences domain")


def remove_path(path: Path) -> None:
    # Never traverse a cache/profile symlink into another app's data.
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def darwin_directory(kind: str) -> Path:
    return Path(subprocess.check_output(["/usr/bin/getconf", f"DARWIN_USER_{kind}_DIR"],
                                        text=True, timeout=10).strip()).resolve()


def remove_system_residue(suite: str, app: Path, user_home: Path | None = None,
                          cache_root: Path | None = None,
                          temp_root: Path | None = None) -> None:
    validate_suite(suite)
    user_home = user_home or Path.home()
    cache_root = cache_root or darwin_directory("CACHE")
    temp_root = temp_root or darwin_directory("TEMP")
    # Unregister while the bundle still exists. Do not rebuild the global LS DB.
    subprocess.run([LSREGISTER, "-u", str(app)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    remove_preferences(suite)
    library = user_home / "Library"
    paths = [library / parent / suite for parent in
             ("Caches", "HTTPStorages", "WebKit", "Application Support")]
    paths += [library / "HTTPStorages" / f"{suite}.binarycookies",
              library / "Saved Application State" / f"{suite}.savedState",
              library / "Saved Application State" / suite]
    for root in (cache_root, temp_root):
        paths.append(root / suite)
        paths += [root / f"com.apple.WebKit.{kind}+{suite}"
                  for kind in ("GPU", "Networking", "WebContent")]
    for path in paths:
        remove_path(path)


@contextmanager
def cleanup_signals():
    # A second Ctrl-C/HUP must not interrupt the cleanup itself.
    previous = {s: signal.signal(s, signal.SIG_IGN)
                for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        yield
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def recover_abandoned_profiles(parent: Path | None = None) -> int:
    """Recover only our versioned, unlocked runs; never sweep by bundle prefix."""
    parent = parent or Path(tempfile.gettempdir()).resolve()
    cleaned = 0
    for root in parent.glob(f"{RUN_PREFIX}*"):
        try:
            token = root.name.removeprefix(RUN_PREFIX)
            if not re.fullmatch(r"[0-9a-f]{32}", token) or root.is_symlink():
                continue
            marker = root / "session.json"
            lock = root / "session.lock"
            if (not marker.is_file() or marker.is_symlink() or lock.is_symlink()
                    or root.stat().st_uid != os.getuid()):
                continue
            with lock.open("a") as handle:
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                metadata = json.loads(marker.read_text())
                suite = f"{INSTALLED_DOMAIN}.QA.{token}"
                if metadata != {"version": 1, "suite": suite}:
                    continue
                app = root / "QuotaMonitorQA.app"
                # If even the supervisor was forcibly killed, a surviving app
                # may still use this profile. Do not signal a stale/reused PID.
                executable = str(app / "Contents/MacOS/QuotaMonitor")
                commands = subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True, timeout=10)
                if executable in commands.splitlines():
                    print(f"QA app still running; quit it before cleanup: {app}", file=sys.stderr)
                    continue
                remove_system_residue(suite, app)
                remove_path(root)
                cleaned += 1
        except FileNotFoundError:
            # Another cleanup may have just finished this profile.
            continue
    return cleaned


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
    token = uuid.uuid4().hex
    root = Path(tempfile.gettempdir()).resolve() / f"{RUN_PREFIX}{token}"
    root.mkdir(mode=0o700)
    suite = f"{INSTALLED_DOMAIN}.QA.{token}"
    with (root / "session.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        (root / "session.json").write_text(json.dumps({"version": 1, "suite": suite}))
        process = None
        try:
            config, preferences = prepare_profile(root, data, view, language, Path.home())
            config["defaultsSuite"] = suite
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
            with cleanup_signals():
                stop_app(process)
                remove_system_residue(suite, root / "QuotaMonitorQA.app")
                remove_path(root)


def supervise(args) -> int:
    """Own the app even if the terminal/outer launcher dies (including SIGKILL)."""
    with launch(args.data, args.view, args.language) as process:
        deadline = time.monotonic() + args.seconds if args.seconds else float("inf")
        while process.poll() is None and time.monotonic() < deadline:
            readable, _, _ = select.select([sys.stdin], [], [], 0.2)
            if readable and not os.read(sys.stdin.fileno(), 1):
                break  # Parent exited: pipe EOF is a lifetime signal, not a PID.
        if process.poll() not in (None, 0):
            raise RuntimeError(f"QA app exited with status {process.returncode}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", choices=["fixture", "snapshot"], default="fixture",
                        help="synthetic data (default) or a read-only backup of the installed DB")
    parser.add_argument("--view", choices=VIEWS, default="dashboard")
    parser.add_argument("--language", choices=["en", "zh-Hans"])
    parser.add_argument("--no-build", action="store_true", help="reuse this worktree's latest build")
    parser.add_argument("--seconds", type=float, help="automatically stop after a bounded smoke run")
    parser.add_argument("--cleanup", action="store_true", help="clean abandoned QA profiles without launching")
    parser.add_argument("--supervise", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.seconds is not None and not (0 < args.seconds < float("inf")):
        parser.error("--seconds must be a positive finite number")

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, interrupted)
    try:
        if args.supervise:
            return supervise(args)
        recover_abandoned_profiles()
        if args.cleanup:
            return 0
        if not args.no_build:
            subprocess.run([str(REPO / "build.sh"), "debug"], cwd=REPO, check=True)
        command = [sys.executable, str(Path(__file__).resolve()), "--supervise",
                   "--data", args.data, "--view", args.view]
        if args.language:
            command += ["--language", args.language]
        if args.seconds is not None:
            command += ["--seconds", str(args.seconds)]
        supervisor = subprocess.Popen(command, stdin=subprocess.PIPE, start_new_session=True)
        try:
            return supervisor.wait()
        finally:
            with cleanup_signals():
                supervisor.stdin.close()
                supervisor.wait(timeout=45)
    except KeyboardInterrupt:
        return 130
    except (OSError, RuntimeError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
