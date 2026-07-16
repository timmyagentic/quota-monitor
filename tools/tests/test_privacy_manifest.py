#!/usr/bin/env python3
import copy
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
VERIFIER = REPO_ROOT / "tools" / "verify-privacy-manifest.py"
SOURCE_MANIFEST = REPO_ROOT / "Resources" / "PrivacyInfo.xcprivacy"

EXPECTED_MANIFEST = {
    "NSPrivacyTracking": False,
    "NSPrivacyCollectedDataTypes": [
        {
            "NSPrivacyCollectedDataType": (
                "NSPrivacyCollectedDataTypeProductInteraction"
            ),
            "NSPrivacyCollectedDataTypeLinked": False,
            "NSPrivacyCollectedDataTypeTracking": False,
            "NSPrivacyCollectedDataTypePurposes": [
                "NSPrivacyCollectedDataTypePurposeAnalytics"
            ],
        }
    ],
    "NSPrivacyAccessedAPITypes": [],
}


class PrivacyManifestTests(unittest.TestCase):
    def read_text(self, relative_path: str) -> str:
        return (REPO_ROOT / relative_path).read_text(encoding="utf-8")

    def run_verifier(self, path: pathlib.Path | None = None):
        command = [sys.executable, str(VERIFIER)]
        if path is not None:
            command.append(str(path))
        return subprocess.run(
            command,
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )

    def write_plist(self, directory: pathlib.Path, value) -> pathlib.Path:
        path = directory / "PrivacyInfo.xcprivacy"
        with path.open("wb") as manifest_file:
            plistlib.dump(value, manifest_file)
        return path

    def assert_rejected(self, value) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_plist(pathlib.Path(temp_dir), value)
            result = self.run_verifier(path)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn(repr(value), result.stderr)

    def test_source_manifest_has_exact_schema_and_default_cli_accepts_it(self):
        with SOURCE_MANIFEST.open("rb") as manifest_file:
            manifest = plistlib.load(manifest_file)

        self.assertEqual(manifest, EXPECTED_MANIFEST)
        self.assertIs(manifest["NSPrivacyTracking"], False)
        collected = manifest["NSPrivacyCollectedDataTypes"][0]
        self.assertIs(collected["NSPrivacyCollectedDataTypeLinked"], False)
        self.assertIs(collected["NSPrivacyCollectedDataTypeTracking"], False)

        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_verifier_rejects_extra_top_level_or_collected_type_keys(self):
        top_level = copy.deepcopy(EXPECTED_MANIFEST)
        top_level["NSPrivacyTrackingDomains"] = []
        self.assert_rejected(top_level)

        collected_type = copy.deepcopy(EXPECTED_MANIFEST)
        collected_type["NSPrivacyCollectedDataTypes"][0]["Unexpected"] = "value"
        self.assert_rejected(collected_type)

    def test_verifier_rejects_wrong_purpose_or_data_type(self):
        wrong_purpose = copy.deepcopy(EXPECTED_MANIFEST)
        wrong_purpose["NSPrivacyCollectedDataTypes"][0][
            "NSPrivacyCollectedDataTypePurposes"
        ] = ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
        self.assert_rejected(wrong_purpose)

        wrong_data_type = copy.deepcopy(EXPECTED_MANIFEST)
        wrong_data_type["NSPrivacyCollectedDataTypes"][0][
            "NSPrivacyCollectedDataType"
        ] = "NSPrivacyCollectedDataTypeDeviceID"
        self.assert_rejected(wrong_data_type)

    def test_verifier_rejects_linked_or_tracking_collection(self):
        linked = copy.deepcopy(EXPECTED_MANIFEST)
        linked["NSPrivacyCollectedDataTypes"][0][
            "NSPrivacyCollectedDataTypeLinked"
        ] = True
        self.assert_rejected(linked)

        tracking = copy.deepcopy(EXPECTED_MANIFEST)
        tracking["NSPrivacyCollectedDataTypes"][0][
            "NSPrivacyCollectedDataTypeTracking"
        ] = True
        self.assert_rejected(tracking)

        app_tracking = copy.deepcopy(EXPECTED_MANIFEST)
        app_tracking["NSPrivacyTracking"] = True
        self.assert_rejected(app_tracking)

    def test_verifier_rejects_nonempty_accessed_api_types(self):
        manifest = copy.deepcopy(EXPECTED_MANIFEST)
        manifest["NSPrivacyAccessedAPITypes"] = [
            {
                "NSPrivacyAccessedAPIType": (
                    "NSPrivacyAccessedAPICategoryUserDefaults"
                ),
                "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
            }
        ]

        self.assert_rejected(manifest)

    def test_verifier_rejects_integer_values_in_every_boolean_field(self):
        boolean_paths = (
            ("NSPrivacyTracking",),
            (
                "NSPrivacyCollectedDataTypes",
                0,
                "NSPrivacyCollectedDataTypeLinked",
            ),
            (
                "NSPrivacyCollectedDataTypes",
                0,
                "NSPrivacyCollectedDataTypeTracking",
            ),
        )
        for path in boolean_paths:
            with self.subTest(path=path):
                manifest = copy.deepcopy(EXPECTED_MANIFEST)
                target = manifest
                for component in path[:-1]:
                    target = target[component]
                target[path[-1]] = 0
                self.assert_rejected(manifest)

    def test_verifier_rejects_malformed_plist_without_echoing_contents(self):
        sentinel = "do-not-echo-private-payload"
        with tempfile.TemporaryDirectory() as temp_dir:
            path = pathlib.Path(temp_dir) / "PrivacyInfo.xcprivacy"
            path.write_text(f"not a plist: {sentinel}", encoding="utf-8")
            result = self.run_verifier(path)

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(sentinel, result.stderr)

    def test_verifier_rejects_missing_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            missing = pathlib.Path(temp_dir) / "missing.xcprivacy"
            result = self.run_verifier(missing)

        self.assertNotEqual(result.returncode, 0)

    def test_verifier_rejects_symlink_even_when_target_is_valid(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = pathlib.Path(temp_dir)
            target = self.write_plist(directory, EXPECTED_MANIFEST)
            symlink = directory / "linked.xcprivacy"
            symlink.symlink_to(target)
            result = self.run_verifier(symlink)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn(target.name, result.stderr)

    def test_verifier_rejects_broken_symlink_without_leaking_target(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = pathlib.Path(temp_dir)
            missing_target = directory / "sensitive-target-name.xcprivacy"
            symlink = directory / "broken.xcprivacy"
            symlink.symlink_to(missing_target)
            result = self.run_verifier(symlink)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn(missing_target.name, result.stderr)

    def test_verifier_rejects_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = pathlib.Path(temp_dir) / "manifest-directory"
            directory.mkdir()
            result = self.run_verifier(directory)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn(directory.name, result.stderr)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires POSIX")
    def test_verifier_rejects_fifo_without_blocking(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fifo = pathlib.Path(temp_dir) / "manifest.fifo"
            os.mkfifo(fifo)
            result = self.run_verifier(fifo)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn(fifo.name, result.stderr)

    def test_build_copies_and_verifies_manifest_before_signing(self):
        build = self.read_text("build.sh")
        source = 'PRIVACY_MANIFEST_SOURCE="Resources/PrivacyInfo.xcprivacy"'
        bundled = (
            'APP_PRIVACY_MANIFEST="${CONTENTS}/Resources/PrivacyInfo.xcprivacy"'
        )
        verify_source = (
            'python3 tools/verify-privacy-manifest.py "${PRIVACY_MANIFEST_SOURCE}"'
        )
        copy_manifest = (
            'cp "${PRIVACY_MANIFEST_SOURCE}" "${APP_PRIVACY_MANIFEST}"'
        )
        verify_bundle = (
            'python3 tools/verify-privacy-manifest.py "${APP_PRIVACY_MANIFEST}"'
        )
        compare = (
            'cmp -s "${PRIVACY_MANIFEST_SOURCE}" '
            '"${APP_PRIVACY_MANIFEST}"'
        )
        signing = 'codesign "${CODESIGN_ARGS[@]}"'

        for command in (
            source,
            bundled,
            verify_source,
            copy_manifest,
            verify_bundle,
            compare,
            signing,
        ):
            self.assertIn(command, build)
        self.assertLess(build.index(verify_source), build.index(copy_manifest))
        self.assertLess(build.index(copy_manifest), build.index(verify_bundle))
        self.assertLess(build.index(verify_bundle), build.index(compare))
        self.assertLess(build.index(compare), build.index(signing))

    def test_make_dmg_verifies_source_and_app_before_staging(self):
        make_dmg = self.read_text("tools/make-dmg.sh")
        source = 'PRIVACY_MANIFEST_SOURCE="Resources/PrivacyInfo.xcprivacy"'
        bundled = (
            'APP_PRIVACY_MANIFEST="${APP}/Contents/Resources/PrivacyInfo.xcprivacy"'
        )
        verify_source = (
            'python3 tools/verify-privacy-manifest.py "${PRIVACY_MANIFEST_SOURCE}"'
        )
        verify_bundle = (
            'python3 tools/verify-privacy-manifest.py "${APP_PRIVACY_MANIFEST}"'
        )
        compare = (
            'cmp -s "${PRIVACY_MANIFEST_SOURCE}" '
            '"${APP_PRIVACY_MANIFEST}"'
        )
        staging = 'echo "==> Staging in ${STAGING}"'

        for command in (
            source,
            bundled,
            verify_source,
            verify_bundle,
            compare,
            staging,
        ):
            self.assertIn(command, make_dmg)
        self.assertLess(make_dmg.index(verify_source), make_dmg.index(verify_bundle))
        self.assertLess(make_dmg.index(verify_bundle), make_dmg.index(compare))
        self.assertLess(make_dmg.index(compare), make_dmg.index(staging))

    def test_release_verifies_mounted_manifest_before_codesign_and_spctl(self):
        release = self.read_text("tools/release.sh")
        mounted = (
            'INSIDE_PRIVACY_MANIFEST="${INSIDE_APP}/Contents/Resources/'
            'PrivacyInfo.xcprivacy"'
        )
        verify_mounted = (
            'python3 tools/verify-privacy-manifest.py "${INSIDE_PRIVACY_MANIFEST}"'
        )
        compare = (
            'cmp -s "${PRIVACY_MANIFEST_SOURCE}" '
            '"${INSIDE_PRIVACY_MANIFEST}"'
        )
        codesign = 'codesign --verify --strict --verbose=2 "${INSIDE_APP}"'
        spctl = 'spctl --assess --type execute --verbose=2 "${INSIDE_APP}"'

        for command in (mounted, verify_mounted, compare, codesign, spctl):
            self.assertIn(command, release)
        mounted_index = release.index(mounted)
        self.assertGreater(mounted_index, release.index('INSIDE_APP="${MOUNT_POINT}'))
        self.assertLess(mounted_index, release.index(verify_mounted))
        self.assertLess(release.index(verify_mounted), release.index(compare))
        codesign_index = release.index(codesign, mounted_index)
        spctl_index = release.index(spctl, mounted_index)
        self.assertLess(release.index(compare), codesign_index)
        self.assertLess(codesign_index, spctl_index)


if __name__ == "__main__":
    unittest.main()
