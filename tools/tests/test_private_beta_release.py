import contextlib
import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest


SPEC = importlib.util.spec_from_file_location(
    "private_beta_release",
    Path(__file__).parents[1] / "private-beta-release.py",
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class PrivateBetaReleaseTests(unittest.TestCase):
    @staticmethod
    def public_appcast(*, length: int = 6) -> str:
        return f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>QuotaMonitor</title>
    <item>
      <title>QuotaMonitor 1.0.3</title>
      <pubDate>Thu, 27 Aug 2026 13:00:00 +0000</pubDate>
      <sparkle:version>10000039000</sparkle:version>
      <sparkle:shortVersionString>1.0.3</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink xml:lang="en">https://raw.githubusercontent.com/timmyagentic/quota-monitor/main/ReleaseNotes/1.0.3.en.html</sparkle:releaseNotesLink>
      <sparkle:releaseNotesLink xml:lang="zh-Hans">https://raw.githubusercontent.com/timmyagentic/quota-monitor/main/ReleaseNotes/1.0.3.zh-Hans.html</sparkle:releaseNotesLink>
      <enclosure
        url="https://github.com/timmyagentic/quota-monitor/releases/download/v1.0.3/QuotaMonitor-1.0.3.dmg"
        type="application/octet-stream"
        sparkle:edSignature="stable-signature"
        length="{length}" />
    </item>
  </channel>
</rss>
'''

    def test_worker_base_url_requires_a_clean_https_origin(self):
        self.assertEqual(
            MODULE.validate_worker_base_url(
                "https://example.test/api/private-beta/"
            ),
            "https://example.test/api/private-beta",
        )
        for value in [
            "http://example.test/api/private-beta",
            "https://user:secret@example.test/api/private-beta",
            "https://example.test/api/private-beta?token=secret",
            "https://example.test/api/private-beta#fragment",
        ]:
            with self.subTest(value=value):
                with self.assertRaises(RuntimeError):
                    MODULE.validate_worker_base_url(value)

    def test_admin_requests_refuse_redirects(self):
        handler = MODULE.RefuseRedirects()
        self.assertIsNone(handler.redirect_request(
            None,
            None,
            302,
            "Found",
            {},
            "https://other.example.test/admin",
        ))

    def test_external_commands_are_bounded_below_the_lease_lifetime(self):
        calls = []
        original = MODULE.subprocess.run
        original_admin_token = os.environ.get("PRIVATE_BETA_ADMIN_TOKEN")
        os.environ["PRIVATE_BETA_ADMIN_TOKEN"] = "must-not-reach-child"
        MODULE.subprocess.run = lambda *args, **kwargs: (
            calls.append(kwargs) or subprocess.CompletedProcess(args[0], 0, "ok")
        )
        try:
            MODULE.run(["example"])
        finally:
            MODULE.subprocess.run = original
            if original_admin_token is None:
                os.environ.pop("PRIVATE_BETA_ADMIN_TOKEN", None)
            else:
                os.environ["PRIVATE_BETA_ADMIN_TOKEN"] = original_admin_token

        self.assertEqual(calls[0]["timeout"], MODULE.COMMAND_TIMEOUT_SECONDS)
        self.assertLess(
            MODULE.COMMAND_TIMEOUT_SECONDS,
            MODULE.PUBLICATION_LEASE_LIFETIME_SECONDS,
        )
        self.assertNotIn("PRIVATE_BETA_ADMIN_TOKEN", calls[0]["env"])

    def test_remote_read_treats_only_the_exact_missing_error_as_absent(self):
        responses = [
            subprocess.CompletedProcess([], 1, "", "The specified key does not exist."),
            subprocess.CompletedProcess([], 1, "", "Authentication failed"),
        ]
        original = MODULE.subprocess.run
        MODULE.subprocess.run = lambda *_args, **_kwargs: responses.pop(0)
        try:
            with tempfile.TemporaryDirectory() as directory:
                destination = Path(directory) / "object"
                self.assertFalse(MODULE.get_remote_object(
                    "bucket",
                    "missing",
                    destination,
                    allow_missing=True,
                ))
                with self.assertRaisesRegex(RuntimeError, "failed to read"):
                    MODULE.get_remote_object(
                        "bucket",
                        "private",
                        destination,
                        allow_missing=True,
                    )
        finally:
            MODULE.subprocess.run = original

    def test_stable_mirror_reuses_exact_bytes_and_rejects_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "stable.dmg"
            path.write_bytes(b"stable")
            uploads = []
            original_read = MODULE.remote_object_bytes
            original_upload = MODULE.upload
            MODULE.upload = lambda *args: uploads.append(args)
            try:
                MODULE.remote_object_bytes = lambda *_args, **_kwargs: b"stable"
                self.assertEqual(
                    MODULE.ensure_remote_object(
                        "bucket", "stable", path, "application/octet-stream"
                    ),
                    "reused",
                )
                self.assertEqual(uploads, [])

                MODULE.remote_object_bytes = lambda *_args, **_kwargs: b"different"
                with self.assertRaisesRegex(RuntimeError, "differs"):
                    MODULE.ensure_remote_object(
                        "bucket", "stable", path, "application/octet-stream"
                    )

                readbacks = [None, b"stable"]
                MODULE.remote_object_bytes = lambda *_args, **_kwargs: readbacks.pop(0)
                self.assertEqual(
                    MODULE.ensure_remote_object(
                        "bucket", "new-stable", path, "application/octet-stream"
                    ),
                    "uploaded",
                )
                self.assertEqual(len(uploads), 1)
            finally:
                MODULE.remote_object_bytes = original_read
                MODULE.upload = original_upload

    def test_appcast_uses_private_routes_and_numeric_build(self):
        appcast = MODULE.appcast_xml(
            version="0.2.44-beta.7",
            build=20_440_007,
            signature="signature",
            length=123,
            base_url="https://example.test/api/private-beta",
            artifact_name="QuotaMonitor-0.2.44-beta.7.dmg",
            minimum_system_version="14.0",
        )

        self.assertIn("<sparkle:version>20440007</sparkle:version>", appcast)
        self.assertIn("<sparkle:channel>private-beta</sparkle:channel>", appcast)
        self.assertIn("/api/private-beta/artifacts/", appcast)
        self.assertIn("/api/private-beta/notes/", appcast)
        self.assertNotIn("github.com", appcast)
        self.assertNotIn("raw.githubusercontent.com", appcast)

    def test_stable_item_rewrites_every_request_to_private_routes(self):
        item = MODULE.private_stable_item(
            self.public_appcast(),
            version="1.0.3",
            base_url="https://example.test/api/private-beta",
            artifact_name="QuotaMonitor-1.0.3.dmg",
        )

        self.assertIn("<sparkle:version>10000039000</sparkle:version>", item)
        self.assertIn("stable-signature", item)
        self.assertIn(
            "https://example.test/api/private-beta/artifacts/QuotaMonitor-1.0.3.dmg",
            item,
        )
        self.assertIn(
            "https://example.test/api/private-beta/notes/1.0.3.en.html",
            item,
        )
        self.assertIn(
            "https://example.test/api/private-beta/notes/1.0.3.zh-Hans.html",
            item,
        )
        self.assertNotIn("<sparkle:channel>", item)
        self.assertNotIn("github.com", item)
        self.assertNotIn("raw.githubusercontent.com", item)

        invalid_build = self.public_appcast().replace(
            "<sparkle:version>10000039000</sparkle:version>",
            "<sparkle:version>not-a-build</sparkle:version>",
        )
        with self.assertRaisesRegex(RuntimeError, "numeric build"):
            MODULE.private_stable_item(
                invalid_build,
                version="1.0.3",
                base_url="https://example.test/api/private-beta",
                artifact_name="QuotaMonitor-1.0.3.dmg",
            )

    def test_latest_public_stable_version_uses_the_highest_valid_build(self):
        older = self.public_appcast().replace(
            "<sparkle:version>10000039000</sparkle:version>",
            "<sparkle:version>10000029000</sparkle:version>",
        ).replace("1.0.3", "1.0.2")
        older_item = older[
            older.index("    <item>"):
            older.index("    </item>") + len("    </item>")
        ]
        combined = self.public_appcast().replace(
            "  </channel>",
            f"{older_item}\n  </channel>",
        )

        self.assertEqual(
            MODULE.latest_public_stable_version(combined),
            "1.0.3",
        )

    def test_private_appcast_keeps_beta_first_and_latest_stable(self):
        stable_item = MODULE.private_stable_item(
            self.public_appcast(),
            version="1.0.3",
            base_url="https://example.test/api/private-beta",
            artifact_name="QuotaMonitor-1.0.3.dmg",
        )
        appcast = MODULE.appcast_xml(
            version="1.0.3-beta.3",
            build=10_000_030_003,
            signature="beta-signature",
            length=123,
            base_url="https://example.test/api/private-beta",
            artifact_name="QuotaMonitor-1.0.3-beta.3.dmg",
            minimum_system_version="14.0",
            stable_item=stable_item,
        )

        beta_position = appcast.index("<sparkle:version>10000030003</sparkle:version>")
        stable_position = appcast.index("<sparkle:version>10000039000</sparkle:version>")
        self.assertLess(beta_position, stable_position)
        self.assertEqual(appcast.count("<sparkle:channel>private-beta</sparkle:channel>"), 1)
        self.assertEqual(appcast.count("<sparkle:shortVersionString>1.0.3</sparkle:shortVersionString>"), 1)
        self.assertEqual(
            MODULE.preserved_stable_item(appcast),
            stable_item,
        )
        MODULE.validate_authenticated_appcast_routes(
            appcast,
            "https://example.test/api/private-beta",
        )

        unsafe = appcast.replace(
            "https://example.test/api/private-beta/artifacts/QuotaMonitor-1.0.3.dmg",
            "https://github.com/example/QuotaMonitor-1.0.3.dmg",
        )
        with self.assertRaisesRegex(RuntimeError, "authenticated appcast URL"):
            MODULE.validate_authenticated_appcast_routes(
                unsafe,
                "https://example.test/api/private-beta",
            )

    def test_stable_release_files_must_match_sidecar_and_appcast_length(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "QuotaMonitor-1.0.3.dmg"
            checksum = root / "QuotaMonitor-1.0.3.dmg.sha256"
            artifact.write_bytes(b"stable")
            digest = hashlib.sha256(b"stable").hexdigest()
            checksum.write_text(f"{digest}  {artifact.name}\n")
            item = MODULE.private_stable_item(
                self.public_appcast(length=artifact.stat().st_size),
                version="1.0.3",
                base_url="https://example.test/api/private-beta",
                artifact_name=artifact.name,
            )

            MODULE.validate_stable_release_files(
                artifact,
                checksum,
                item,
                expected_signature="stable-signature",
                expected_length=artifact.stat().st_size,
            )

            with self.assertRaisesRegex(RuntimeError, "Sparkle signature"):
                MODULE.validate_stable_release_files(
                    artifact,
                    checksum,
                    item,
                    expected_signature="different-signature",
                )

            checksum.write_text(f"{'0' * 64}  {artifact.name}\n")
            with self.assertRaisesRegex(RuntimeError, "checksum"):
                MODULE.validate_stable_release_files(artifact, checksum, item)

            checksum.write_text(f"{digest}  {artifact.name}\n")
            wrong_length_item = MODULE.private_stable_item(
                self.public_appcast(length=artifact.stat().st_size + 1),
                version="1.0.3",
                base_url="https://example.test/api/private-beta",
                artifact_name=artifact.name,
            )
            with self.assertRaisesRegex(RuntimeError, "length"):
                MODULE.validate_stable_release_files(
                    artifact,
                    checksum,
                    wrong_length_item,
                )

    def test_stable_sync_dry_run_validates_and_plans_private_mirror(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "QuotaMonitor-1.0.3.dmg"
            checksum = root / "QuotaMonitor-1.0.3.dmg.sha256"
            public_appcast = root / "appcast.xml"
            artifact.write_bytes(b"stable")
            digest = hashlib.sha256(b"stable").hexdigest()
            checksum.write_text(f"{digest}  {artifact.name}\n")
            public_appcast.write_text(self.public_appcast())
            args = SimpleNamespace(
                stable_artifact=str(artifact),
                stable_checksum=str(checksum),
                public_appcast=str(public_appcast),
                worker_base_url="https://example.test/api/private-beta",
                sparkle_account="quotamonitor",
                bucket="bucket",
                dry_run=True,
            )
            original_signature = MODULE.sparkle_signature
            MODULE.sparkle_signature = lambda *_args: (
                "stable-signature",
                artifact.stat().st_size,
            )
            output = io.StringIO()
            try:
                with contextlib.redirect_stdout(output):
                    self.assertEqual(MODULE.sync_stable_to_private_beta(args), 0)
            finally:
                MODULE.sparkle_signature = original_signature

            plan = json.loads(output.getvalue())
            self.assertEqual(plan["mode"], "sync-stable")
            self.assertEqual(plan["version"], "1.0.3")
            self.assertTrue(plan["preservesPrivateBetaItems"])
            self.assertTrue(plan["allAuthenticatedURLsRemainPrivate"])
            self.assertEqual(plan["uploads"][-1], "private-beta/appcast.xml")

    def test_upload_plan_keeps_appcast_last(self):
        source = (Path(__file__).parents[1] / "private-beta-release.py").read_text()
        publisher = source.index("def publish_private_beta")
        lock = source.index('        "acquire",', publisher)
        preserve = source.index("preserved_stable_item", lock)
        immutable_loop = source.index("for key, path, content_type in immutable:")
        appcast_upload = source.index('"private-beta/appcast.xml"', immutable_loop)
        unlock = source.index('                "release",', appcast_upload)
        self.assertLess(lock, preserve)
        self.assertLess(lock, immutable_loop)
        self.assertLess(preserve, appcast_upload)
        self.assertGreater(appcast_upload, immutable_loop)
        self.assertGreater(unlock, appcast_upload)

    def test_admin_lock_request_keeps_the_secret_out_of_the_url(self):
        requests = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return None

            def read(self):
                return b'{"acquired": true}'

        class Opener:
            def open(self, request, timeout):
                requests.append((request, timeout))
                return Response()

        original = MODULE.admin_opener
        MODULE.admin_opener = lambda: Opener()
        try:
            payload = MODULE.admin_post(
                "https://example.test/api/private-beta",
                "acquire",
                "A" * 43,
                "secret-" + "x" * 32,
            )
        finally:
            MODULE.admin_opener = original

        self.assertTrue(payload["acquired"])
        request, timeout = requests[0]
        self.assertEqual(timeout, 30)
        self.assertNotIn("secret", request.full_url)
        self.assertEqual(
            request.full_url,
            "https://example.test/api/private-beta/admin/publication-lock/acquire",
        )
        self.assertEqual(
            request.get_header("User-agent"),
            "QuotaMonitor-Private-Beta-Publisher/1.0",
        )


if __name__ == "__main__":
    unittest.main()
