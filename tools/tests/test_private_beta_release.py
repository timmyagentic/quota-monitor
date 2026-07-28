import importlib.util
from pathlib import Path
import subprocess
import unittest


SPEC = importlib.util.spec_from_file_location(
    "private_beta_release",
    Path(__file__).parents[1] / "private-beta-release.py",
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class PrivateBetaReleaseTests(unittest.TestCase):
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
        MODULE.subprocess.run = lambda *args, **kwargs: (
            calls.append(kwargs) or subprocess.CompletedProcess(args[0], 0, "ok")
        )
        try:
            MODULE.run(["example"])
        finally:
            MODULE.subprocess.run = original

        self.assertEqual(calls[0]["timeout"], MODULE.COMMAND_TIMEOUT_SECONDS)
        self.assertLess(
            MODULE.COMMAND_TIMEOUT_SECONDS,
            MODULE.PUBLICATION_LEASE_LIFETIME_SECONDS,
        )

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

    def test_upload_plan_keeps_appcast_last(self):
        source = (Path(__file__).parents[1] / "private-beta-release.py").read_text()
        lock = source.index('        "acquire",')
        renewal = source.index('                "renew",', lock)
        immutable_loop = source.index("for key, path, content_type in immutable:")
        appcast_upload = source.index('"private-beta/appcast.xml"', immutable_loop)
        unlock = source.index('                "release",', appcast_upload)
        self.assertLess(lock, immutable_loop)
        self.assertLess(renewal, appcast_upload)
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
