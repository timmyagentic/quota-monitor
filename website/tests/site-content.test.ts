import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { describe, expect, it } from "vitest";

const websiteDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");
const publicDirectory = join(websiteDirectory, "public");
const designDirectory = join(websiteDirectory, "design");

function readPublic(name: string): string {
  return readFileSync(join(publicDirectory, name), "utf8");
}

function attributeValues(source: string, attribute: string): string[] {
  const pattern = new RegExp(`\\b${attribute}="([^"]+)"`, "g");
  return [...source.matchAll(pattern)].map((match) => match[1] ?? "");
}

function escapeRegularExpression(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function ruleBody(source: string, selector: string): string {
  const match = source.match(
    new RegExp(`${escapeRegularExpression(selector)}\\s*\\{([^}]*)\\}`, "s"),
  );
  expect(match, `missing CSS rule for ${selector}`).not.toBeNull();
  return match?.[1] ?? "";
}

function readUnsigned24LE(buffer: Buffer, offset: number): number {
  return buffer[offset]! | (buffer[offset + 1]! << 8) | (buffer[offset + 2]! << 16);
}

function imageDimensions(path: string): { width: number; height: number } {
  const buffer = readFileSync(path);

  if (
    buffer.length >= 24 &&
    buffer.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
  ) {
    return {
      width: buffer.readUInt32BE(16),
      height: buffer.readUInt32BE(20),
    };
  }

  if (
    buffer.length >= 30 &&
    buffer.toString("ascii", 0, 4) === "RIFF" &&
    buffer.toString("ascii", 8, 12) === "WEBP"
  ) {
    for (let offset = 12; offset + 8 <= buffer.length;) {
      const chunk = buffer.toString("ascii", offset, offset + 4);
      const chunkSize = buffer.readUInt32LE(offset + 4);
      const dataOffset = offset + 8;

      if (chunk === "VP8X" && dataOffset + 10 <= buffer.length) {
        return {
          width: readUnsigned24LE(buffer, dataOffset + 4) + 1,
          height: readUnsigned24LE(buffer, dataOffset + 7) + 1,
        };
      }

      if (chunk === "VP8 " && dataOffset + 10 <= buffer.length) {
        return {
          width: buffer.readUInt16LE(dataOffset + 6) & 0x3fff,
          height: buffer.readUInt16LE(dataOffset + 8) & 0x3fff,
        };
      }

      if (chunk === "VP8L" && dataOffset + 5 <= buffer.length) {
        const first = buffer[dataOffset + 1]!;
        const second = buffer[dataOffset + 2]!;
        const third = buffer[dataOffset + 3]!;
        const fourth = buffer[dataOffset + 4]!;
        return {
          width: 1 + first + ((second & 0x3f) << 8),
          height: 1 + (second >> 6) + (third << 2) + ((fourth & 0x0f) << 10),
        };
      }

      offset = dataOffset + chunkSize + (chunkSize % 2);
    }
  }

  throw new Error(`unsupported image format: ${path}`);
}

type SiteModule = {
  translations: Record<"en" | "zh-Hans", Record<string, string>>;
  resolveLanguage: (saved?: unknown, languages?: unknown) => "en" | "zh-Hans";
  applyLanguage: (language: unknown) => "en" | "zh-Hans";
  hydrateRelease: () => Promise<unknown>;
};

async function loadAppModule(): Promise<SiteModule> {
  const moduleUrl = pathToFileURL(join(publicDirectory, "app.js")).href;
  return import(/* @vite-ignore */ `${moduleUrl}?site-content-test`) as Promise<SiteModule>;
}

describe("public product content", () => {
  it("provides the semantic product journey and direct download actions", () => {
    const html = readPublic("index.html");

    expect(html).toContain('<a class="skip-link" href="#main-content"');
    expect(html).toContain('<main id="main-content">');
    expect(html).toContain('id="features"');
    expect(html).toContain('id="privacy"');
    expect(html).toContain('id="installation"');
    expect(html.match(/href="\/download"/g)).toHaveLength(2);
    expect(html).toContain("Know your quota. Keep your flow.");
    expect(html).toContain("Quota Monitor brings Codex and Claude Code quotas, token trends, API-equivalent cost estimates, and session details into one lightweight macOS menu-bar app.");
    expect(html.match(/<section\b/g)?.length ?? 0).toBeGreaterThanOrEqual(8);
    expect(html).toMatch(/<h1\b[^>]*data-i18n="heroTitle"/);
    expect(html).toContain('src="/assets/dashboard-hero.webp"');
    expect(html).toContain('src="/assets/sessions-detail.webp"');
    expect(html).toContain('href="/styles.css"');
    expect(html).toContain('src="/app.js"');
  });

  it("keeps every visitor-facing link and full URL on the product domain", () => {
    const files = ["index.html", "404.html", "_headers", "app.js"].map(readPublic);
    const combined = files.join("\n");

    expect(combined).not.toMatch(/github/i);

    for (const url of combined.match(/https?:\/\/[^"'\s<]+/g) ?? []) {
      expect(
        url.startsWith("https://quota-monitor.timmyagentic.com/") ||
          url === "https://schema.org",
        url,
      ).toBe(true);
    }

    for (const html of files.slice(0, 2)) {
      for (const href of [...html.matchAll(/<a\b[^>]*\bhref="([^"]+)"/g)].map(
        (match) => match[1] ?? "",
      )) {
        expect(href, href).toMatch(/^(?:\/(?!\/)[^:]*|#[A-Za-z][\w-]*)$/);
      }
    }

    expect(attributeValues(readPublic("404.html"), "href").filter((href) => href === "/")).toHaveLength(1);
    expect([...readPublic("404.html").matchAll(/<a\b[^>]*\bhref="([^"]+)"/g)].map((match) => match[1])).toEqual(["/"]);
  });

  it("has complete English and Simplified Chinese localization coverage", async () => {
    const html = `${readPublic("index.html")}\n${readPublic("404.html")}`;
    const { translations } = await loadAppModule();
    const englishKeys = Object.keys(translations.en).sort();
    const chineseKeys = Object.keys(translations["zh-Hans"]).sort();

    expect(Object.isFrozen(translations)).toBe(true);
    expect(Object.isFrozen(translations.en)).toBe(true);
    expect(Object.isFrozen(translations["zh-Hans"])).toBe(true);
    expect(chineseKeys).toEqual(englishKeys);
    expect(englishKeys.length).toBeGreaterThan(30);

    const bindingKeys = [
      ...html.matchAll(/\bdata-i18n(?:-(?:alt|aria-label|content))?="([^"]+)"/g),
    ].map((match) => match[1] ?? "");
    for (const key of bindingKeys) {
      const english = translations.en[key];
      const chinese = translations["zh-Hans"][key];
      expect(english, `missing English ${key}`).toBeTypeOf("string");
      expect(chinese, `missing Chinese ${key}`).toBeTypeOf("string");
      expect(english?.trim(), key).not.toBe("");
      expect(chinese?.trim(), key).not.toBe("");
    }

    expect(html).toContain('data-i18n-content="metaDescription"');
    expect(html).toContain('data-i18n-content="ogTitle"');
    expect(html).toContain('data-i18n-content="ogDescription"');
    expect(html).toContain('data-i18n-alt="dashboardHeroAlt"');
    expect(html).toContain('data-i18n-aria-label="languageLabel"');
  });

  it("keeps version text separate from localized download labels", () => {
    const html = readPublic("index.html");

    expect(html.match(/data-version>0\.2\.40<\/span>/g)).toHaveLength(2);
    expect(html.match(/data-i18n="downloadAction"/g)).toHaveLength(2);
    expect(html).not.toMatch(/data-i18n="[^"]+"[^>]*data-version/);
  });

  it("uses only external executable scripts and styles", () => {
    const html = `${readPublic("index.html")}\n${readPublic("404.html")}`;

    expect(html).not.toMatch(/<style\b/i);
    expect(html).not.toMatch(/\sstyle\s*=/i);
    expect(html).not.toMatch(/\son[a-z]+\s*=/i);
    expect(html).not.toMatch(/javascript:/i);

    for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
      const attributes = match[1] ?? "";
      const body = (match[2] ?? "").trim();
      if (/type="application\/ld\+json"/i.test(attributes)) {
        expect(() => JSON.parse(body)).not.toThrow();
      } else {
        expect(attributes).toContain('type="module"');
        expect(attributes).toContain('src="/app.js"');
        expect(body).toBe("");
      }
    }
  });

  it("ships the static asset security policy", () => {
    const headers = readPublic("_headers");

    expect(headers).toContain("Content-Security-Policy: default-src 'self'; base-uri 'none'; connect-src 'self'");
    expect(headers).toContain("script-src 'self'; script-src-attr 'none'");
    expect(headers).toContain("style-src 'self'; style-src-attr 'none'");
    expect(headers).toContain("frame-ancestors 'none'");
    expect(headers).toContain("Permissions-Policy: camera=(), geolocation=(), microphone=(), payment=(), usb=()");
    expect(headers).toContain("Strict-Transport-Security: max-age=31536000; includeSubDomains");
    expect(headers).toContain("X-Content-Type-Options: nosniff");
    expect(headers).toContain("X-Frame-Options: DENY");
  });

  it("uses the release API and updates structured software metadata", () => {
    const html = readPublic("index.html");
    const app = readPublic("app.js");

    expect(app).toContain('"/api/release"');
    expect(app).toContain("validateRelease");
    expect(app).toContain("softwareVersion");
    expect(html).toContain('id="software-application"');
    expect(html).toContain('"softwareVersion": "0.2.40"');
    expect(html).toContain('"downloadUrl": "https://quota-monitor.timmyagentic.com/download"');
  });

  it("ships complete, correctly sized raster design and production assets", () => {
    const assets = [
      {
        path: join(designDirectory, "native-focus-homepage.png"),
        minimumBytes: 100_000,
        minimumWidth: 800,
        minimumHeight: 1_000,
      },
      {
        path: join(designDirectory, "social-card-source.png"),
        minimumBytes: 100_000,
        minimumWidth: 1_200,
        minimumHeight: 600,
      },
      {
        path: join(publicDirectory, "assets/app-icon.png"),
        minimumBytes: 10_000,
        exactWidth: 1_024,
        exactHeight: 1_024,
      },
      {
        path: join(publicDirectory, "assets/dashboard-hero.webp"),
        minimumBytes: 20_000,
        exactWidth: 980,
        exactHeight: 732,
        sha256: "10e0a8a0e5358628a95cd9253980ef1cdebdb99b6c0bce1e240d5ad94e5fd3e8",
        landscape: true,
      },
      {
        path: join(publicDirectory, "assets/sessions-detail.webp"),
        minimumBytes: 20_000,
        minimumWidth: 900,
        minimumHeight: 600,
        landscape: true,
      },
      {
        path: join(publicDirectory, "assets/social-card.webp"),
        minimumBytes: 20_000,
        exactWidth: 1_200,
        exactHeight: 630,
        landscape: true,
      },
    ];

    for (const asset of assets) {
      expect(existsSync(asset.path), asset.path).toBe(true);
      const dimensions = imageDimensions(asset.path);
      expect(statSync(asset.path).size, asset.path).toBeGreaterThan(asset.minimumBytes);
      expect(dimensions.width, asset.path).toBeGreaterThan(0);
      expect(dimensions.height, asset.path).toBeGreaterThan(0);

      if (asset.minimumWidth !== undefined) {
        expect(dimensions.width, asset.path).toBeGreaterThanOrEqual(asset.minimumWidth);
      }
      if (asset.minimumHeight !== undefined) {
        expect(dimensions.height, asset.path).toBeGreaterThanOrEqual(asset.minimumHeight);
      }
      if (asset.exactWidth !== undefined) {
        expect(dimensions.width, asset.path).toBe(asset.exactWidth);
      }
      if (asset.exactHeight !== undefined) {
        expect(dimensions.height, asset.path).toBe(asset.exactHeight);
      }
      if ("sha256" in asset) {
        const digest = createHash("sha256").update(readFileSync(asset.path)).digest("hex");
        expect(digest, `${asset.path} approved composition`).toBe(asset.sha256);
      }
      if (asset.landscape) {
        expect(dimensions.width / dimensions.height, asset.path).toBeGreaterThan(1.2);
        expect(dimensions.width / dimensions.height, asset.path).toBeLessThan(2.4);
      }
    }

    const html = readPublic("index.html");
    const rasterSources = new Set([
      ...attributeValues(html, "src"),
      ...attributeValues(html, "srcset"),
    ].filter((source) => source.startsWith("/assets/")));

    expect(rasterSources).toEqual(new Set([
      "/assets/app-icon.png",
      "/assets/dashboard-hero.webp",
      "/assets/sessions-detail.webp",
    ]));
    for (const source of rasterSources) {
      expect(source).toMatch(/\.(?:png|webp)$/);
      expect(existsSync(join(publicDirectory, source))).toBe(true);
    }
  });

  it("declares the real intrinsic dimensions for every product screenshot", () => {
    const html = readPublic("index.html");
    const productSources = new Set([
      "/assets/dashboard-hero.webp",
      "/assets/sessions-detail.webp",
    ]);
    const productImages = [...html.matchAll(/<img\b([^>]*)>/g)]
      .map((match) => match[1] ?? "")
      .map((attributes) => ({
        source: attributes.match(/\bsrc="([^"]+)"/)?.[1] ?? "",
        width: Number(attributes.match(/\bwidth="(\d+)"/)?.[1]),
        height: Number(attributes.match(/\bheight="(\d+)"/)?.[1]),
      }))
      .filter(({ source }) => productSources.has(source));

    expect(productImages).toHaveLength(4);
    for (const image of productImages) {
      const dimensions = imageDimensions(join(publicDirectory, image.source));
      expect(image.width, `${image.source} width`).toBe(dimensions.width);
      expect(image.height, `${image.source} height`).toBe(dimensions.height);
    }
  });

  it("implements the Native Focus visual and accessibility contract", () => {
    const stylePath = join(publicDirectory, "styles.css");
    expect(existsSync(stylePath), "website/public/styles.css").toBe(true);
    const css = readFileSync(stylePath, "utf8");
    const root = ruleBody(css, ":root");
    const tokens = {
      "color-scheme": "light",
      "--ink": "#142033",
      "--muted": "#5f6f83",
      "--surface": "#ffffff",
      "--surface-soft": "#f4f8fd",
      "--line": "rgba(49, 75, 108, 0.14)",
      "--blue": "#1868d5",
      "--blue-hover": "#105bbf",
      "--codex": "#4aa8b8",
      "--claude": "#cc7a59",
      "--sky": "#8cc7f2",
      "--safe": "#76b85a",
      "--danger": "#f06b7a",
      "--radius-window": "28px",
      "--shadow-window": "0 36px 90px rgba(36, 75, 122, 0.18)",
    } as const;

    for (const [name, value] of Object.entries(tokens)) {
      expect(root).toMatch(
        new RegExp(`${escapeRegularExpression(name)}\\s*:\\s*${escapeRegularExpression(value)}\\s*;`),
      );
    }
    expect(root).toContain('font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", sans-serif;');

    expect(ruleBody(css, "html")).not.toMatch(/min-width\s*:/);
    expect(ruleBody(css, "body")).not.toMatch(/min-width\s*:/);
    expect(ruleBody(css, ".container")).toMatch(/max-width:\s*1200px\s*;/);
    const heroLayout = ruleBody(css, ".hero-layout");
    expect(heroLayout).toMatch(/display:\s*grid\s*;/);
    expect(heroLayout).toMatch(/grid-template-columns:\s*minmax\([^;]+\)\s+minmax\([^;]+\)\s*;/);
    expect(ruleBody(css, ".button")).toMatch(/min-height:\s*48px\s*;/);
    expect(ruleBody(css, 'body[data-page="download-error"] .not-found')).toMatch(
      /min-height:\s*100vh\s*;/,
    );
    expect(ruleBody(css, ".not-found-eyebrow")).toMatch(/color:\s*var\(--blue\)\s*;/);
    expect(ruleBody(css, ".not-found-actions")).toMatch(/display:\s*flex\s*;/);
    expect(ruleBody(css, ".not-found-actions")).toMatch(/gap:\s*12px\s*;/);

    const mobileStart = css.search(/@media\s*\(max-width:\s*(?:759|760)px\)\s*\{/);
    expect(mobileStart, "missing below-760px responsive rules").toBeGreaterThanOrEqual(0);
    const mobileCss = css.slice(Math.max(0, mobileStart));
    expect(mobileCss).toMatch(/\.hero-layout[\s\S]*?grid-template-columns:\s*1fr\s*;/);
    expect(mobileCss).toMatch(/\.feature-layout[\s\S]*?grid-template-columns:\s*1fr\s*;/);
    expect(mobileCss).toMatch(/\.not-found-actions[\s\S]*?flex-direction:\s*column\s*;/);

    expect(css).toMatch(/:focus-visible\s*\{[^}]*outline:\s*3px\s+solid\s+var\(--blue\)\s*;/s);
    expect(css).not.toMatch(/outline:\s*none\b/i);
    expect(css).toMatch(/@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{/);
    expect(css).toMatch(/@media\s*\(prefers-reduced-motion:\s*reduce\)[\s\S]*?transition:\s*none\s*!important\s*;/);
    expect(css).toMatch(/@media\s*\(forced-colors:\s*active\)\s*\{/);
    expect(css).toMatch(/@media\s*\(forced-colors:\s*active\)[\s\S]*?forced-color-adjust:\s*auto\s*;/);

    expect(css).not.toMatch(/github/i);
    expect(css).not.toMatch(/(?:linear|radial|conic)-gradient\s*\(/i);
    expect(css).not.toMatch(/::(?:before|after)\b/i);
    expect(css).not.toMatch(/(?:clip-path|mask|background-image)\s*:/i);
    expect(css).not.toMatch(/(?:data:image|<svg|\bplaceholder\b)/i);
    expect(`${readPublic("index.html")}\n${readPublic("404.html")}`).not.toMatch(/\sstyle\s*=|<style\b/i);
  });
});

describe("language resolution", () => {
  it("prefers a supported explicit choice", async () => {
    const { resolveLanguage } = await loadAppModule();

    expect(resolveLanguage("zh-Hans", ["en-US"])).toBe("zh-Hans");
    expect(resolveLanguage("en", ["zh-CN"])).toBe("en");
  });

  it("selects Chinese from browser languages and otherwise defaults to English", async () => {
    const { resolveLanguage } = await loadAppModule();

    expect(resolveLanguage(null, ["fr-FR", "zh-CN"])).toBe("zh-Hans");
    expect(resolveLanguage("unsupported", ["de-DE"])).toBe("en");
    expect(resolveLanguage(null, [null, 42, "ZH-hant"])).toBe("zh-Hans");
    expect(() => resolveLanguage()).not.toThrow();
  });

  it("keeps DOM-dependent exports safe in Node", async () => {
    const { applyLanguage, hydrateRelease } = await loadAppModule();

    expect(applyLanguage("unsupported")).toBe("en");
    await expect(hydrateRelease()).resolves.not.toThrow();
  });
});
