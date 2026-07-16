#!/usr/bin/env python3
import base64
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import sys
import unittest
import urllib.error
import urllib.request


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "tools" / "check-update-feed-health.py"
MODULE_NAME = "check_update_feed_health"
SPEC = importlib.util.spec_from_file_location(MODULE_NAME, SCRIPT)
CHECKER = importlib.util.module_from_spec(SPEC)
sys.modules[MODULE_NAME] = CHECKER
SPEC.loader.exec_module(CHECKER)

SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VALID_SIGNATURE = base64.b64encode(b"s" * 64).decode("ascii")
QUOTA_ASSET_URL = (
    "https://github.com/timmyagentic/quota-monitor/releases/download/"
    "v0.2.40/QuotaMonitor-0.2.40.dmg"
)
CODEX_ASSET_URL = (
    "https://github.com/timmyagentic/codex-monitor/releases/download/"
    "v0.2.40/CodexMonitor-0.2.40.dmg"
)
LEGACY_CODEX_ASSET_URL = (
    "https://github.com/systemoutprintlnnnn/codex-monitor/releases/download/"
    "v0.2.40/CodexMonitor-0.2.40.dmg"
)
LEGACY_CODEX_FEED_URL = (
    "https://raw.githubusercontent.com/systemoutprintlnnnn/"
    "codex-monitor/main/appcast.xml"
)
TRUSTED_CDN_URL = (
    "https://release-assets.githubusercontent.com/"
    "github-production-release-asset/123/example?download=1"
)


def item(
    version=None,
    *,
    enclosure=True,
    enclosure_url=QUOTA_ASSET_URL,
    length="6992960",
    signature=VALID_SIGNATURE,
):
    version_element = ""
    if version is not None:
        version_element = "<sparkle:version>{}</sparkle:version>".format(version)
    enclosure_element = ""
    if enclosure:
        attributes = []
        if enclosure_url is not None:
            attributes.append('url="{}"'.format(enclosure_url))
        if length is not None:
            attributes.append('length="{}"'.format(length))
        if signature is not None:
            attributes.append('sparkle:edSignature="{}"'.format(signature))
        enclosure_element = "<enclosure {} />".format(" ".join(attributes))
    return "<item>{}{}</item>".format(version_element, enclosure_element)


def appcast(*items, metadata=""):
    return (
        '<?xml version="1.0"?>'
        '<rss xmlns:sparkle="{}">'
        "<channel>{}{}</channel>"
        "</rss>"
    ).format(SPARKLE_NAMESPACE, metadata, "".join(items)).encode("utf-8")


def release_asset(
    *,
    name="QuotaMonitor-0.2.40.dmg",
    size=6_992_960,
    url=QUOTA_ASSET_URL,
):
    return {
        "name": name,
        "size": size,
        "browser_download_url": url,
    }


def release_payload(tag="v0.2.40", assets=None):
    if assets is None:
        assets = [release_asset()]
    return json.dumps({"tag_name": tag, "assets": assets}).encode("utf-8")


class FakeResponse:
    def __init__(
        self,
        payload,
        chunk_size=None,
        final_url=None,
        status=200,
        headers=None,
    ):
        self.payload = payload
        self.chunk_size = chunk_size
        self.final_url = final_url
        self.status = status
        self.headers = {} if headers is None else headers
        self.offset = 0
        self.read_sizes = []
        self.bytes_returned = 0

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def geturl(self):
        return self.final_url

    def getcode(self):
        return self.status

    def read(self, size=-1):
        self.read_sizes.append(size)
        if self.offset >= len(self.payload):
            return b""
        available = len(self.payload) - self.offset
        take = available if size is None or size < 0 else min(size, available)
        if self.chunk_size is not None:
            take = min(take, self.chunk_size)
        chunk = self.payload[self.offset:self.offset + take]
        self.offset += len(chunk)
        self.bytes_returned += len(chunk)
        return chunk


class RecordingOpener:
    def __init__(self, *results):
        self.results = list(results)
        self.calls = []

    def __call__(self, request, timeout):
        self.calls.append((request, timeout))
        if not self.results:
            raise AssertionError("unexpected network request")
        result = self.results.pop(0)
        if isinstance(result, BaseException):
            raise result
        if result.final_url is None:
            result.final_url = request.full_url
        return result


class FeedParserAndPolicyTests(unittest.TestCase):
    def test_nested_item_is_ignored_and_first_direct_item_wins(self):
        metadata = (
            "<metadata><item>"
            "<sparkle:version>9.9.9</sparkle:version>"
            "</item></metadata>"
        )
        payload = appcast(item("0.2.40"), item("0.2.41"), metadata=metadata)

        self.assertEqual(CHECKER.parse_top_appcast_version(payload), "0.2.40")

    def test_release_and_feed_versions_remove_one_leading_v(self):
        result = CHECKER.validate_health(
            "  v0.2.40  ",
            appcast(item(" v0.2.40 ")),
            100_000,
        )

        self.assertEqual(result.release_version, "0.2.40")
        self.assertEqual(result.appcast_version, "0.2.40")

    def test_malformed_and_empty_xml_fail(self):
        for payload in (b"", b"<rss>"):
            with self.subTest(payload=payload):
                with self.assertRaises(CHECKER.FeedHealthError):
                    CHECKER.parse_top_appcast_version(payload)

    def test_missing_rss_channel_and_item_fail(self):
        payloads = (
            b"<feed />",
            b"<rss />",
            b"<rss><channel /></rss>",
        )
        for payload in payloads:
            with self.subTest(payload=payload):
                with self.assertRaises(CHECKER.FeedHealthError):
                    CHECKER.parse_top_appcast_version(payload)

    def test_first_item_missing_version_fails_even_when_second_is_valid(self):
        payload = appcast(item(), item("0.2.40"))

        with self.assertRaisesRegex(CHECKER.FeedHealthError, "first.*version"):
            CHECKER.parse_top_appcast_version(payload)

    def test_wrong_sparkle_namespace_fails(self):
        payload = appcast(item("0.2.40")).replace(
            SPARKLE_NAMESPACE.encode("utf-8"),
            b"https://example.test/not-sparkle",
        )

        with self.assertRaises(CHECKER.FeedHealthError):
            CHECKER.parse_top_appcast_version(payload)

    def test_empty_normalized_release_or_feed_version_fails(self):
        cases = (
            ("v", appcast(item("0.2.40"))),
            ("v0.2.40", appcast(item(" v "))),
        )
        for release, payload in cases:
            with self.subTest(release=release):
                with self.assertRaises(CHECKER.FeedHealthError):
                    CHECKER.validate_health(release, payload, 100_000)

    def test_mismatch_fails_with_both_versions_in_diagnostic(self):
        with self.assertRaises(CHECKER.FeedHealthError) as raised:
            CHECKER.validate_health("v0.2.41", appcast(item("0.2.40")), 100_000)

        message = str(raised.exception)
        self.assertIn("0.2.41", message)
        self.assertIn("0.2.40", message)

    def test_payload_exactly_at_ceiling_succeeds(self):
        payload = appcast(item("0.2.40"))

        result = CHECKER.validate_health("v0.2.40", payload, len(payload))

        self.assertEqual(result.appcast_bytes, len(payload))

    def test_payload_one_byte_above_ceiling_fails(self):
        payload = appcast(item("0.2.40"))

        with self.assertRaisesRegex(CHECKER.FeedHealthError, "exceeds"):
            CHECKER.validate_health("v0.2.40", payload, len(payload) - 1)

    def test_nonpositive_ceiling_fails(self):
        for maximum in (0, -1):
            with self.subTest(maximum=maximum):
                with self.assertRaises(CHECKER.FeedHealthError):
                    CHECKER.validate_health("v0.2.40", appcast(item("0.2.40")), maximum)

    def test_successful_health_fields_are_exact(self):
        payload = appcast(item("0.2.40"))

        result = CHECKER.validate_health("v0.2.40", payload, 100_000)

        self.assertEqual(
            result,
            CHECKER.FeedHealth(
                release_version="0.2.40",
                appcast_version="0.2.40",
                appcast_bytes=len(payload),
            ),
        )


class AppcastEnclosurePolicyTests(unittest.TestCase):
    def assert_invalid_enclosure(self, item_xml, diagnostic):
        with self.assertRaisesRegex(CHECKER.FeedHealthError, diagnostic):
            CHECKER.validate_health(
                "v0.2.40",
                appcast(item_xml),
                100_000,
            )

    def test_first_item_requires_a_direct_enclosure(self):
        self.assert_invalid_enclosure(item("0.2.40", enclosure=False), "enclosure")
        nested = item("0.2.40", enclosure=False).replace(
            "</item>",
            "<metadata>{}</metadata></item>".format(
                item("0.2.40").split("<item>", 1)[1].split("</item>", 1)[0]
            ),
        )
        self.assert_invalid_enclosure(nested, "enclosure")

    def test_enclosure_url_must_be_credential_free_https(self):
        invalid_urls = (
            None,
            "",
            "http://github.com/example/project/releases/download/v1/App.dmg",
            "https://user:pass@github.com/example/project/releases/download/v1/App.dmg",
            "https:///App.dmg",
        )
        for url in invalid_urls:
            with self.subTest(url=url):
                self.assert_invalid_enclosure(
                    item("0.2.40", enclosure_url=url),
                    "enclosure URL",
                )

    def test_enclosure_length_must_be_a_positive_decimal_integer(self):
        for length in (None, "", "0", "-1", "1.5", "size", "9" * 5_000):
            with self.subTest(length=length):
                self.assert_invalid_enclosure(
                    item("0.2.40", length=length),
                    "length",
                )

    def test_enclosure_signature_must_decode_to_exactly_64_bytes(self):
        invalid_signatures = (
            None,
            "",
            "not-base64!",
            base64.b64encode(b"s" * 63).decode("ascii"),
            base64.b64encode(b"s" * 65).decode("ascii"),
            " " + VALID_SIGNATURE,
        )
        for signature in invalid_signatures:
            with self.subTest(signature=signature):
                self.assert_invalid_enclosure(
                    item("0.2.40", signature=signature),
                    "Ed25519|signature",
                )


class BoundedReadTests(unittest.TestCase):
    def test_short_reads_stop_after_limit_plus_one_bytes(self):
        response = FakeResponse(b"abcdefghi", chunk_size=1)

        with self.assertRaisesRegex(CHECKER.FeedHealthError, "exceeds"):
            CHECKER.read_bounded(response, 5, "feed")

        self.assertEqual(response.bytes_returned, 6)
        self.assertLessEqual(max(response.read_sizes), 6)

    def test_exact_limit_survives_repeated_short_reads(self):
        response = FakeResponse(b"abcde", chunk_size=1)

        payload = CHECKER.read_bounded(response, 5, "feed")

        self.assertEqual(payload, b"abcde")
        self.assertEqual(response.bytes_returned, 5)

    def test_latest_release_json_has_its_own_one_megabyte_bound(self):
        response = FakeResponse(b"x" * (CHECKER.RELEASE_JSON_MAX_BYTES + 10), chunk_size=7)
        opener = RecordingOpener(response)

        with self.assertRaisesRegex(CHECKER.FeedHealthError, "release.*exceeds"):
            CHECKER.fetch_latest_release_tag(
                "timmyagentic/quota-monitor",
                opener=opener,
            )

        self.assertEqual(response.bytes_returned, CHECKER.RELEASE_JSON_MAX_BYTES + 1)


class NetworkTests(unittest.TestCase):
    def api_response(self, tag="v0.2.40"):
        return FakeResponse(release_payload(tag), chunk_size=2)

    def test_malformed_json_and_missing_or_nonstring_tag_fail(self):
        payloads = (
            b"not-json",
            b"{}",
            b'{"tag_name":null}',
            b'{"tag_name":40}',
            b"\xff",
        )
        for payload in payloads:
            with self.subTest(payload=payload):
                with self.assertRaises(CHECKER.FeedHealthError):
                    CHECKER.fetch_latest_release_tag(
                        "timmyagentic/quota-monitor",
                        opener=RecordingOpener(FakeResponse(payload, chunk_size=1)),
                    )

    def test_optional_bearer_is_sent_to_api_only_and_all_requests_are_gets(self):
        api_opener = RecordingOpener(self.api_response())
        feed_opener = RecordingOpener(FakeResponse(appcast(item("0.2.40")), chunk_size=3))
        asset_response = FakeResponse(
            b"x",
            final_url=TRUSTED_CDN_URL,
            status=206,
            headers={"Content-Range": "bytes 0-0/6992960"},
        )
        asset_opener = RecordingOpener(asset_response)

        result = CHECKER.check_remote(
            repo="timmyagentic/quota-monitor",
            feed_url="https://raw.githubusercontent.com/timmyagentic/quota-monitor/main/appcast.xml",
            max_bytes=100_000,
            token="secret-token",
            timeout=7,
            api_opener=api_opener,
            feed_opener=feed_opener,
            asset_opener=asset_opener,
        )

        self.assertEqual(result.release_version, "0.2.40")
        self.assertEqual(len(api_opener.calls), 1)
        self.assertEqual(len(feed_opener.calls), 1)
        self.assertEqual(len(asset_opener.calls), 1)
        api_request, api_timeout = api_opener.calls[0]
        feed_request, feed_timeout = feed_opener.calls[0]
        asset_request, asset_timeout = asset_opener.calls[0]
        self.assertEqual(
            api_request.full_url,
            "https://api.github.com/repos/timmyagentic/quota-monitor/releases/latest",
        )
        self.assertEqual(api_request.get_method(), "GET")
        self.assertEqual(feed_request.get_method(), "GET")
        self.assertEqual(asset_request.get_method(), "GET")
        self.assertIsNone(api_request.data)
        self.assertIsNone(feed_request.data)
        self.assertIsNone(asset_request.data)
        self.assertEqual(api_request.get_header("Authorization"), "Bearer secret-token")
        self.assertIsNone(feed_request.get_header("Authorization"))
        self.assertIsNone(asset_request.get_header("Authorization"))
        self.assertIsNone(asset_request.get_header("Cookie"))
        self.assertEqual(asset_request.get_header("Range"), "bytes=0-0")
        self.assertEqual(api_request.get_header("Accept"), "application/vnd.github+json")
        self.assertEqual(api_request.get_header("X-github-api-version"), "2026-03-10")
        self.assertTrue(api_request.get_header("User-agent"))
        self.assertEqual(feed_request.get_header("Accept-encoding"), "identity")
        self.assertEqual(api_timeout, 7)
        self.assertEqual(feed_timeout, 7)
        self.assertEqual(asset_timeout, 7)
        self.assertEqual(asset_response.read_sizes, [2])
        self.assertEqual(asset_response.bytes_returned, 1)

    def test_absent_token_creates_no_authorization_header(self):
        opener = RecordingOpener(self.api_response())

        tag = CHECKER.fetch_latest_release_tag(
            "timmyagentic/quota-monitor",
            token=None,
            opener=opener,
        )

        self.assertEqual(tag, "v0.2.40")
        self.assertIsNone(opener.calls[0][0].get_header("Authorization"))

    def test_authenticated_api_redirects_are_rejected(self):
        handler = CHECKER.RejectRedirectHandler()
        request = urllib.request.Request(
            "https://api.github.com/repos/timmyagentic/quota-monitor/releases/latest",
            headers={"Authorization": "Bearer secret-token"},
            method="GET",
        )

        redirected = handler.redirect_request(
            request,
            None,
            302,
            "Found",
            {},
            "https://evil.example.test/capture",
        )

        self.assertIsNone(redirected)

    def test_feed_reader_stops_at_ceiling_plus_one_with_short_chunks(self):
        response = FakeResponse(b"abcdefghi", chunk_size=1)

        with self.assertRaises(CHECKER.FeedHealthError):
            CHECKER.fetch_feed(
                "https://updates.example.test/appcast.xml",
                max_bytes=5,
                opener=RecordingOpener(response),
            )

        self.assertEqual(response.bytes_returned, 6)

    def test_http_url_and_timeout_errors_are_normalized_without_token_leakage(self):
        secret = "do-not-leak-this-token"
        errors = (
            urllib.error.HTTPError(
                "https://api.github.com/repos/example/project/releases/latest",
                503,
                "Service Unavailable " + secret,
                None,
                None,
            ),
            urllib.error.URLError("offline " + secret),
            TimeoutError("timed out " + secret),
        )
        for error in errors:
            with self.subTest(error=type(error).__name__):
                with self.assertRaises(CHECKER.FeedHealthError) as raised:
                    CHECKER.fetch_latest_release_tag(
                        "example/project",
                        token=secret,
                        opener=RecordingOpener(error),
                    )
                self.assertNotIn(secret, str(raised.exception))

    def test_feed_http_url_and_timeout_errors_are_normalized(self):
        errors = (
            urllib.error.HTTPError(
                "https://updates.example.test/appcast.xml",
                503,
                "Service Unavailable",
                None,
                None,
            ),
            urllib.error.URLError("offline"),
            TimeoutError("timed out"),
        )
        for error in errors:
            with self.subTest(error=type(error).__name__):
                with self.assertRaisesRegex(CHECKER.FeedHealthError, "Appcast request failed"):
                    CHECKER.fetch_feed(
                        "https://updates.example.test/appcast.xml",
                        max_bytes=100_000,
                        opener=RecordingOpener(error),
                    )

    def test_invalid_repo_feed_url_and_timeout_fail_before_network(self):
        cases = (
            {"repo": "owner", "feed_url": "https://updates.example.test/appcast.xml", "timeout": 20},
            {"repo": "owner/repo/extra", "feed_url": "https://updates.example.test/appcast.xml", "timeout": 20},
            {"repo": "owner/repo", "feed_url": "http://updates.example.test/appcast.xml", "timeout": 20},
            {"repo": "owner/repo", "feed_url": "https://user:pass@updates.example.test/appcast.xml", "timeout": 20},
            {"repo": "owner/repo", "feed_url": "https:///appcast.xml", "timeout": 20},
            {"repo": "owner/repo", "feed_url": "https://updates.example.test/appcast.xml", "timeout": 0},
        )
        for arguments in cases:
            with self.subTest(arguments=arguments):
                api_opener = RecordingOpener()
                feed_opener = RecordingOpener()
                with self.assertRaises(CHECKER.FeedHealthError):
                    CHECKER.check_remote(
                        max_bytes=100_000,
                        api_opener=api_opener,
                        feed_opener=feed_opener,
                        **arguments
                    )
                self.assertEqual(api_opener.calls, [])
                self.assertEqual(feed_opener.calls, [])


class ReleaseAssetMetadataTests(unittest.TestCase):
    def check(
        self,
        document,
        item_xml=None,
        repo="timmyagentic/quota-monitor",
        feed_url="https://updates.example.test/appcast.xml",
    ):
        if item_xml is None:
            item_xml = item("0.2.40")
        return CHECKER.check_remote(
            repo=repo,
            feed_url=feed_url,
            max_bytes=100_000,
            api_opener=RecordingOpener(
                FakeResponse(json.dumps(document).encode("utf-8"))
            ),
            feed_opener=RecordingOpener(FakeResponse(appcast(item_xml))),
            asset_opener=RecordingOpener(
                FakeResponse(
                    b"x",
                    final_url=TRUSTED_CDN_URL,
                    status=206,
                    headers={"Content-Range": "bytes 0-0/6993358"},
                )
            ),
        )

    def test_legacy_installed_feed_owner_can_reference_the_canonical_release_asset(self):
        result = self.check(
            {
                "tag_name": "v0.2.40",
                "assets": [
                    release_asset(
                        name="CodexMonitor-0.2.40.dmg",
                        size=6_993_358,
                        url=CODEX_ASSET_URL,
                    )
                ],
            },
            item(
                "0.2.40",
                enclosure_url=LEGACY_CODEX_ASSET_URL,
                length="6993358",
            ),
            repo="timmyagentic/codex-monitor",
            feed_url=LEGACY_CODEX_FEED_URL,
        )

        self.assertEqual(result.release_version, "0.2.40")

    def test_legacy_feed_rejects_an_enclosure_from_an_unrelated_owner(self):
        with self.assertRaisesRegex(CHECKER.FeedHealthError, "canonical asset"):
            self.check(
                {
                    "tag_name": "v0.2.40",
                    "assets": [
                        release_asset(
                            name="CodexMonitor-0.2.40.dmg",
                            size=6_993_358,
                            url=CODEX_ASSET_URL,
                        )
                    ],
                },
                item(
                    "0.2.40",
                    enclosure_url=(
                        "https://github.com/unrelated/codex-monitor/releases/"
                        "download/v0.2.40/CodexMonitor-0.2.40.dmg"
                    ),
                    length="6993358",
                ),
                repo="timmyagentic/codex-monitor",
                feed_url=LEGACY_CODEX_FEED_URL,
            )

    def test_arbitrary_raw_feed_cannot_create_a_legacy_enclosure_alias(self):
        attacker_asset_url = (
            "https://github.com/attacker/codex-monitor/releases/download/"
            "v0.2.40/CodexMonitor-0.2.40.dmg"
        )
        with self.assertRaisesRegex(CHECKER.FeedHealthError, "canonical asset"):
            self.check(
                {
                    "tag_name": "v0.2.40",
                    "assets": [
                        release_asset(
                            name="CodexMonitor-0.2.40.dmg",
                            size=6_993_358,
                            url=CODEX_ASSET_URL,
                        )
                    ],
                },
                item(
                    "0.2.40",
                    enclosure_url=attacker_asset_url,
                    length="6993358",
                ),
                repo="timmyagentic/codex-monitor",
                feed_url=(
                    "https://raw.githubusercontent.com/attacker/"
                    "codex-monitor/main/appcast.xml"
                ),
            )

    def test_latest_release_requires_an_assets_array(self):
        documents = (
            {"tag_name": "v0.2.40"},
            {"tag_name": "v0.2.40", "assets": None},
            {"tag_name": "v0.2.40", "assets": {}},
            {"tag_name": "v0.2.40", "assets": []},
        )
        for document in documents:
            with self.subTest(document=document):
                with self.assertRaisesRegex(CHECKER.FeedHealthError, "asset"):
                    self.check(document)

    def test_latest_release_rejects_malformed_asset_metadata(self):
        malformed_assets = (
            "asset",
            {},
            {"name": "QuotaMonitor-0.2.40.dmg", "size": 6_992_960},
            {
                "name": "QuotaMonitor-0.2.40.dmg",
                "size": "6992960",
                "browser_download_url": QUOTA_ASSET_URL,
            },
        )
        for asset in malformed_assets:
            with self.subTest(asset=asset):
                with self.assertRaisesRegex(CHECKER.FeedHealthError, "asset"):
                    self.check({"tag_name": "v0.2.40", "assets": [asset]})

    def test_latest_release_must_contain_the_enclosure_asset(self):
        with self.assertRaisesRegex(CHECKER.FeedHealthError, "asset"):
            self.check(
                {
                    "tag_name": "v0.2.40",
                    "assets": [
                        release_asset(
                            name="QuotaMonitor-0.2.40.dmg.sha256",
                            size=90,
                            url=QUOTA_ASSET_URL + ".sha256",
                        )
                    ],
                }
            )

    def test_release_asset_name_url_and_size_must_exactly_match_enclosure(self):
        cases = (
            release_asset(name="Other.dmg"),
            release_asset(url=QUOTA_ASSET_URL.replace("QuotaMonitor", "Other")),
            release_asset(size=6_992_959),
        )
        for asset in cases:
            with self.subTest(asset=asset):
                with self.assertRaisesRegex(
                    CHECKER.FeedHealthError,
                    "filename|URL|size|length|asset",
                ):
                    self.check({"tag_name": "v0.2.40", "assets": [asset]})

    def test_enclosure_url_must_use_the_requested_repo_and_exact_release_tag(self):
        cases = (
            QUOTA_ASSET_URL.replace("timmyagentic", "other-owner"),
            QUOTA_ASSET_URL.replace("v0.2.40", "v0.2.39"),
        )
        for url in cases:
            with self.subTest(url=url):
                with self.assertRaisesRegex(
                    CHECKER.FeedHealthError,
                    "repo|tag|URL|asset",
                ):
                    self.check(
                        {
                            "tag_name": "v0.2.40",
                            "assets": [release_asset(url=url)],
                        },
                        item("0.2.40", enclosure_url=url),
                    )


class ReleaseAssetProbeTests(unittest.TestCase):
    def check(
        self,
        asset_response,
        *,
        repo="timmyagentic/quota-monitor",
        feed_url="https://updates.example.test/appcast.xml",
        asset=None,
        item_xml=None,
        token="api-token",
    ):
        if asset is None:
            asset = release_asset()
        if item_xml is None:
            item_xml = item("0.2.40")
        asset_opener = RecordingOpener(asset_response)
        result = CHECKER.check_remote(
            repo=repo,
            feed_url=feed_url,
            max_bytes=100_000,
            token=token,
            timeout=9,
            api_opener=RecordingOpener(
                FakeResponse(release_payload(assets=[asset]))
            ),
            feed_opener=RecordingOpener(FakeResponse(appcast(item_xml))),
            asset_opener=asset_opener,
        )
        return result, asset_opener

    def partial_response(
        self,
        *,
        status=206,
        total=6_992_960,
        payload=b"x",
        final_url=TRUSTED_CDN_URL,
        content_range=None,
    ):
        if content_range is None:
            content_range = "bytes 0-0/{}".format(total)
        headers = {}
        if content_range is not False:
            headers["Content-Range"] = content_range
        return FakeResponse(
            payload,
            final_url=final_url,
            status=status,
            headers=headers,
        )

    def test_both_release_repositories_probe_the_exact_enclosure_asset(self):
        cases = (
            (
                "timmyagentic/quota-monitor",
                release_asset(),
                item("0.2.40"),
                6_992_960,
            ),
            (
                "timmyagentic/codex-monitor",
                release_asset(
                    name="CodexMonitor-0.2.40.dmg",
                    size=6_993_358,
                    url=CODEX_ASSET_URL,
                ),
                item(
                    "0.2.40",
                    enclosure_url=LEGACY_CODEX_ASSET_URL,
                    length="6993358",
                ),
                6_993_358,
                LEGACY_CODEX_FEED_URL,
            ),
        )
        for case in cases:
            repo, asset, item_xml, total, *feed_urls = case
            feed_url = feed_urls[0] if feed_urls else "https://updates.example.test/appcast.xml"
            with self.subTest(repo=repo):
                response = self.partial_response(total=total)
                result, opener = self.check(
                    response,
                    repo=repo,
                    feed_url=feed_url,
                    asset=asset,
                    item_xml=item_xml,
                )

                self.assertEqual(result.release_version, "0.2.40")
                self.assertEqual(len(opener.calls), 1)
                request, timeout = opener.calls[0]
                expected_probe_url = (
                    LEGACY_CODEX_ASSET_URL
                    if repo == "timmyagentic/codex-monitor"
                    else asset["browser_download_url"]
                )
                self.assertEqual(request.full_url, expected_probe_url)
                self.assertEqual(request.get_method(), "GET")
                self.assertEqual(request.get_header("Range"), "bytes=0-0")
                self.assertEqual(request.get_header("Accept-encoding"), "identity")
                for forbidden in ("Authorization", "Cookie", "Proxy-Authorization"):
                    self.assertIsNone(request.get_header(forbidden))
                self.assertEqual(timeout, 9)
                self.assertEqual(response.read_sizes, [2])
                self.assertEqual(response.bytes_returned, 1)

    def test_http_404_and_non_partial_200_are_rejected_without_reading_a_body(self):
        errors = (
            urllib.error.HTTPError(
                QUOTA_ASSET_URL,
                404,
                "Not Found",
                None,
                None,
            ),
            self.partial_response(status=200, payload=b"x" * 100_000),
        )
        for result in errors:
            with self.subTest(result=type(result).__name__):
                opener_result = result
                if isinstance(result, FakeResponse):
                    opener_result = result
                with self.assertRaisesRegex(
                    CHECKER.FeedHealthError,
                    "asset.*failed|206|partial",
                ):
                    self.check(opener_result)
                if isinstance(result, FakeResponse):
                    self.assertEqual(result.bytes_returned, 0)
                    self.assertEqual(result.read_sizes, [])

    def test_content_range_must_describe_exactly_one_byte_and_expected_total(self):
        invalid_headers = (
            False,
            "bytes 0-1/6992960",
            "bytes 1-1/6992960",
            "bytes 0-0/*",
            "bytes 0-0/6992959",
            "bytes 0-0/" + "9" * 5_000,
            "garbage",
        )
        for content_range in invalid_headers:
            with self.subTest(content_range=content_range):
                response = self.partial_response(content_range=content_range)
                with self.assertRaisesRegex(
                    CHECKER.FeedHealthError,
                    "Content-Range|length",
                ):
                    self.check(response)
                self.assertEqual(response.bytes_returned, 0)

    def test_partial_response_must_return_exactly_one_byte(self):
        for payload in (b"", b"xy"):
            with self.subTest(payload=payload):
                response = self.partial_response(payload=payload)

                with self.assertRaisesRegex(CHECKER.FeedHealthError, "one byte"):
                    self.check(response)

                self.assertEqual(response.read_sizes, [2])
                self.assertEqual(response.bytes_returned, len(payload))

    def test_final_asset_url_must_be_the_official_https_release_cdn(self):
        invalid_urls = (
            QUOTA_ASSET_URL,
            "http://release-assets.githubusercontent.com/path",
            "https://user@release-assets.githubusercontent.com/path",
            "https://release-assets.githubusercontent.com.evil.example/path",
            "https://evil.example/path",
        )
        for final_url in invalid_urls:
            with self.subTest(final_url=final_url):
                response = self.partial_response(final_url=final_url)
                with self.assertRaisesRegex(
                    CHECKER.FeedHealthError,
                    "redirect|final URL|CDN",
                ):
                    self.check(response)
                self.assertEqual(response.bytes_returned, 0)


class ReleaseAssetRedirectPolicyTests(unittest.TestCase):
    def source_request(self, **headers):
        safe_headers = {
            "Range": "bytes=0-0",
            "Accept": "application/octet-stream",
            "Accept-Encoding": "identity",
            "User-Agent": "test-agent",
        }
        safe_headers.update(headers)
        return urllib.request.Request(
            QUOTA_ASSET_URL,
            headers=safe_headers,
            method="GET",
        )

    def redirect(self, handler, request, target, code=302):
        return handler.redirect_request(
            request,
            None,
            code,
            "Found",
            {},
            target,
        )

    def test_one_exact_github_to_official_release_cdn_redirect_is_allowed(self):
        handler = CHECKER.ReleaseAssetRedirectHandler(QUOTA_ASSET_URL)

        redirected = self.redirect(handler, self.source_request(), TRUSTED_CDN_URL)

        self.assertIsNotNone(redirected)
        self.assertEqual(redirected.full_url, TRUSTED_CDN_URL)
        self.assertEqual(redirected.get_method(), "GET")
        self.assertEqual(redirected.get_header("Range"), "bytes=0-0")
        self.assertEqual(redirected.get_header("Accept-encoding"), "identity")
        for forbidden in ("Authorization", "Cookie", "Proxy-Authorization"):
            self.assertIsNone(redirected.get_header(forbidden))
        self.assertIsNone(
            self.redirect(handler, redirected, TRUSTED_CDN_URL + "&again=1")
        )

    def test_legacy_owner_allows_only_exact_canonical_then_official_cdn(self):
        handler = CHECKER.ReleaseAssetRedirectHandler(
            LEGACY_CODEX_ASSET_URL,
            CODEX_ASSET_URL,
        )
        source = urllib.request.Request(
            LEGACY_CODEX_ASSET_URL,
            headers={
                "Range": "bytes=0-0",
                "Accept-Encoding": "identity",
            },
            method="GET",
        )

        canonical = self.redirect(
            handler,
            source,
            CODEX_ASSET_URL,
            code=301,
        )
        self.assertIsNotNone(canonical)
        self.assertEqual(canonical.full_url, CODEX_ASSET_URL)

        direct_cdn_handler = CHECKER.ReleaseAssetRedirectHandler(
            LEGACY_CODEX_ASSET_URL,
            CODEX_ASSET_URL,
        )
        self.assertIsNone(
            self.redirect(
                direct_cdn_handler,
                source,
                TRUSTED_CDN_URL,
                code=302,
            )
        )

        cdn = self.redirect(handler, canonical, TRUSTED_CDN_URL, code=302)
        self.assertIsNotNone(cdn)
        self.assertEqual(cdn.full_url, TRUSTED_CDN_URL)
        self.assertIsNone(
            self.redirect(handler, cdn, TRUSTED_CDN_URL + "&again=1", code=302)
        )

    def test_other_redirect_codes_origins_or_destinations_are_rejected(self):
        cases = (
            (301, self.source_request(), TRUSTED_CDN_URL),
            (
                302,
                urllib.request.Request(
                    QUOTA_ASSET_URL + "?changed=1",
                    headers={"Range": "bytes=0-0"},
                    method="GET",
                ),
                TRUSTED_CDN_URL,
            ),
            (302, self.source_request(), TRUSTED_CDN_URL.replace("https://", "http://")),
            (302, self.source_request(), "https://evil.example/asset"),
            (
                302,
                self.source_request(),
                "https://release-assets.githubusercontent.com.evil.example/asset",
            ),
            (
                302,
                self.source_request(),
                "https://user@release-assets.githubusercontent.com/asset",
            ),
        )
        for code, request, target in cases:
            with self.subTest(code=code, source=request.full_url, target=target):
                handler = CHECKER.ReleaseAssetRedirectHandler(QUOTA_ASSET_URL)
                self.assertIsNone(self.redirect(handler, request, target, code=code))

    def test_sensitive_source_headers_make_the_redirect_fail_closed(self):
        for header in ("Authorization", "Cookie", "Proxy-Authorization"):
            with self.subTest(header=header):
                handler = CHECKER.ReleaseAssetRedirectHandler(QUOTA_ASSET_URL)
                request = self.source_request(**{header: "secret"})
                self.assertIsNone(self.redirect(handler, request, TRUSTED_CDN_URL))


class DefaultNetworkPolicyTests(unittest.TestCase):
    def test_direct_opener_ignores_environment_proxy_discovery(self):
        original_getproxies = CHECKER.urllib.request.getproxies

        def unexpected_proxy_discovery():
            raise AssertionError("environment proxy discovery must stay disabled")

        CHECKER.urllib.request.getproxies = unexpected_proxy_discovery
        try:
            opener = CHECKER._direct_opener(CHECKER.RejectRedirectHandler())
        finally:
            CHECKER.urllib.request.getproxies = original_getproxies

        self.assertFalse(
            any(
                isinstance(handler, urllib.request.ProxyHandler)
                for handler in opener.handlers
            )
        )

    def test_api_and_feed_default_openers_reject_redirects(self):
        captured_handlers = []

        class StubOpener:
            def open(self, request, timeout):
                return request, timeout

        def capture(*handlers):
            captured_handlers.append(handlers)
            return StubOpener()

        original_direct_opener = CHECKER._direct_opener
        CHECKER._direct_opener = capture
        try:
            request = urllib.request.Request("https://example.test/source")
            CHECKER._default_api_opener(request, 3)
            CHECKER._default_feed_opener(request, 4)
        finally:
            CHECKER._direct_opener = original_direct_opener

        self.assertEqual(len(captured_handlers), 2)
        for handlers in captured_handlers:
            self.assertEqual(len(handlers), 1)
            self.assertIsInstance(handlers[0], CHECKER.RejectRedirectHandler)


class CLITests(unittest.TestCase):
    def arguments(self, *extra):
        return [
            "--repo", "timmyagentic/quota-monitor",
            "--feed-url", "https://updates.example.test/appcast.xml",
            "--max-bytes", "100000",
        ] + list(extra)

    def test_success_is_one_compact_sorted_json_line(self):
        api_opener = RecordingOpener(FakeResponse(release_payload(), chunk_size=1))
        payload = appcast(item("0.2.40"))
        feed_opener = RecordingOpener(FakeResponse(payload, chunk_size=1))
        asset_opener = RecordingOpener(
            FakeResponse(
                b"x",
                final_url=TRUSTED_CDN_URL,
                status=206,
                headers={"Content-Range": "bytes 0-0/6992960"},
            )
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        status = CHECKER.main(
            self.arguments("--token-env", "TEST_GITHUB_TOKEN"),
            environ={"TEST_GITHUB_TOKEN": "secret-token"},
            stdout=stdout,
            stderr=stderr,
            api_opener=api_opener,
            feed_opener=feed_opener,
            asset_opener=asset_opener,
        )

        expected = json.dumps(
            {
                "appcast_bytes": len(payload),
                "appcast_version": "0.2.40",
                "release_version": "0.2.40",
            },
            separators=(",", ":"),
            sort_keys=True,
        ) + "\n"
        self.assertEqual(status, 0)
        self.assertEqual(stdout.getvalue(), expected)
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(
            api_opener.calls[0][0].get_header("Authorization"),
            "Bearer secret-token",
        )

    def test_failure_leaves_stdout_empty_and_returns_one(self):
        stdout = io.StringIO()
        stderr = io.StringIO()

        status = CHECKER.main(
            self.arguments(),
            environ={},
            stdout=stdout,
            stderr=stderr,
            api_opener=RecordingOpener(FakeResponse(b"not-json")),
            feed_opener=RecordingOpener(),
        )

        self.assertEqual(status, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertRegex(stderr.getvalue(), r"^error: .+\n$")
        self.assertEqual(len(stderr.getvalue().splitlines()), 1)

    def test_argparse_rejects_nonpositive_maximum_and_timeout_with_status_two(self):
        cases = (
            self.arguments("--timeout", "0"),
            [
                "--repo", "timmyagentic/quota-monitor",
                "--feed-url", "https://updates.example.test/appcast.xml",
                "--max-bytes", "0",
            ],
        )
        for arguments in cases:
            with self.subTest(arguments=arguments):
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as raised:
                        CHECKER.main(arguments, environ={})
                self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
