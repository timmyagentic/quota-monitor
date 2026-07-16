#!/usr/bin/env python3
import datetime as dt
import http.client
import importlib.util
import io
import json
import pathlib
import sys
import unittest
import urllib.error
from unittest import mock


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "tools" / "check-version-statistics-service.py"
MODULE_NAME = "check_version_statistics_service"
SPEC = importlib.util.spec_from_file_location(MODULE_NAME, SCRIPT)
CHECKER = importlib.util.module_from_spec(SPEC)
sys.modules[MODULE_NAME] = CHECKER
SPEC.loader.exec_module(CHECKER)


class FakeResponse:
    def __init__(
        self,
        status,
        body=b"",
        headers=None,
        final_url=None,
        chunk_size=None,
    ):
        self.status = status
        self.body = body
        self.headers = headers or {}
        self.final_url = final_url
        self.chunk_size = chunk_size
        self.offset = 0
        self.read_sizes = []
        self.bytes_returned = 0
        self.close_calls = 0
        self.closed = False

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def getcode(self):
        return self.status

    def geturl(self):
        return self.final_url

    def read(self, size=-1):
        self.read_sizes.append(size)
        if self.offset >= len(self.body):
            return b""
        available = len(self.body) - self.offset
        take = available if size is None or size < 0 else min(size, available)
        if self.chunk_size is not None:
            take = min(take, self.chunk_size)
        chunk = self.body[self.offset:self.offset + take]
        self.offset += len(chunk)
        self.bytes_returned += len(chunk)
        return chunk

    def close(self):
        self.close_calls += 1
        self.closed = True


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


def release_body(
    version="0.2.41",
    filename=None,
    size=8_000_000,
    minimum="14.0",
):
    return json.dumps(
        {
            "version": version,
            "filename": filename or "QuotaMonitor-{}.dmg".format(version),
            "size": size,
            "minimumSystemVersion": minimum,
        },
        separators=(",", ":"),
    ).encode("utf-8")


def root_response(**overrides):
    values = {
        "status": 301,
        "headers": {"Location": CHECKER.PRODUCTION_ORIGIN + "/"},
    }
    values.update(overrides)
    return FakeResponse(**values)


def release_response(**overrides):
    values = {
        "status": 200,
        "body": release_body(),
        "headers": {"Content-Type": "application/json"},
    }
    values.update(overrides)
    return FakeResponse(**values)


def dashboard_response(**overrides):
    values = {
        "status": 401,
        "headers": {
            "WWW-Authenticate": 'Basic realm="Quota Monitor version statistics"',
            "Cache-Control": "private, no-store",
            "Vary": "Authorization",
        },
    }
    values.update(overrides)
    return FakeResponse(**values)


def daily_response(**overrides):
    values = {
        "status": 409,
        "headers": {"Cache-Control": "no-store"},
    }
    values.update(overrides)
    return FakeResponse(**values)


def successful_opener(*prefix):
    return RecordingOpener(
        *prefix,
        root_response(),
        release_response(),
        dashboard_response(),
        daily_response(),
    )


class RequestContractTests(unittest.TestCase):
    def test_cross_year_yesterday_and_exact_request_sequence(self):
        opener = successful_opener()
        now = dt.datetime(2026, 1, 1, 0, 1, tzinfo=dt.timezone.utc)

        result = CHECKER.run_probe(now=now, timeout=7.5, attempts=2, opener=opener)

        self.assertEqual(result, {"checks": 4, "status": "ok"})
        self.assertEqual(len(opener.calls), 4)
        expected = (
            ("GET", "http://quota-monitor.timmyagentic.com/"),
            ("GET", CHECKER.PRODUCTION_ORIGIN + "/api/release"),
            ("GET", CHECKER.PRODUCTION_ORIGIN + "/maintainer/versions"),
            ("POST", CHECKER.PRODUCTION_ORIGIN + "/api/v1/daily-active"),
        )
        for (request, timeout), (method, url) in zip(opener.calls, expected):
            self.assertEqual(request.get_method(), method)
            self.assertEqual(request.full_url, url)
            self.assertEqual(timeout, 7.5)

        bodies = [request.data for request, _ in opener.calls]
        self.assertEqual(bodies[:3], [None, None, None])
        payload = json.loads(bodies[3].decode("utf-8"))
        self.assertEqual(
            payload,
            {
                "schema": 1,
                "day": "2025-12-31",
                "token": "AAAAAAAAAAAAAAAAAAAAAA",
                "version": "0.0.0",
                "brand": "quota-monitor",
                "channel": "developer-id",
            },
        )

    def test_headers_are_exact_and_never_carry_identity_or_credentials(self):
        opener = successful_opener()

        CHECKER.run_probe(
            now=dt.datetime(2026, 7, 16, 12, tzinfo=dt.timezone.utc),
            timeout=4,
            attempts=1,
            opener=opener,
        )

        headers = [
            {key.lower(): value for key, value in request.header_items()}
            for request, _ in opener.calls
        ]
        common = {
            "accept-encoding": "identity",
            "user-agent": CHECKER.USER_AGENT,
        }
        self.assertEqual(headers[0], {**common, "accept": "text/html"})
        self.assertEqual(headers[1], {**common, "accept": "application/json"})
        self.assertEqual(headers[2], {**common, "accept": "text/html"})
        post_body = opener.calls[3][0].data
        self.assertEqual(
            headers[3],
            {
                **common,
                "accept": "application/json",
                "content-type": "application/json",
                "content-length": str(len(post_body)),
            },
        )
        forbidden = {
            "authorization",
            "cookie",
            "cf-connecting-ip",
            "true-client-ip",
            "x-forwarded-for",
        }
        for request_headers in headers:
            self.assertTrue(forbidden.isdisjoint(request_headers))

    def test_post_retry_reuses_identical_body_bytes(self):
        first_post = FakeResponse(503, body=b"try later")
        opener = RecordingOpener(
            root_response(),
            release_response(),
            dashboard_response(),
            first_post,
            daily_response(),
        )

        CHECKER.run_probe(
            now=dt.datetime(2026, 7, 16, tzinfo=dt.timezone.utc),
            attempts=2,
            opener=opener,
            sleep=lambda _delay: None,
        )

        first_body = opener.calls[3][0].data
        second_body = opener.calls[4][0].data
        self.assertIs(first_body, second_body)
        self.assertEqual(first_body, second_body)

    def test_production_origin_is_fixed_and_run_probe_has_no_origin_parameter(self):
        import inspect

        self.assertEqual(
            CHECKER.PRODUCTION_ORIGIN,
            "https://quota-monitor.timmyagentic.com",
        )
        self.assertNotIn("origin", inspect.signature(CHECKER.run_probe).parameters)
        parser = CHECKER._argument_parser(stderr=io.StringIO())
        with self.assertRaises(SystemExit) as raised:
            parser.parse_args(["--origin", "https://example.test"])
        self.assertEqual(raised.exception.code, 2)

    def test_default_opener_disables_environment_proxies_and_redirects(self):
        built = mock.Mock()
        built.open.return_value = object()
        request = object()

        with mock.patch.object(
            CHECKER.urllib.request,
            "build_opener",
            return_value=built,
        ) as build_opener:
            result = CHECKER._default_open(request, 6.5)

        self.assertIs(result, built.open.return_value)
        built.open.assert_called_once_with(request, timeout=6.5)
        handlers = build_opener.call_args.args
        proxy_handlers = [
            handler
            for handler in handlers
            if isinstance(handler, CHECKER.urllib.request.ProxyHandler)
        ]
        redirect_handlers = [
            handler
            for handler in handlers
            if isinstance(handler, CHECKER.RejectRedirectHandler)
        ]
        self.assertEqual(len(proxy_handlers), 1)
        self.assertEqual(proxy_handlers[0].proxies, {})
        self.assertEqual(len(redirect_handlers), 1)


class RedirectAndResponseContractTests(unittest.TestCase):
    def assert_probe_error(self, *responses):
        opener = RecordingOpener(*responses)
        with self.assertRaises(CHECKER.ProbeError):
            CHECKER.run_probe(
                now=dt.datetime(2026, 7, 16, tzinfo=dt.timezone.utc),
                attempts=1,
                opener=opener,
            )
        return opener

    def test_redirect_handler_refuses_every_redirect(self):
        handler = CHECKER.RejectRedirectHandler()
        self.assertIsNone(
            handler.redirect_request(None, None, 301, "Moved", {}, "https://evil.test")
        )

    def test_http_error_is_consumed_as_a_response_without_retry(self):
        url = CHECKER.PLAIN_HTTP_ORIGIN + "/"
        file_pointer = io.BytesIO(b"redirect response")
        error = urllib.error.HTTPError(
            url,
            301,
            "Moved Permanently",
            {"Location": CHECKER.PRODUCTION_ORIGIN + "/"},
            file_pointer,
        )
        opener = RecordingOpener(error)
        sleeps = []

        response = CHECKER._fetch(
            CHECKER._request(url, "text/html"),
            timeout=2,
            attempts=3,
            opener=opener,
            sleep=sleeps.append,
        )

        self.assertEqual(response.status, 301)
        self.assertEqual(response.body, b"redirect response")
        self.assertEqual(len(opener.calls), 1)
        self.assertEqual(sleeps, [])
        self.assertTrue(file_pointer.closed)

    def test_http_root_requires_exact_301_and_https_location(self):
        cases = (
            root_response(status=200),
            root_response(status=302),
            root_response(headers={}),
            root_response(headers={"Location": CHECKER.PRODUCTION_ORIGIN}),
            root_response(headers={"Location": "https://evil.test/"}),
        )
        for response in cases:
            with self.subTest(status=response.status, headers=response.headers):
                opener = self.assert_probe_error(response)
                self.assertEqual(len(opener.calls), 1)

    def test_changed_final_url_is_rejected_even_with_valid_status(self):
        opener = self.assert_probe_error(
            root_response(final_url=CHECKER.PRODUCTION_ORIGIN + "/"),
        )
        self.assertEqual(len(opener.calls), 1)

    def test_release_requires_exact_status_and_json_keys(self):
        extra = json.loads(release_body())
        extra["available"] = True
        cases = (
            release_response(status=201),
            release_response(body=json.dumps(extra).encode()),
            release_response(body=b"[]"),
            release_response(body=b"{}"),
        )
        for response in cases:
            with self.subTest(status=response.status, body=response.body):
                opener = self.assert_probe_error(root_response(), response)
                self.assertEqual(len(opener.calls), 2)

    def test_release_requires_json_content_type_and_allows_parameters(self):
        opener = RecordingOpener(
            root_response(),
            release_response(headers={"Content-Type": "application/json; charset=utf-8"}),
            dashboard_response(),
            daily_response(),
        )
        CHECKER.run_probe(
            now=dt.datetime(2026, 7, 16, tzinfo=dt.timezone.utc),
            attempts=1,
            opener=opener,
        )

        for content_type in (None, "text/json", "text/plain", "application/problem+json"):
            with self.subTest(content_type=content_type):
                headers = {} if content_type is None else {"Content-Type": content_type}
                rejected = self.assert_probe_error(
                    root_response(),
                    release_response(headers=headers),
                )
                self.assertEqual(len(rejected.calls), 2)

    def test_release_rejects_invalid_utf8_malformed_and_duplicate_json(self):
        duplicate = (
            b'{"version":"0.2.41","version":"0.2.42",'
            b'"filename":"QuotaMonitor-0.2.41.dmg","size":8000000,'
            b'"minimumSystemVersion":"14.0"}'
        )
        for body in (b"\xff", b"{", duplicate):
            with self.subTest(body=body):
                opener = self.assert_probe_error(
                    root_response(),
                    release_response(body=body),
                )
                self.assertEqual(len(opener.calls), 2)

    def test_release_enforces_strict_three_component_semver(self):
        invalid = (
            "1.2",
            "1.2.3.4",
            "v1.2.3",
            "01.2.3",
            "1.02.3",
            "1.2.03",
            "1.2.3-beta",
            " 1.2.3 ",
            True,
            123,
        )
        for version in invalid:
            with self.subTest(version=version):
                body = release_body()
                document = json.loads(body)
                document["version"] = version
                document["filename"] = "QuotaMonitor-{}.dmg".format(version)
                self.assert_probe_error(
                    root_response(),
                    release_response(body=json.dumps(document).encode()),
                )

    def test_release_filename_must_exactly_match_version(self):
        for filename in (
            "QuotaMonitor-0.2.40.dmg",
            "CodexMonitor-0.2.41.dmg",
            "QuotaMonitor-0.2.41.DMG",
            "../QuotaMonitor-0.2.41.dmg",
            True,
        ):
            with self.subTest(filename=filename):
                self.assert_probe_error(
                    root_response(),
                    release_response(body=release_body(filename=filename)),
                )

    def test_release_size_is_a_safe_bounded_non_boolean_integer(self):
        valid = (1_000_000, (2**53) - 1)
        invalid = (999_999, 2**53, True, False, 1_000_000.0, "8000000")
        for size in valid:
            with self.subTest(valid=size):
                opener = RecordingOpener(
                    root_response(),
                    release_response(body=release_body(size=size)),
                    dashboard_response(),
                    daily_response(),
                )
                CHECKER.run_probe(
                    now=dt.datetime(2026, 7, 16, tzinfo=dt.timezone.utc),
                    attempts=1,
                    opener=opener,
                )
        for size in invalid:
            with self.subTest(invalid=size):
                self.assert_probe_error(
                    root_response(),
                    release_response(body=release_body(size=size)),
                )

    def test_release_minimum_system_version_is_exact(self):
        for minimum in ("14", "14.0.0", "13.0", " 14.0 ", 14.0, True):
            with self.subTest(minimum=minimum):
                self.assert_probe_error(
                    root_response(),
                    release_response(body=release_body(minimum=minimum)),
                )

    def test_dashboard_requires_exact_private_basic_challenge(self):
        base = dashboard_response().headers
        cases = (
            dashboard_response(status=403),
            dashboard_response(headers={**base, "WWW-Authenticate": "Basic"}),
            dashboard_response(headers={**base, "Cache-Control": "no-store"}),
            dashboard_response(headers={**base, "Vary": "authorization"}),
            dashboard_response(headers={key: value for key, value in base.items() if key != "Vary"}),
        )
        for response in cases:
            with self.subTest(status=response.status, headers=response.headers):
                opener = self.assert_probe_error(
                    root_response(),
                    release_response(),
                    response,
                )
                self.assertEqual(len(opener.calls), 3)

    def test_daily_active_requires_exact_409_no_store_and_empty_body(self):
        cases = (
            daily_response(status=204),
            daily_response(status=400),
            daily_response(headers={}),
            daily_response(headers={"Cache-Control": "private, no-store"}),
            daily_response(body=b"{}"),
            daily_response(body=b"\n"),
        )
        for response in cases:
            with self.subTest(status=response.status, headers=response.headers, body=response.body):
                opener = self.assert_probe_error(
                    root_response(),
                    release_response(),
                    dashboard_response(),
                    response,
                )
                self.assertEqual(len(opener.calls), 4)


class BoundedReadTests(unittest.TestCase):
    def test_exact_64_kibibyte_body_is_accepted_with_short_reads(self):
        response = FakeResponse(
            200,
            body=b"x" * CHECKER.MAX_RESPONSE_BYTES,
            chunk_size=7,
        )

        payload = CHECKER.read_bounded(response)

        self.assertEqual(len(payload), CHECKER.MAX_RESPONSE_BYTES)
        self.assertEqual(response.bytes_returned, CHECKER.MAX_RESPONSE_BYTES)
        self.assertLessEqual(max(response.read_sizes), CHECKER.READ_CHUNK_BYTES)

    def test_64_kibibytes_plus_one_is_rejected_without_reading_more(self):
        response = FakeResponse(
            200,
            body=b"x" * (CHECKER.MAX_RESPONSE_BYTES + 100),
            chunk_size=11,
        )

        with self.assertRaises(CHECKER.ProbeError):
            CHECKER.read_bounded(response)

        self.assertEqual(response.bytes_returned, CHECKER.MAX_RESPONSE_BYTES + 1)

    def test_non_bytes_read_is_rejected(self):
        class BadResponse:
            def read(self, _size):
                return "not bytes"

        with self.assertRaises(CHECKER.ProbeError):
            CHECKER.read_bounded(BadResponse())

    def test_every_consumed_response_is_closed_once(self):
        responses = (
            root_response(),
            release_response(),
            dashboard_response(),
            daily_response(),
        )
        opener = RecordingOpener(*responses)

        CHECKER.run_probe(
            now=dt.datetime(2026, 7, 16, tzinfo=dt.timezone.utc),
            attempts=1,
            opener=opener,
        )

        for response in responses:
            self.assertTrue(response.closed)
            self.assertEqual(response.close_calls, 1)


class RetryTests(unittest.TestCase):
    def run_with(self, *responses, attempts=3):
        opener = RecordingOpener(*responses)
        sleeps = []
        result = CHECKER.run_probe(
            now=dt.datetime(2026, 7, 16, tzinfo=dt.timezone.utc),
            attempts=attempts,
            opener=opener,
            sleep=sleeps.append,
        )
        return result, opener, sleeps

    def test_network_failure_retries_then_continues_in_order(self):
        result, opener, sleeps = self.run_with(
            urllib.error.URLError("private-host-192.0.2.1"),
            root_response(),
            release_response(),
            dashboard_response(),
            daily_response(),
        )

        self.assertEqual(result["status"], "ok")
        self.assertEqual([call[0].full_url for call in opener.calls[:2]], [
            "http://quota-monitor.timmyagentic.com/",
            "http://quota-monitor.timmyagentic.com/",
        ])
        self.assertEqual(sleeps, [0.5])

    def test_timeout_and_oserror_are_retryable(self):
        for error in (TimeoutError("detail"), OSError("detail")):
            with self.subTest(error=type(error).__name__):
                result, opener, sleeps = self.run_with(
                    error,
                    root_response(),
                    release_response(),
                    dashboard_response(),
                    daily_response(),
                )
                self.assertEqual(result["status"], "ok")
                self.assertEqual(len(opener.calls), 5)
                self.assertEqual(sleeps, [0.5])

    def test_http_protocol_failures_are_retryable_network_errors(self):
        failures = (
            http.client.IncompleteRead(b"partial", 10),
            http.client.BadStatusLine("invalid status line"),
            http.client.LineTooLong("header line"),
        )
        for failure in failures:
            with self.subTest(error=type(failure).__name__):
                result, opener, sleeps = self.run_with(
                    failure,
                    root_response(),
                    release_response(),
                    dashboard_response(),
                    daily_response(),
                )
                self.assertEqual(result["status"], "ok")
                self.assertEqual(len(opener.calls), 5)
                self.assertEqual(sleeps, [0.5])

    def test_5xx_retries_and_honors_attempt_limit(self):
        result, opener, sleeps = self.run_with(
            FakeResponse(503, body=b"first"),
            root_response(),
            release_response(),
            dashboard_response(),
            daily_response(),
        )
        self.assertEqual(result["status"], "ok")
        self.assertEqual(len(opener.calls), 5)
        self.assertEqual(sleeps, [0.5])

        exhausted = RecordingOpener(FakeResponse(500), FakeResponse(502), FakeResponse(503))
        exhausted_sleeps = []
        with self.assertRaises(CHECKER.ProbeError):
            CHECKER.run_probe(
                now=dt.datetime(2026, 7, 16, tzinfo=dt.timezone.utc),
                attempts=3,
                opener=exhausted,
                sleep=exhausted_sleeps.append,
            )
        self.assertEqual(len(exhausted.calls), 3)
        self.assertEqual(exhausted_sleeps, [0.5, 1.0])

    def test_mixed_network_and_5xx_retries_use_capped_backoff(self):
        result, opener, sleeps = self.run_with(
            FakeResponse(503),
            urllib.error.URLError("temporary"),
            root_response(),
            release_response(),
            dashboard_response(),
            daily_response(),
            attempts=3,
        )

        self.assertEqual(result["status"], "ok")
        self.assertEqual(len(opener.calls), 6)
        self.assertEqual(sleeps, [0.5, 1.0])

    def test_429_and_other_non_5xx_statuses_never_retry(self):
        for status in (301, 400, 401, 409, 429):
            with self.subTest(status=status):
                opener = RecordingOpener(FakeResponse(status))
                sleeps = []
                with self.assertRaises(CHECKER.ProbeError):
                    CHECKER.run_probe(
                        now=dt.datetime(2026, 7, 16, tzinfo=dt.timezone.utc),
                        attempts=3,
                        opener=opener,
                        sleep=sleeps.append,
                    )
                self.assertEqual(len(opener.calls), 1)
                self.assertEqual(sleeps, [])

    def test_contract_failure_never_retries(self):
        opener = RecordingOpener(
            root_response(),
            release_response(body=b"not-json"),
            release_response(),
        )
        sleeps = []
        with self.assertRaises(CHECKER.ProbeError):
            CHECKER.run_probe(
                now=dt.datetime(2026, 7, 16, tzinfo=dt.timezone.utc),
                attempts=3,
                opener=opener,
                sleep=sleeps.append,
            )
        self.assertEqual(len(opener.calls), 2)
        self.assertEqual(sleeps, [])


class CLITests(unittest.TestCase):
    def test_positive_timeout_and_attempts_are_accepted(self):
        opener = successful_opener()
        stdout = io.StringIO()
        stderr = io.StringIO()

        code = CHECKER.main(
            ["--timeout", "2.5", "--attempts", "4"],
            stdout=stdout,
            stderr=stderr,
            opener=opener,
            now=lambda: dt.datetime(2026, 7, 16, tzinfo=dt.timezone.utc),
        )

        self.assertEqual(code, 0)
        self.assertEqual(
            stdout.getvalue(),
            '{"checks":4,"status":"ok"}\n',
        )
        self.assertEqual(stderr.getvalue(), "")

    def test_invalid_arguments_use_argparse_exit_two_with_one_generic_line(self):
        cases = (
            ["--timeout", "0"],
            ["--timeout", "nan"],
            ["--attempts", "0"],
            ["--attempts", "1.5"],
            ["--origin", "https://example.test"],
            ["unexpected"],
        )
        for argv in cases:
            with self.subTest(argv=argv):
                stdout = io.StringIO()
                stderr = io.StringIO()
                with self.assertRaises(SystemExit) as raised:
                    CHECKER.main(argv, stdout=stdout, stderr=stderr)
                self.assertEqual(raised.exception.code, 2)
                self.assertEqual(stdout.getvalue(), "")
                self.assertEqual(
                    stderr.getvalue(),
                    "version statistics service check failed\n",
                )

    def test_runtime_failure_never_prints_request_or_exception_details(self):
        sensitive = (
            "AAAAAAAAAAAAAAAAAAAAAA Authorization Cookie "
            "192.0.2.88 private-header-value"
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        opener = RecordingOpener(urllib.error.URLError(sensitive))

        code = CHECKER.main(
            ["--attempts", "1"],
            stdout=stdout,
            stderr=stderr,
            opener=opener,
            now=lambda: dt.datetime(2026, 7, 16, tzinfo=dt.timezone.utc),
        )

        self.assertEqual(code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue().count("\n"), 1)
        for value in sensitive.split():
            self.assertNotIn(value, stderr.getvalue())

    def test_source_does_not_read_environment_or_offer_sensitive_parameters(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("import os", source)
        self.assertNotIn("os.environ", source)
        self.assertNotIn("VERSION_STATS_ADMIN_TOKEN", source)
        self.assertNotIn("--origin", source)
        self.assertNotIn("--token", source)
        self.assertNotIn("--header", source)


if __name__ == "__main__":
    unittest.main()
