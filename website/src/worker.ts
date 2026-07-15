import { renderDownloadError } from "./error-page";
import { handleDailyActive } from "./daily-active";
import { fetchLatestRelease, type ReleaseInfo } from "./release";
import {
  aggregateClosedDays,
  handleVersionDistribution,
} from "./version-distribution";

type ReleaseLoader = () => Promise<ReleaseInfo>;

const securityHeaders = {
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

const dashboardSecurityHeaders = {
  ...securityHeaders,
  "Content-Security-Policy": securityHeaders["Content-Security-Policy"].replace(
    "form-action 'none'",
    "form-action 'self'",
  ),
};

const upstreamFetchInit = {
  redirect: "manual",
  cf: {
    cacheEverything: true,
    cacheTtlByStatus: { "200-299": 86_400, "300-599": 0 },
  },
} as const;

const redirectStatuses = new Set([301, 302, 303, 307, 308]);
const approvedDMGContentTypes = new Set([
  "application/octet-stream",
  "application/x-apple-diskimage",
]);

function hasApprovedDMGContentType(contentType: string | null): boolean {
  if (contentType === null) {
    return false;
  }

  const [mediaType = ""] = contentType.split(";", 1);
  return approvedDMGContentTypes.has(mediaType.trim().toLowerCase());
}

function validatedAssetRedirect(location: string | null, canonicalUrl: string): string {
  if (location === null) {
    throw new Error("Missing DMG redirect location");
  }

  const target = new URL(location, canonicalUrl);
  if (
    target.protocol !== "https:" ||
    target.hostname !== "release-assets.githubusercontent.com" ||
    target.username !== "" ||
    target.password !== "" ||
    target.port !== "" ||
    !target.pathname.startsWith("/github-production-release-asset/")
  ) {
    throw new Error("Invalid DMG redirect location");
  }

  return target.toString();
}

function methodNotAllowed(allow: string): Response {
  return new Response("Method Not Allowed", {
    status: 405,
    headers: {
      ...securityHeaders,
      Allow: allow,
      "Cache-Control": "no-store",
      "Content-Type": "text/plain; charset=utf-8",
    },
  });
}

function optionalStringBinding(env: Env, name: string): string | undefined {
  const value: unknown = Reflect.get(env, name);
  return typeof value === "string" ? value : undefined;
}

function withSecurityHeaders(
  response: Response,
  headers: Readonly<Record<string, string>> = securityHeaders,
): Response {
  for (const [name, value] of Object.entries(headers)) {
    response.headers.set(name, value);
  }
  return response;
}

export async function handleReleaseAPI(
  load: ReleaseLoader = fetchLatestRelease,
): Promise<Response> {
  try {
    const release = await load();
    return Response.json(
      {
        version: release.version,
        filename: release.filename,
        size: release.size,
        minimumSystemVersion: "14.0",
      },
      {
        headers: {
          ...securityHeaders,
          "Cache-Control": "public, max-age=300",
        },
      },
    );
  } catch {
    return Response.json(
      { available: false },
      {
        status: 503,
        headers: { ...securityHeaders, "Cache-Control": "no-store" },
      },
    );
  }
}

export async function handleDownload(
  request: Request,
  load: ReleaseLoader = fetchLatestRelease,
  fetcher: typeof fetch = fetch,
): Promise<Response> {
  let upstreamToCancel: Response | undefined;

  try {
    const release = await load();
    let upstream = await fetcher(release.upstreamUrl, upstreamFetchInit);
    upstreamToCancel = upstream;
    if (redirectStatuses.has(upstream.status)) {
      const target = validatedAssetRedirect(
        upstream.headers.get("Location"),
        release.upstreamUrl,
      );
      await upstream.body?.cancel();
      upstreamToCancel = undefined;
      upstream = await fetcher(target, upstreamFetchInit);
      upstreamToCancel = upstream;
    }
    const contentLength = upstream.headers.get("Content-Length");
    const contentType = upstream.headers.get("Content-Type");

    if (
      upstream.status !== 200 ||
      !upstream.body ||
      contentLength === null ||
      !/^\d+$/.test(contentLength) ||
      !hasApprovedDMGContentType(contentType)
    ) {
      throw new Error("Invalid DMG response");
    }

    const length = Number(contentLength);
    if (
      !Number.isSafeInteger(length) ||
      length < 1_000_000 ||
      length !== release.size
    ) {
      throw new Error("Invalid DMG length");
    }

    upstreamToCancel = undefined;
    return new Response(upstream.body, {
      status: 200,
      headers: {
        ...securityHeaders,
        "Cache-Control": "no-store",
        "Content-Disposition": `attachment; filename="${release.filename}"`,
        "Content-Length": String(length),
        "Content-Type": "application/x-apple-diskimage",
      },
    });
  } catch {
    if (upstreamToCancel?.body) {
      try {
        await upstreamToCancel.body.cancel();
      } catch {
        // Preserve the visitor-facing download error if stream cleanup fails.
      }
    }
    return new Response(renderDownloadError(request.headers.get("Accept-Language")), {
      status: 503,
      headers: {
        ...securityHeaders,
        "Cache-Control": "no-store",
        "Content-Type": "text/html; charset=utf-8",
      },
    });
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/api/v1/daily-active") {
      const response = await handleDailyActive(
        request,
        env.VERSION_STATS_DB,
        env.DAILY_ACTIVE_GLOBAL_RATE_LIMITER,
        env.DAILY_ACTIVE_RATE_LIMITER,
      );
      return withSecurityHeaders(response);
    }
    if (url.pathname === "/maintainer/versions") {
      const response = await handleVersionDistribution(
        request,
        env.VERSION_STATS_DB,
        optionalStringBinding(env, "VERSION_STATS_ADMIN_TOKEN"),
        env.ADMIN_VERSION_STATS_RATE_LIMITER,
      );
      return withSecurityHeaders(response, dashboardSecurityHeaders);
    }
    if (url.pathname === "/api/release") {
      if (request.method !== "GET") {
        return methodNotAllowed("GET");
      }
      return handleReleaseAPI();
    }
    if (url.pathname === "/download") {
      if (request.method !== "GET") {
        return methodNotAllowed("GET");
      }
      return handleDownload(request);
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return methodNotAllowed("GET, HEAD");
    }

    const asset = await env.ASSETS.fetch(request);
    const response = new Response(asset.body, asset);
    return withSecurityHeaders(response);
  },

  async scheduled(controller, env, _ctx): Promise<void> {
    await aggregateClosedDays(env.VERSION_STATS_DB, controller.scheduledTime);
  },
} satisfies ExportedHandler<Env>;
