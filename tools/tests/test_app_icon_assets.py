#!/usr/bin/env python3
import pathlib
import shutil
import subprocess
import tempfile
import unittest

from PIL import Image


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE_ICON = REPO_ROOT / "Resources" / "AppIcon.png"
BUNDLE_ICON = REPO_ROOT / "Resources" / "AppIcon.icns"
MAKE_ICON = REPO_ROOT / "tools" / "make-icon.sh"


class AppIconAssetTests(unittest.TestCase):
    def test_source_icon_preserves_transparent_corners(self):
        image = Image.open(SOURCE_ICON).convert("RGBA")

        self.assertEqual(image.getpixel((0, 0))[3], 0)
        self.assertEqual(image.getpixel((image.width - 1, 0))[3], 0)
        self.assertEqual(image.getpixel((0, image.height - 1))[3], 0)
        self.assertEqual(image.getpixel((image.width - 1, image.height - 1))[3], 0)
        self.assertEqual(image.getpixel((image.width // 2, image.height // 2))[3], 255)

    def test_committed_icns_preserves_alpha(self):
        result = subprocess.run(
            ["sips", "-g", "hasAlpha", str(BUNDLE_ICON)],
            text=True,
            capture_output=True,
            check=True,
        )

        self.assertIn("hasAlpha: yes", result.stdout)

    def test_make_icon_rejects_sources_without_alpha(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = pathlib.Path(tmp)
            (repo / "tools").mkdir()
            (repo / "Resources").mkdir()
            shutil.copy2(MAKE_ICON, repo / "tools" / "make-icon.sh")
            source = repo / "Resources" / "AppIcon.png"
            Image.new("RGB", (16, 16), (255, 255, 255)).save(source)

            result = subprocess.run(
                [str(repo / "tools" / "make-icon.sh")],
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source icon must preserve transparent corners", result.stderr)


if __name__ == "__main__":
    unittest.main()
