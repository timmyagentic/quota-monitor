#!/usr/bin/env python3
"""Package and publish a Private Beta without touching GitHub Releases.

Immutable artifacts, checksums, and notes are uploaded first. The mutable
appcast is uploaded only after every referenced object succeeds.
"""

from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import html
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PUBLICATION_LEASE_LIFETIME_SECONDS = 30 * 60
COMMAND_TIMEOUT_SECONDS = 10 * 60
SIGNATURE_PATTERN = re.compile(
    r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"'
)


def run(command: list[str], *, env: dict[str, str] | None = None) -> str:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        timeout=COMMAND_TIMEOUT_SECONDS,
    )
    return completed.stdout


def build_number(version: str, sequence: int) -> int:
    output = run([
        sys.executable,
        "tools/build-number.py",
        version,
        "--channel",
        "private-beta",
        "--beta-sequence",
        str(sequence),
    ])
    return int(output.strip())


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sparkle_signature(path: Path, account: str) -> tuple[str, int]:
    executable = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
    if not executable.is_file():
        raise RuntimeError(f"{executable} is missing; run swift package resolve")
    output = run([str(executable), "--account", account, str(path)])
    match = SIGNATURE_PATTERN.search(output)
    if match is None:
        raise RuntimeError("sign_update returned an unrecognized signature")
    return match.group(1), int(match.group(2))


def appcast_xml(
    *,
    version: str,
    build: int,
    signature: str,
    length: int,
    base_url: str,
    artifact_name: str,
    minimum_system_version: str,
) -> str:
    escaped_base = html.escape(base_url.rstrip("/"), quote=True)
    escaped_name = html.escape(artifact_name, quote=True)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>QuotaMonitor Private Beta</title>
    <item>
      <title>QuotaMonitor {html.escape(version)}</title>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:channel>private-beta</sparkle:channel>
      <sparkle:minimumSystemVersion>{html.escape(minimum_system_version)}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink xml:lang="en">{escaped_base}/notes/{html.escape(version)}.en.html</sparkle:releaseNotesLink>
      <sparkle:releaseNotesLink xml:lang="zh-Hans">{escaped_base}/notes/{html.escape(version)}.zh-Hans.html</sparkle:releaseNotesLink>
      <enclosure
        url="{escaped_base}/artifacts/{escaped_name}"
        type="application/octet-stream"
        sparkle:edSignature="{html.escape(signature, quote=True)}"
        length="{length}" />
    </item>
  </channel>
</rss>
"""


def wrangler_command(*arguments: str) -> list[str]:
    return [
        "npx",
        "--prefix",
        "website",
        "wrangler",
        *arguments,
    ]


def assert_remote_object_absent(bucket: str, key: str) -> None:
    with tempfile.TemporaryDirectory(prefix="qm-private-beta-check-") as directory:
        destination = Path(directory) / "existing-object"
        result = subprocess.run(
            wrangler_command(
                "r2", "object", "get", f"{bucket}/{key}",
                "--remote", "--file", str(destination),
            ),
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
        if result.returncode == 0:
            raise RuntimeError(f"immutable R2 object already exists: {key}")


def upload(bucket: str, key: str, path: Path, content_type: str) -> None:
    run(wrangler_command(
        "r2", "object", "put", f"{bucket}/{key}",
        "--remote", "--file", str(path), "--content-type", content_type,
        "--cache-control", "private, no-store",
    ))


class RefuseRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        request,
        file_pointer,
        code,
        message,
        headers,
        new_url,
    ):
        return None


def admin_opener() -> urllib.request.OpenerDirector:
    return urllib.request.build_opener(RefuseRedirects())


def validate_worker_base_url(value: str) -> str:
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError as error:
        raise RuntimeError("worker base URL is invalid") from error
    if (
        parsed.scheme != "https"
        or parsed.hostname is None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise RuntimeError(
            "worker base URL must be HTTPS and contain no credentials, query, or fragment"
        )
    return urllib.parse.urlunsplit((
        parsed.scheme,
        parsed.netloc,
        parsed.path.rstrip("/"),
        "",
        "",
    ))


def admin_post(
    base_url: str,
    action: str,
    publication_id: str,
    admin_token: str,
) -> dict[str, object]:
    body = json.dumps({"publicationID": publication_id}).encode()
    credentials = base64.b64encode(f"admin:{admin_token}".encode()).decode()
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/admin/publication-lock/{action}",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Basic {credentials}",
            "Content-Type": "application/json",
            "Content-Length": str(len(body)),
        },
    )
    with admin_opener().open(request, timeout=30) as response:
        payload = json.loads(response.read())
    if not isinstance(payload, dict):
        raise RuntimeError("publication lock returned an invalid response")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--beta-sequence", type=int, required=True)
    parser.add_argument("--bucket", default="quota-monitor-private-beta")
    parser.add_argument(
        "--worker-base-url",
        default="https://quota-monitor.timmyagentic.com/api/private-beta",
    )
    parser.add_argument("--sparkle-account", default="quotamonitor")
    parser.add_argument("--minimum-system-version", default="14.0")
    parser.add_argument("--skip-package", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    args.worker_base_url = validate_worker_base_url(args.worker_base_url)

    version = (ROOT / "Resources/VERSION").read_text().strip()
    display_version = f"{version}-beta.{args.beta_sequence}"
    build = build_number(version, args.beta_sequence)
    artifact_name = f"QuotaMonitor-{display_version}.dmg"
    artifact = ROOT / "dist" / artifact_name
    checksum = artifact.with_suffix(".dmg.sha256")
    notes = {
        "en": ROOT / "ReleaseNotes" / f"{version}.en.html",
        "zh-Hans": ROOT / "ReleaseNotes" / f"{version}.zh-Hans.html",
    }

    plan = {
        "version": display_version,
        "build": build,
        "artifact": str(artifact.relative_to(ROOT)),
        "uploads": [
            f"private-beta/artifacts/{artifact_name}",
            f"private-beta/artifacts/{artifact_name}.sha256",
            f"private-beta/notes/{display_version}.en.html",
            f"private-beta/notes/{display_version}.zh-Hans.html",
            "private-beta/appcast.xml",
        ],
        "githubRelease": False,
        "publicAppcast": False,
        "atomicPublicationLock": True,
    }
    if args.dry_run:
        print(json.dumps(plan, indent=2))
        return 0

    if not args.skip_package:
        environment = os.environ.copy()
        environment.update({
            "QM_RELEASE_CHANNEL": "private-beta",
            "QM_BETA_SEQUENCE": str(args.beta_sequence),
            "QM_RELEASE_SIGNING": "developer-id",
        })
        run(["tools/release.sh", "--force"], env=environment)

    if not artifact.is_file():
        raise RuntimeError(f"missing packaged artifact: {artifact}")
    for language, path in notes.items():
        if not path.is_file():
            raise RuntimeError(f"missing {language} release notes: {path}")

    signature, signed_length = sparkle_signature(artifact, args.sparkle_account)
    if signed_length != artifact.stat().st_size:
        raise RuntimeError("Sparkle signature length does not match the DMG")
    checksum.write_text(f"{file_sha256(artifact)}  {artifact.name}\n")

    appcast = ROOT / ".build" / "private-beta" / f"appcast-{display_version}.xml"
    appcast.parent.mkdir(parents=True, exist_ok=True)
    appcast.write_text(appcast_xml(
        version=display_version,
        build=build,
        signature=signature,
        length=signed_length,
        base_url=args.worker_base_url,
        artifact_name=artifact.name,
        minimum_system_version=args.minimum_system_version,
    ))

    immutable = [
        (f"private-beta/artifacts/{artifact.name}", artifact,
         "application/x-apple-diskimage"),
        (f"private-beta/artifacts/{artifact.name}.sha256", checksum,
         "text/plain; charset=utf-8"),
        (f"private-beta/notes/{display_version}.en.html", notes["en"],
         "text/html; charset=utf-8"),
        (f"private-beta/notes/{display_version}.zh-Hans.html", notes["zh-Hans"],
         "text/html; charset=utf-8"),
    ]
    admin_token = os.environ.get("PRIVATE_BETA_ADMIN_TOKEN")
    if admin_token is None:
        admin_token = getpass.getpass("Private Beta admin token: ")
    if len(admin_token) < 32:
        raise RuntimeError("PRIVATE_BETA_ADMIN_TOKEN must be at least 32 characters")
    publication_id = secrets.token_urlsafe(32)
    acquired = admin_post(
        args.worker_base_url,
        "acquire",
        publication_id,
        admin_token,
    )
    if acquired.get("acquired") is not True:
        raise RuntimeError("failed to acquire the private Beta publication lock")
    published = False
    try:
        for key, _, _ in immutable:
            renewed = admin_post(
                args.worker_base_url,
                "renew",
                publication_id,
                admin_token,
            )
            if renewed.get("renewed") is not True:
                raise RuntimeError("lost the private Beta publication lock")
            assert_remote_object_absent(args.bucket, key)
        for key, path, content_type in immutable:
            renewed = admin_post(
                args.worker_base_url,
                "renew",
                publication_id,
                admin_token,
            )
            if renewed.get("renewed") is not True:
                raise RuntimeError("lost the private Beta publication lock")
            upload(args.bucket, key, path, content_type)
        renewed = admin_post(
            args.worker_base_url,
            "renew",
            publication_id,
            admin_token,
        )
        if renewed.get("renewed") is not True:
            raise RuntimeError("lost the private Beta publication lock")
        upload(
            args.bucket,
            "private-beta/appcast.xml",
            appcast,
            "application/xml; charset=utf-8",
        )
        published = True
    finally:
        if published:
            released = admin_post(
                args.worker_base_url,
                "release",
                publication_id,
                admin_token,
            )
            if released.get("released") is not True:
                raise RuntimeError("failed to release the private Beta publication lock")
    print(json.dumps(plan, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
