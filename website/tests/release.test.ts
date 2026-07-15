import { describe, expect, it, vi } from "vitest";
import {
  ReleaseLookupError,
  fetchLatestRelease,
  parseLatestRelease,
} from "../src/release";

const APPCAST = `<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
  <item>
    <title>QuotaMonitor 0.2.40</title>
    <sparkle:version>0.2.40</sparkle:version>
    <enclosure url="https://downloads.example.test/v0.2.40/QuotaMonitor-0.2.40.dmg" length="6992960" />
  </item>
  <item>
    <sparkle:version>0.2.39</sparkle:version>
    <enclosure url="https://downloads.example.test/v0.2.39/QuotaMonitor-0.2.39.dmg" length="6978296" />
  </item>
</channel></rss>`;

describe("parseLatestRelease", () => {
  it("selects the first DMG item and returns public metadata", () => {
    expect(parseLatestRelease(APPCAST)).toEqual({
      version: "0.2.40",
      filename: "QuotaMonitor-0.2.40.dmg",
      size: 6992960,
      upstreamUrl: "https://downloads.example.test/v0.2.40/QuotaMonitor-0.2.40.dmg",
    });
  });

  it.each([
    ["missing version", APPCAST.replace("<sparkle:version>0.2.40</sparkle:version>", "")],
    ["non-DMG asset", APPCAST.replace("QuotaMonitor-0.2.40.dmg", "QuotaMonitor-0.2.40.zip")],
    ["missing length", APPCAST.replace(' length="6992960"', "")],
  ])("rejects %s", (_label, xml) => {
    expect(() => parseLatestRelease(xml)).toThrow(ReleaseLookupError);
  });
});

describe("fetchLatestRelease", () => {
  it("rejects a failed appcast response", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(new Response("down", { status: 503 }));
    await expect(fetchLatestRelease(fetcher)).rejects.toThrow("Appcast request failed: 503");
  });
});
