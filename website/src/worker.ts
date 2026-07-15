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
    const upstream = await fetcher(release.upstreamUrl, {
      redirect: "follow",
      cf: { cacheEverything: true, cacheTtl: 86_400 },
    });
    const contentLength = upstream.headers.get("Content-Length");

    if (
      !upstream.ok ||
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

    if (request.method === "GET" && url.pathname === "/api/release") {
      return handleReleaseAPI();
    }
    if (request.method === "GET" && url.pathname === "/download") {
      return handleDownload(request);
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: {
          ...securityHeaders,
          Allow: "GET, HEAD",
          "Cache-Control": "no-store",
          "Content-Type": "text/plain; charset=utf-8",
        },
      });
    }

    const asset = await env.ASSETS.fetch(request);
    const response = new Response(asset.body, asset);
    for (const [name, value] of Object.entries(securityHeaders)) {
      response.headers.set(name, value);
    }
    return response;
  },
} satisfies ExportedHandler<Env>;
