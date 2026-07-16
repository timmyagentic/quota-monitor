#!/usr/bin/env python3
"""Verify the fixed production statistics service before a release."""

import argparse
import datetime as dt
import json
import math
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass


PRODUCTION_ORIGIN = "https://quota-monitor.timmyagentic.com"
PLAIN_HTTP_ORIGIN = "http://quota-monitor.timmyagentic.com"
USER_AGENT = "QuotaMonitor-version-statistics-release-probe/1"
MAX_RESPONSE_BYTES = 64 * 1024
READ_CHUNK_BYTES = 8 * 1024
DAILY_TOKEN = "AAAAAAAAAAAAAAAAAAAAAA"
SEMVER_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
RELEASE_KEYS = {"version", "filename", "size", "minimumSystemVersion"}
FAILURE_MESSAGE = "version statistics service check failed"


class ProbeError(Exception):
    """An expected argument, network, or production-contract failure."""


class ProbeArgumentParser(argparse.ArgumentParser):
    def __init__(self, *args, error_stream=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.error_stream = error_stream

    def error(self, _message):
        stream = sys.stderr if self.error_stream is None else self.error_stream
        self._print_message(FAILURE_MESSAGE + "\n", stream)
        raise SystemExit(2)


class RejectRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Return redirect responses to the probe instead of following them."""

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


@dataclass(frozen=True)
class ProbeResponse:
    status: int
    final_url: str
    headers: object
    body: bytes


def _positive_integer(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ProbeError("{} must be a positive integer".format(label))
    return value


def _positive_timeout(value):
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value <= 0
    ):
        raise ProbeError("timeout must be positive and finite")
    return float(value)


def _positive_integer_argument(value):
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError("must be an integer") from None
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def _positive_timeout_argument(value):
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError("must be a number") from None
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive and finite")
    return parsed


def _argument_parser(stderr=None):
    parser = ProbeArgumentParser(
        description="Check the production Quota Monitor version statistics service",
        error_stream=stderr,
    )
    parser.add_argument(
        "--timeout",
        type=_positive_timeout_argument,
        default=20.0,
        metavar="SECONDS",
    )
    parser.add_argument(
        "--attempts",
        type=_positive_integer_argument,
        default=3,
        metavar="N",
    )
    return parser


def read_bounded(response):
    """Stream at most 64 KiB plus the single overflow sentinel byte."""

    payload = bytearray()
    sentinel = MAX_RESPONSE_BYTES + 1
    while len(payload) < sentinel:
        requested = min(READ_CHUNK_BYTES, sentinel - len(payload))
        chunk = response.read(requested)
        if not chunk:
            break
        if not isinstance(chunk, (bytes, bytearray)):
            raise ProbeError("response returned non-byte data")
        payload.extend(chunk[:sentinel - len(payload)])
    if len(payload) > MAX_RESPONSE_BYTES:
        raise ProbeError("response exceeds byte ceiling")
    return bytes(payload)


def _header(headers, name):
    value = headers.get(name)
    if value is not None:
        return value
    try:
        items = headers.items()
    except AttributeError:
        return None
    normalized = name.casefold()
    for key, candidate in items:
        if str(key).casefold() == normalized:
            return candidate
    return None


def _status(response):
    status = getattr(response, "status", None)
    if status is None:
        status = response.getcode()
    if isinstance(status, bool) or not isinstance(status, int):
        raise ProbeError("response has no integer status")
    return status


def _final_url(response):
    try:
        value = response.geturl()
    except AttributeError:
        raise ProbeError("response has no final URL") from None
    if not isinstance(value, str):
        raise ProbeError("response has no final URL")
    return value


def _consume(response):
    try:
        return ProbeResponse(
            status=_status(response),
            final_url=_final_url(response),
            headers=response.headers,
            body=read_bounded(response),
        )
    finally:
        close = getattr(response, "close", None)
        if callable(close):
            close()


def _default_open(request, timeout):
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        RejectRedirectHandler(),
    )
    return opener.open(request, timeout=timeout)


def _fetch(request, timeout, attempts, opener, sleep):
    for attempt in range(attempts):
        try:
            try:
                raw_response = opener(request, timeout)
            except urllib.error.HTTPError as error:
                raw_response = error
            response = _consume(raw_response)
        except ProbeError:
            raise
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt + 1 < attempts:
                sleep(0.5 if attempt == 0 else 1.0)
                continue
            raise ProbeError("network attempts exhausted") from None

        if response.final_url != request.full_url:
            raise ProbeError("redirected response")
        if 500 <= response.status <= 599 and attempt + 1 < attempts:
            sleep(0.5 if attempt == 0 else 1.0)
            continue
        return response
    raise ProbeError("request attempts exhausted")


def _request(url, accept, method="GET", body=None):
    headers = {
        "Accept": accept,
        "Accept-Encoding": "identity",
        "User-Agent": USER_AGENT,
    }
    if body is not None:
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = str(len(body))
    return urllib.request.Request(
        url,
        data=body,
        headers=headers,
        method=method,
    )


def _exact_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProbeError("duplicate JSON key")
        result[key] = value
    return result


def _decode_release(body):
    try:
        document = json.loads(body.decode("utf-8"), object_pairs_hook=_exact_object)
    except ProbeError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ProbeError("invalid release JSON") from None
    if not isinstance(document, dict) or set(document) != RELEASE_KEYS:
        raise ProbeError("release JSON keys differ")

    version = document["version"]
    if not isinstance(version, str) or SEMVER_PATTERN.fullmatch(version) is None:
        raise ProbeError("invalid release version")
    if document["filename"] != "QuotaMonitor-{}.dmg".format(version):
        raise ProbeError("invalid release filename")
    size = document["size"]
    if (
        isinstance(size, bool)
        or not isinstance(size, int)
        or size < 1_000_000
        or size > (2**53) - 1
    ):
        raise ProbeError("invalid release size")
    if document["minimumSystemVersion"] != "14.0":
        raise ProbeError("invalid minimum system version")
    return document


def _yesterday(now):
    if not isinstance(now, dt.datetime) or now.tzinfo is None:
        raise ProbeError("now must be timezone-aware")
    today = now.astimezone(dt.timezone.utc).date()
    return (today - dt.timedelta(days=1)).isoformat()


def _daily_body(now):
    payload = {
        "schema": 1,
        "day": _yesterday(now),
        "token": DAILY_TOKEN,
        "version": "0.0.0",
        "brand": "quota-monitor",
        "channel": "developer-id",
    }
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _require_status(response, status):
    if response.status != status:
        raise ProbeError("unexpected status")


def run_probe(now=None, timeout=20.0, attempts=3, opener=None, sleep=None):
    resolved_timeout = _positive_timeout(timeout)
    resolved_attempts = _positive_integer(attempts, "attempts")
    instant = dt.datetime.now(dt.timezone.utc) if now is None else now
    open_request = _default_open if opener is None else opener
    wait = time.sleep if sleep is None else sleep
    if not callable(wait):
        raise ProbeError("sleep must be callable")

    root = _fetch(
        _request(PLAIN_HTTP_ORIGIN + "/", "text/html"),
        resolved_timeout,
        resolved_attempts,
        open_request,
        wait,
    )
    _require_status(root, 301)
    if _header(root.headers, "Location") != PRODUCTION_ORIGIN + "/":
        raise ProbeError("unexpected HTTPS redirect")

    release = _fetch(
        _request(PRODUCTION_ORIGIN + "/api/release", "application/json"),
        resolved_timeout,
        resolved_attempts,
        open_request,
        wait,
    )
    _require_status(release, 200)
    content_type = _header(release.headers, "Content-Type")
    if (
        not isinstance(content_type, str)
        or content_type.split(";", 1)[0].strip().lower() != "application/json"
    ):
        raise ProbeError("release response is not JSON")
    _decode_release(release.body)

    dashboard = _fetch(
        _request(PRODUCTION_ORIGIN + "/maintainer/versions", "text/html"),
        resolved_timeout,
        resolved_attempts,
        open_request,
        wait,
    )
    _require_status(dashboard, 401)
    if _header(dashboard.headers, "WWW-Authenticate") != (
        'Basic realm="Quota Monitor version statistics"'
    ):
        raise ProbeError("unexpected authentication challenge")
    if _header(dashboard.headers, "Cache-Control") != "private, no-store":
        raise ProbeError("dashboard cache policy differs")
    if _header(dashboard.headers, "Vary") != "Authorization":
        raise ProbeError("dashboard vary policy differs")

    body = _daily_body(instant)
    daily = _fetch(
        _request(
            PRODUCTION_ORIGIN + "/api/v1/daily-active",
            "application/json",
            method="POST",
            body=body,
        ),
        resolved_timeout,
        resolved_attempts,
        open_request,
        wait,
    )
    _require_status(daily, 409)
    if _header(daily.headers, "Cache-Control") != "no-store":
        raise ProbeError("daily-active cache policy differs")
    if daily.body != b"":
        raise ProbeError("daily-active response is not empty")

    return {"checks": 4, "status": "ok"}


def main(argv=None, stdout=None, stderr=None, opener=None, now=None, sleep=None):
    output = sys.stdout if stdout is None else stdout
    error_output = sys.stderr if stderr is None else stderr
    try:
        arguments = _argument_parser(stderr=error_output).parse_args(argv)
        instant = None if now is None else now()
        result = run_probe(
            now=instant,
            timeout=arguments.timeout,
            attempts=arguments.attempts,
            opener=opener,
            sleep=sleep,
        )
    except Exception:
        error_output.write(FAILURE_MESSAGE + "\n")
        return 1

    output.write(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
