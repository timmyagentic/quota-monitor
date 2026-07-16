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

function parseReleaseCandidate(item: string): ReleaseInfo | undefined {
  const version = item.match(/<sparkle:version>([^<]+)<\/sparkle:version>/)?.[1]?.trim();
  const enclosure = item.match(/<enclosure\b([^>]+?)\/?\s*>/)?.[1];
  const encodedUrl = enclosure?.match(/\burl="([^"]+)"/)?.[1];
  const encodedLength = enclosure?.match(/\blength="(\d+)"/)?.[1];

  if (!version || !/^\d+(?:\.\d+)+$/.test(version) || !encodedUrl || !encodedLength) {
    return undefined;
  }

  const upstreamUrl = decodeXML(encodedUrl);
  const filename = `QuotaMonitor-${version}.dmg`;
  const pathname = `/timmyagentic/quota-monitor/releases/download/v${version}/${filename}`;
  const canonicalUrl = `https://github.com${pathname}`;
  const size = Number(encodedLength);

  if (!Number.isSafeInteger(size) || size < 1_000_000) {
    return undefined;
  }

  try {
    const url = new URL(upstreamUrl);
    if (
      upstreamUrl !== canonicalUrl ||
      url.protocol !== "https:" ||
      url.hostname !== "github.com" ||
      url.username !== "" ||
      url.password !== "" ||
      url.port !== "" ||
      url.search !== "" ||
      url.hash !== "" ||
      url.pathname !== pathname
    ) {
      return undefined;
    }
  } catch {
    return undefined;
  }

  return { version, filename, size, upstreamUrl };
}

function compareNumericVersions(left: string, right: string): number {
  const leftComponents = left.split(".");
  const rightComponents = right.split(".");
  const componentCount = Math.max(leftComponents.length, rightComponents.length);

  for (let index = 0; index < componentCount; index += 1) {
    const leftComponent = BigInt(leftComponents[index] ?? "0");
    const rightComponent = BigInt(rightComponents[index] ?? "0");
    if (leftComponent !== rightComponent) {
      return leftComponent > rightComponent ? 1 : -1;
    }
  }

  return 0;
}

export function parseLatestRelease(xml: string): ReleaseInfo {
  const candidates: ReleaseInfo[] = [];
  for (const match of xml.matchAll(/<item\b[^>]*>[\s\S]*?<\/item>/g)) {
    const candidate = parseReleaseCandidate(match[0]);
    if (candidate) {
      candidates.push(candidate);
    }
  }

  if (candidates.length === 0) {
    throw new ReleaseLookupError("Appcast contains no valid QuotaMonitor release");
  }

  return candidates.reduce((latest, candidate) =>
    compareNumericVersions(candidate.version, latest.version) > 0 ? candidate : latest,
  );
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
