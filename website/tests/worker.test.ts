import { timingSafeEqual, webcrypto } from "node:crypto";
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

const ASSET_URL =
  "https://release-assets.githubusercontent.com/github-production-release-asset/123456/abcdef01?sp=r&sv=2025-01-05&sr=b&sig=signed";

const MANUAL_FETCH_INIT = {
  redirect: "manual",
  cf: {
    cacheEverything: true,
    cacheTtlByStatus: { "200-299": 86_400, "300-599": 0 },
  },
} as const;

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

function expectSecurityHeaders(
  response: Response,
  formAction: "none" | "self" = "none",
): void {
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
    const expected = name === "Content-Security-Policy" && formAction === "self"
      ? value.replace("form-action 'none'", "form-action 'self'")
      : value;
    expect(response.headers.get(name), name).toBe(expected);
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

const TEST_D1_META: D1Meta & Record<string, unknown> = {
  duration: 0,
  size_after: 0,
  rows_read: 0,
  rows_written: 0,
  last_row_id: 0,
  changed_db: false,
  changes: 0,
};

function testD1Result<T>(results: T[], changes = 0): D1Result<T> {
  return {
    success: true,
    meta: { ...TEST_D1_META, changed_db: changes > 0, changes },
    results,
  };
}

class WorkerTestStatement implements D1PreparedStatement {
  readonly bindings: unknown[] = [];

  constructor(
    readonly query: string,
    private readonly rows: Record<string, unknown>[],
  ) {}

  bind(...values: unknown[]): D1PreparedStatement {
    this.bindings.splice(0, this.bindings.length, ...values);
    return this;
  }

  async first<T = unknown>(colName?: string): Promise<T | null> {
    const row = this.rows[0];
    if (row === undefined) return null;
    return (colName === undefined ? row : row[colName]) as T ?? null;
  }

  async run<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    return testD1Result(this.rows as T[]);
  }

  async all<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    return testD1Result(this.rows as T[]);
  }

  async raw<T = unknown[]>(options: { columnNames: true }): Promise<[string[], ...T[]]>;
  async raw<T = unknown[]>(options?: { columnNames?: false }): Promise<T[]>;
  async raw<T = unknown[]>(
    options?: { columnNames?: boolean },
  ): Promise<T[] | [string[], ...T[]]> {
    const rows = this.rows as T[];
    return options?.columnNames === true ? [[], ...rows] : rows;
  }
}

class WorkerTestDatabase implements D1Database {
  readonly statements: WorkerTestStatement[] = [];
  readonly batchCalls: D1PreparedStatement[][] = [];
  batchChanges = [0, 0, 0];
  batchFailure: Error | null = null;

  constructor(
    private readonly rows: (query: string) => Record<string, unknown>[] = () => [],
    private readonly rejectPrepare = false,
  ) {}

  prepare(query: string): D1PreparedStatement {
    if (this.rejectPrepare) {
      throw new Error("The version statistics database is unused in this test");
    }
    const statement = new WorkerTestStatement(query, this.rows(query));
    this.statements.push(statement);
    return statement;
  }

  async batch<T = unknown>(statements: D1PreparedStatement[]): Promise<D1Result<T>[]> {
    this.batchCalls.push(statements);
    if (this.batchFailure !== null) throw this.batchFailure;
    return statements.map((_, index) =>
      testD1Result<T>([], this.batchChanges[index] ?? 0)
    );
  }

  async exec(): Promise<D1ExecResult> {
    return { count: 0, duration: 0 };
  }

  withSession(): D1DatabaseSession {
    throw new Error("D1 sessions are unused in Worker tests");
  }

  async dump(): Promise<ArrayBuffer> {
    return new ArrayBuffer(0);
  }
}

function allowLimiter(): RateLimit {
  return {
    async limit(): Promise<RateLimitOutcome> {
      return { success: true };
    },
  };
}

function workerEnv(
  assets: Fetcher = assetsBinding(),
  rateLimiter: RateLimit = allowLimiter(),
  coloRateLimiter: RateLimit = allowLimiter(),
  adminRateLimiter: RateLimit = allowLimiter(),
  database: D1Database = new WorkerTestDatabase(() => [], true),
  adminSecret?: string,
): Env {
  const env = {
    ASSETS: assets,
    DAILY_ACTIVE_RATE_LIMITER: rateLimiter,
    DAILY_ACTIVE_COLO_RATE_LIMITER: coloRateLimiter,
    ADMIN_VERSION_STATS_RATE_LIMITER: adminRateLimiter,
    VERSION_STATS_DB: database,
  };
  return adminSecret === undefined
    ? env
    : Object.assign(env, { VERSION_STATS_ADMIN_TOKEN: adminSecret });
}

function stubWorkerCrypto(): void {
  vi.stubGlobal("crypto", {
    subtle: {
      digest: webcrypto.subtle.digest.bind(webcrypto.subtle),
      timingSafeEqual(left: ArrayBuffer, right: ArrayBuffer): boolean {
        return timingSafeEqual(new Uint8Array(left), new Uint8Array(right));
      },
    },
  });
}

function adminAuthorization(secret: string): string {
  return `Basic ${btoa(`admin:${secret}`)}`;
}

const successfulUpstream = (): Response =>
  new Response(new Uint8Array([0x44, 0x4d, 0x47]), {
    status: 200,
    headers: {
      "Content-Length": String(RELEASE.size),
      "Content-Type": "application/octet-stream",
    },
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
      ...MANUAL_FETCH_INIT,
    });
    expectSecurityHeaders(response);
  });

  it("passes through a successful DMG stream without canceling or buffering it", async () => {
    const cancel = vi.fn();
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array([0x44, 0x4d, 0x47]));
        controller.close();
      },
      cancel,
    });
    const upstream = new Response(body, {
      status: 200,
      headers: {
        "Content-Length": String(RELEASE.size),
        "Content-Type": "Application/X-Apple-DiskImage; version=1",
      },
    });

    const response = await handleDownload(
      new Request("https://quota-monitor.test/download"),
      async () => RELEASE,
      vi.fn<typeof fetch>().mockResolvedValue(upstream),
    );

    expect(response.status).toBe(200);
    expect(response.body).toBe(upstream.body);
    expect(cancel).not.toHaveBeenCalled();
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(
      new Uint8Array([0x44, 0x4d, 0x47]),
    );
    expect(cancel).not.toHaveBeenCalled();
  });

  it("follows one validated official asset redirect and streams the final response", async () => {
    const fetcher = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(
        new Response(null, { status: 302, headers: { Location: ASSET_URL } }),
      )
      .mockResolvedValueOnce(successfulUpstream());

    const response = await handleDownload(
      new Request("https://quota-monitor.test/download"),
      async () => RELEASE,
      fetcher,
    );

    expect(response.status).toBe(200);
    expect(fetcher).toHaveBeenNthCalledWith(1, RELEASE.upstreamUrl, MANUAL_FETCH_INIT);
    expect(fetcher).toHaveBeenNthCalledWith(2, ASSET_URL, MANUAL_FETCH_INIT);
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(MANUAL_FETCH_INIT.cf.cacheTtlByStatus["300-599"]).toBe(0);
    expect(MANUAL_FETCH_INIT.cf).not.toHaveProperty("cacheTtl");
    expect(response.headers.get("Location")).toBeNull();
    expect([...response.headers].join("\n")).not.toContain(ASSET_URL);
    expect([...response.headers].join("\n")).not.toContain("release-assets.githubusercontent.com");
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(
      new Uint8Array([0x44, 0x4d, 0x47]),
    );
    expectSecurityHeaders(response);
  });

  it("awaits redirect-body cancellation before requesting the official asset", async () => {
    const events: string[] = [];
    const redirect = new Response(
      new ReadableStream({
        async cancel() {
          events.push("cancel:start");
          await Promise.resolve();
          events.push("cancel:end");
        },
      }),
      { status: 302, headers: { Location: ASSET_URL } },
    );
    let requestCount = 0;
    const fetcher = vi.fn<typeof fetch>(async () => {
      requestCount += 1;
      if (requestCount === 1) {
        return redirect;
      }
      events.push("fetch:asset");
      return successfulUpstream();
    });

    const response = await handleDownload(
      new Request("https://quota-monitor.test/download"),
      async () => RELEASE,
      fetcher,
    );

    expect(response.status).toBe(200);
    expect(events).toEqual(["cancel:start", "cancel:end", "fetch:asset"]);
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it("rejects a foreign redirect before making a second request", async () => {
    const target = "https://downloads.example.test/github-production-release-asset/file";
    const fetcher = vi
      .fn<typeof fetch>()
      .mockResolvedValue(new Response(null, { status: 302, headers: { Location: target } }));

    const response = await handleDownload(
      new Request("https://quota-monitor.test/download"),
      async () => RELEASE,
      fetcher,
    );
    const body = await response.text();

    expect(response.status).toBe(503);
    expect(fetcher).toHaveBeenCalledOnce();
    expect(body).not.toContain(target);
    expect([...response.headers].join("\n")).not.toContain(target);
    expectSecurityHeaders(response);
  });

  it.each([
    ["HTTP protocol", ASSET_URL.replace("https://", "http://")],
    ["credentials", ASSET_URL.replace("https://", "https://user:secret@")],
    [
      "custom port",
      ASSET_URL.replace("release-assets.githubusercontent.com", "release-assets.githubusercontent.com:8443"),
    ],
    [
      "wrong path",
      "https://release-assets.githubusercontent.com/not-github-production-release-asset/file?sig=signed",
    ],
    ["invalid URL", "https://[invalid"],
  ])("rejects an official asset redirect with %s", async (_label, location) => {
    const fetcher = vi
      .fn<typeof fetch>()
      .mockResolvedValue(new Response(null, { status: 302, headers: { Location: location } }));

    const response = await handleDownload(
      new Request("https://quota-monitor.test/download"),
      async () => RELEASE,
      fetcher,
    );

    expect(response.status).toBe(503);
    expect(fetcher).toHaveBeenCalledOnce();
    expect(await response.text()).not.toContain(location);
    expectSecurityHeaders(response);
  });

  it("rejects a redirect without a Location header", async () => {
    const fetcher = vi
      .fn<typeof fetch>()
      .mockResolvedValue(new Response(null, { status: 302 }));

    const response = await handleDownload(
      new Request("https://quota-monitor.test/download"),
      async () => RELEASE,
      fetcher,
    );

    expect(response.status).toBe(503);
    expect(fetcher).toHaveBeenCalledOnce();
    expectSecurityHeaders(response);
  });

  it("rejects a second redirect without following it", async () => {
    const secondTarget = `${ASSET_URL}&retry=1`;
    const fetcher = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(
        new Response(null, { status: 302, headers: { Location: ASSET_URL } }),
      )
      .mockResolvedValueOnce(
        new Response(null, { status: 307, headers: { Location: secondTarget } }),
      );

    const response = await handleDownload(
      new Request("https://quota-monitor.test/download"),
      async () => RELEASE,
      fetcher,
    );
    const body = await response.text();

    expect(response.status).toBe(503);
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(body).not.toContain(ASSET_URL);
    expect([...response.headers].join("\n")).not.toContain(ASSET_URL);
    expectSecurityHeaders(response);
  });

  it.each([
    ["non-OK response", new Response("upstream failure", { status: 502, headers: { "Content-Length": String(RELEASE.size) } })],
    ["non-200 final response", new Response(new Uint8Array([0x44]), { status: 206, headers: { "Content-Length": String(RELEASE.size) } })],
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

  it("cancels an invalid upstream body before returning the error response", async () => {
    const cancel = vi.fn();
    const upstream = new Response(new ReadableStream({ cancel }), {
      status: 502,
      headers: { "Content-Length": String(RELEASE.size) },
    });
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(upstream);

    const response = await handleDownload(
      new Request("https://quota-monitor.test/download"),
      async () => RELEASE,
      fetcher,
    );

    expect(response.status).toBe(503);
    expect(cancel).toHaveBeenCalledOnce();
    expect(fetcher).toHaveBeenCalledWith(RELEASE.upstreamUrl, MANUAL_FETCH_INIT);
  });

  it("rejects and cancels a same-length HTML body instead of streaming it as a DMG", async () => {
    const cancel = vi.fn();
    const upstream = new Response(new ReadableStream({ cancel }), {
      status: 200,
      headers: {
        "Content-Length": String(RELEASE.size),
        "Content-Type": "text/html; charset=utf-8",
      },
    });

    const response = await handleDownload(
      new Request("https://quota-monitor.test/download", {
        headers: { "Accept-Language": "en-US" },
      }),
      async () => RELEASE,
      vi.fn<typeof fetch>().mockResolvedValue(upstream),
    );

    expect(response.status).toBe(503);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(response.headers.get("Content-Type")).toBe("text/html; charset=utf-8");
    expect(await response.text()).toContain("Download temporarily unavailable");
    expect(cancel).toHaveBeenCalledOnce();
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
    [
      "Chinese",
      "zh-CN, en-US;q=0.8",
      'lang="zh-Hans"',
      "暂时无法开始下载",
      "重试",
      "返回首页",
    ],
    [
      "English",
      "en-US, zh-CN;q=0.8",
      'lang="en"',
      "Download temporarily unavailable",
      "Try again",
      "Back home",
    ],
  ])("renders safe %s copy with localizable retry and home actions", (
    _label,
    language,
    lang,
    copy,
    retry,
    backHome,
  ) => {
    const html = renderDownloadError(language);
    const anchors = [...html.matchAll(/<a\b[^>]*\bhref="([^"]+)"[^>]*>([^<]+)<\/a>/gi)].map(
      ([, href, text]) => ({ href, text }),
    );

    expect(html).toContain("<!doctype html>");
    expect(html).toContain(lang);
    expect(html).toContain(copy);
    expect(html).toContain('<meta name="robots" content="noindex">');
    expect(html).toContain('<link rel="stylesheet" href="/styles.css">');
    expect(html).toContain('<title data-i18n="downloadErrorMetaTitle">');
    expect(html).toContain('<body data-page="download-error">');
    expect(html).toContain('<main id="main-content" class="not-found" aria-labelledby="download-error-title">');
    expect(html).toContain('<div class="container not-found-content">');
    expect(html).toContain('<p class="not-found-eyebrow">Quota Monitor</p>');
    expect(html).toContain('<h1 id="download-error-title" data-i18n="downloadErrorTitle">');
    expect(html).toContain('<p data-i18n="downloadErrorDescription">');
    expect(html).toContain('data-i18n-aria-label="downloadErrorActionsLabel"');
    expect(html).toContain(`<a href="/download" class="button button-primary" data-i18n="downloadErrorRetry">${retry}</a>`);
    expect(html).toContain(`<a href="/" class="button button-secondary" data-i18n="downloadErrorBackHome">${backHome}</a>`);
    expect(html).toContain('<script type="module" src="/app.js"></script>');
    expect(anchors).toEqual([
      { href: "/download", text: retry },
      { href: "/", text: backHome },
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
    vi.restoreAllMocks();
  });

  it("serves public metadata from /api/release without exposing the upstream URL", async () => {
    const response = await worker.fetch(
      new Request("https://quota-monitor.test/api/release"),
      workerEnv(),
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
      workerEnv(),
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("Location")).toBeNull();
    expect(response.headers.get("Cache-Control")).toBe("no-store");
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
      workerEnv(assetsBinding(assetsFetch)),
    );

    expect(response.status).toBe(200);
    expect(await response.text()).toBe("home");
    expect(response.headers.get("Content-Type")).toBe("text/html; charset=utf-8");
    expectSecurityHeaders(response);
  });

  it.each(["/api/release", "/download"])(
    "rejects HEAD for dynamic route %s without touching assets or upstream",
    async (pathname) => {
      const upstreamFetch = vi.fn<typeof fetch>();
      const assetsFetch = vi.fn<Fetcher["fetch"]>().mockResolvedValue(
        new Response(null, { status: 200 }),
      );
      vi.stubGlobal("fetch", upstreamFetch);

      const response = await worker.fetch(
        new Request(`https://quota-monitor.test${pathname}`, { method: "HEAD" }),
        workerEnv(assetsBinding(assetsFetch)),
      );

      expect(response.status).toBe(405);
      expect(response.headers.get("Allow")).toBe("GET");
      expect(releaseMocks.fetchLatestRelease).not.toHaveBeenCalled();
      expect(upstreamFetch).not.toHaveBeenCalled();
      expect(assetsFetch).not.toHaveBeenCalled();
      expectSecurityHeaders(response);
    },
  );

  it("forwards static asset HEAD requests", async () => {
    const assetsFetch = vi.fn<Fetcher["fetch"]>().mockResolvedValue(
      new Response(null, {
        status: 200,
        headers: { "Content-Type": "text/css; charset=utf-8" },
      }),
    );
    const request = new Request("https://quota-monitor.test/styles.css", {
      method: "HEAD",
    });

    const response = await worker.fetch(request, workerEnv(assetsBinding(assetsFetch)));

    expect(response.status).toBe(200);
    expect(assetsFetch).toHaveBeenCalledWith(request);
    expect(response.headers.get("Content-Type")).toBe("text/css; charset=utf-8");
    expectSecurityHeaders(response);
  });

  it("returns a secured 405 with GET as the allowed dynamic method", async () => {
    const assetsFetch = vi.fn<Fetcher["fetch"]>();

    const response = await worker.fetch(
      new Request("https://quota-monitor.test/api/release", { method: "POST" }),
      workerEnv(assetsBinding(assetsFetch)),
    );

    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("GET");
    expect(assetsFetch).not.toHaveBeenCalled();
    expectSecurityHeaders(response);
  });

  it("routes the daily-active endpoint through its POST-only handler", async () => {
    const assetsFetch = vi.fn<Fetcher["fetch"]>();
    const limit = vi.fn<RateLimit["limit"]>().mockResolvedValue({ success: true });

    const response = await worker.fetch(
      new Request("https://quota-monitor.test/api/v1/daily-active"),
      workerEnv(assetsBinding(assetsFetch), { limit }),
    );

    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("POST");
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(limit).not.toHaveBeenCalled();
    expect(assetsFetch).not.toHaveBeenCalled();
    expectSecurityHeaders(response);
  });

  it("routes ingest through the per-colo best-effort circuit breaker before its per-IP limiter", async () => {
    const assetsFetch = vi.fn<Fetcher["fetch"]>();
    const ipLimit = vi.fn<RateLimit["limit"]>().mockResolvedValue({ success: true });
    const coloLimit = vi.fn<RateLimit["limit"]>().mockResolvedValue({ success: false });

    const response = await worker.fetch(
      new Request("https://quota-monitor.test/api/v1/daily-active", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "CF-Connecting-IP": "203.0.113.50",
        },
        body: "{malformed",
      }),
      workerEnv(
        assetsBinding(assetsFetch),
        { limit: ipLimit },
        { limit: coloLimit },
      ),
    );

    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("60");
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(coloLimit).toHaveBeenCalledWith({ key: "daily-active-colo" });
    expect(ipLimit).not.toHaveBeenCalled();
    expect(assetsFetch).not.toHaveBeenCalled();
    expectSecurityHeaders(response);
  });

  it("challenges unauthenticated dashboard requests before querying D1", async () => {
    stubWorkerCrypto();
    const database = new WorkerTestDatabase();
    const assetsFetch = vi.fn<Fetcher["fetch"]>();
    const adminLimit = vi.fn<RateLimit["limit"]>().mockResolvedValue({ success: true });

    const response = await worker.fetch(
      new Request("https://quota-monitor.test/maintainer/versions", {
        headers: {
          Authorization: adminAuthorization("wrong"),
          "CF-Connecting-IP": "203.0.113.51",
        },
      }),
      workerEnv(
        assetsBinding(assetsFetch),
        allowLimiter(),
        allowLimiter(),
        { limit: adminLimit },
        database,
        "dashboard-secret",
      ),
    );

    expect(response.status).toBe(401);
    expect(response.headers.get("WWW-Authenticate")).toContain("Basic");
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(response.headers.get("Vary")).toBe("Authorization");
    expect(response.headers.get("Content-Security-Policy")).toContain(
      "form-action 'self'",
    );
    expect(response.headers.get("Content-Security-Policy")).not.toContain(
      "form-action 'none'",
    );
    expect(adminLimit).toHaveBeenCalledWith({ key: "203.0.113.51" });
    expect(database.statements).toEqual([]);
    expect(assetsFetch).not.toHaveBeenCalled();
    expectSecurityHeaders(response, "self");
  });

  it("fails the dashboard closed when its secret binding is absent", async () => {
    const database = new WorkerTestDatabase();
    const adminLimit = vi.fn<RateLimit["limit"]>().mockResolvedValue({ success: true });

    const response = await worker.fetch(
      new Request("https://quota-monitor.test/maintainer/versions"),
      workerEnv(
        assetsBinding(),
        allowLimiter(),
        allowLimiter(),
        { limit: adminLimit },
        database,
      ),
    );

    expect(response.status).toBe(503);
    expect(await response.text()).toBe("Service unavailable");
    expect(adminLimit).not.toHaveBeenCalled();
    expect(database.statements).toEqual([]);
    expectSecurityHeaders(response, "self");
  });

  it("serves the authenticated dashboard from grouped and aggregate D1 rows", async () => {
    stubWorkerCrypto();
    const database = new WorkerTestDatabase((query) =>
      query.includes("daily_active_observations")
        ? [{ day: "2026-07-16", version: "0.2.43", brand: "quota-monitor", channel: "developer-id", active_count: 4 }]
        : [{ day: "2026-07-15", version: "0.2.42", brand: "quota-monitor", channel: "developer-id", active_count: 3 }],
    );
    const assetsFetch = vi.fn<Fetcher["fetch"]>();

    const response = await worker.fetch(
      new Request("https://quota-monitor.test/maintainer/versions?range=30", {
        headers: { Authorization: adminAuthorization("dashboard-secret") },
      }),
      workerEnv(
        assetsBinding(assetsFetch),
        allowLimiter(),
        allowLimiter(),
        allowLimiter(),
        database,
        "dashboard-secret",
      ),
    );
    const html = await response.text();

    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("text/html; charset=utf-8");
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(response.headers.get("Vary")).toBe("Authorization");
    expect(database.statements).toHaveLength(2);
    expect(html).toContain("Anonymous version distribution");
    expect(html).not.toContain("dashboard-secret");
    expect(assetsFetch).not.toHaveBeenCalled();
    expectSecurityHeaders(response, "self");
  });

  it("awaits scheduled closed-day aggregation in one three-statement batch", async () => {
    const database = new WorkerTestDatabase();
    database.batchChanges = [12, 9, 2];
    const info = vi.spyOn(console, "info").mockImplementation(() => undefined);
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const scheduledTime = Date.parse("2026-07-16T07:15:00.000Z");
    const controller: ScheduledController = {
      scheduledTime,
      cron: "15 * * * *",
      noRetry: vi.fn(),
    };

    await worker.scheduled(
      controller,
      workerEnv(
        assetsBinding(),
        allowLimiter(),
        allowLimiter(),
        allowLimiter(),
        database,
      ),
      undefined!,
    );

    expect(database.batchCalls).toHaveLength(1);
    expect(database.batchCalls[0]).toHaveLength(3);
    expect(database.statements.map((statement) => statement.bindings)).toEqual([
      ["2026-07-16"],
      ["2026-07-16"],
      ["2025-06-11"],
    ]);
    expect(info).toHaveBeenCalledExactlyOnceWith({
      event: "version_distribution_aggregation_succeeded",
      day: "2026-07-16",
      aggregateChanges: 12,
      rawDeleteChanges: 9,
      retentionDeleteChanges: 2,
    });
    expect(error).not.toHaveBeenCalled();
  });

  it("logs only a fixed event and UTC day when scheduled aggregation fails", async () => {
    const database = new WorkerTestDatabase();
    database.batchFailure = new Error(
      "Authorization https://private.test token_hash=secret body=private 203.0.113.70",
    );
    const info = vi.spyOn(console, "info").mockImplementation(() => undefined);
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const controller: ScheduledController = {
      scheduledTime: Date.parse("2026-07-16T23:15:00.000Z"),
      cron: "15 * * * *",
      noRetry: vi.fn(),
    };

    await expect(
      worker.scheduled(
        controller,
        workerEnv(
          assetsBinding(),
          allowLimiter(),
          allowLimiter(),
          allowLimiter(),
          database,
        ),
        undefined!,
      ),
    ).rejects.toThrow("Scheduled aggregation failed");

    expect(info).not.toHaveBeenCalled();
    expect(error).toHaveBeenCalledExactlyOnceWith({
      event: "version_distribution_aggregation_failed",
      day: "2026-07-16",
    });
    expect(JSON.stringify(error.mock.calls)).not.toMatch(
      /Authorization|https?:|token|hash|body|203\.0\.113\.70|private/i,
    );
  });
});
