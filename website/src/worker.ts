import { renderDownloadError } from "./error-page";
import { fetchLatestRelease, type ReleaseInfo } from "./release";

export interface Env {
  ASSETS: Fetcher;
}

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

const upstreamFetchInit = {
  redirect: "manual",
  cf: { cacheEverything: true, cacheTtl: 86_400 },
} as const;

const redirectStatuses = new Set([301, 302, 303, 307, 308]);

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
  try {
    const release = await load();
    let upstream = await fetcher(release.upstreamUrl, upstreamFetchInit);
    if (redirectStatuses.has(upstream.status)) {
      const target = validatedAssetRedirect(
        upstream.headers.get("Location"),
        release.upstreamUrl,
      );
      upstream = await fetcher(target, upstreamFetchInit);
    }
    const contentLength = upstream.headers.get("Content-Length");

    if (
      upstream.status !== 200 ||
      !upstream.body ||
      contentLength === null ||
      !/^\d+$/.test(contentLength)
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

    return new Response(upstream.body, {
      status: 200,
      headers: {
        ...securityHeaders,
        "Cache-Control": "public, max-age=3600",
        "Content-Disposition": `attachment; filename="${release.filename}"`,
        "Content-Length": String(length),
        "Content-Type": "application/x-apple-diskimage",
      },
    });
  } catch {
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
    for (const [name, value] of Object.entries(securityHeaders)) {
      response.headers.set(name, value);
    }
    return response;
  },
} satisfies ExportedHandler<Env>;
