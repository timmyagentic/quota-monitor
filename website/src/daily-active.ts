const MAX_BODY_BYTES = 2_048;
const PAYLOAD_KEYS = ["brand", "channel", "day", "schema", "token", "version"] as const;
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{21}[AQgw]$/;
const SEMVER_PATTERN = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const MAX_VERSION_LENGTH = 64;
const DAY_PATTERN = /^\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])$/;
const ALLOWED_BRANDS = new Set(["quota-monitor", "codex-monitor"]);
const ALLOWED_CHANNELS = new Set(["developer-id", "app-store"]);

const UPSERT_OBSERVATION_SQL = `
INSERT INTO daily_active_observations (day, token_hash, version, brand, channel)
VALUES (?1, ?2, ?3, ?4, ?5)
ON CONFLICT(day, token_hash) DO UPDATE SET
  version = excluded.version,
  brand = excluded.brand,
  channel = excluded.channel
`;

export interface DailyActiveRunnable {
  run(): Promise<unknown>;
}

export interface DailyActiveStatement {
  bind(...values: unknown[]): DailyActiveRunnable;
}

export interface DailyActiveDatabase {
  prepare(query: string): DailyActiveStatement;
}

export interface DailyActiveRateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface DailyActiveDependencies {
  now?: () => Date;
  digest?: (bytes: Uint8Array) => Promise<ArrayBuffer>;
}

type DailyActivePayload = {
  schema: 1;
  day: string;
  token: string;
  version: string;
  brand: string;
  channel: string;
};

type BodyResult =
  | { status: "ok"; value: unknown }
  | { status: "invalid" }
  | { status: "too-large" };

function emptyResponse(status: number, headers: HeadersInit = {}): Response {
  return new Response(null, {
    status,
    headers: {
      "Cache-Control": "no-store",
      ...headers,
    },
  });
}

async function cancelBody(body: ReadableStream<Uint8Array> | null): Promise<void> {
  if (body === null) {
    return;
  }

  try {
    await body.cancel();
  } catch {
    // A rejected body is already unusable; preserve the validation response.
  }
}

function declaredBodyIsTooLarge(contentLength: string | null): boolean {
  if (contentLength === null || !/^\d+$/.test(contentLength)) {
    return false;
  }

  const normalized = contentLength.replace(/^0+/, "") || "0";
  return normalized.length > 4 || Number(normalized) > MAX_BODY_BYTES;
}

async function readBoundedJSON(request: Request): Promise<BodyResult> {
  if (request.body === null) {
    return { status: "invalid" };
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let byteCount = 0;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }

      byteCount += value.byteLength;
      if (byteCount > MAX_BODY_BYTES) {
        try {
          await reader.cancel();
        } catch {
          // The size decision is final even when stream cleanup fails.
        }
        return { status: "too-large" };
      }
      chunks.push(value);
    }
  } catch {
    try {
      await reader.cancel();
    } catch {
      // The invalid response does not depend on cleanup succeeding.
    }
    return { status: "invalid" };
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  try {
    const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
    return { status: "ok", value: JSON.parse(text) };
  } catch {
    return { status: "invalid" };
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isRealCalendarDay(day: string): boolean {
  if (!DAY_PATTERN.test(day)) {
    return false;
  }

  const parsed = new Date(`${day}T00:00:00.000Z`);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString().slice(0, 10) === day;
}

function validatedPayload(value: unknown): DailyActivePayload | null {
  if (!isRecord(value)) {
    return null;
  }

  const keys = Object.keys(value).sort();
  if (keys.length !== PAYLOAD_KEYS.length || keys.some((key, index) => key !== PAYLOAD_KEYS[index])) {
    return null;
  }

  const { schema, day, token, version, brand, channel } = value;
  if (
    schema !== 1 ||
    typeof day !== "string" ||
    !isRealCalendarDay(day) ||
    typeof token !== "string" ||
    !TOKEN_PATTERN.test(token) ||
    typeof version !== "string" ||
    version.length > MAX_VERSION_LENGTH ||
    !SEMVER_PATTERN.test(version) ||
    typeof brand !== "string" ||
    !ALLOWED_BRANDS.has(brand) ||
    typeof channel !== "string" ||
    !ALLOWED_CHANNELS.has(channel)
  ) {
    return null;
  }

  return { schema, day, token, version, brand, channel };
}

async function defaultDigest(bytes: Uint8Array): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", bytes);
}

function hexEncoded(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export async function handleDailyActive(
  request: Request,
  database: DailyActiveDatabase,
  coloRateLimiter: DailyActiveRateLimiter,
  rateLimiter: DailyActiveRateLimiter,
  dependencies: DailyActiveDependencies = {},
): Promise<Response> {
  if (request.method !== "POST") {
    return emptyResponse(405, { Allow: "POST" });
  }
  if (new URL(request.url).protocol !== "https:") {
    return emptyResponse(400);
  }
  if (request.headers.get("Content-Type") !== "application/json") {
    return emptyResponse(415);
  }
  if (declaredBodyIsTooLarge(request.headers.get("Content-Length"))) {
    await cancelBody(request.body);
    return emptyResponse(413);
  }
  const contentEncoding = request.headers.get("Content-Encoding");
  if (contentEncoding !== null && contentEncoding !== "identity") {
    return emptyResponse(415);
  }

  try {
    // Workers RateLimit bindings are per-colo and best-effort, not a global Durable Object.
    const { success } = await coloRateLimiter.limit({ key: "daily-active-colo" });
    if (!success) {
      return emptyResponse(429, { "Retry-After": "60" });
    }
  } catch {
    return emptyResponse(503);
  }

  const connectingIP = request.headers.get("CF-Connecting-IP");
  const rateLimitKey = connectingIP === null || connectingIP === ""
    ? "missing-cf-connecting-ip"
    : connectingIP;
  try {
    const { success } = await rateLimiter.limit({ key: rateLimitKey });
    if (!success) {
      return emptyResponse(429, { "Retry-After": "60" });
    }
  } catch {
    return emptyResponse(503);
  }

  const body = await readBoundedJSON(request);
  if (body.status === "too-large") {
    return emptyResponse(413);
  }
  if (body.status === "invalid") {
    return emptyResponse(400);
  }

  const payload = validatedPayload(body.value);
  if (payload === null) {
    return emptyResponse(400);
  }

  const now = dependencies.now ?? (() => new Date());
  if (payload.day !== now().toISOString().slice(0, 10)) {
    return emptyResponse(409);
  }

  const digest = dependencies.digest ?? defaultDigest;
  try {
    const hashInput = new TextEncoder().encode(`v1\0${payload.day}\0${payload.token}`);
    const tokenHash = hexEncoded(await digest(hashInput));
    await database
      .prepare(UPSERT_OBSERVATION_SQL)
      .bind(payload.day, tokenHash, payload.version, payload.brand, payload.channel)
      .run();
    return emptyResponse(204);
  } catch {
    return emptyResponse(503);
  }
}
