import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { renderDownloadError } from "../src/error-page";
import { ReleaseLookupError, type ReleaseInfo } from "../src/release";
import worker, { handleDownload, handleReleaseAPI } from "../src/worker";

const releaseMocks = vi.hoisted(() => ({
  fetchLatestRelease: vi.fn(),
}));

vi.mock("../src/release", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/release")>()),
  fetchLatestRelease: releaseMocks.fetchLatestRelease,
}));

const RELEASE: ReleaseInfo = {
  version: "0.2.40",
  filename: "QuotaMonitor-0.2.40.dmg",
  size: 6_992_960,
  upstreamUrl:
    "https://github.com/timmyagentic/quota-monitor/releases/download/v0.2.40/QuotaMonitor-0.2.40.dmg",
};

const SECURITY_HEADERS = {
  "Content-Security-Policy":
    "default-src 'self'; base-uri 'none'; connect-src 'self'; font-src 'self'; form-action 'none'; frame-ancestors 'none'; frame-src 'none'; img-src 'self' data:; manifest-src 'self'; media-src 'self'; object-src 'none'; script-src 'self'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; worker-src 'none'; upgrade-insecure-requests",
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Resource-Policy": "same-origin",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "X-XSS-Protection": "0",
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
  "Permissions-Policy": "camera=(), geolocation=(), microphone=(), payment=(), usb=()",
} as const;

function expectSecurityHeaders(response: Response): void {
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
    expect(response.headers.get(name), name).toBe(value);
  }
}

function assetsBinding(fetcher: Fetcher["fetch"] = vi.fn<Fetcher["fetch"]>()): Fetcher {
  return {
    fetch: fetcher,
    connect() {
      throw new Error("Socket connections are not available in this test binding");
    },
  };
}

const successfulUpstream = (): Response =>
  new Response(new Uint8Array([0x44, 0x4d, 0x47]), {
    status: 200,
    headers: { "Content-Length": String(RELEASE.size) },
  });

describe("handleReleaseAPI", () => {
  it("returns only public release metadata", async () => {
    const response = await handleReleaseAPI(async () => RELEASE);
    const responseText = await response.text();

    expect(response.status).toBe(200);
    expect(JSON.parse(responseText)).toEqual({
      version: "0.2.40",
      filename: "QuotaMonitor-0.2.40.dmg",
      size: 6_992_960,
      minimumSystemVersion: "14.0",
    });
    expect(responseText).not.toContain("upstreamUrl");
    expect(responseText).not.toMatch(/github/i);
    expect(response.headers.get("Cache-Control")).toBe("public, max-age=300");
    expectSecurityHeaders(response);
  });

  it("returns a non-cacheable unavailable response when release lookup fails", async () => {
    const response = await handleReleaseAPI(async () => {
      throw new ReleaseLookupError("unavailable");
    });

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ available: false });
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expectSecurityHeaders(response);
  });
});

describe("handleDownload", () => {
  it("streams an exact-length DMG through the same-origin response", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(successfulUpstream());
    const response = await handleDownload(
      new Request("https://quota-monitor.test/download", {
        headers: { "Accept-Language": "zh-CN" },
      }),
      async () => RELEASE,
      fetcher,
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Disposition")).toBe(
      'attachment; filename="QuotaMonitor-0.2.40.dmg"',
    );
    expect(response.headers.get("Content-Length")).toBe(String(RELEASE.size));
    expect(response.headers.get("Content-Type")).toBe("application/x-apple-diskimage");
    expect(response.headers.get("Location")).toBeNull();
    expect([...response.headers].join("\n")).not.toMatch(/github/i);
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(
      new Uint8Array([0x44, 0x4d, 0x47]),
    );
    expect(fetcher).toHaveBeenCalledWith(RELEASE.upstreamUrl, {
      redirect: "follow",
      cf: { cacheEverything: true, cacheTtl: 86_400 },
    });
    expectSecurityHeaders(response);
  });

  it.each([
    ["non-OK response", new Response("upstream failure", { status: 502, headers: { "Content-Length": String(RELEASE.size) } })],
    ["missing body", new Response(null, { status: 200, headers: { "Content-Length": String(RELEASE.size) } })],
    ["missing Content-Length", new Response(new Uint8Array([0x44]), { status: 200 })],
    ["unsafe Content-Length", new Response(new Uint8Array([0x44]), { status: 200, headers: { "Content-Length": "9007199254740992" } })],
    ["non-decimal Content-Length", new Response(new Uint8Array([0x44]), { status: 200, headers: { "Content-Length": `${RELEASE.size}.0` } })],
    ["mismatched Content-Length", new Response(new Uint8Array([0x44]), { status: 200, headers: { "Content-Length": String(RELEASE.size + 1) } })],
  ])("renders an error for a %s", async (_label, upstream) => {
    const response = await handleDownload(
      new Request("https://quota-monitor.test/download", {
        headers: { "Accept-Language": "en-US" },
      }),
      async () => RELEASE,
      vi.fn<typeof fetch>().mockResolvedValue(upstream),
    );

    expect(response.status).toBe(503);
    expect(await response.text()).toContain("Download temporarily unavailable");
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expectSecurityHeaders(response);
  });

  it("renders a Chinese error without fetching upstream when release lookup fails", async () => {
    const fetcher = vi.fn<typeof fetch>();
    const response = await handleDownload(
      new Request("https://quota-monitor.test/download", {
        headers: { "Accept-Language": "zh-CN, en-US;q=0.8" },
      }),
      async () => {
        throw new ReleaseLookupError("unavailable");
      },
      fetcher,
    );

    expect(response.status).toBe(503);
    expect(await response.text()).toContain("暂时无法开始下载");
    expect(fetcher).not.toHaveBeenCalled();
    expectSecurityHeaders(response);
  });
});

describe("renderDownloadError", () => {
  it.each([
    ["Chinese", "zh-CN, en-US;q=0.8", 'lang="zh-Hans"', "暂时无法开始下载"],
    ["English", "en-US, zh-CN;q=0.8", 'lang="en"', "Download temporarily unavailable"],
  ])("renders safe %s copy with only retry and home actions", (_label, language, lang, copy) => {
    const html = renderDownloadError(language);
    const anchors = [...html.matchAll(/<a\b[^>]*\bhref="([^"]+)"[^>]*>([^<]+)<\/a>/gi)].map(
      ([, href, text]) => ({ href, text }),
    );

    expect(html).toContain("<!doctype html>");
    expect(html).toContain(lang);
    expect(html).toContain(copy);
    expect(html).toContain('<meta name="robots" content="noindex">');
    expect(html).toContain('<link rel="stylesheet" href="/styles.css">');
    expect(anchors).toEqual([
      { href: "/download", text: "重试 / Retry" },
      { href: "/", text: "返回首页 / Back home" },
    ]);
    expect(html).not.toMatch(/github/i);
    expect(html).not.toMatch(/href=["'](?:https?:)?\/\//i);
    expect(html).not.toMatch(/\sstyle=/i);
    expect(html).not.toMatch(/\son[a-z]+=/i);
  });
});

describe("Worker routes", () => {
  beforeEach(() => {
    releaseMocks.fetchLatestRelease.mockReset();
    releaseMocks.fetchLatestRelease.mockResolvedValue(RELEASE);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("serves public metadata from /api/release without exposing the upstream URL", async () => {
    const response = await worker.fetch(
      new Request("https://quota-monitor.test/api/release"),
      { ASSETS: assetsBinding() },
    );
    const body = await response.text();

    expect(response.status).toBe(200);
    expect(JSON.parse(body)).toEqual({
      version: RELEASE.version,
      filename: RELEASE.filename,
      size: RELEASE.size,
      minimumSystemVersion: "14.0",
    });
    expect(body).not.toContain("upstreamUrl");
    expect(body).not.toMatch(/github/i);
    expectSecurityHeaders(response);
  });

  it("streams /download without redirecting the visitor upstream", async () => {
    const upstreamFetch = vi.fn<typeof fetch>().mockResolvedValue(successfulUpstream());
    vi.stubGlobal("fetch", upstreamFetch);

    const response = await worker.fetch(
      new Request("https://quota-monitor.test/download"),
      { ASSETS: assetsBinding() },
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("Location")).toBeNull();
    expect(upstreamFetch).toHaveBeenCalledOnce();
    expectSecurityHeaders(response);
  });

  it("adds security headers to static asset responses", async () => {
    const assetsFetch = vi.fn<Fetcher["fetch"]>().mockResolvedValue(
      new Response("home", {
        status: 200,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      }),
    );

    const response = await worker.fetch(
      new Request("https://quota-monitor.test/"),
      { ASSETS: assetsBinding(assetsFetch) },
    );

    expect(response.status).toBe(200);
    expect(await response.text()).toBe("home");
    expect(response.headers.get("Content-Type")).toBe("text/html; charset=utf-8");
    expectSecurityHeaders(response);
  });

  it("returns a secured 405 with the allowed methods", async () => {
    const assetsFetch = vi.fn<Fetcher["fetch"]>();

    const response = await worker.fetch(
      new Request("https://quota-monitor.test/api/release", { method: "POST" }),
      { ASSETS: assetsBinding(assetsFetch) },
    );

    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("GET, HEAD");
    expect(assetsFetch).not.toHaveBeenCalled();
    expectSecurityHeaders(response);
  });
});
