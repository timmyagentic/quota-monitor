import { verifyAdminAuthorization } from "./admin-auth";

const encoder = new TextEncoder();
const enrollmentCodePattern = /^[A-Z2-9]{4}(?:-[A-Z2-9]{4}){3}$/;
const bearerPattern = /^Bearer ([A-Za-z0-9_-]{43})$/;
const resourcePrefix = "private-beta/";
const maximumEnrollmentBodyBytes = 4_096;
const enrollmentCodeLifetimeSeconds = 15 * 60;

type PrivateBetaBindings = Pick<
  Env,
  | "PRIVATE_BETA_DB"
  | "PRIVATE_BETA_BUCKET"
  | "PRIVATE_BETA_ENROLL_RATE_LIMITER"
  | "PRIVATE_BETA_RESOURCE_RATE_LIMITER"
  | "PRIVATE_BETA_ADMIN_RATE_LIMITER"
  | "PRIVATE_BETA_ADMIN_TOKEN"
>;

interface EnrollmentBody {
  code: string;
  deviceLabel: string;
}

interface ActiveDevice {
  device_id: string;
}

const privateHeaders = {
  "Cache-Control": "private, no-store",
  "Cross-Origin-Resource-Policy": "same-origin",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
} as const;

function hiddenNotFound(): Response {
  return new Response("Not Found", {
    status: 404,
    headers: {
      ...privateHeaders,
      "Content-Type": "text/plain; charset=utf-8",
    },
  });
}

function jsonResponse(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: privateHeaders,
  });
}

function decodeBase64URL(value: string): Uint8Array {
  const padding = "=".repeat((4 - (value.length % 4)) % 4);
  const decoded = atob(value.replace(/-/g, "+").replace(/_/g, "/") + padding);
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

function encodeBase64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function randomToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return encodeBase64URL(bytes);
}

function randomEnrollmentCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  const characters = Array.from(bytes, (byte) => alphabet[byte % alphabet.length]);
  return [
    characters.slice(0, 4).join(""),
    characters.slice(4, 8).join(""),
    characters.slice(8, 12).join(""),
    characters.slice(12, 16).join(""),
  ].join("-");
}

async function sha256Hex(value: string | Uint8Array): Promise<string> {
  const bytes = typeof value === "string" ? encoder.encode(value) : value;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function rateLimitKey(request: Request, suffix: string): string {
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
  return `${address}:${suffix}`;
}

async function isRateLimited(
  limiter: RateLimit,
  request: Request,
  suffix: string,
): Promise<boolean> {
  const outcome = await limiter.limit({ key: rateLimitKey(request, suffix) });
  return !outcome.success;
}

async function parseEnrollmentBody(request: Request): Promise<EnrollmentBody | null> {
  const contentLength = request.headers.get("Content-Length");
  if (
    contentLength === null ||
    !/^\d+$/.test(contentLength) ||
    Number(contentLength) > maximumEnrollmentBodyBytes ||
    request.headers.get("Content-Type")?.split(";", 1)[0] !== "application/json"
  ) {
    return null;
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return null;
  }
  if (typeof body !== "object" || body === null) return null;
  const code = Reflect.get(body, "code");
  const deviceLabel = Reflect.get(body, "deviceLabel");
  if (
    typeof code !== "string" ||
    !enrollmentCodePattern.test(code) ||
    typeof deviceLabel !== "string" ||
    deviceLabel.trim().length < 1 ||
    encoder.encode(deviceLabel.trim()).byteLength > 120
  ) {
    return null;
  }
  return { code, deviceLabel: deviceLabel.trim() };
}

async function authenticateDevice(
  request: Request,
  env: PrivateBetaBindings,
): Promise<ActiveDevice | null> {
  const authorization = request.headers.get("Authorization");
  const match = authorization?.match(bearerPattern);
  if (match === undefined || match === null) return null;

  let tokenBytes: Uint8Array;
  try {
    tokenBytes = decodeBase64URL(match[1]!);
  } catch {
    return null;
  }
  if (tokenBytes.byteLength !== 32) return null;

  const tokenDigest = await sha256Hex(tokenBytes);
  return env.PRIVATE_BETA_DB.prepare(
    `SELECT device_id
       FROM private_beta_devices
      WHERE token_digest = ? AND revoked_at IS NULL`,
  ).bind(tokenDigest).first<ActiveDevice>();
}

export async function handlePrivateBetaEnrollment(
  request: Request,
  env: PrivateBetaBindings,
  now = Date.now(),
): Promise<Response> {
  try {
    if (request.method !== "POST") return hiddenNotFound();
    if (await isRateLimited(env.PRIVATE_BETA_ENROLL_RATE_LIMITER, request, "enroll")) {
      return hiddenNotFound();
    }

    const body = await parseEnrollmentBody(request);
    if (body === null) return hiddenNotFound();
    const token = randomToken();
    const tokenDigest = await sha256Hex(decodeBase64URL(token));
    const deviceID = crypto.randomUUID();
    const codeDigest = await sha256Hex(body.code);
    const enrollmentResults = await env.PRIVATE_BETA_DB.batch([
      env.PRIVATE_BETA_DB.prepare(
        `INSERT INTO private_beta_devices(
            device_id, token_digest, device_label, enrolled_at, last_seen_at, revoked_at
         )
         SELECT ?, ?, ?, ?, ?, NULL
           FROM private_beta_enrollment_codes
          WHERE code_digest = ?
            AND used_at IS NULL
            AND expires_at >= ?`,
      ).bind(
        deviceID,
        tokenDigest,
        body.deviceLabel,
        now,
        now,
        codeDigest,
        now,
      ),
      env.PRIVATE_BETA_DB.prepare(
        `UPDATE private_beta_enrollment_codes
            SET used_at = ?
          WHERE code_digest = ?
            AND used_at IS NULL
            AND expires_at >= ?`,
      ).bind(now, codeDigest, now),
    ]);
    const deviceInsert = enrollmentResults[0];
    const codeClaim = enrollmentResults[1];
    if (
      deviceInsert === undefined ||
      codeClaim === undefined ||
      (deviceInsert.meta.changes ?? 0) !== 1 ||
      (codeClaim.meta.changes ?? 0) !== 1
    ) {
      return hiddenNotFound();
    }

    return jsonResponse({ deviceID, token }, 201);
  } catch {
    return hiddenNotFound();
  }
}

export async function handlePrivateBetaAdmin(
  request: Request,
  env: PrivateBetaBindings,
  pathname: string,
  now = Date.now(),
): Promise<Response> {
  if (
    request.method !== "POST" ||
    env.PRIVATE_BETA_ADMIN_TOKEN.length < 32 ||
    await isRateLimited(env.PRIVATE_BETA_ADMIN_RATE_LIMITER, request, "admin") ||
    !await verifyAdminAuthorization(
      request.headers.get("Authorization"),
      env.PRIVATE_BETA_ADMIN_TOKEN,
    )
  ) {
    return hiddenNotFound();
  }

  if (pathname === "/api/private-beta/admin/enrollment-codes") {
    const code = randomEnrollmentCode();
    await env.PRIVATE_BETA_DB.prepare(
      `INSERT INTO private_beta_enrollment_codes(
          code_digest, created_at, expires_at, used_at
       ) VALUES (?, ?, ?, NULL)`,
    ).bind(
      await sha256Hex(code),
      now,
      now + enrollmentCodeLifetimeSeconds * 1_000,
    ).run();
    return jsonResponse({
      code,
      expiresAt: new Date(now + enrollmentCodeLifetimeSeconds * 1_000).toISOString(),
    }, 201);
  }

  const revokeMatch = pathname.match(
    /^\/api\/private-beta\/admin\/devices\/([0-9a-f-]{36})\/revoke$/,
  );
  if (revokeMatch === null) return hiddenNotFound();
  const result = await env.PRIVATE_BETA_DB.prepare(
    `UPDATE private_beta_devices
        SET revoked_at = ?
      WHERE device_id = ? AND revoked_at IS NULL`,
  ).bind(now, revokeMatch[1]).run();
  if ((result.meta.changes ?? 0) !== 1) return hiddenNotFound();
  return jsonResponse({ revoked: true });
}

function resolvedRange(object: R2ObjectBody): { start: number; length: number } | null {
  const range = object.range;
  if (range === undefined) return null;
  if ("suffix" in range) {
    const length = Math.min(range.suffix, object.size);
    return { start: object.size - length, length };
  }
  const start = range.offset ?? 0;
  const length = range.length ?? object.size - start;
  return { start, length };
}

async function serveObject(
  request: Request,
  env: PrivateBetaBindings,
  key: string,
): Promise<Response> {
  if (!key.startsWith(resourcePrefix) || key.includes("..") || key.includes("\\")) {
    return hiddenNotFound();
  }

  if (request.method === "HEAD") {
    const object = await env.PRIVATE_BETA_BUCKET.head(key);
    if (object === null) return hiddenNotFound();
    const headers = new Headers(privateHeaders);
    object.writeHttpMetadata(headers);
    headers.set("Accept-Ranges", "bytes");
    headers.set("Content-Length", String(object.size));
    headers.set("ETag", object.httpEtag);
    return new Response(null, { headers });
  }

  const object = await env.PRIVATE_BETA_BUCKET.get(key, {
    range: request.headers,
  });
  if (object === null || !("body" in object)) return hiddenNotFound();
  const headers = new Headers(privateHeaders);
  object.writeHttpMetadata(headers);
  headers.set("Accept-Ranges", "bytes");
  headers.set("ETag", object.httpEtag);

  const range = resolvedRange(object);
  if (range === null) {
    headers.set("Content-Length", String(object.size));
    return new Response(object.body, { headers });
  }
  headers.set("Content-Length", String(range.length));
  headers.set(
    "Content-Range",
    `bytes ${range.start}-${range.start + range.length - 1}/${object.size}`,
  );
  return new Response(object.body, { status: 206, headers });
}

export async function handlePrivateBetaResource(
  request: Request,
  env: PrivateBetaBindings,
  pathname: string,
  context?: Pick<ExecutionContext, "waitUntil">,
): Promise<Response> {
  try {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return hiddenNotFound();
    }
    if (
      await isRateLimited(env.PRIVATE_BETA_RESOURCE_RATE_LIMITER, request, "resource")
    ) {
      return hiddenNotFound();
    }
    const device = await authenticateDevice(request, env);
    if (device === null) return hiddenNotFound();

    const routeMatch = pathname.match(
      /^\/api\/private-beta\/(appcast\.xml|notes\/[A-Za-z0-9._-]+|artifacts\/[A-Za-z0-9._-]+)$/,
    );
    if (routeMatch === null) return hiddenNotFound();
    const key = `${resourcePrefix}${routeMatch[1]}`;
    const response = await serveObject(request, env, key);
    if (response.status < 400) {
      const lastSeenUpdate = env.PRIVATE_BETA_DB.prepare(
        "UPDATE private_beta_devices SET last_seen_at = ? WHERE device_id = ?",
      ).bind(Date.now(), device.device_id).run().then(() => undefined);
      if (context === undefined) {
        await lastSeenUpdate;
      } else {
        context.waitUntil(lastSeenUpdate);
      }
    }
    return response;
  } catch {
    return hiddenNotFound();
  }
}
