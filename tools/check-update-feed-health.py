#!/usr/bin/env python3
"""Check that a GitHub Release and its Sparkle feed agree.

The checker performs two read-only GET requests: GitHub's latest-release API
and the configured Appcast URL. It never creates or modifies releases, tags,
branches, feeds, or local files.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree
from dataclasses import asdict, dataclass


SPARKLE_VERSION_TAG = (
    "{http://www.andymatuschak.org/xml-namespaces/sparkle}version"
)
GITHUB_API_VERSION = "2026-03-10"
USER_AGENT = "QuotaMonitor-update-feed-health/1"
RELEASE_JSON_MAX_BYTES = 1_000_000
READ_CHUNK_BYTES = 64 * 1024


class FeedHealthError(Exception):
    """Expected network, parsing, or release/feed policy failure."""


@dataclass(frozen=True)
class FeedHealth:
    release_version: str
    appcast_version: str
    appcast_bytes: int


class RejectRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Reject API redirects so an Authorization header cannot cross origins."""

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


def _positive_integer(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise FeedHealthError("{} must be a positive integer".format(label))
    return value


def _positive_timeout(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
        raise FeedHealthError("timeout must be positive")
    return value


def normalize_version(value, label):
    if not isinstance(value, str):
        raise FeedHealthError("{} must be a string".format(label))
    normalized = value.strip()
    if normalized.startswith("v"):
        normalized = normalized[1:]
    if not normalized:
        raise FeedHealthError("{} is empty after normalization".format(label))
    return normalized


def parse_top_appcast_version(payload: bytes) -> str:
    """Return the normalized version from the first direct channel item."""

    if not isinstance(payload, (bytes, bytearray)):
        raise FeedHealthError("Appcast payload must be bytes")
    try:
        root = ElementTree.fromstring(bytes(payload))
    except (ElementTree.ParseError, ValueError) as error:
        raise FeedHealthError("Appcast XML is malformed: {}".format(error)) from None

    if root.tag != "rss":
        raise FeedHealthError("Appcast root must be rss")
    channel = root.find("./channel")
    if channel is None:
        raise FeedHealthError("Appcast rss has no direct channel")
    first_item = channel.find("./item")
    if first_item is None:
        raise FeedHealthError("Appcast channel has no direct item")
    version_element = first_item.find("./" + SPARKLE_VERSION_TAG)
    if version_element is None:
        raise FeedHealthError("Appcast first direct item has no Sparkle version")
    return normalize_version(version_element.text or "", "Appcast first item version")


def validate_health(release_tag: str, appcast: bytes, max_bytes: int) -> FeedHealth:
    maximum = _positive_integer(max_bytes, "max_bytes")
    if not isinstance(appcast, (bytes, bytearray)):
        raise FeedHealthError("Appcast payload must be bytes")
    appcast_size = len(appcast)
    if appcast_size > maximum:
        raise FeedHealthError(
            "Appcast payload is {} bytes and exceeds the {}-byte ceiling".format(
                appcast_size,
                maximum,
            )
        )

    release_version = normalize_version(release_tag, "GitHub release tag")
    appcast_version = parse_top_appcast_version(appcast)
    if release_version != appcast_version:
        raise FeedHealthError(
            "GitHub release {} does not match Appcast {}".format(
                release_version,
                appcast_version,
            )
        )
    return FeedHealth(
        release_version=release_version,
        appcast_version=appcast_version,
        appcast_bytes=appcast_size,
    )


def read_bounded(response, limit, label):
    """Read through short chunks while retaining no more than limit + 1."""

    maximum = _positive_integer(limit, "{} byte limit".format(label))
    payload = bytearray()
    sentinel_size = maximum + 1
    while len(payload) < sentinel_size:
        requested = min(READ_CHUNK_BYTES, sentinel_size - len(payload))
        chunk = response.read(requested)
        if not chunk:
            break
        if not isinstance(chunk, (bytes, bytearray)):
            raise FeedHealthError("{} response returned non-byte data".format(label))
        payload.extend(chunk[:sentinel_size - len(payload)])

    if len(payload) > maximum:
        raise FeedHealthError(
            "{} payload exceeds the {}-byte ceiling".format(label, maximum)
        )
    return bytes(payload)


def _validated_repo(repo):
    if not isinstance(repo, str):
        raise FeedHealthError("repo must use OWNER/REPO form")
    parts = repo.strip().split("/")
    if len(parts) != 2 or not parts[0] or not parts[1]:
        raise FeedHealthError("repo must use OWNER/REPO form")
    if any(character.isspace() for character in parts[0] + parts[1]):
        raise FeedHealthError("repo must not contain whitespace")
    return parts[0], parts[1]


def _validated_feed_url(feed_url):
    if not isinstance(feed_url, str):
        raise FeedHealthError("feed URL must be HTTPS")
    try:
        parsed = urllib.parse.urlsplit(feed_url)
        parsed.port
    except ValueError as error:
        raise FeedHealthError("feed URL is invalid: {}".format(error)) from None
    if parsed.scheme != "https" or not parsed.hostname:
        raise FeedHealthError("feed URL must be HTTPS with a host")
    if parsed.username is not None or parsed.password is not None:
        raise FeedHealthError("feed URL must not contain user information")
    return feed_url


def _redacted_message(value, token=None):
    message = str(value)
    if token:
        message = message.replace(token, "<redacted>")
    return " ".join(message.splitlines())


def _network_error(label, error, token=None):
    if isinstance(error, urllib.error.HTTPError):
        detail = "HTTP {} {}".format(error.code, error.reason)
    elif isinstance(error, urllib.error.URLError):
        detail = str(error.reason)
    else:
        detail = str(error)
    return FeedHealthError(
        "{} request failed: {}".format(label, _redacted_message(detail, token))
    )


def _default_api_opener(request, timeout):
    opener = urllib.request.build_opener(RejectRedirectHandler())
    return opener.open(request, timeout=timeout)


def _default_feed_opener(request, timeout):
    return urllib.request.urlopen(request, timeout=timeout)


def fetch_latest_release_tag(repo, token=None, timeout=20, opener=None):
    owner, repository = _validated_repo(repo)
    resolved_timeout = _positive_timeout(timeout)
    owner_path = urllib.parse.quote(owner, safe="")
    repo_path = urllib.parse.quote(repository, safe="")
    url = "https://api.github.com/repos/{}/{}/releases/latest".format(
        owner_path,
        repo_path,
    )
    headers = {
        "Accept": "application/vnd.github+json",
        "Accept-Encoding": "identity",
        "User-Agent": USER_AGENT,
        "X-GitHub-Api-Version": GITHUB_API_VERSION,
    }
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(url, headers=headers, method="GET")
    open_request = opener or _default_api_opener

    try:
        with open_request(request, resolved_timeout) as response:
            payload = read_bounded(
                response,
                RELEASE_JSON_MAX_BYTES,
                "GitHub latest release",
            )
    except FeedHealthError:
        raise
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError) as error:
        raise _network_error("GitHub latest release", error, token) from None

    try:
        decoded = payload.decode("utf-8")
        document = json.loads(decoded)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise FeedHealthError(
            "GitHub latest release response is invalid JSON: {}".format(error)
        ) from None
    if not isinstance(document, dict):
        raise FeedHealthError("GitHub latest release response must be a JSON object")
    tag = document.get("tag_name")
    if not isinstance(tag, str):
        raise FeedHealthError("GitHub latest release response has no string tag_name")
    if not tag.strip():
        raise FeedHealthError("GitHub latest release tag_name is empty")
    return tag


def fetch_feed(feed_url, max_bytes, timeout=20, opener=None):
    resolved_url = _validated_feed_url(feed_url)
    maximum = _positive_integer(max_bytes, "max_bytes")
    resolved_timeout = _positive_timeout(timeout)
    request = urllib.request.Request(
        resolved_url,
        headers={
            "Accept": "application/xml, text/xml;q=0.9, */*;q=0.1",
            "Accept-Encoding": "identity",
            "User-Agent": USER_AGENT,
        },
        method="GET",
    )
    open_request = opener or _default_feed_opener
    try:
        with open_request(request, resolved_timeout) as response:
            return read_bounded(response, maximum, "Appcast")
    except FeedHealthError:
        raise
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError) as error:
        raise _network_error("Appcast", error) from None


def check_remote(
    repo,
    feed_url,
    max_bytes,
    token=None,
    timeout=20,
    api_opener=None,
    feed_opener=None,
):
    _validated_repo(repo)
    _validated_feed_url(feed_url)
    _positive_integer(max_bytes, "max_bytes")
    _positive_timeout(timeout)

    release_tag = fetch_latest_release_tag(
        repo,
        token=token,
        timeout=timeout,
        opener=api_opener,
    )
    appcast = fetch_feed(
        feed_url,
        max_bytes=max_bytes,
        timeout=timeout,
        opener=feed_opener,
    )
    return validate_health(release_tag, appcast, max_bytes)


def _positive_integer_argument(value):
    try:
        parsed = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("must be an integer") from None
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def _positive_timeout_argument(value):
    try:
        parsed = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("must be a number") from None
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def _argument_parser():
    parser = argparse.ArgumentParser(
        description="Check GitHub latest-release and Sparkle Appcast parity"
    )
    parser.add_argument("--repo", required=True, metavar="OWNER/REPO")
    parser.add_argument("--feed-url", required=True, metavar="HTTPS_URL")
    parser.add_argument(
        "--max-bytes",
        required=True,
        type=_positive_integer_argument,
        metavar="N",
    )
    parser.add_argument("--token-env", default="GITHUB_TOKEN", metavar="NAME")
    parser.add_argument(
        "--timeout",
        default=20.0,
        type=_positive_timeout_argument,
        metavar="SECONDS",
    )
    return parser


def main(
    argv=None,
    environ=None,
    stdout=None,
    stderr=None,
    api_opener=None,
    feed_opener=None,
):
    arguments = _argument_parser().parse_args(argv)
    environment = os.environ if environ is None else environ
    output = sys.stdout if stdout is None else stdout
    error_output = sys.stderr if stderr is None else stderr
    token = environment.get(arguments.token_env)

    try:
        health = check_remote(
            repo=arguments.repo,
            feed_url=arguments.feed_url,
            max_bytes=arguments.max_bytes,
            token=token,
            timeout=arguments.timeout,
            api_opener=api_opener,
            feed_opener=feed_opener,
        )
    except FeedHealthError as error:
        message = _redacted_message(error, token)
        error_output.write("error: {}\n".format(message))
        return 1

    json.dump(
        asdict(health),
        output,
        separators=(",", ":"),
        sort_keys=True,
    )
    output.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
