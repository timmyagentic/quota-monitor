#!/usr/bin/env python3
"""Check that a GitHub Release and its Sparkle feed agree.

The checker performs three read-only request flows: GitHub's latest-release
API, the configured Appcast URL, and a one-byte Range probe for the newest DMG.
It never creates or modifies releases, tags, branches, feeds, or local files.
"""

import argparse
import base64
import binascii
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree
from dataclasses import asdict, dataclass


SPARKLE_VERSION_TAG = (
    "{http://www.andymatuschak.org/xml-namespaces/sparkle}version"
)
SPARKLE_SIGNATURE_ATTRIBUTE = (
    "{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"
)
GITHUB_API_VERSION = "2026-03-10"
USER_AGENT = "QuotaMonitor-update-feed-health/1"
RELEASE_JSON_MAX_BYTES = 1_000_000
READ_CHUNK_BYTES = 64 * 1024
DECIMAL_INTEGER_MAX_DIGITS = 20
ASSET_SAFE_HEADERS = (
    "Accept",
    "Accept-Encoding",
    "Range",
    "User-Agent",
)
ASSET_SENSITIVE_HEADERS = (
    "Authorization",
    "Cookie",
    "Proxy-Authorization",
)
LEGACY_INSTALLED_FEED_REPOSITORIES = {
    (
        "timmyagentic",
        "codex-monitor",
        "https://raw.githubusercontent.com/systemoutprintlnnnn/"
        "codex-monitor/main/appcast.xml",
    ): ("systemoutprintlnnnn", "codex-monitor"),
}


class FeedHealthError(Exception):
    """Expected network, parsing, or release/feed policy failure."""


@dataclass(frozen=True)
class FeedHealth:
    release_version: str
    appcast_version: str
    appcast_bytes: int


@dataclass(frozen=True)
class AppcastItem:
    version: str
    enclosure_url: str
    enclosure_length: int
    signature: str


@dataclass(frozen=True)
class ReleaseAsset:
    name: str
    size: int
    browser_download_url: str


@dataclass(frozen=True)
class LatestRelease:
    tag_name: str
    assets: tuple


class RejectRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Reject API redirects so an Authorization header cannot cross origins."""

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


def _request_header(request, name):
    expected = name.casefold()
    for header_name, value in request.header_items():
        if header_name.casefold() == expected:
            return value
    return None


class ReleaseAssetRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Default-deny redirect policy for an anonymous release-asset probe."""

    def __init__(self, source_url, canonical_url=None):
        super().__init__()
        self.source_url = source_url
        self.canonical_url = canonical_url or source_url
        self.current_url = source_url
        self.redirect_count = 0

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        if request.full_url != self.current_url or request.get_method() != "GET":
            return None
        if any(_request_header(request, name) is not None for name in ASSET_SENSITIVE_HEADERS):
            return None

        moves_to_canonical = (
            self.current_url == self.source_url
            and self.source_url != self.canonical_url
            and code == 301
            and new_url == self.canonical_url
        )
        moves_to_cdn = (
            self.current_url == self.canonical_url
            and code == 302
            and _is_official_release_cdn_url(new_url)
        )
        if not moves_to_canonical and not moves_to_cdn:
            return None
        if self.redirect_count >= 2:
            return None

        safe_headers = {}
        for name in ASSET_SAFE_HEADERS:
            value = _request_header(request, name)
            if value is not None:
                safe_headers[name] = value
        self.redirect_count += 1
        self.current_url = new_url
        return urllib.request.Request(
            new_url,
            headers=safe_headers,
            method="GET",
        )


def _is_official_release_cdn_url(url):
    if not isinstance(url, str):
        return False
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port
    except ValueError:
        return False
    return (
        parsed.scheme == "https"
        and parsed.hostname == "release-assets.githubusercontent.com"
        and port is None
        and parsed.username is None
        and parsed.password is None
        and not parsed.fragment
    )


def _positive_integer(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise FeedHealthError("{} must be a positive integer".format(label))
    return value


def _positive_decimal_integer(value, label):
    if (
        not isinstance(value, str)
        or not value
        or len(value) > DECIMAL_INTEGER_MAX_DIGITS
        or not value.isascii()
        or not value.isdigit()
    ):
        raise FeedHealthError("{} must be a positive decimal integer".format(label))
    parsed = int(value)
    if parsed <= 0:
        raise FeedHealthError("{} must be a positive decimal integer".format(label))
    return parsed


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


def parse_top_appcast_item(payload: bytes) -> AppcastItem:
    """Return validated update metadata from the first direct channel item."""
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
    version = normalize_version(version_element.text or "", "Appcast first item version")

    enclosure = first_item.find("./enclosure")
    if enclosure is None:
        raise FeedHealthError("Appcast first direct item has no direct enclosure")

    enclosure_url = enclosure.get("url")
    if not enclosure_url:
        raise FeedHealthError("Appcast enclosure URL is missing")
    try:
        parsed_url = urllib.parse.urlsplit(enclosure_url)
        parsed_url.port
    except ValueError as error:
        raise FeedHealthError("Appcast enclosure URL is invalid: {}".format(error)) from None
    if parsed_url.scheme != "https" or not parsed_url.hostname:
        raise FeedHealthError("Appcast enclosure URL must be HTTPS with a host")
    if parsed_url.username is not None or parsed_url.password is not None:
        raise FeedHealthError("Appcast enclosure URL must not contain user information")

    enclosure_length = _positive_decimal_integer(
        enclosure.get("length"),
        "Appcast enclosure length",
    )

    signature = enclosure.get(SPARKLE_SIGNATURE_ATTRIBUTE)
    if not signature:
        raise FeedHealthError("Appcast enclosure Ed25519 signature is missing")
    try:
        decoded_signature = base64.b64decode(signature, validate=True)
    except (binascii.Error, ValueError):
        raise FeedHealthError("Appcast enclosure Ed25519 signature is invalid base64") from None
    if len(decoded_signature) != 64:
        raise FeedHealthError(
            "Appcast enclosure Ed25519 signature must decode to exactly 64 bytes"
        )

    return AppcastItem(
        version=version,
        enclosure_url=enclosure_url,
        enclosure_length=enclosure_length,
        signature=signature,
    )


def parse_top_appcast_version(payload: bytes) -> str:
    """Return the normalized version from the first direct channel item."""

    return parse_top_appcast_item(payload).version


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


def _direct_opener(*handlers):
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        *handlers,
    )


def _default_api_opener(request, timeout):
    opener = _direct_opener(RejectRedirectHandler())
    return opener.open(request, timeout=timeout)


def _default_feed_opener(request, timeout):
    opener = _direct_opener(RejectRedirectHandler())
    return opener.open(request, timeout=timeout)


def fetch_latest_release(repo, token=None, timeout=20, opener=None):
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

    raw_assets = document.get("assets")
    if not isinstance(raw_assets, list) or not raw_assets:
        raise FeedHealthError("GitHub latest release has no non-empty assets array")
    assets = []
    for index, raw_asset in enumerate(raw_assets):
        label = "GitHub latest release asset {}".format(index)
        if not isinstance(raw_asset, dict):
            raise FeedHealthError("{} must be a JSON object".format(label))
        name = raw_asset.get("name")
        if not isinstance(name, str) or not name:
            raise FeedHealthError("{} has no non-empty string name".format(label))
        size = raw_asset.get("size")
        if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
            raise FeedHealthError("{} size must be a positive integer".format(label))
        browser_download_url = raw_asset.get("browser_download_url")
        if not isinstance(browser_download_url, str) or not browser_download_url:
            raise FeedHealthError(
                "{} has no non-empty string browser_download_url".format(label)
            )
        try:
            parsed_asset_url = urllib.parse.urlsplit(browser_download_url)
            parsed_asset_url.port
        except ValueError as error:
            raise FeedHealthError("{} URL is invalid: {}".format(label, error)) from None
        if parsed_asset_url.scheme != "https" or not parsed_asset_url.hostname:
            raise FeedHealthError("{} URL must be HTTPS with a host".format(label))
        if parsed_asset_url.username is not None or parsed_asset_url.password is not None:
            raise FeedHealthError("{} URL must not contain user information".format(label))
        assets.append(
            ReleaseAsset(
                name=name,
                size=size,
                browser_download_url=browser_download_url,
            )
        )
    return LatestRelease(tag_name=tag, assets=tuple(assets))


def fetch_latest_release_tag(repo, token=None, timeout=20, opener=None):
    return fetch_latest_release(
        repo,
        token=token,
        timeout=timeout,
        opener=opener,
    ).tag_name


def _release_asset_url(owner, repository, tag, filename):
    return "https://github.com/{}/{}/releases/download/{}/{}".format(
        urllib.parse.quote(owner, safe=""),
        urllib.parse.quote(repository, safe=""),
        urllib.parse.quote(tag, safe=""),
        urllib.parse.quote(filename, safe=""),
    )


def matching_release_asset(repo, release, appcast_item, feed_url=None):
    owner, repository = _validated_repo(repo)
    allowed_enclosure_repositories = {(owner, repository)}
    legacy_repository = LEGACY_INSTALLED_FEED_REPOSITORIES.get(
        (owner, repository, feed_url)
    )
    if legacy_repository is not None:
        allowed_enclosure_repositories.add(legacy_repository)

    matching_assets = []
    for asset in release.assets:
        canonical_url = _release_asset_url(
            owner,
            repository,
            release.tag_name,
            asset.name,
        )
        if asset.browser_download_url != canonical_url:
            continue
        allowed_urls = {
            _release_asset_url(
                enclosure_owner,
                enclosure_repository,
                release.tag_name,
                asset.name,
            )
            for enclosure_owner, enclosure_repository
            in allowed_enclosure_repositories
        }
        if appcast_item.enclosure_url in allowed_urls:
            matching_assets.append(asset)

    if len(matching_assets) != 1:
        raise FeedHealthError(
            "GitHub latest release must contain exactly one canonical asset matching the installed-client Appcast enclosure"
        )
    asset = matching_assets[0]
    if asset.size != appcast_item.enclosure_length:
        raise FeedHealthError(
            "GitHub release asset size {} does not match Appcast enclosure length {}".format(
                asset.size,
                appcast_item.enclosure_length,
            )
        )
    return asset


def probe_release_asset(
    asset,
    expected_length,
    timeout=20,
    opener=None,
    source_url=None,
):
    length = _positive_integer(expected_length, "expected asset length")
    resolved_timeout = _positive_timeout(timeout)
    resolved_source_url = source_url or asset.browser_download_url
    request = urllib.request.Request(
        resolved_source_url,
        headers={
            "Accept": "application/octet-stream",
            "Accept-Encoding": "identity",
            "Range": "bytes=0-0",
            "User-Agent": USER_AGENT,
        },
        method="GET",
    )
    if opener is None:
        redirect_handler = ReleaseAssetRedirectHandler(
            resolved_source_url,
            asset.browser_download_url,
        )
        asset_url_opener = _direct_opener(redirect_handler)
        open_request = lambda asset_request, asset_timeout: asset_url_opener.open(
            asset_request,
            timeout=asset_timeout,
        )
    else:
        open_request = opener
    try:
        with open_request(request, resolved_timeout) as response:
            status = getattr(response, "status", None)
            if status is None:
                status = response.getcode()
            if status != 206:
                raise FeedHealthError(
                    "GitHub release asset must return HTTP 206 for a one-byte Range request"
                )

            final_url = response.geturl()
            if not _is_official_release_cdn_url(final_url):
                raise FeedHealthError(
                    "GitHub release asset redirect final URL is not the official HTTPS release CDN"
                )

            content_range = response.headers.get("Content-Range")
            match = re.fullmatch(r"bytes 0-0/([1-9][0-9]*)", content_range or "")
            if match is None:
                raise FeedHealthError(
                    "GitHub release asset Content-Range must be bytes 0-0/TOTAL"
                )
            total = _positive_decimal_integer(
                match.group(1),
                "GitHub release asset Content-Range total",
            )
            if total != length:
                raise FeedHealthError(
                    "GitHub release asset Content-Range total {} does not match length {}".format(
                        total,
                        length,
                    )
                )

            payload = response.read(2)
            if not isinstance(payload, (bytes, bytearray)) or len(payload) != 1:
                raise FeedHealthError(
                    "GitHub release asset partial response must return exactly one byte"
                )
    except FeedHealthError:
        raise
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError) as error:
        raise _network_error("GitHub release asset", error) from None


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
    asset_opener=None,
):
    _validated_repo(repo)
    _validated_feed_url(feed_url)
    _positive_integer(max_bytes, "max_bytes")
    _positive_timeout(timeout)

    release = fetch_latest_release(
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
    health = validate_health(release.tag_name, appcast, max_bytes)
    appcast_item = parse_top_appcast_item(appcast)
    asset = matching_release_asset(
        repo,
        release,
        appcast_item,
        feed_url=feed_url,
    )
    probe_release_asset(
        asset,
        appcast_item.enclosure_length,
        timeout=timeout,
        opener=asset_opener,
        source_url=appcast_item.enclosure_url,
    )
    return health


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
    asset_opener=None,
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
            asset_opener=asset_opener,
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
