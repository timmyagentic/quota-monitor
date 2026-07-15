#!/usr/bin/env python3
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


def item(version=None):
    version_element = ""
    if version is not None:
        version_element = "<sparkle:version>{}</sparkle:version>".format(version)
    return "<item>{}</item>".format(version_element)


def appcast(*items, metadata=""):
    return (
        '<?xml version="1.0"?>'
        '<rss xmlns:sparkle="{}">'
        "<channel>{}{}</channel>"
        "</rss>"
    ).format(SPARKLE_NAMESPACE, metadata, "".join(items)).encode("utf-8")


class FakeResponse:
    def __init__(self, payload, chunk_size=None, final_url=None):
        self.payload = payload
        self.chunk_size = chunk_size
        self.final_url = final_url
        self.offset = 0
        self.read_sizes = []
        self.bytes_returned = 0

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def geturl(self):
        return self.final_url

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
        return FakeResponse(json.dumps({"tag_name": tag}).encode("utf-8"), chunk_size=2)

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

    def test_optional_bearer_is_sent_to_api_only_and_both_requests_are_gets(self):
        api_opener = RecordingOpener(self.api_response())
        feed_opener = RecordingOpener(FakeResponse(appcast(item("0.2.40")), chunk_size=3))

        result = CHECKER.check_remote(
            repo="timmyagentic/quota-monitor",
            feed_url="https://raw.githubusercontent.com/timmyagentic/quota-monitor/main/appcast.xml",
            max_bytes=100_000,
            token="secret-token",
            timeout=7,
            api_opener=api_opener,
            feed_opener=feed_opener,
        )

        self.assertEqual(result.release_version, "0.2.40")
        self.assertEqual(len(api_opener.calls), 1)
        self.assertEqual(len(feed_opener.calls), 1)
        api_request, api_timeout = api_opener.calls[0]
        feed_request, feed_timeout = feed_opener.calls[0]
        self.assertEqual(
            api_request.full_url,
            "https://api.github.com/repos/timmyagentic/quota-monitor/releases/latest",
        )
        self.assertEqual(api_request.get_method(), "GET")
        self.assertEqual(feed_request.get_method(), "GET")
        self.assertIsNone(api_request.data)
        self.assertIsNone(feed_request.data)
        self.assertEqual(api_request.get_header("Authorization"), "Bearer secret-token")
        self.assertIsNone(feed_request.get_header("Authorization"))
        self.assertEqual(api_request.get_header("Accept"), "application/vnd.github+json")
        self.assertEqual(api_request.get_header("X-github-api-version"), "2026-03-10")
        self.assertTrue(api_request.get_header("User-agent"))
        self.assertEqual(feed_request.get_header("Accept-encoding"), "identity")
        self.assertEqual(api_timeout, 7)
        self.assertEqual(feed_timeout, 7)

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


class CLITests(unittest.TestCase):
    def arguments(self, *extra):
        return [
            "--repo", "timmyagentic/quota-monitor",
            "--feed-url", "https://updates.example.test/appcast.xml",
            "--max-bytes", "100000",
        ] + list(extra)

    def test_success_is_one_compact_sorted_json_line(self):
        api_opener = RecordingOpener(FakeResponse(b'{"tag_name":"v0.2.40"}', chunk_size=1))
        payload = appcast(item("0.2.40"))
        feed_opener = RecordingOpener(FakeResponse(payload, chunk_size=1))
        stdout = io.StringIO()
        stderr = io.StringIO()

        status = CHECKER.main(
            self.arguments("--token-env", "TEST_GITHUB_TOKEN"),
            environ={"TEST_GITHUB_TOKEN": "secret-token"},
            stdout=stdout,
            stderr=stderr,
            api_opener=api_opener,
            feed_opener=feed_opener,
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
