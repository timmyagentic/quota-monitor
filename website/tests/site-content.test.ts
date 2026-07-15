import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { describe, expect, it } from "vitest";

const publicDirectory = join(dirname(fileURLToPath(import.meta.url)), "../public");

function readPublic(name: string): string {
  return readFileSync(join(publicDirectory, name), "utf8");
}

function attributeValues(source: string, attribute: string): string[] {
  const pattern = new RegExp(`\\b${attribute}="([^"]+)"`, "g");
  return [...source.matchAll(pattern)].map((match) => match[1] ?? "");
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
