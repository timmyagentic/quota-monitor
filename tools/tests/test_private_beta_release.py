import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "private_beta_release",
    Path(__file__).parents[1] / "private-beta-release.py",
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class PrivateBetaReleaseTests(unittest.TestCase):
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
        immutable_loop = source.index("for key, path, content_type in immutable:")
        appcast_upload = source.index('"private-beta/appcast.xml"', immutable_loop)
        unlock = source.index('                "release",', appcast_upload)
        self.assertLess(lock, immutable_loop)
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

        original = MODULE.urllib.request.urlopen
        MODULE.urllib.request.urlopen = lambda request, timeout: (
            requests.append((request, timeout)) or Response()
        )
        try:
            payload = MODULE.admin_post(
                "https://example.test/api/private-beta",
                "acquire",
                "A" * 43,
                "secret-" + "x" * 32,
            )
        finally:
            MODULE.urllib.request.urlopen = original

        self.assertTrue(payload["acquired"])
        request, timeout = requests[0]
        self.assertEqual(timeout, 30)
        self.assertNotIn("secret", request.full_url)
        self.assertEqual(
            request.full_url,
            "https://example.test/api/private-beta/admin/publication-lock/acquire",
        )


if __name__ == "__main__":
    unittest.main()
