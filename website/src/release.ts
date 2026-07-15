export const APPCAST_URL =
  "https://raw.githubusercontent.com/timmyagentic/quota-monitor/main/appcast.xml";

export interface ReleaseInfo {
  version: string;
  filename: string;
  size: number;
  upstreamUrl: string;
}

export class ReleaseLookupError extends Error {
  override name = "ReleaseLookupError";
}

const decodeXML = (value: string): string =>
  value
    .replaceAll("&amp;", "&")
    .replaceAll("&quot;", '"')
    .replaceAll("&apos;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">");

export function parseLatestRelease(xml: string): ReleaseInfo {
  const item = xml.match(/<item>[\s\S]*?<\/item>/)?.[0];
  const version = item?.match(/<sparkle:version>([^<]+)<\/sparkle:version>/)?.[1]?.trim();
  const enclosure = item?.match(/<enclosure\b([^>]+?)\/?\s*>/)?.[1];
  const encodedUrl = enclosure?.match(/\burl="([^"]+)"/)?.[1];
  const encodedLength = enclosure?.match(/\blength="(\d+)"/)?.[1];

  if (!version || !encodedUrl || !encodedLength) {
    throw new ReleaseLookupError("Latest appcast item is incomplete");
  }

  const upstreamUrl = decodeXML(encodedUrl);
  const pathname = new URL(upstreamUrl).pathname;
  const filename = decodeURIComponent(pathname.split("/").at(-1) ?? "");
  const size = Number(encodedLength);

  if (!/^QuotaMonitor-[0-9A-Za-z.-]+\.dmg$/.test(filename) || !Number.isSafeInteger(size) || size < 1_000_000) {
    throw new ReleaseLookupError("Latest appcast enclosure is not a valid QuotaMonitor DMG");
  }

  return { version, filename, size, upstreamUrl };
}

export async function fetchLatestRelease(fetcher: typeof fetch = fetch): Promise<ReleaseInfo> {
  const response = await fetcher(APPCAST_URL, {
    headers: { Accept: "application/xml, text/xml;q=0.9" },
    cf: { cacheEverything: true, cacheTtl: 300 },
  });
  if (!response.ok) {
    throw new ReleaseLookupError(`Appcast request failed: ${response.status}`);
  }
  return parseLatestRelease(await response.text());
}
