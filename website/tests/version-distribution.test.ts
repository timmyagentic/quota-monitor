import { createHash, timingSafeEqual } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import {
  aggregateClosedDays,
  handleVersionDistribution,
  parseVersionDistributionFilters,
  renderVersionDistributionHTML,
  type VersionDistributionView,
} from "../src/version-distribution";
import type { AdminAuthCrypto } from "../src/admin-auth";

const TODAY = "2026-07-16";
const SCHEDULED_TIME = Date.parse("2026-07-16T23:15:00.000Z");

const D1_META: D1Meta & Record<string, unknown> = {
  duration: 0,
  size_after: 0,
  rows_read: 0,
  rows_written: 0,
  last_row_id: 0,
  changed_db: false,
  changes: 0,
};

function d1Result<T>(results: T[]): D1Result<T> {
  return { success: true, meta: D1_META, results };
}

type QueryResolver = (query: string, bindings: unknown[]) => unknown[];

class RecordingStatement implements D1PreparedStatement {
  readonly bindings: unknown[] = [];

  constructor(
    readonly query: string,
    private readonly resolver: QueryResolver,
  ) {}

  bind(...values: unknown[]): D1PreparedStatement {
    this.bindings.splice(0, this.bindings.length, ...values);
    return this;
  }

  async first<T = unknown>(colName?: string): Promise<T | null> {
    const first = this.resolver(this.query, this.bindings)[0];
    if (first === undefined) return null;
    if (colName !== undefined && typeof first === "object" && first !== null) {
      return (first as Record<string, unknown>)[colName] as T ?? null;
    }
    return first as T;
  }

  async run<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    return d1Result(this.resolver(this.query, this.bindings) as T[]);
  }

  async all<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    return d1Result(this.resolver(this.query, this.bindings) as T[]);
  }

  async raw<T = unknown[]>(options: { columnNames: true }): Promise<[string[], ...T[]]>;
  async raw<T = unknown[]>(options?: { columnNames?: false }): Promise<T[]>;
  async raw<T = unknown[]>(
    options?: { columnNames?: boolean },
  ): Promise<T[] | [string[], ...T[]]> {
    const values = this.resolver(this.query, this.bindings) as T[];
    return options?.columnNames === true ? [[], ...values] : values;
  }
}

class RecordingDatabase implements D1Database {
  readonly statements: RecordingStatement[] = [];
  readonly batches: RecordingStatement[][] = [];
  prepareCount = 0;
  batchFailure: Error | null = null;

  constructor(private readonly resolver: QueryResolver = () => []) {}

  prepare(query: string): D1PreparedStatement {
    this.prepareCount += 1;
    const statement = new RecordingStatement(query, this.resolver);
    this.statements.push(statement);
    return statement;
  }

  async batch<T = unknown>(statements: D1PreparedStatement[]): Promise<D1Result<T>[]> {
    this.batches.push(statements as RecordingStatement[]);
    if (this.batchFailure !== null) throw this.batchFailure;
    return statements.map(() => d1Result<T>([]));
  }

  async exec(): Promise<D1ExecResult> {
    return { count: 0, duration: 0 };
  }

  withSession(): D1DatabaseSession {
    throw new Error("sessions are not used by version distribution");
  }

  async dump(): Promise<ArrayBuffer> {
    return new ArrayBuffer(0);
  }
}

class RecordingLimiter implements RateLimit {
  readonly keys: string[] = [];
  success = true;
  shouldFail = false;

  async limit(options: RateLimitOptions): Promise<RateLimitOutcome> {
    this.keys.push(options.key);
    if (this.shouldFail) throw new Error("synthetic limiter failure");
    return { success: this.success };
  }
}

const authCrypto: AdminAuthCrypto = {
  async digest(bytes: Uint8Array): Promise<ArrayBuffer> {
    const digest = createHash("sha256").update(bytes).digest();
    return digest.buffer.slice(digest.byteOffset, digest.byteOffset + digest.byteLength);
  },
  timingSafeEqual(left: ArrayBuffer, right: ArrayBuffer): boolean {
    return timingSafeEqual(new Uint8Array(left), new Uint8Array(right));
  },
};

function authorization(secret = "dashboard-secret"): string {
  return `Basic ${btoa(`admin:${secret}`)}`;
}

function dashboardRequest(
  query = "",
  options: { authorization?: string | null; connectingIP?: string } = {},
): Request {
  const headers = new Headers();
  if (options.authorization !== null) {
    headers.set("Authorization", options.authorization ?? authorization());
  }
  if (options.connectingIP !== undefined) {
    headers.set("CF-Connecting-IP", options.connectingIP);
  }
  return new Request(`https://quota-monitor.test/maintainer/versions${query}`, { headers });
}

describe("closed-day aggregation", () => {
  it("uses one atomic D1 batch to upsert every missed closed day before cleanup", async () => {
    const database = new RecordingDatabase();

    await aggregateClosedDays(database, SCHEDULED_TIME);

    expect(database.batches).toHaveLength(1);
    expect(database.batches[0]).toHaveLength(3);
    const [aggregate, deleteRaw, deleteExpired] = database.batches[0] ?? [];

    expect(aggregate?.query).toMatch(/INSERT INTO daily_version_counts/i);
    expect(aggregate?.query).toMatch(/SELECT\s+day,\s*version,\s*brand,\s*channel,\s*COUNT\(\*\)/is);
    expect(aggregate?.query).toMatch(/FROM daily_active_observations/i);
    expect(aggregate?.query).toMatch(/WHERE day < \?1/i);
    expect(aggregate?.query).toMatch(/GROUP BY\s+day,\s*version,\s*brand,\s*channel/is);
    expect(aggregate?.query).toMatch(/ON CONFLICT\s*\(day,\s*version,\s*brand,\s*channel\)\s*DO UPDATE/is);
    expect(aggregate?.query).toMatch(/active_count\s*=\s*excluded\.active_count/i);
    expect(aggregate?.bindings).toEqual([TODAY]);

    expect(deleteRaw?.query).toMatch(/DELETE FROM daily_active_observations/i);
    expect(deleteRaw?.query).toMatch(/WHERE day < \?1/i);
    expect(deleteRaw?.bindings).toEqual([TODAY]);

    expect(deleteExpired?.query).toMatch(/DELETE FROM daily_version_counts/i);
    expect(deleteExpired?.query).toMatch(/WHERE day < \?1/i);
    expect(deleteExpired?.bindings).toEqual(["2025-06-11"]);

    for (const statement of database.batches[0] ?? []) {
      expect(statement.query).not.toContain(TODAY);
      expect(statement.query).not.toContain("2025-06-11");
    }
  });

  it("preserves existing aggregates when a repeated cron finds no raw observations", async () => {
    let aggregateCount = 17;
    const database = new RecordingDatabase();
    database.batch = vi.fn(async (statements: D1PreparedStatement[]) => {
      const [aggregate] = statements as RecordingStatement[];
      if (!aggregate?.query.match(/INSERT\s+INTO\s+daily_version_counts[\s\S]+SELECT/i)) {
        aggregateCount = 0;
      }
      return statements.map(() => d1Result([]));
    });

    await aggregateClosedDays(database, SCHEDULED_TIME);
    await aggregateClosedDays(database, SCHEDULED_TIME + 30 * 60 * 1000);

    expect(aggregateCount).toBe(17);
    expect(database.batch).toHaveBeenCalledTimes(2);
    const batchCalls = vi.mocked(database.batch).mock.calls;
    for (const [statements] of batchCalls) {
      expect((statements[0] as RecordingStatement).query).toMatch(
        /INSERT\s+INTO\s+daily_version_counts[\s\S]+SELECT/i,
      );
    }
  });

  it("relies on one transactional batch so a cleanup failure cannot commit partial aggregation", async () => {
    const database = new RecordingDatabase();
    database.batchFailure = new Error("synthetic second-statement failure");

    await expect(aggregateClosedDays(database, SCHEDULED_TIME)).rejects.toThrow(
      "synthetic second-statement failure",
    );
    expect(database.batches).toHaveLength(1);
    expect(database.batches[0]).toHaveLength(3);
  });

  it("keeps the exact 400-day boundary and removes only older aggregate days", async () => {
    const database = new RecordingDatabase();

    await aggregateClosedDays(database, Date.parse("2026-01-01T00:00:00.000Z"));

    expect(database.batches[0]?.[2]?.bindings).toEqual(["2024-11-27"]);
  });
});

describe("version distribution queries and filters", () => {
  it.each([
    ["", { range: 30, brand: null, channel: null }],
    ["?range=7", { range: 7, brand: null, channel: null }],
    ["?range=90&brand=codex-monitor&channel=app-store", { range: 90, brand: "codex-monitor", channel: "app-store" }],
    ["?range=400&brand=quota-monitor&channel=developer-id", { range: 400, brand: "quota-monitor", channel: "developer-id" }],
    ["?range=365&brand=evil&channel=nightly", { range: 30, brand: null, channel: null }],
  ])("allowlists dashboard filters for %s", (query, expected) => {
    expect(
      parseVersionDistributionFilters(new URL(`https://quota-monitor.test/${query}`)),
    ).toEqual(expected);
  });

  it("queries today only from provisional observations and history only from aggregates", async () => {
    const database = new RecordingDatabase((query) => {
      if (query.includes("daily_active_observations")) {
        return [{ day: TODAY, version: "0.2.42", brand: "quota-monitor", channel: "developer-id", active_count: 3 }];
      }
      if (query.includes("daily_version_counts")) {
        return [{ day: "2026-07-15", version: "0.2.41", brand: "quota-monitor", channel: "developer-id", active_count: 2 }];
      }
      return [];
    });
    const limiter = new RecordingLimiter();

    const response = await handleVersionDistribution(
      dashboardRequest("?range=7&brand=quota-monitor&channel=developer-id"),
      database,
      "dashboard-secret",
      limiter,
      { now: () => new Date(`${TODAY}T10:00:00.000Z`), authCrypto },
    );

    expect(response.status).toBe(200);
    expect(database.statements).toHaveLength(2);
    const provisional = database.statements.find((statement) =>
      statement.query.includes("daily_active_observations"),
    );
    const historical = database.statements.find((statement) =>
      statement.query.includes("daily_version_counts"),
    );
    expect(provisional?.query).toMatch(/WHERE day = \?1/i);
    expect(provisional?.query).not.toContain("daily_version_counts");
    expect(provisional?.bindings).toEqual([
      TODAY,
      "quota-monitor",
      "quota-monitor",
      "developer-id",
      "developer-id",
    ]);
    expect(historical?.query).toMatch(/day >= \?1\s+AND day < \?2/i);
    expect(historical?.query).not.toContain("daily_active_observations");
    expect(historical?.bindings).toEqual([
      "2026-04-17",
      TODAY,
      "quota-monitor",
      "quota-monitor",
      "developer-id",
      "developer-id",
    ]);
  });
});

describe("private maintainer dashboard", () => {
  it.each([undefined, "", "   "])(
    "fails closed with a generic 503 when the admin secret is %j",
    async (secret) => {
      const database = new RecordingDatabase();
      const limiter = new RecordingLimiter();

      const response = await handleVersionDistribution(
        dashboardRequest(),
        database,
        secret,
        limiter,
        { now: () => new Date(), authCrypto },
      );

      expect(response.status).toBe(503);
      expect(await response.text()).toBe("Service unavailable");
      expect(response.headers.get("Cache-Control")).toBe("private, no-store");
      expect(response.headers.get("Vary")).toBe("Authorization");
      expect(database.prepareCount).toBe(0);
      expect(limiter.keys).toEqual([]);
    },
  );

  it("returns a Basic challenge for failed authentication before every D1 query", async () => {
    const database = new RecordingDatabase();
    const limiter = new RecordingLimiter();

    const response = await handleVersionDistribution(
      dashboardRequest("", { authorization: authorization("wrong"), connectingIP: "203.0.113.10" }),
      database,
      "dashboard-secret",
      limiter,
      { now: () => new Date(), authCrypto },
    );

    expect(response.status).toBe(401);
    expect(response.headers.get("WWW-Authenticate")).toBe(
      'Basic realm="QuotaMonitor version distribution", charset="UTF-8"',
    );
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(response.headers.get("Vary")).toBe("Authorization");
    expect(await response.text()).toBe("Authentication required");
    expect(limiter.keys).toEqual(["203.0.113.10"]);
    expect(database.prepareCount).toBe(0);
  });

  it("uses a fixed fallback bucket and returns 429 without querying D1", async () => {
    const database = new RecordingDatabase();
    const limiter = new RecordingLimiter();
    limiter.success = false;

    const response = await handleVersionDistribution(
      dashboardRequest(),
      database,
      "dashboard-secret",
      limiter,
      { now: () => new Date(), authCrypto },
    );

    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("60");
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(response.headers.get("Vary")).toBe("Authorization");
    expect(limiter.keys).toEqual(["missing-cf-connecting-ip"]);
    expect(database.prepareCount).toBe(0);
  });

  it("fails closed with a generic 503 when the admin limiter is unavailable", async () => {
    const database = new RecordingDatabase();
    const limiter = new RecordingLimiter();
    limiter.shouldFail = true;

    const response = await handleVersionDistribution(
      dashboardRequest(),
      database,
      "dashboard-secret",
      limiter,
      { now: () => new Date(), authCrypto },
    );

    expect(response.status).toBe(503);
    expect(await response.text()).toBe("Service unavailable");
    expect(database.prepareCount).toBe(0);
  });

  it("renders semantic escaped HTML with the required estimates, trends, filters, and anomaly signal", () => {
    const view: VersionDistributionView = {
      today: TODAY,
      filters: { range: 30, brand: null, channel: null },
      provisional: [
        { day: TODAY, version: "0.2.43", brand: "quota-monitor", channel: "developer-id", activeCount: 12 },
      ],
      historical: [
        { day: "2026-07-13", version: "0.2.41", brand: "quota-monitor", channel: "developer-id", activeCount: 2 },
        { day: "2026-07-14", version: "0.2.42", brand: "quota-monitor", channel: "developer-id", activeCount: 3 },
        { day: "2026-07-15", version: "0.2.43", brand: "quota-monitor", channel: "developer-id", activeCount: 20 },
        { day: "2026-07-15", version: "0.2.42<script>alert(1)</script>", brand: "codex-monitor", channel: "app-store", activeCount: 1 },
      ],
    };

    const html = renderVersionDistributionHTML(view);

    expect(html).toContain("<!doctype html>");
    expect(html).toContain('<main id="main-content"');
    expect(html).toContain('<link rel="stylesheet" href="/styles.css">');
    expect(html).not.toMatch(/<script\b/i);
    expect(html).toContain("Latest complete-day check-ins");
    expect(html).toContain("2026-07-15");
    expect(html).toContain(">21<");
    expect(html).toContain("Today provisional");
    expect(html).toContain(">12<");
    expect(html).toContain("Newest observed version");
    expect(html).toContain("0.2.43");
    expect(html).toContain("100.0%");
    expect(html).toContain("7-day trend");
    expect(html).toContain("30-day trend");
    expect(html).toContain("90-day trend");
    expect(html).toContain('name="range"');
    expect(html).toContain('value="400"');
    expect(html).toContain('name="brand"');
    expect(html).toContain('value="quota-monitor"');
    expect(html).toContain('name="channel"');
    expect(html).toContain('value="developer-id"');
    expect(html).toContain("Count and share by version");
    expect(html).toContain("Anomaly signal");
    expect(html).toContain("more than twice the prior 7-day average");
    expect(html).toContain("Best-effort public unauthenticated sample");
    expect(html).toContain("estimated active installations");
    expect(html).toContain("date-scoped deduplication");
    expect(html).toContain("not people, total installs, or exact measurements");
    expect(html).not.toMatch(/\busers?\b/i);
    expect(html).not.toContain("0.2.42<script>");
    expect(html).toContain("0.2.42&lt;script&gt;alert(1)&lt;/script&gt;");
    expect(html).not.toMatch(/\btoken(?:_hash)?\b/i);
    expect(html).not.toMatch(/authorization/i);
    expect(html).not.toContain("daily_active_observations");
  });

  it("returns an authenticated non-cacheable dashboard without secret or raw-row material", async () => {
    const rawHash = "ab".repeat(32);
    const database = new RecordingDatabase((query) => {
      if (query.includes("daily_active_observations")) {
        return [{ day: TODAY, version: "0.2.43", brand: "quota-monitor", channel: "developer-id", active_count: 4, token_hash: rawHash }];
      }
      return [{ day: "2026-07-15", version: "0.2.42", brand: "quota-monitor", channel: "developer-id", active_count: 3 }];
    });
    const limiter = new RecordingLimiter();

    const response = await handleVersionDistribution(
      dashboardRequest("?range=30", { connectingIP: "203.0.113.11" }),
      database,
      "dashboard-secret",
      limiter,
      { now: () => new Date(`${TODAY}T20:00:00.000Z`), authCrypto },
    );
    const html = await response.text();

    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(response.headers.get("Vary")).toBe("Authorization");
    expect(response.headers.get("Content-Type")).toBe("text/html; charset=utf-8");
    expect(limiter.keys).toEqual(["203.0.113.11"]);
    expect(html).not.toContain("dashboard-secret");
    expect(html).not.toContain(rawHash);
    expect(html).not.toMatch(/\btoken(?:_hash)?\b/i);
    expect(html).not.toMatch(/authorization/i);
  });
});
