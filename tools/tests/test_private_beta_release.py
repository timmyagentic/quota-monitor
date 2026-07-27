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
        immutable_loop = source.index("for key, path, content_type in immutable:")
        appcast_upload = source.index('"private-beta/appcast.xml"', immutable_loop)
        self.assertGreater(appcast_upload, immutable_loop)


if __name__ == "__main__":
    unittest.main()
