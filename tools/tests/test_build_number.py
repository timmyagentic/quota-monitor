import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "build_number",
    Path(__file__).parents[1] / "build-number.py",
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class BuildNumberTests(unittest.TestCase):
    def test_app_store_builds_retain_a_conforming_dotted_bundle_version(self):
        build_script = (
            Path(__file__).resolve().parents[2] / "build.sh"
        ).read_text()
        self.assertIn('if [[ "${QM_DISTRIBUTION}" == "app-store" ]]', build_script)
        self.assertIn('BUILD_NUMBER="${VERSION}"', build_script)
        self.assertIn(
            "App Store builds support only the stable release channel",
            build_script,
        )

    def test_stable_supersedes_every_beta_for_the_same_version(self):
        stable = MODULE.build_number("0.2.44", "stable")
        self.assertGreater(
            stable,
            MODULE.build_number("0.2.44", "private-beta", 8_999),
        )

    def test_next_version_beta_supersedes_previous_stable(self):
        self.assertGreater(
            MODULE.build_number("0.2.45", "private-beta", 1),
            MODULE.build_number("0.2.44", "stable"),
        )

    def test_beta_sequence_is_bounded(self):
        with self.assertRaisesRegex(ValueError, "1...8999"):
            MODULE.build_number("0.2.44", "private-beta", 9_000)

    def test_invalid_version_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "major.minor.patch"):
            MODULE.build_number("0.2.44-beta.1", "private-beta", 1)


if __name__ == "__main__":
    unittest.main()
