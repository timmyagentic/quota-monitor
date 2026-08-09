import { timingSafeEqual, webcrypto } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  handlePrivateBetaAdmin,
  handlePrivateBetaEnrollment,
  handlePrivateBetaResource,
} from "../src/private-beta";

const adminSecret = "a-secure-private-beta-admin-secret";

class Statement {
  bindings: unknown[] = [];

  constructor(
    readonly query: string,
    private readonly firstResult: unknown,
    private readonly changes = 1,
  ) {}

  bind(...values: unknown[]): D1PreparedStatement {
    this.bindings = values;
    return this as unknown as D1PreparedStatement;
  }

  async first<T>(): Promise<T | null> {
    return this.firstResult as T | null;
  }

  async run<T>(): Promise<D1Result<T>> {
    return {
      success: true,
      results: [],
      meta: { changes: this.changes },
    } as unknown as D1Result<T>;
  }
}

class Database {
  statements: Statement[] = [];
  firstResults: unknown[] = [];
  changes: number[] = [];

  prepare(query: string): D1PreparedStatement {
    const statement = new Statement(
      query,
      this.firstResults.shift() ?? null,
      this.changes.shift() ?? 1,
    );
    this.statements.push(statement);
    return statement as unknown as D1PreparedStatement;
  }

  async batch<T = unknown>(
    statements: D1PreparedStatement[],
  ): Promise<D1Result<T>[]> {
    return Promise.all(statements.map((statement) => statement.run<T>()));
  }
}

function limiter(success = true): RateLimit {
  return {
    async limit(): Promise<RateLimitOutcome> {
      return { success };
    },
  };
}

function objectBody(
  bytes: Uint8Array,
  range?: R2Range,
): R2ObjectBody {
  return {
    key: "private-beta/artifacts/app.dmg",
    version: "1",
    size: 10,
    etag: "etag",
    httpEtag: "\"etag\"",
    checksums: {},
    uploaded: new Date(0),
    storageClass: "Standard",
    range,
    body: new Response(bytes).body!,
    bodyUsed: false,
    writeHttpMetadata(headers: Headers): void {
      headers.set("Content-Type", "application/x-apple-diskimage");
    },
  } as unknown as R2ObjectBody;
}

function lockObject(value: string, etag: string): R2ObjectBody {
  const response = new Response(value);
  return {
    key: "private-beta/publication-lock.json",
    version: etag,
    size: value.length,
    etag,
    httpEtag: `"${etag}"`,
    checksums: {},
    uploaded: new Date(0),
    storageClass: "Standard",
    body: response.body!,
    bodyUsed: false,
    text: () => response.text(),
    writeHttpMetadata(): void {},
  } as unknown as R2ObjectBody;
}

function publicationLockBucket(): R2Bucket {
  let stored: { value: string; etag: string } | null = null;
  let revision = 0;
  return {
    async get(): Promise<R2ObjectBody | null> {
      return stored === null ? null : lockObject(stored.value, stored.etag);
    },
    async put(
      _key: string,
      value: ReadableStream | ArrayBuffer | ArrayBufferView | string | null | Blob,
      options?: R2PutOptions,
    ): Promise<R2Object | null> {
      const condition = options?.onlyIf;
      if (
        condition instanceof Headers &&
        condition.get("If-None-Match") === "*" &&
        stored !== null
      ) {
        return null;
      }
      if (
        condition instanceof Headers &&
        condition.has("If-Match") &&
        condition.get("If-Match") !== `"${stored?.etag}"`
      ) {
        return null;
      }
      if (
        condition !== undefined &&
        !(condition instanceof Headers) &&
        condition.etagMatches !== undefined &&
        condition.etagMatches !== stored?.etag
      ) {
        return null;
      }
      revision += 1;
      stored = { value: String(value), etag: `etag-${revision}` };
      return lockObject(stored.value, stored.etag);
    },
  } as unknown as R2Bucket;
}

function environment(
  database = new Database(),
  bucketGet: R2ObjectBody | null = objectBody(new Uint8Array([1, 2, 3])),
): Env {
  return {
    PRIVATE_BETA_DB: database as unknown as D1Database,
    PRIVATE_BETA_BUCKET: {
      async get(): Promise<R2ObjectBody | null> {
        return bucketGet;
      },
      async head(): Promise<R2Object | null> {
        return bucketGet;
      },
    } as unknown as R2Bucket,
    PRIVATE_BETA_ENROLL_RATE_LIMITER: limiter(),
    PRIVATE_BETA_RESOURCE_RATE_LIMITER: limiter(),
    PRIVATE_BETA_ADMIN_RATE_LIMITER: limiter(),
    PRIVATE_BETA_ADMIN_TOKEN: adminSecret,
  } as Env;
}

function jsonRequest(path: string, body: unknown): Request {
  const serialized = JSON.stringify(body);
  return new Request(`https://example.test${path}`, {
    method: "POST",
    headers: {
      "Content-Length": String(new TextEncoder().encode(serialized).byteLength),
      "Content-Type": "application/json",
    },
    body: serialized,
  });
}

function adminJSONRequest(path: string, body: unknown): Request {
  const request = jsonRequest(path, body);
  request.headers.set("Authorization", basic(adminSecret));
  return request;
}

function basic(secret: string): string {
  return `Basic ${btoa(`admin:${secret}`)}`;
}

beforeEach(() => {
  vi.stubGlobal("crypto", {
    randomUUID: () => "11111111-1111-4111-8111-111111111111",
    getRandomValues<T extends ArrayBufferView>(array: T): T {
      new Uint8Array(array.buffer, array.byteOffset, array.byteLength).fill(7);
      return array;
    },
    subtle: {
      digest: webcrypto.subtle.digest.bind(webcrypto.subtle),
      timingSafeEqual(left: ArrayBuffer, right: ArrayBuffer): boolean {
        return timingSafeEqual(new Uint8Array(left), new Uint8Array(right));
      },
    },
  });
});

describe("private Beta enrollment", () => {
  it("consumes a one-time code and stores only the device token digest", async () => {
    const database = new Database();
    database.changes = [1, 1];
    const response = await handlePrivateBetaEnrollment(
      jsonRequest("/api/private-beta/enroll", {
        code: "ABCD-EFGH-JKLM-NPQR",
        deviceLabel: "Timmy Mac",
      }),
      environment(database),
      1_000,
    );
    const payload = await response.json<{ deviceID: string; token: string }>();

    expect(response.status).toBe(201);
    expect(payload.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(database.statements[0]?.query).toContain("INSERT INTO private_beta_devices");
    expect(database.statements[1]?.query).toContain("UPDATE private_beta_enrollment_codes");
    expect(database.statements[0]?.bindings).not.toContain(payload.token);
    expect(database.statements[0]?.bindings[1]).toMatch(/^[0-9a-f]{64}$/);
  });

  it("does not create a device when a code cannot be claimed", async () => {
    const database = new Database();
    database.changes = [0, 0];
    const response = await handlePrivateBetaEnrollment(
      jsonRequest("/api/private-beta/enroll", {
        code: "ABCD-EFGH-JKLM-NPQR",
        deviceLabel: "Timmy Mac",
      }),
      environment(database),
      1_000,
    );
    expect(response.status).toBe(404);
    expect(database.statements).toHaveLength(2);
  });

  it.each([
    ["missing code", { deviceLabel: "Mac" }],
    ["malformed code", { code: "wrong", deviceLabel: "Mac" }],
    ["empty label", { code: "ABCD-EFGH-JKLM-NPQR", deviceLabel: "" }],
  ])("fails closed for %s", async (_label, body) => {
    const response = await handlePrivateBetaEnrollment(
      jsonRequest("/api/private-beta/enroll", body),
      environment(),
    );
    expect(response.status).toBe(404);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("fails closed when enrollment is rate limited", async () => {
    const env = environment();
    env.PRIVATE_BETA_ENROLL_RATE_LIMITER = limiter(false);
    const response = await handlePrivateBetaEnrollment(
      jsonRequest("/api/private-beta/enroll", {
        code: "ABCD-EFGH-JKLM-NPQR",
        deviceLabel: "Mac",
      }),
      env,
    );
    expect(response.status).toBe(404);
  });
});

describe("private Beta administration", () => {
  it("creates a short-lived one-time enrollment code without storing plaintext", async () => {
    const database = new Database();
    const response = await handlePrivateBetaAdmin(
      new Request("https://example.test/api/private-beta/admin/enrollment-codes", {
        method: "POST",
        headers: { Authorization: basic(adminSecret) },
      }),
      environment(database),
      "/api/private-beta/admin/enrollment-codes",
      10_000,
    );
    const payload = await response.json<{ code: string; expiresAt: string }>();

    expect(response.status).toBe(201);
    expect(payload.code).toMatch(/^[A-Z2-9]{4}(?:-[A-Z2-9]{4}){3}$/);
    expect(database.statements[0]?.bindings).not.toContain(payload.code);
    expect(database.statements[0]?.bindings[0]).toMatch(/^[0-9a-f]{64}$/);
  });

  it("revokes one device and hides missing devices", async () => {
    const database = new Database();
    database.changes = [1, 0];
    const env = environment(database);
    const path =
      "/api/private-beta/admin/devices/11111111-1111-4111-8111-111111111111/revoke";
    const request = new Request(`https://example.test${path}`, {
      method: "POST",
      headers: { Authorization: basic(adminSecret) },
    });

    expect((await handlePrivateBetaAdmin(request, env, path)).status).toBe(200);
    expect((await handlePrivateBetaAdmin(request, env, path)).status).toBe(404);
  });

  it("fails closed when the configured admin secret is too short", async () => {
    const env = environment();
    env.PRIVATE_BETA_ADMIN_TOKEN = "short";
    const path = "/api/private-beta/admin/enrollment-codes";
    const response = await handlePrivateBetaAdmin(
      new Request(`https://example.test${path}`, {
        method: "POST",
        headers: { Authorization: basic("short") },
      }),
      env,
      path,
    );
    expect(response.status).toBe(404);
  });

  it("atomically serializes publication leases and requires the holder to release", async () => {
    const env = environment();
    env.PRIVATE_BETA_BUCKET = publicationLockBucket();
    const acquirePath = "/api/private-beta/admin/publication-lock/acquire";
    const releasePath = "/api/private-beta/admin/publication-lock/release";
    const firstID = "A".repeat(43);
    const secondID = "B".repeat(43);

    const [first, competing] = await Promise.all([
      handlePrivateBetaAdmin(
        adminJSONRequest(acquirePath, { publicationID: firstID }),
        env,
        acquirePath,
        10_000,
      ),
      handlePrivateBetaAdmin(
        adminJSONRequest(acquirePath, { publicationID: secondID }),
        env,
        acquirePath,
        10_000,
      ),
    ]);
    expect([first.status, competing.status].sort()).toEqual([201, 404]);

    const wrongRelease = await handlePrivateBetaAdmin(
      adminJSONRequest(releasePath, { publicationID: secondID }),
      env,
      releasePath,
      20_000,
    );
    expect(wrongRelease.status).toBe(404);

    const release = await handlePrivateBetaAdmin(
      adminJSONRequest(releasePath, { publicationID: firstID }),
      env,
      releasePath,
      20_000,
    );
    expect(release.status).toBe(200);

    const next = await handlePrivateBetaAdmin(
      adminJSONRequest(acquirePath, { publicationID: secondID }),
      env,
      acquirePath,
      20_000,
    );
    expect(next.status).toBe(201);
  });

  it("renews a publication lease only for its current holder", async () => {
    const env = environment();
    env.PRIVATE_BETA_BUCKET = publicationLockBucket();
    const acquirePath = "/api/private-beta/admin/publication-lock/acquire";
    const renewPath = "/api/private-beta/admin/publication-lock/renew";
    const firstID = "A".repeat(43);
    const secondID = "B".repeat(43);

    const acquired = await handlePrivateBetaAdmin(
      adminJSONRequest(acquirePath, { publicationID: firstID }),
      env,
      acquirePath,
      10_000,
    );
    expect(acquired.status).toBe(201);

    const wrongHolder = await handlePrivateBetaAdmin(
      adminJSONRequest(renewPath, { publicationID: secondID }),
      env,
      renewPath,
      20_000,
    );
    expect(wrongHolder.status).toBe(404);

    const renewed = await handlePrivateBetaAdmin(
      adminJSONRequest(renewPath, { publicationID: firstID }),
      env,
      renewPath,
      20_000,
    );
    expect(renewed.status).toBe(200);
    expect(await renewed.json()).toEqual({
      renewed: true,
      expiresAt: new Date(20_000 + 30 * 60 * 1_000).toISOString(),
    });

    const competing = await handlePrivateBetaAdmin(
      adminJSONRequest(acquirePath, { publicationID: secondID }),
      env,
      acquirePath,
      10_000 + 30 * 60 * 1_000 + 1,
    );
    expect(competing.status).toBe(404);
  });
});

describe("private Beta resources", () => {
  it("uses the same hidden response for missing, invalid, and revoked credentials", async () => {
    const database = new Database();
    database.firstResults = [null, null];
    const env = environment(database, null);
    const path = "/api/private-beta/artifacts/app.dmg";
    const missing = await handlePrivateBetaResource(
      new Request(`https://example.test${path}`),
      env,
      path,
    );
    const invalid = await handlePrivateBetaResource(
      new Request(`https://example.test${path}`, {
        headers: { Authorization: "Bearer invalid" },
      }),
      env,
      path,
    );

    expect([missing.status, invalid.status]).toEqual([404, 404]);
    expect(await missing.text()).toBe(await invalid.text());
  });

  it("streams authenticated appcast, release notes, and artifacts", async () => {
    for (const path of [
      "/api/private-beta/appcast.xml",
      "/api/private-beta/notes/0.2.44.en.html",
      "/api/private-beta/artifacts/QuotaMonitor-0.2.44-beta.1.dmg",
    ]) {
      const database = new Database();
      database.firstResults = [{ device_id: "device-1" }];
      const response = await handlePrivateBetaResource(
        new Request(`https://example.test${path}`, {
          headers: {
            Authorization: `Bearer ${"A".repeat(43)}`,
          },
        }),
        environment(database),
        path,
      );
      expect(response.status).toBe(200);
      expect(response.body).not.toBeNull();
      expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    }
  });

  it("keeps full downloads out of the R2 range path", async () => {
    const database = new Database();
    database.firstResults = [{ device_id: "device-1" }];
    const env = environment(database);
    let getOptions: R2GetOptions | undefined;
    env.PRIVATE_BETA_BUCKET = {
      async get(_key: string, options?: R2GetOptions): Promise<R2ObjectBody> {
        getOptions = options;
        return objectBody(new Uint8Array(10));
      },
    } as unknown as R2Bucket;
    const path = "/api/private-beta/artifacts/app.dmg";
    const response = await handlePrivateBetaResource(
      new Request(`https://example.test${path}`, {
        headers: { Authorization: `Bearer ${"A".repeat(43)}` },
      }),
      env,
      path,
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Length")).toBe("10");
    expect(response.headers.get("Content-Range")).toBeNull();
    expect(getOptions).toBeUndefined();
  });

  it("preserves byte ranges for Sparkle downloads", async () => {
    const database = new Database();
    database.firstResults = [{ device_id: "device-1" }];
    const env = environment(database);
    let getOptions: R2GetOptions | undefined;
    env.PRIVATE_BETA_BUCKET = {
      async get(_key: string, options?: R2GetOptions): Promise<R2ObjectBody> {
        getOptions = options;
        return objectBody(new Uint8Array([4, 5, 6]));
      },
    } as unknown as R2Bucket;
    const response = await handlePrivateBetaResource(
      new Request("https://example.test/api/private-beta/artifacts/app.dmg", {
        headers: {
          Authorization: `Bearer ${"A".repeat(43)}`,
          Range: "bytes=4-6",
        },
      }),
      env,
      "/api/private-beta/artifacts/app.dmg",
    );

    expect(response.status).toBe(206);
    expect(response.headers.get("Content-Range")).toBe("bytes 4-6/10");
    expect(response.headers.get("Content-Length")).toBe("3");
    expect(response.headers.get("Accept-Ranges")).toBe("bytes");
    expect(getOptions?.range).toEqual({ offset: 4, length: 3 });
  });

  it("preserves the zero-offset probe used before a Sparkle download", async () => {
    const database = new Database();
    database.firstResults = [{ device_id: "device-1" }];
    const env = environment(database);
    let getOptions: R2GetOptions | undefined;
    env.PRIVATE_BETA_BUCKET = {
      async get(_key: string, options?: R2GetOptions): Promise<R2ObjectBody> {
        getOptions = options;
        return objectBody(new Uint8Array([0]));
      },
    } as unknown as R2Bucket;
    const path = "/api/private-beta/artifacts/app.dmg";
    const response = await handlePrivateBetaResource(
      new Request(`https://example.test${path}`, {
        headers: {
          Authorization: `Bearer ${"A".repeat(43)}`,
          Range: "bytes=0-0",
        },
      }),
      env,
      path,
    );

    expect(response.status).toBe(206);
    expect(response.headers.get("Content-Length")).toBe("1");
    expect(response.headers.get("Content-Range")).toBe("bytes 0-0/10");
    expect(getOptions?.range).toEqual({ offset: 0, length: 1 });
  });

  it("normalizes an open-ended range before reading R2", async () => {
    const database = new Database();
    database.firstResults = [{ device_id: "device-1" }];
    const env = environment(database);
    let getOptions: R2GetOptions | undefined;
    env.PRIVATE_BETA_BUCKET = {
      async get(_key: string, options?: R2GetOptions): Promise<R2ObjectBody> {
        getOptions = options;
        return objectBody(new Uint8Array(6));
      },
    } as unknown as R2Bucket;
    const path = "/api/private-beta/artifacts/app.dmg";
    const response = await handlePrivateBetaResource(
      new Request(`https://example.test${path}`, {
        headers: {
          Authorization: `Bearer ${"A".repeat(43)}`,
          Range: "bytes=4-",
        },
      }),
      env,
      path,
    );

    expect(response.status).toBe(206);
    expect(response.headers.get("Content-Range")).toBe("bytes 4-9/10");
    expect(getOptions?.range).toEqual({ offset: 4 });
  });

  it.each([
    ["bytes=-3", { offset: 7, length: 3 }, 3, "bytes 7-9/10"],
    ["bytes=-20", { offset: 0, length: 10 }, 10, "bytes 0-9/10"],
  ])(
    "converts the supported suffix range %s into an explicit R2 read",
    async (header, expectedStorageRange, bodyLength, expectedContentRange) => {
      const database = new Database();
      database.firstResults = [{ device_id: "device-1" }];
      const env = environment(database);
      let getOptions: R2GetOptions | undefined;
      const head = vi.fn(async () => objectBody(new Uint8Array()));
      env.PRIVATE_BETA_BUCKET = {
        head,
        async get(_key: string, options?: R2GetOptions): Promise<R2ObjectBody> {
          getOptions = options;
          return objectBody(new Uint8Array(bodyLength));
        },
      } as unknown as R2Bucket;
      const path = "/api/private-beta/artifacts/app.dmg";
      const response = await handlePrivateBetaResource(
        new Request(`https://example.test${path}`, {
          headers: {
            Authorization: `Bearer ${"A".repeat(43)}`,
            Range: header,
          },
        }),
        env,
        path,
      );

      expect(response.status).toBe(206);
      expect(response.headers.get("Content-Range")).toBe(expectedContentRange);
      expect(response.headers.get("Content-Length")).toBe(String(bodyLength));
      expect(getOptions?.range).toEqual(expectedStorageRange);
      expect(head).toHaveBeenCalledOnce();
    },
  );

  it.each([
    "bytes=",
    "bytes=-0",
    "bytes=6-4",
    "bytes=0-0,2-2",
    "items=0-1",
    "bytes=999999999999999999999-",
  ])("fails closed before R2 for malformed range %s", async (header) => {
    const database = new Database();
    database.firstResults = [{ device_id: "device-1" }];
    const env = environment(database);
    const get = vi.fn();
    env.PRIVATE_BETA_BUCKET = { get } as unknown as R2Bucket;
    const path = "/api/private-beta/artifacts/app.dmg";
    const response = await handlePrivateBetaResource(
      new Request(`https://example.test${path}`, {
        headers: {
          Authorization: `Bearer ${"A".repeat(43)}`,
          Range: header,
        },
      }),
      env,
      path,
    );

    expect(response.status).toBe(404);
    expect(get).not.toHaveBeenCalled();
  });

  it("ignores malformed production R2 range metadata", async () => {
    const database = new Database();
    database.firstResults = [{ device_id: "device-1" }];
    const malformedRange = { offset: Number.NaN, length: Number.NaN };
    const response = await handlePrivateBetaResource(
      new Request("https://example.test/api/private-beta/artifacts/app.dmg", {
        headers: {
          Authorization: `Bearer ${"A".repeat(43)}`,
          Range: "bytes=0-0",
        },
      }),
      environment(
        database,
        objectBody(new Uint8Array([1]), malformedRange),
      ),
      "/api/private-beta/artifacts/app.dmg",
    );

    expect(response.status).toBe(206);
    expect(response.headers.get("Content-Length")).toBe("1");
    expect(response.headers.get("Content-Range")).toBe("bytes 0-0/10");
  });

  it("clips a requested end beyond the object size", async () => {
    const database = new Database();
    database.firstResults = [{ device_id: "device-1" }];
    const env = environment(database);
    let getOptions: R2GetOptions | undefined;
    env.PRIVATE_BETA_BUCKET = {
      async get(_key: string, options?: R2GetOptions): Promise<R2ObjectBody> {
        getOptions = options;
        return objectBody(new Uint8Array([8, 9]));
      },
    } as unknown as R2Bucket;
    const path = "/api/private-beta/artifacts/app.dmg";
    const response = await handlePrivateBetaResource(
      new Request(`https://example.test${path}`, {
        headers: {
          Authorization: `Bearer ${"A".repeat(43)}`,
          Range: "bytes=8-20",
        },
      }),
      env,
      path,
    );

    expect(response.status).toBe(206);
    expect(response.headers.get("Content-Length")).toBe("2");
    expect(response.headers.get("Content-Range")).toBe("bytes 8-9/10");
    expect(getOptions?.range).toEqual({ offset: 8, length: 13 });
  });

  it("fails closed when authenticated storage access fails", async () => {
    const database = new Database();
    database.firstResults = [{ device_id: "device-1" }];
    const env = environment(database);
    env.PRIVATE_BETA_BUCKET = {
      async get(): Promise<never> {
        throw new Error("synthetic R2 failure");
      },
    } as unknown as R2Bucket;
    const path = "/api/private-beta/appcast.xml";
    const response = await handlePrivateBetaResource(
      new Request(`https://example.test${path}`, {
        headers: { Authorization: `Bearer ${"A".repeat(43)}` },
      }),
      env,
      path,
    );
    expect(response.status).toBe(404);
    expect(await response.text()).toBe("Not Found");
  });

  it("defers last-seen bookkeeping to the execution context", async () => {
    const database = new Database();
    database.firstResults = [{ device_id: "device-1" }];
    const deferred: Promise<unknown>[] = [];
    const path = "/api/private-beta/appcast.xml";
    const response = await handlePrivateBetaResource(
      new Request(`https://example.test${path}`, {
        headers: { Authorization: `Bearer ${"A".repeat(43)}` },
      }),
      environment(database),
      path,
      { waitUntil: (promise) => deferred.push(promise) },
    );

    expect(response.status).toBe(200);
    expect(deferred).toHaveLength(1);
    await Promise.all(deferred);
  });
});
