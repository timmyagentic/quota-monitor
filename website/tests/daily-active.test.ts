import { afterEach, describe, expect, it, vi } from "vitest";
import {
  handleDailyActive,
  type DailyActiveDatabase,
  type DailyActiveRateLimiter,
  type DailyActiveStatement,
} from "../src/daily-active";

const FIXED_NOW = new Date("2026-07-16T12:34:56.000Z");
const VALID_TOKEN = "AAAAAAAAAAAAAAAAAAAAAA";
const VALID_PAYLOAD = {
  schema: 1,
  day: "2026-07-16",
  token: VALID_TOKEN,
  version: "0.2.41",
  brand: "quota-monitor",
  channel: "developer-id",
} as const;

type Observation = {
  day: string;
  tokenHash: string;
  version: string;
  brand: string;
  channel: string;
};

class RecordingDatabase implements DailyActiveDatabase {
  readonly preparedSQL: string[] = [];
  readonly boundValues: unknown[][] = [];
  readonly observations = new Map<string, Observation>();
  runCount = 0;
  shouldFail = false;

  prepare(query: string): DailyActiveStatement {
    this.preparedSQL.push(query);
    return {
      bind: (...values: unknown[]) => {
        this.boundValues.push(values);
        return {
          run: async () => {
            this.runCount += 1;
            if (this.shouldFail) {
              throw new Error("synthetic storage failure");
            }

            const [day, tokenHash, version, brand, channel] = values;
            if (
              typeof day !== "string" ||
              typeof tokenHash !== "string" ||
              typeof version !== "string" ||
              typeof brand !== "string" ||
              typeof channel !== "string"
            ) {
              throw new Error("unexpected bindings");
            }

            this.observations.set(`${day}|${tokenHash}`, {
              day,
              tokenHash,
              version,
              brand,
              channel,
            });
          },
        };
      },
    };
  }
}

class RecordingLimiter implements DailyActiveRateLimiter {
  readonly keys: string[] = [];
  success = true;
  shouldFail = false;

  async limit(options: { key: string }): Promise<{ success: boolean }> {
    this.keys.push(options.key);
    if (this.shouldFail) {
      throw new Error("synthetic rate limiter failure");
    }
    return { success: this.success };
  }
}

function requestFor(
  payload: unknown = VALID_PAYLOAD,
  options: {
    method?: string;
    url?: string;
    contentType?: string | null;
    contentLength?: string;
    contentEncoding?: string;
    body?: BodyInit | null;
    connectingIP?: string;
  } = {},
): Request {
  const headers = new Headers();
  if (options.contentType !== null) {
    headers.set("Content-Type", options.contentType ?? "application/json");
  }
  if (options.contentLength !== undefined) {
    headers.set("Content-Length", options.contentLength);
  }
  if (options.contentEncoding !== undefined) {
    headers.set("Content-Encoding", options.contentEncoding);
  }
  if (options.connectingIP !== undefined) {
    headers.set("CF-Connecting-IP", options.connectingIP);
  }

  return new Request(
    options.url ?? "https://quota-monitor.test/api/v1/daily-active",
    {
      method: options.method ?? "POST",
      headers,
      body: options.body === undefined ? JSON.stringify(payload) : options.body,
    },
  );
}

async function handle(
  database: RecordingDatabase,
  request: Request = requestFor(),
  digest?: (bytes: Uint8Array) => Promise<ArrayBuffer>,
  limiter: RecordingLimiter = new RecordingLimiter(),
  globalLimiter: RecordingLimiter = new RecordingLimiter(),
): Promise<Response> {
  return handleDailyActive(request, database, globalLimiter, limiter, {
    now: () => FIXED_NOW,
    ...(digest === undefined ? {} : { digest }),
  });
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("daily active request validation", () => {
  it.each(["GET", "PUT", "DELETE", "HEAD"])(
    "accepts only POST, rejecting %s without touching D1",
    async (method) => {
      const database = new RecordingDatabase();

      const response = await handle(database, requestFor(undefined, { method, body: null }));

      expect(response.status).toBe(405);
      expect(response.headers.get("Allow")).toBe("POST");
      expect(response.headers.get("Cache-Control")).toBe("no-store");
      expect(database.preparedSQL).toEqual([]);
    },
  );

  it("requires HTTPS before reading or storing the payload", async () => {
    const database = new RecordingDatabase();

    const response = await handle(
      database,
      requestFor(VALID_PAYLOAD, {
        url: "http://quota-monitor.test/api/v1/daily-active",
      }),
    );

    expect(response.status).toBe(400);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(database.preparedSQL).toEqual([]);
  });

  it.each([null, "text/plain", "application/json; charset=utf-8", "Application/JSON"])(
    "requires the exact application/json media type (%s)",
    async (contentType) => {
      const database = new RecordingDatabase();

      const response = await handle(database, requestFor(VALID_PAYLOAD, { contentType }));

      expect(response.status).toBe(415);
      expect(response.headers.get("Cache-Control")).toBe("no-store");
      expect(database.preparedSQL).toEqual([]);
    },
  );

  it.each(["gzip", "br"])(
    "rejects the encoded %s body before rate limiting or storage",
    async (contentEncoding) => {
      const database = new RecordingDatabase();
      const limiter = new RecordingLimiter();

      const response = await handle(
        database,
        requestFor(VALID_PAYLOAD, { contentEncoding }),
        undefined,
        limiter,
      );

      expect(response.status).toBe(415);
      expect(limiter.keys).toEqual([]);
      expect(database.preparedSQL).toEqual([]);
    },
  );

  it("rejects a declared body larger than 2 KiB without touching D1", async () => {
    const database = new RecordingDatabase();

    const response = await handle(
      database,
      requestFor(VALID_PAYLOAD, { contentLength: "2049" }),
    );

    expect(response.status).toBe(413);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(database.preparedSQL).toEqual([]);
  });

  it("accepts an exactly 2 KiB body", async () => {
    const database = new RecordingDatabase();
    const json = JSON.stringify(VALID_PAYLOAD);
    const body = `${json}${" ".repeat(2_048 - new TextEncoder().encode(json).byteLength)}`;

    const response = await handle(
      database,
      requestFor(undefined, { body, contentLength: "2048" }),
    );

    expect(response.status).toBe(204);
    expect(database.runCount).toBe(1);
  });

  it("streams and cancels a chunked body as soon as it exceeds 2 KiB", async () => {
    const database = new RecordingDatabase();
    const cancel = vi.fn();
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(1_024));
        controller.enqueue(new Uint8Array(1_025));
      },
      cancel,
    });
    const init: RequestInit & { duplex: "half" } = {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      duplex: "half",
    };
    const request = new Request(
      "https://quota-monitor.test/api/v1/daily-active",
      init,
    );

    const response = await handle(database, request);

    expect(response.status).toBe(413);
    expect(cancel).toHaveBeenCalledOnce();
    expect(database.preparedSQL).toEqual([]);
  });

  it.each([
    ["null", null],
    ["array", [VALID_PAYLOAD]],
    ["missing key", (({ channel: _channel, ...payload }) => payload)(VALID_PAYLOAD)],
    ["extra key", { ...VALID_PAYLOAD, locale: "en" }],
    ["wrong schema", { ...VALID_PAYLOAD, schema: 2 }],
    ["impossible day", { ...VALID_PAYLOAD, day: "2026-02-30" }],
    ["short token", { ...VALID_PAYLOAD, token: VALID_TOKEN.slice(1) }],
    ["non-base64url token", { ...VALID_PAYLOAD, token: `${VALID_TOKEN.slice(1)}+` }],
    ["non-canonical 128-bit token", { ...VALID_PAYLOAD, token: `${"A".repeat(21)}B` }],
    ["empty version", { ...VALID_PAYLOAD, version: "" }],
    ["non-semver version", { ...VALID_PAYLOAD, version: "0.2" }],
    ["leading-zero version", { ...VALID_PAYLOAD, version: "0.02.41" }],
    ["overlong version", { ...VALID_PAYLOAD, version: `1.2.${"3".repeat(61)}` }],
    ["unknown brand", { ...VALID_PAYLOAD, brand: "other-monitor" }],
    ["unknown channel", { ...VALID_PAYLOAD, channel: "nightly" }],
  ])("rejects an invalid %s payload without touching D1", async (_label, payload) => {
    const database = new RecordingDatabase();

    const response = await handle(database, requestFor(payload));

    expect(response.status).toBe(400);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(database.preparedSQL).toEqual([]);
  });

  it("rejects malformed JSON without touching D1", async () => {
    const database = new RecordingDatabase();

    const response = await handle(database, requestFor(undefined, { body: "{" }));

    expect(response.status).toBe(400);
    expect(database.preparedSQL).toEqual([]);
  });

  it("returns 409 for a valid observation day other than the current UTC day", async () => {
    const database = new RecordingDatabase();

    const response = await handle(
      database,
      requestFor({ ...VALID_PAYLOAD, day: "2026-07-15" }),
    );

    expect(response.status).toBe(409);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(database.preparedSQL).toEqual([]);
  });

  it("does not spend a rate-limit token on basic request failures", async () => {
    const cases = [
      requestFor(undefined, { method: "GET", body: null }),
      requestFor(VALID_PAYLOAD, { url: "http://quota-monitor.test/api/v1/daily-active" }),
      requestFor(VALID_PAYLOAD, { contentType: "text/plain" }),
      requestFor(VALID_PAYLOAD, { contentLength: "2049" }),
    ];

    for (const request of cases) {
      const database = new RecordingDatabase();
      const limiter = new RecordingLimiter();
      await handle(database, request, undefined, limiter);
      expect(limiter.keys).toEqual([]);
      expect(database.preparedSQL).toEqual([]);
    }
  });

  it("cancels a request stream whose read rejects", async () => {
    const database = new RecordingDatabase();
    const cancel = vi.fn(async () => undefined);
    const releaseLock = vi.fn();
    const request = requestFor();
    Object.defineProperty(request, "body", {
      value: {
        getReader: () => ({
          read: vi.fn(async () => {
            throw new Error("synthetic stream failure");
          }),
          cancel,
          releaseLock,
        }),
      },
    });

    const response = await handle(database, request);

    expect(response.status).toBe(400);
    expect(cancel).toHaveBeenCalledOnce();
    expect(releaseLock).toHaveBeenCalledOnce();
    expect(database.preparedSQL).toEqual([]);
  });
});

describe("daily active abuse limiting", () => {
  it("checks the fixed per-colo global circuit breaker before the per-IP limiter", async () => {
    const database = new RecordingDatabase();
    const globalLimiter = new RecordingLimiter();
    const ipLimiter = new RecordingLimiter();

    const response = await handle(
      database,
      requestFor(VALID_PAYLOAD, { connectingIP: "203.0.113.40" }),
      undefined,
      ipLimiter,
      globalLimiter,
    );

    expect(response.status).toBe(204);
    expect(globalLimiter.keys).toEqual(["daily-active-global"]);
    expect(ipLimiter.keys).toEqual(["203.0.113.40"]);
  });

  it("returns 429 before the per-IP limiter, body read, or D1 when the global limit is exceeded", async () => {
    const database = new RecordingDatabase();
    const globalLimiter = new RecordingLimiter();
    const ipLimiter = new RecordingLimiter();
    globalLimiter.success = false;

    const response = await handle(
      database,
      requestFor(undefined, { body: "{malformed", connectingIP: "203.0.113.41" }),
      undefined,
      ipLimiter,
      globalLimiter,
    );

    expect(response.status).toBe(429);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(response.headers.get("Retry-After")).toBe("60");
    expect(await response.text()).toBe("");
    expect(globalLimiter.keys).toEqual(["daily-active-global"]);
    expect(ipLimiter.keys).toEqual([]);
    expect(database.preparedSQL).toEqual([]);
  });

  it("fails closed before the per-IP limiter and D1 when the global limiter is unavailable", async () => {
    const database = new RecordingDatabase();
    const globalLimiter = new RecordingLimiter();
    const ipLimiter = new RecordingLimiter();
    globalLimiter.shouldFail = true;

    const response = await handle(
      database,
      requestFor(undefined, { body: "{malformed" }),
      undefined,
      ipLimiter,
      globalLimiter,
    );

    expect(response.status).toBe(503);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(globalLimiter.keys).toEqual(["daily-active-global"]);
    expect(ipLimiter.keys).toEqual([]);
    expect(database.preparedSQL).toEqual([]);
  });

  it("uses the Cloudflare connecting IP only as the edge rate-limit key", async () => {
    const database = new RecordingDatabase();
    const limiter = new RecordingLimiter();
    const connectingIP = "203.0.113.42";

    const response = await handle(
      database,
      requestFor(VALID_PAYLOAD, { connectingIP }),
      undefined,
      limiter,
    );

    expect(response.status).toBe(204);
    expect(limiter.keys).toEqual([connectingIP]);
    expect(database.preparedSQL.join("\n")).not.toContain(connectingIP);
    expect(database.boundValues.flat()).not.toContain(connectingIP);
  });

  it("uses one fixed edge bucket when Cloudflare does not provide a connecting IP", async () => {
    const database = new RecordingDatabase();
    const limiter = new RecordingLimiter();

    const response = await handle(database, requestFor(), undefined, limiter);

    expect(response.status).toBe(204);
    expect(limiter.keys).toEqual(["missing-cf-connecting-ip"]);
  });

  it("returns 429 before reading the body or touching D1 when the edge limit is exceeded", async () => {
    const database = new RecordingDatabase();
    const limiter = new RecordingLimiter();
    limiter.success = false;

    const response = await handle(
      database,
      requestFor(undefined, {
        body: "{malformed",
        connectingIP: "203.0.113.43",
      }),
      undefined,
      limiter,
    );

    expect(response.status).toBe(429);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(response.headers.get("Retry-After")).toBe("60");
    expect(await response.text()).toBe("");
    expect(database.preparedSQL).toEqual([]);
  });

  it("fails closed with a generic 503 when the edge limiter is unavailable", async () => {
    const database = new RecordingDatabase();
    const limiter = new RecordingLimiter();
    limiter.shouldFail = true;

    const response = await handle(
      database,
      requestFor(undefined, { body: "{malformed" }),
      undefined,
      limiter,
    );

    expect(response.status).toBe(503);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(database.preparedSQL).toEqual([]);
  });
});

describe("daily active hashing and D1 upsert", () => {
  it("hashes the exact date-scoped v1 input and stores only bound values", async () => {
    const database = new RecordingDatabase();
    const digestBytes = new Uint8Array(32).fill(0xab);
    const digest = vi.fn(async (_bytes: Uint8Array) => digestBytes.buffer);
    const logSpies = [
      vi.spyOn(console, "debug").mockImplementation(() => undefined),
      vi.spyOn(console, "info").mockImplementation(() => undefined),
      vi.spyOn(console, "log").mockImplementation(() => undefined),
      vi.spyOn(console, "warn").mockImplementation(() => undefined),
      vi.spyOn(console, "error").mockImplementation(() => undefined),
    ];

    const response = await handle(database, requestFor(), digest);

    expect(response.status).toBe(204);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(await response.text()).toBe("");
    expect(digest).toHaveBeenCalledOnce();
    expect(new TextDecoder().decode(digest.mock.calls[0]?.[0])).toBe(
      `v1\0${VALID_PAYLOAD.day}\0${VALID_TOKEN}`,
    );

    const expectedHash = "ab".repeat(32);
    expect(database.preparedSQL).toHaveLength(1);
    expect(database.preparedSQL[0]).toMatch(/INSERT INTO daily_active_observations/i);
    expect(database.preparedSQL[0]).toMatch(/VALUES\s*\(\?1,\s*\?2,\s*\?3,\s*\?4,\s*\?5\)/i);
    expect(database.preparedSQL[0]).toMatch(/ON CONFLICT\s*\(day,\s*token_hash\)\s*DO UPDATE/i);
    expect(database.preparedSQL[0]).toMatch(/version\s*=\s*excluded\.version/i);
    expect(database.preparedSQL[0]).toMatch(/brand\s*=\s*excluded\.brand/i);
    expect(database.preparedSQL[0]).toMatch(/channel\s*=\s*excluded\.channel/i);
    expect(database.preparedSQL[0]).not.toContain(VALID_TOKEN);
    expect(database.boundValues).toEqual([
      [
        VALID_PAYLOAD.day,
        expectedHash,
        VALID_PAYLOAD.version,
        VALID_PAYLOAD.brand,
        VALID_PAYLOAD.channel,
      ],
    ]);
    expect(database.boundValues.flat()).not.toContain(VALID_TOKEN);
    expect(JSON.stringify(logSpies.flatMap((spy) => spy.mock.calls))).not.toContain(
      VALID_TOKEN,
    );
  });

  it("updates version, brand, and channel for the same day-scoped token", async () => {
    const database = new RecordingDatabase();
    const digest = async (): Promise<ArrayBuffer> => new Uint8Array(32).fill(0x11).buffer;

    const first = await handle(database, requestFor(), digest);
    const second = await handle(
      database,
      requestFor({
        ...VALID_PAYLOAD,
        version: "0.2.42",
        brand: "codex-monitor",
        channel: "app-store",
      }),
      digest,
    );

    expect(first.status).toBe(204);
    expect(second.status).toBe(204);
    expect(database.observations).toHaveLength(1);
    expect([...database.observations.values()]).toEqual([
      {
        day: VALID_PAYLOAD.day,
        tokenHash: "11".repeat(32),
        version: "0.2.42",
        brand: "codex-monitor",
        channel: "app-store",
      },
    ]);
  });

  it("returns a generic non-cacheable 503 without logging request data on storage failure", async () => {
    const database = new RecordingDatabase();
    database.shouldFail = true;
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await handle(database);
    const responseText = await response.text();

    expect(response.status).toBe(503);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(responseText).not.toContain(VALID_TOKEN);
    expect(responseText).not.toContain(VALID_PAYLOAD.day);
    expect(JSON.stringify(error.mock.calls)).not.toContain(VALID_TOKEN);
    expect(JSON.stringify(error.mock.calls)).not.toContain(VALID_PAYLOAD.day);
  });
});
