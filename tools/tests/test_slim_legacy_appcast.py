#!/usr/bin/env python3
import importlib.util
import io
import os
import pathlib
import stat
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ElementTree


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "tools" / "slim-legacy-appcast.py"
MODULE_NAME = "slim_legacy_appcast"
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE_VERSION = "{{{}}}version".format(SPARKLE_NAMESPACE)
SPARKLE_SHORT_VERSION = "{{{}}}shortVersionString".format(SPARKLE_NAMESPACE)
SPARKLE_SIGNATURE = "{{{}}}edSignature".format(SPARKLE_NAMESPACE)


def load_slimmer():
    if not SCRIPT.is_file():
        return None
    spec = importlib.util.spec_from_file_location(MODULE_NAME, SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[MODULE_NAME] = module
    spec.loader.exec_module(module)
    return module


SLIMMER = load_slimmer()


def legacy_fixture(newline="\r\n"):
    channel_description = (
        "    <description><![CDATA[Channel <b>description</b> stays exact]]>"
        "</description>" + newline
    )
    first_description = (
        "      <description xml:lang=\"en\"><![CDATA["
        + ("A" * 4096)
        + " literal </description> and <item></item> stay inside CDATA"
        + "]]></description>"
        + newline
    )
    second_description = (
        "      <description xml:lang=\"zh-Hans\"><![CDATA["
        + ("中" * 4096)
        + "]]></description>"
        + newline
    )
    plain_description = (
        "      <description xml:lang=\"plain\">Keep &amp; preserve me"
        "</description>" + newline
    )
    payload = "".join(
        (
            '<?xml version="1.0" encoding="UTF-8"?>', newline,
            '<rss xmlns:sparkle="{}">'.format(SPARKLE_NAMESPACE), newline,
            "  <channel>", newline,
            channel_description,
            "    <item>", newline,
            "      <title>CodexMonitor 0.2.40</title>", newline,
            "      <pubDate>Wed, 15 Jul 2026 00:00:00 +0000</pubDate>", newline,
            "      <sparkle:version>0.2.40</sparkle:version>", newline,
            "      <sparkle:shortVersionString>0.2.40</sparkle:shortVersionString>", newline,
            "      <sparkle:releaseNotesLink>https://example.test/0.2.40.html"
            "</sparkle:releaseNotesLink>", newline,
            first_description,
            "      <enclosure url=\"https://example.test/CodexMonitor-0.2.40.dmg\" "
            "type=\"application/octet-stream\" length=\"4040\" "
            "sparkle:edSignature=\"signature-040\" />", newline,
            "    </item>", newline,
            "    <item>", newline,
            "      <title>CodexMonitor 0.2.39</title>", newline,
            "      <pubDate>Tue, 14 Jul 2026 00:00:00 +0000</pubDate>", newline,
            "      <sparkle:version>0.2.39</sparkle:version>", newline,
            "      <sparkle:shortVersionString>0.2.39</sparkle:shortVersionString>", newline,
            second_description,
            plain_description,
            "      <enclosure url=\"https://example.test/CodexMonitor-0.2.39.dmg\" "
            "type=\"application/octet-stream\" length=\"3939\" "
            "sparkle:edSignature=\"signature-039\" />", newline,
            "    </item>", newline,
            "  </channel>", newline,
            "</rss>", newline,
        )
    )
    return payload, channel_description, first_description, second_description, plain_description


def item_fingerprint(payload):
    root = ElementTree.fromstring(payload)
    channel = root.find("./channel")
    return tuple(
        (
            item.find("./" + SPARKLE_VERSION).text,
            item.find("./" + SPARKLE_SHORT_VERSION).text,
            item.find("./enclosure").get("url"),
            item.find("./enclosure").get("type"),
            item.find("./enclosure").get("length"),
            item.find("./enclosure").get(SPARKLE_SIGNATURE),
        )
        for item in channel.findall("./item")
    )


class SlimmerAvailabilityTests(unittest.TestCase):
    def test_slimmer_tool_exists(self):
        self.assertTrue(SCRIPT.is_file(), "expected tools/slim-legacy-appcast.py")


@unittest.skipIf(SLIMMER is None, "production slimmer is intentionally missing during RED")
class SlimFeedTests(unittest.TestCase):
    def test_comment_outside_items_is_preserved_byte_for_byte(self):
        protected_comment = (
            "    <!-- template <item><description><![CDATA[comment payload]]>"
            "</description></item> stays exact -->\r\n"
        )
        real_description = (
            "      <description><![CDATA[real payload]]></description>\r\n"
        )
        payload = "".join(
            (
                '<?xml version="1.0" encoding="UTF-8"?>\r\n',
                "<rss>\r\n",
                "  <channel>\r\n",
                protected_comment,
                "    <item>\r\n",
                real_description,
                "    </item>\r\n",
                "  </channel>\r\n",
                "</rss>\r\n",
            )
        )
        expected = payload.replace(real_description, "")

        result = SLIMMER.slim_feed(payload)

        self.assertEqual(result.count(protected_comment), 1)
        self.assertEqual(result, expected)

    def test_comment_inside_item_is_preserved_byte_for_byte(self):
        protected_comment = (
            "      <!-- template <description><![CDATA[comment payload]]>"
            "</description> stays exact -->\n"
        )
        real_description = (
            "      <description><![CDATA[real payload]]></description>\n"
        )
        payload = "".join(
            (
                "<rss>\n",
                "  <channel>\n",
                "    <item>\n",
                protected_comment,
                real_description,
                "    </item>\n",
                "  </channel>\n",
                "</rss>\n",
            )
        )
        expected = payload.replace(real_description, "")

        result = SLIMMER.slim_feed(payload)

        self.assertEqual(result.count(protected_comment), 1)
        self.assertEqual(result, expected)

    def test_processing_instruction_markup_is_preserved_byte_for_byte(self):
        protected_instruction = (
            '    <?audit template="<item><description><![CDATA[PI payload]]>'
            '</description></item>"?>\n'
        )
        real_description = (
            "      <description><![CDATA[real payload]]></description>\n"
        )
        payload = "".join(
            (
                "<rss>\n",
                "  <channel>\n",
                protected_instruction,
                "    <item>\n",
                real_description,
                "    </item>\n",
                "  </channel>\n",
                "</rss>\n",
            )
        )
        expected = payload.replace(real_description, "")

        result = SLIMMER.slim_feed(payload)

        self.assertEqual(result.count(protected_instruction), 1)
        self.assertEqual(result, expected)

    def test_channel_cdata_markup_is_preserved_byte_for_byte(self):
        protected_cdata = (
            "    <description><![CDATA[template <item><description>plain payload"
            "</description></item> stays exact]]></description>\n"
        )
        real_description = (
            "      <description><![CDATA[real payload]]></description>\n"
        )
        payload = "".join(
            (
                "<rss>\n",
                "  <channel>\n",
                protected_cdata,
                "    <item>\n",
                real_description,
                "    </item>\n",
                "  </channel>\n",
                "</rss>\n",
            )
        )
        expected = payload.replace(real_description, "")

        result = SLIMMER.slim_feed(payload)

        self.assertEqual(result.count(protected_cdata), 1)
        self.assertEqual(result, expected)

    def test_cdata_description_with_nested_comment_is_not_removed(self):
        protected_description = (
            "      <description><!-- retain exact -->"
            "<![CDATA[real payload]]></description>\n"
        )
        payload = "".join(
            (
                "<rss>\n",
                "  <channel>\n",
                "    <item>\n",
                protected_description,
                "    </item>\n",
                "  </channel>\n",
                "</rss>\n",
            )
        )

        result = SLIMMER.slim_feed(payload)

        self.assertEqual(result, payload)

    def test_internal_dtd_entity_is_preserved_byte_for_byte(self):
        declaration = (
            '<!DOCTYPE rss [<!ENTITY sample "<item><description><![CDATA[fake]]>'
            '</description></item>">]>\n'
        )
        payload = (
            declaration
            + "<rss><channel><item><description><![CDATA[real]]></description>"
            "</item></channel></rss>\n"
        )
        expected = declaration + "<rss><channel><item></item></channel></rss>\n"

        result = SLIMMER.slim_feed(payload)

        self.assertEqual(result, expected)

    def test_complete_doctype_internal_subset_is_preserved_byte_for_byte(self):
        declaration = "".join(
            (
                "<!DOCTYPE rss [\n",
                '  <!ENTITY punctuation "keep > [ ] exact">\n',
                "  <!ENTITY sample '<item><description><![CDATA[fake]]>"
                "</description></item> > [ ]'>\n",
                "  <!-- keep > [ ] <item><description><![CDATA[comment fake]]>"
                "</description></item> exact -->\n",
                "  <?audit keep=\"> [ ] <item><description><![CDATA[PI fake]]>"
                "</description></item>\"?>\n",
                "]>\n",
            )
        )
        real_description = (
            "      <description><![CDATA[real]]></description>\n"
        )
        payload = "".join(
            (
                declaration,
                "<rss>\n",
                "  <channel>\n",
                "    <item>\n",
                real_description,
                "    </item>\n",
                "  </channel>\n",
                "</rss>\n",
            )
        )
        expected = payload.replace(real_description, "")

        result = SLIMMER.slim_feed(payload)

        self.assertEqual(result, expected)

    def test_only_item_cdata_descriptions_are_removed_byte_for_byte(self):
        payload, channel, first, second, plain = legacy_fixture()
        expected = payload.replace(first, "").replace(second, "")

        result = SLIMMER.slim_feed(payload)

        self.assertEqual(result, expected)
        self.assertIn(channel, result)
        self.assertIn(plain, result)
        self.assertEqual(item_fingerprint(result), item_fingerprint(payload))
        self.assertEqual(
            item_fingerprint(result),
            (
                (
                    "0.2.40",
                    "0.2.40",
                    "https://example.test/CodexMonitor-0.2.40.dmg",
                    "application/octet-stream",
                    "4040",
                    "signature-040",
                ),
                (
                    "0.2.39",
                    "0.2.39",
                    "https://example.test/CodexMonitor-0.2.39.dmg",
                    "application/octet-stream",
                    "3939",
                    "signature-039",
                ),
            ),
        )
        ElementTree.fromstring(result)

    def test_second_pass_and_no_match_are_identical(self):
        payload, _, first, second, _ = legacy_fixture(newline="\n")
        slimmed = SLIMMER.slim_feed(payload)

        self.assertEqual(SLIMMER.slim_feed(slimmed), slimmed)
        no_cdata = payload.replace(first, "").replace(second, "")
        self.assertEqual(SLIMMER.slim_feed(no_cdata), no_cdata)

    def test_malformed_xml_is_rejected_before_transformation(self):
        with self.assertRaises(SLIMMER.SlimFeedError):
            SLIMMER.slim_feed("<rss><channel>")


@unittest.skipIf(SLIMMER is None, "production slimmer is intentionally missing during RED")
class SlimmerCLITests(unittest.TestCase):
    def run_main(self, arguments):
        stdout = io.StringIO()
        stderr = io.StringIO()
        status = SLIMMER.main(arguments, stdout=stdout, stderr=stderr)
        return status, stdout.getvalue(), stderr.getvalue()

    def test_invalid_utf8_and_malformed_xml_do_not_truncate_input(self):
        cases = (b"\xff\xfe", b"<rss><channel>")
        for contents in cases:
            with self.subTest(contents=contents):
                with tempfile.TemporaryDirectory() as directory:
                    path = pathlib.Path(directory) / "appcast.xml"
                    path.write_bytes(contents)

                    status, stdout, stderr = self.run_main([str(path), "--in-place"])

                    self.assertEqual(status, 1)
                    self.assertEqual(stdout, "")
                    self.assertRegex(stderr, r"^error: .+\n$")
                    self.assertEqual(path.read_bytes(), contents)

    def test_same_path_requires_in_place_and_different_output_is_incompatible(self):
        payload = legacy_fixture()[0].encode("utf-8")
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "appcast.xml"
            other = pathlib.Path(directory) / "other.xml"
            source.write_bytes(payload)

            status, stdout, stderr = self.run_main([str(source), str(source)])
            self.assertEqual(status, 1)
            self.assertEqual(stdout, "")
            self.assertIn("--in-place", stderr)
            self.assertEqual(source.read_bytes(), payload)

            status, stdout, stderr = self.run_main(
                [str(source), str(other), "--in-place"]
            )
            self.assertEqual(status, 1)
            self.assertEqual(stdout, "")
            self.assertIn("different output", stderr)
            self.assertFalse(other.exists())
            self.assertEqual(source.read_bytes(), payload)

    def test_in_place_write_uses_atomic_same_directory_replace(self):
        payload, _, first, second, _ = legacy_fixture()
        expected = payload.replace(first, "").replace(second, "").encode("utf-8")
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "appcast.xml"
            source.write_bytes(payload.encode("utf-8"))
            source.chmod(0o640)
            real_replace = os.replace
            with mock.patch.object(
                SLIMMER.os,
                "replace",
                wraps=real_replace,
            ) as replace:
                status, stdout, stderr = self.run_main([str(source), "--in-place"])

            self.assertEqual(status, 0)
            self.assertEqual(stdout, "")
            self.assertEqual(stderr, "")
            self.assertEqual(source.read_bytes(), expected)
            self.assertEqual(stat.S_IMODE(source.stat().st_mode), 0o640)
            replace.assert_called_once()
            temporary, destination = replace.call_args[0]
            self.assertEqual(pathlib.Path(temporary).parent, source.parent)
            self.assertEqual(pathlib.Path(destination), source)
            self.assertFalse(pathlib.Path(temporary).exists())

    def test_output_file_and_stdout_modes_preserve_the_input(self):
        payload, _, first, second, _ = legacy_fixture(newline="\n")
        expected = payload.replace(first, "").replace(second, "")
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "appcast.xml"
            output = pathlib.Path(directory) / "slim.xml"
            source.write_text(payload, encoding="utf-8", newline="")

            status, stdout, stderr = self.run_main([str(source), str(output)])
            self.assertEqual(status, 0)
            self.assertEqual(stdout, "")
            self.assertEqual(stderr, "")
            self.assertEqual(output.read_text(encoding="utf-8"), expected)
            self.assertEqual(source.read_text(encoding="utf-8"), payload)

            status, stdout, stderr = self.run_main([str(source)])
            self.assertEqual(status, 0)
            self.assertEqual(stdout, expected)
            self.assertEqual(stderr, "")
            self.assertEqual(source.read_text(encoding="utf-8"), payload)


if __name__ == "__main__":
    unittest.main()
