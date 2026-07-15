import { describe, expect, it, vi } from "vitest";
import {
  ReleaseLookupError,
  fetchLatestRelease,
  parseLatestRelease,
} from "../src/release";

const releaseUrl = (version: string): string =>
  `https://github.com/timmyagentic/quota-monitor/releases/download/v${version}/QuotaMonitor-${version}.dmg`;

function releaseItem(
  version: string,
  options: { attributes?: string; length?: number | null; url?: string } = {},
): string {
  const attributes = options.attributes ?? "";
  const length = options.length === null ? "" : ` length="${options.length ?? 6_992_960}"`;
  const url = options.url ?? releaseUrl(version);

  return `<item${attributes}>
    <sparkle:version>${version}</sparkle:version>
    <enclosure url="${url}"${length} />
  </item>`;
}

const appcast = (...items: string[]): string =>
  `<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
${items.join("\n")}
</channel></rss>`;

const APPCAST = appcast(releaseItem("0.2.40"), releaseItem("0.2.39", { length: 6_978_296 }));

describe("parseLatestRelease", () => {
  it("returns public metadata for the highest valid release", () => {
    expect(parseLatestRelease(APPCAST)).toEqual({
      version: "0.2.40",
      filename: "QuotaMonitor-0.2.40.dmg",
      size: 6_992_960,
      upstreamUrl: releaseUrl("0.2.40"),
    });
  });

  it.each([
    [
      "missing version",
      appcast(releaseItem("0.2.40").replace("<sparkle:version>0.2.40</sparkle:version>", "")),
    ],
    ["non-DMG asset", appcast(releaseItem("0.2.40", { url: releaseUrl("0.2.40").replace(".dmg", ".zip") }))],
    ["missing length", appcast(releaseItem("0.2.40", { length: null }))],
  ])("rejects %s when no valid candidate remains", (_label, xml) => {
    expect(() => parseLatestRelease(xml)).toThrow(ReleaseLookupError);
  });

  it("skips a leading ZIP item when a later valid DMG exists", () => {
    const xml = appcast(
      releaseItem("0.2.41", { url: releaseUrl("0.2.41").replace(".dmg", ".zip") }),
      releaseItem("0.2.40"),
    );

    expect(parseLatestRelease(xml).version).toBe("0.2.40");
  });

  it("selects the highest numeric version when items are out of order", () => {
    const xml = appcast(releaseItem("0.2.9"), releaseItem("0.2.10"));

    expect(parseLatestRelease(xml).version).toBe("0.2.10");
  });

  it("accepts item elements with attributes", () => {
    const xml = appcast(releaseItem("0.2.40", { attributes: ' data-channel="stable"' }));

    expect(parseLatestRelease(xml).version).toBe("0.2.40");
  });

  it.each([
    ["foreign host", releaseUrl("0.2.40").replace("github.com", "downloads.example.test")],
    ["HTTP", releaseUrl("0.2.40").replace("https://", "http://")],
    ["FTP", releaseUrl("0.2.40").replace("https://", "ftp://")],
    ["credentials", releaseUrl("0.2.40").replace("https://", "https://user:secret@")],
    ["custom port", releaseUrl("0.2.40").replace("github.com", "github.com:8443")],
    ["query", `${releaseUrl("0.2.40")}?download=1`],
    ["fragment", `${releaseUrl("0.2.40")}#latest`],
  ])("rejects a %s release URL", (_label, url) => {
    expect(() => parseLatestRelease(appcast(releaseItem("0.2.40", { url })))).toThrow(ReleaseLookupError);
  });

  it.each([
    ["malformed URL", "not a URL"],
    ["malformed percent escape", releaseUrl("0.2.40").replace("QuotaMonitor-0.2.40.dmg", "QuotaMonitor-%ZZ.dmg")],
  ])("normalizes a %s failure", (_label, url) => {
    expect(() => parseLatestRelease(appcast(releaseItem("0.2.40", { url })))).toThrow(ReleaseLookupError);
  });

  it("skips a malformed URL when another valid candidate exists", () => {
    const xml = appcast(releaseItem("0.2.41", { url: "not a URL" }), releaseItem("0.2.40"));

    expect(parseLatestRelease(xml).version).toBe("0.2.40");
  });

  it.each([
    ["tag", releaseUrl("0.2.40").replace("/v0.2.40/", "/v0.2.39/")],
    ["filename", releaseUrl("0.2.40").replace("QuotaMonitor-0.2.40.dmg", "QuotaMonitor-0.2.39.dmg")],
  ])("rejects a mismatched %s version", (_label, url) => {
    expect(() => parseLatestRelease(appcast(releaseItem("0.2.40", { url })))).toThrow(ReleaseLookupError);
  });

  it.each(["0.2.beta", "0..40", "v0.2.40"])("rejects invalid numeric version %s", (version) => {
    expect(() => parseLatestRelease(appcast(releaseItem(version)))).toThrow(ReleaseLookupError);
  });
});

describe("fetchLatestRelease", () => {
  it("rejects a failed appcast response", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(new Response("down", { status: 503 }));
    await expect(fetchLatestRelease(fetcher)).rejects.toThrow("Appcast request failed: 503");
  });
});
