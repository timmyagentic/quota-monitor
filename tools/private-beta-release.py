#!/usr/bin/env python3
"""Publish Private Beta updates and mirror a verified Stable into that feed.

Immutable artifacts, checksums, and notes are uploaded first. The mutable
appcast is uploaded only after every referenced object succeeds. Public
GitHub Releases and the public appcast remain owned by release.yml.
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
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PUBLICATION_LEASE_LIFETIME_SECONDS = 30 * 60
COMMAND_TIMEOUT_SECONDS = 10 * 60
SIGNATURE_PATTERN = re.compile(
    r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"'
)
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
XML_NAMESPACE = "http://www.w3.org/XML/1998/namespace"
SPARKLE_CHANNEL = f"{{{SPARKLE_NAMESPACE}}}channel"
SPARKLE_VERSION = f"{{{SPARKLE_NAMESPACE}}}version"
SPARKLE_SHORT_VERSION = f"{{{SPARKLE_NAMESPACE}}}shortVersionString"
SPARKLE_SIGNATURE = f"{{{SPARKLE_NAMESPACE}}}edSignature"
XML_LANGUAGE = f"{{{XML_NAMESPACE}}}lang"
SAFE_ROUTE_COMPONENT = re.compile(r"^[A-Za-z0-9._-]+$")
STABLE_VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")

ET.register_namespace("sparkle", SPARKLE_NAMESPACE)


def child_environment(environment: dict[str, str] | None = None) -> dict[str, str]:
    resolved = (environment or os.environ).copy()
    resolved.pop("PRIVATE_BETA_ADMIN_TOKEN", None)
    return resolved


def run(command: list[str], *, env: dict[str, str] | None = None) -> str:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=child_environment(env),
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


def appcast_channel(document: str) -> ET.Element:
    try:
        root = ET.fromstring(document)
    except ET.ParseError as error:
        raise RuntimeError("appcast XML is invalid") from error
    channel = root.find("channel")
    if channel is None:
        raise RuntimeError("appcast XML has no channel")
    return channel


def serialized_item(item: ET.Element) -> str:
    item.tail = None
    return ET.tostring(item, encoding="unicode", short_empty_elements=True)


def latest_public_stable_version(public_appcast: str) -> str:
    stable_items: list[tuple[int, str]] = []
    for item in appcast_channel(public_appcast).findall("item"):
        item_channel = item.find(SPARKLE_CHANNEL)
        if item_channel is not None and (item_channel.text or "").strip():
            continue
        version = (item.findtext(SPARKLE_SHORT_VERSION) or "").strip()
        raw_build = (item.findtext(SPARKLE_VERSION) or "").strip()
        if (
            not STABLE_VERSION_PATTERN.fullmatch(version)
            or not raw_build.isdigit()
            or int(raw_build) <= 0
        ):
            continue
        stable_items.append((int(raw_build), version))
    if not stable_items:
        raise RuntimeError("public appcast has no valid Stable item")
    return max(stable_items, key=lambda candidate: candidate[0])[1]


def private_stable_item(
    public_appcast: str,
    *,
    version: str,
    base_url: str,
    artifact_name: str,
) -> str:
    """Copy one public Stable item while keeping every request on our Worker.

    Sparkle applies the Private Beta Bearer header to updater requests. A
    public GitHub enclosure in the authenticated feed could therefore expose a
    device token to a third-party origin. The Stable DMG and notes are mirrored
    byte-for-byte under the private Worker routes before this rewritten item is
    published.
    """
    if not STABLE_VERSION_PATTERN.fullmatch(version):
        raise RuntimeError("stable version is not safe for a private route")
    if (
        not SAFE_ROUTE_COMPONENT.fullmatch(artifact_name)
        or Path(artifact_name).name != artifact_name
    ):
        raise RuntimeError("stable artifact name is not safe for a private route")
    if artifact_name != f"QuotaMonitor-{version}.dmg":
        raise RuntimeError("stable artifact name does not match the version")
    private_base = validate_worker_base_url(base_url)
    candidates = []
    for item in appcast_channel(public_appcast).findall("item"):
        item_channel = item.find(SPARKLE_CHANNEL)
        display_version = item.findtext(SPARKLE_SHORT_VERSION)
        if (
            display_version == version
            and (item_channel is None or not (item_channel.text or "").strip())
        ):
            candidates.append(item)
    if len(candidates) != 1:
        raise RuntimeError(
            f"public appcast must contain exactly one Stable {version} item"
        )

    item = candidates[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise RuntimeError("public Stable item has no enclosure")
    signature = enclosure.get(SPARKLE_SIGNATURE, "").strip()
    raw_length = enclosure.get("length", "").strip()
    if not signature or not raw_length.isdigit() or int(raw_length) <= 0:
        raise RuntimeError("public Stable item has invalid signature metadata")
    raw_build = (item.findtext(SPARKLE_VERSION) or "").strip()
    if not raw_build.isdigit() or int(raw_build) <= 0:
        raise RuntimeError("public Stable item has no numeric build")

    enclosure.set(
        "url",
        f"{private_base}/artifacts/{artifact_name}",
    )
    notes_by_language = {
        note.get(XML_LANGUAGE): note
        for note in item.findall(f"{{{SPARKLE_NAMESPACE}}}releaseNotesLink")
    }
    for language in ("en", "zh-Hans"):
        note = notes_by_language.get(language)
        if note is None:
            raise RuntimeError(
                f"public Stable item has no {language} release notes link"
            )
        note.text = f"{private_base}/notes/{version}.{language}.html"
    return serialized_item(item)


def preserved_stable_item(private_appcast: str) -> str | None:
    stable_items: list[tuple[int, ET.Element]] = []
    for item in appcast_channel(private_appcast).findall("item"):
        item_channel = item.find(SPARKLE_CHANNEL)
        if item_channel is not None and (item_channel.text or "").strip():
            continue
        raw_build = (item.findtext(SPARKLE_VERSION) or "").strip()
        if not raw_build.isdigit():
            raise RuntimeError("private Stable item has no numeric build")
        stable_items.append((int(raw_build), item))
    if not stable_items:
        return None
    return serialized_item(max(stable_items, key=lambda candidate: candidate[0])[1])


def merge_stable_item(private_appcast: str, stable_item: str) -> str:
    try:
        root = ET.fromstring(private_appcast)
        stable = ET.fromstring(stable_item)
    except ET.ParseError as error:
        raise RuntimeError("private appcast item XML is invalid") from error
    channel = root.find("channel")
    if channel is None:
        raise RuntimeError("private appcast XML has no channel")
    if stable.tag != "item" or stable.find(SPARKLE_CHANNEL) is not None:
        raise RuntimeError("private Stable item must be a channel-less item")
    for item in list(channel.findall("item")):
        item_channel = item.find(SPARKLE_CHANNEL)
        if item_channel is None or not (item_channel.text or "").strip():
            channel.remove(item)
    channel.append(stable)
    return ET.tostring(
        root,
        encoding="unicode",
        xml_declaration=True,
        short_empty_elements=True,
    ) + "\n"


def validate_authenticated_appcast_routes(document: str, base_url: str) -> None:
    private_base = urllib.parse.urlsplit(validate_worker_base_url(base_url))
    private_path = private_base.path.rstrip("/") + "/"
    for item in appcast_channel(document).findall("item"):
        item_channel = item.find(SPARKLE_CHANNEL)
        channel_name = (item_channel.text or "").strip() if item_channel is not None else ""
        if channel_name not in ("", "private-beta"):
            raise RuntimeError("authenticated appcast has an unsupported channel")
        enclosure = item.find("enclosure")
        if enclosure is None:
            raise RuntimeError("authenticated appcast item has no enclosure")
        urls = [enclosure.get("url", "")]
        urls.extend(
            (note.text or "").strip()
            for note in item.findall(f"{{{SPARKLE_NAMESPACE}}}releaseNotesLink")
        )
        for value in urls:
            try:
                target = urllib.parse.urlsplit(value)
            except ValueError as error:
                raise RuntimeError("authenticated appcast URL is invalid") from error
            if (
                target.scheme != private_base.scheme
                or target.netloc != private_base.netloc
                or not target.path.startswith(private_path)
                or target.username is not None
                or target.password is not None
                or target.query
                or target.fragment
            ):
                raise RuntimeError(
                    "authenticated appcast URL must stay on the private Worker"
                )


def validate_stable_release_files(
    artifact: Path,
    checksum: Path,
    stable_item: str,
    *,
    expected_signature: str | None = None,
    expected_length: int | None = None,
) -> None:
    if not artifact.is_file():
        raise RuntimeError(f"missing Stable artifact: {artifact}")
    if not checksum.is_file():
        raise RuntimeError(f"missing Stable checksum: {checksum}")
    parts = checksum.read_text(encoding="utf-8").strip().split()
    if not parts or not re.fullmatch(r"[0-9a-fA-F]{64}", parts[0]):
        raise RuntimeError("Stable checksum sidecar is invalid")
    if len(parts) > 1 and Path(parts[-1]).name != artifact.name:
        raise RuntimeError("Stable checksum sidecar names another artifact")
    if parts[0].lower() != file_sha256(artifact):
        raise RuntimeError("Stable checksum does not match the artifact")
    try:
        item = ET.fromstring(stable_item)
    except ET.ParseError as error:
        raise RuntimeError("private Stable item XML is invalid") from error
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise RuntimeError("private Stable item has no enclosure")
    raw_length = enclosure.get("length", "")
    if not raw_length.isdigit() or int(raw_length) != artifact.stat().st_size:
        raise RuntimeError("private Stable item length does not match the artifact")
    signature = enclosure.get(SPARKLE_SIGNATURE, "").strip()
    if not signature:
        raise RuntimeError("private Stable item has no Sparkle signature")
    if expected_signature is not None and signature != expected_signature:
        raise RuntimeError("private Stable item Sparkle signature does not match the artifact")
    if expected_length is not None and int(raw_length) != expected_length:
        raise RuntimeError("recomputed Sparkle length does not match the Stable item")
    enclosure_name = Path(
        urllib.parse.urlsplit(enclosure.get("url", "")).path
    ).name
    if enclosure_name != artifact.name:
        raise RuntimeError("private Stable item names another artifact")


def appcast_xml(
    *,
    version: str,
    build: int,
    signature: str,
    length: int,
    base_url: str,
    artifact_name: str,
    minimum_system_version: str,
    stable_item: str | None = None,
) -> str:
    escaped_base = html.escape(base_url.rstrip("/"), quote=True)
    escaped_name = html.escape(artifact_name, quote=True)
    document = f"""<?xml version="1.0" encoding="utf-8"?>
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
    return merge_stable_item(document, stable_item) if stable_item else document


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
        if get_remote_object(
            bucket,
            key,
            destination,
            allow_missing=True,
        ):
            raise RuntimeError(f"immutable R2 object already exists: {key}")


def upload(bucket: str, key: str, path: Path, content_type: str) -> None:
    run(wrangler_command(
        "r2", "object", "put", f"{bucket}/{key}",
        "--remote", "--file", str(path), "--content-type", content_type,
        "--cache-control", "private, no-store",
    ))


def get_remote_object(
    bucket: str,
    key: str,
    destination: Path,
    *,
    allow_missing: bool = False,
) -> bool:
    result = subprocess.run(
        wrangler_command(
            "r2", "object", "get", f"{bucket}/{key}",
            "--remote", "--file", str(destination),
        ),
        cwd=ROOT,
        env=child_environment(),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=COMMAND_TIMEOUT_SECONDS,
    )
    if result.returncode == 0:
        return True
    output = f"{result.stdout}\n{result.stderr}".lower()
    if allow_missing and "specified key does not exist" in output:
        return False
    raise RuntimeError(f"failed to read remote R2 object: {key}")


def remote_object_bytes(
    bucket: str,
    key: str,
    *,
    allow_missing: bool = False,
) -> bytes | None:
    with tempfile.TemporaryDirectory(prefix="qm-private-beta-read-") as directory:
        destination = Path(directory) / "object"
        if not get_remote_object(
            bucket,
            key,
            destination,
            allow_missing=allow_missing,
        ):
            return None
        return destination.read_bytes()


def ensure_remote_object(
    bucket: str,
    key: str,
    path: Path,
    content_type: str,
) -> str:
    expected = path.read_bytes()
    existing = remote_object_bytes(bucket, key, allow_missing=True)
    if existing is not None:
        if existing != expected:
            raise RuntimeError(f"immutable R2 object differs from local bytes: {key}")
        return "reused"
    upload(bucket, key, path, content_type)
    readback = remote_object_bytes(bucket, key)
    if readback != expected:
        raise RuntimeError(f"R2 readback differs after upload: {key}")
    return "uploaded"


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
            "User-Agent": "QuotaMonitor-Private-Beta-Publisher/1.0",
        },
    )
    with admin_opener().open(request, timeout=30) as response:
        payload = json.loads(response.read())
    if not isinstance(payload, dict):
        raise RuntimeError("publication lock returned an invalid response")
    return payload


def read_admin_token() -> str:
    token = os.environ.get("PRIVATE_BETA_ADMIN_TOKEN")
    if token is None:
        token = getpass.getpass("Private Beta admin token: ")
    if len(token) < 32:
        raise RuntimeError("PRIVATE_BETA_ADMIN_TOKEN must be at least 32 characters")
    return token


def renew_publication_lock(
    base_url: str,
    publication_id: str,
    admin_token: str,
) -> None:
    renewed = admin_post(base_url, "renew", publication_id, admin_token)
    if renewed.get("renewed") is not True:
        raise RuntimeError("lost the private Beta publication lock")


def rooted_path(value: str | None, default: Path) -> Path:
    if value is None:
        return default
    path = Path(value)
    return path if path.is_absolute() else ROOT / path


def publish_private_beta(args: argparse.Namespace) -> int:
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
        "mode": "private-beta",
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
        "preservesStableItem": True,
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
    appcast = ROOT / ".build" / "private-beta" / f"appcast-{display_version}.xml"
    appcast.parent.mkdir(parents=True, exist_ok=True)
    admin_token = read_admin_token()
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
        current_feed = remote_object_bytes(
            args.bucket,
            "private-beta/appcast.xml",
            allow_missing=args.allow_missing_private_appcast,
        )
        stable_item = (
            preserved_stable_item(current_feed.decode("utf-8"))
            if current_feed is not None
            else None
        )
        appcast_document = appcast_xml(
            version=display_version,
            build=build,
            signature=signature,
            length=signed_length,
            base_url=args.worker_base_url,
            artifact_name=artifact.name,
            minimum_system_version=args.minimum_system_version,
            stable_item=stable_item,
        )
        validate_authenticated_appcast_routes(
            appcast_document,
            args.worker_base_url,
        )
        appcast.write_text(appcast_document)
        for key, _, _ in immutable:
            renew_publication_lock(
                args.worker_base_url,
                publication_id,
                admin_token,
            )
            assert_remote_object_absent(args.bucket, key)
        for key, path, content_type in immutable:
            renew_publication_lock(
                args.worker_base_url,
                publication_id,
                admin_token,
            )
            upload(args.bucket, key, path, content_type)
        renew_publication_lock(
            args.worker_base_url,
            publication_id,
            admin_token,
        )
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


def sync_stable_to_private_beta(args: argparse.Namespace) -> int:
    public_appcast = rooted_path(args.public_appcast, ROOT / "appcast.xml")
    if not public_appcast.is_file():
        raise RuntimeError(f"missing public appcast: {public_appcast}")
    public_appcast_document = public_appcast.read_text(encoding="utf-8")
    version = latest_public_stable_version(public_appcast_document)
    artifact = rooted_path(
        args.stable_artifact,
        ROOT / "dist" / f"QuotaMonitor-{version}.dmg",
    )
    checksum = rooted_path(
        args.stable_checksum,
        artifact.with_suffix(".dmg.sha256"),
    )
    notes = {
        "en": ROOT / "ReleaseNotes" / f"{version}.en.html",
        "zh-Hans": ROOT / "ReleaseNotes" / f"{version}.zh-Hans.html",
    }
    for language, path in notes.items():
        if not path.is_file():
            raise RuntimeError(f"missing {language} release notes: {path}")
    stable_item = private_stable_item(
        public_appcast_document,
        version=version,
        base_url=args.worker_base_url,
        artifact_name=artifact.name,
    )
    recomputed_signature, recomputed_length = sparkle_signature(
        artifact,
        args.sparkle_account,
    )
    validate_stable_release_files(
        artifact,
        checksum,
        stable_item,
        expected_signature=recomputed_signature,
        expected_length=recomputed_length,
    )
    immutable = [
        (f"private-beta/artifacts/{artifact.name}", artifact,
         "application/x-apple-diskimage"),
        (f"private-beta/artifacts/{checksum.name}", checksum,
         "text/plain; charset=utf-8"),
        (f"private-beta/notes/{version}.en.html", notes["en"],
         "text/html; charset=utf-8"),
        (f"private-beta/notes/{version}.zh-Hans.html", notes["zh-Hans"],
         "text/html; charset=utf-8"),
    ]
    plan = {
        "mode": "sync-stable",
        "version": version,
        "artifact": str(artifact),
        "uploads": [key for key, _, _ in immutable]
            + ["private-beta/appcast.xml"],
        "preservesPrivateBetaItems": True,
        "allAuthenticatedURLsRemainPrivate": True,
        "githubRelease": False,
        "publicAppcast": False,
        "atomicPublicationLock": True,
    }
    if args.dry_run:
        print(json.dumps(plan, indent=2))
        return 0

    admin_token = read_admin_token()
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
        current_feed = remote_object_bytes(
            args.bucket,
            "private-beta/appcast.xml",
        )
        if current_feed is None:
            raise RuntimeError("private Beta appcast is missing")
        merged_document = merge_stable_item(
            current_feed.decode("utf-8"),
            stable_item,
        )
        validate_authenticated_appcast_routes(
            merged_document,
            args.worker_base_url,
        )
        merged_feed = merged_document.encode("utf-8")
        for key, path, content_type in immutable:
            renew_publication_lock(
                args.worker_base_url,
                publication_id,
                admin_token,
            )
            ensure_remote_object(args.bucket, key, path, content_type)
        with tempfile.TemporaryDirectory(prefix="qm-private-stable-appcast-") as directory:
            appcast = Path(directory) / "appcast.xml"
            appcast.write_bytes(merged_feed)
            renew_publication_lock(
                args.worker_base_url,
                publication_id,
                admin_token,
            )
            upload(
                args.bucket,
                "private-beta/appcast.xml",
                appcast,
                "application/xml; charset=utf-8",
            )
        if remote_object_bytes(
            args.bucket,
            "private-beta/appcast.xml",
        ) != merged_feed:
            raise RuntimeError("private appcast readback differs after Stable sync")
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


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--beta-sequence", type=int)
    mode.add_argument("--sync-stable", action="store_true")
    parser.add_argument("--bucket", default="quota-monitor-private-beta")
    parser.add_argument(
        "--worker-base-url",
        default="https://quota-monitor.timmyagentic.com/api/private-beta",
    )
    parser.add_argument("--sparkle-account", default="quotamonitor")
    parser.add_argument("--minimum-system-version", default="14.0")
    parser.add_argument("--skip-package", action="store_true")
    parser.add_argument("--allow-missing-private-appcast", action="store_true")
    parser.add_argument("--stable-artifact")
    parser.add_argument("--stable-checksum")
    parser.add_argument("--public-appcast")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    args.worker_base_url = validate_worker_base_url(args.worker_base_url)
    if args.sync_stable:
        return sync_stable_to_private_beta(args)
    return publish_private_beta(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
