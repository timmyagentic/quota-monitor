import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";

const websiteDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");
const repositoryDirectory = join(websiteDirectory, "..");
const publicDirectory = join(websiteDirectory, "public");
const designDirectory = join(websiteDirectory, "design");

function stripJSONComments(source: string): string {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/^\s*\/\/.*$/gm, "");
}

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
  it("gates website changes through the required CI summary", () => {
    const workflow = readFileSync(
      join(repositoryDirectory, ".github", "workflows", "tests.yml"),
      "utf8",
    );

    expect(workflow).toContain(
      "types: [opened, synchronize, reopened, ready_for_review]",
    );
    expect(workflow).toContain(
      "website-test: ${{ steps.filter.outputs.website-test }}",
    );
    expect(workflow).toContain("website/**)");
    expect(workflow).toContain("website_test:");
    expect(workflow).toMatch(/uses: actions\/setup-node@v\d+(?:\.\d+){0,2}/);
    expect(workflow).toMatch(/node-version:\s*['\"]?22['\"]?/);
    expect(workflow).toContain("working-directory: website");
    expect(workflow).toContain("run: npm ci");
    expect(workflow).toContain("run: npm run check");
    expect(workflow).toContain("WEBSITE_RESULT: ${{ needs.website_test.result }}");
    expect(workflow).toContain(
      '[[ "${NEEDS_WEBSITE_TEST}" == "true" && "${WEBSITE_RESULT}" != "success" ]]',
    );
  });

  it("defines the production Worker and static asset deployment contract", () => {
    const configPath = join(websiteDirectory, "wrangler.jsonc");
    expect(existsSync(configPath), "website/wrangler.jsonc").toBe(true);
    const config = JSON.parse(stripJSONComments(readFileSync(configPath, "utf8")));

    expect(config.name).toBe("quota-monitor-site");
    expect(config.main).toBe("src/worker.ts");
    expect(config.compatibility_date).toBe("2026-07-15");
    expect(config.compatibility_flags).toEqual(["nodejs_compat"]);
    expect(config.workers_dev).toBe(false);
    expect(config.assets.directory).toBe("./public");
    expect(config.assets.binding).toBe("ASSETS");
    expect(config.assets.not_found_handling).toBe("404-page");
    expect(config.assets.run_worker_first).toEqual([
      "/download",
      "/api/release",
      "/api/v1/daily-active",
      "/maintainer/versions",
    ]);
    expect(config.d1_databases).toEqual([
      {
        binding: "VERSION_STATS_DB",
        database_name: "quota-monitor-version-stats",
        migrations_dir: "migrations",
      },
    ]);
    expect(config.ratelimits).toEqual([
      {
        name: "DAILY_ACTIVE_RATE_LIMITER",
        namespace_id: "2026071601",
        simple: { limit: 120, period: 60 },
      },
      {
        name: "DAILY_ACTIVE_COLO_RATE_LIMITER",
        namespace_id: "2026071602",
        simple: { limit: 5000, period: 60 },
      },
      {
        name: "ADMIN_VERSION_STATS_RATE_LIMITER",
        namespace_id: "2026071603",
        simple: { limit: 30, period: 60 },
      },
    ]);
    expect(config).not.toHaveProperty("durable_objects");
    expect(config.triggers).toEqual({ crons: ["15 * * * *"] });
    expect(config.routes).toContainEqual({
      pattern: "quota-monitor.timmyagentic.com",
      custom_domain: true,
    });
    expect(config.observability).toEqual({
      enabled: true,
      logs: {
        enabled: true,
        invocation_logs: false,
        persist: true,
      },
    });
  });

  it("publishes the exact public robots policy", () => {
    expect(readPublic("robots.txt")).toBe("User-agent: *\nAllow: /\n");
  });

  it("uses generated Worker bindings and exposes the complete validation scripts", () => {
    const worker = readFileSync(join(websiteDirectory, "src", "worker.ts"), "utf8");
    const manifest = JSON.parse(
      readFileSync(join(websiteDirectory, "package.json"), "utf8"),
    );

    expect(worker).not.toMatch(/\b(?:interface|type)\s+Env\b/);
    expect(manifest.scripts.typegen).toBe("wrangler types");
    expect(manifest.scripts.typecheck).toBe("wrangler types --check && tsc --noEmit");
    expect(manifest.scripts["test:integration"]).toBe(
      "vitest run --config vitest.integration.config.ts",
    );
    expect(manifest.scripts.check).toBe(
      "npm run typecheck && npm test && npm run test:integration && wrangler deploy --dry-run --outdir .wrangler/dry-run && wrangler check startup --outfile .wrangler/worker-startup.cpuprofile",
    );
    expect(manifest.devDependencies["@cloudflare/vitest-pool-workers"]).toBe("0.18.5");
    expect(existsSync(join(websiteDirectory, "vitest.integration.config.ts"))).toBe(true);
    expect(existsSync(join(websiteDirectory, "tests", "d1.integration.test.ts"))).toBe(true);
    expect(existsSync(join(websiteDirectory, "tests", "d1-integration-setup.ts"))).toBe(true);
  });

  it("awaits the scheduled aggregation without destructuring its execution context", () => {
    const worker = readFileSync(join(websiteDirectory, "src", "worker.ts"), "utf8");

    expect(worker).toMatch(/async scheduled\s*\(\s*controller,\s*env,\s*_?ctx\s*\)/);
    expect(worker).toMatch(
      /await aggregateClosedDays\s*\(\s*env\.VERSION_STATS_DB,\s*controller\.scheduledTime,?\s*\)/,
    );
    expect(worker).not.toMatch(/(?:const|let|var)\s*\{[^}]*\}\s*=\s*_?ctx\b/);
    expect(worker).toMatch(/console\.info\s*\(/);
    expect(worker).toMatch(/console\.error\s*\(/);
  });

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
    expect(html).toMatch(/<h1\b[^>]*id="hero-title"/);
    expect(html).toContain('src="/assets/dashboard-hero.webp"');
    expect(html).toContain('src="/assets/sessions-detail.webp"');
    expect(html).toContain('href="/styles.css"');
    expect(html).toContain('src="/app.js"');
  });

  it("keeps the desktop English hero promise on its approved two-line phrase boundary", async () => {
    const html = readPublic("index.html");
    const css = readPublic("styles.css");
    const { translations } = await loadAppModule();

    expect(html).toContain(
      '<span class="hero-title-line" data-i18n="heroTitleFirstLine">Know your quota.</span><span class="hero-title-line" data-i18n="heroTitleSecondLine"> Keep your flow.</span>',
    );
    expect(translations.en.heroTitleFirstLine).toBe("Know your quota.");
    expect(translations.en.heroTitleSecondLine).toBe(" Keep your flow.");
    const mobileLine = ruleBody(css, ".hero-title-line");
    expect(mobileLine).toMatch(/display:\s*inline\s*;/);
    expect(mobileLine).toMatch(/white-space:\s*normal\s*;/);

    const desktopStart = css.search(/@media\s*\(min-width:\s*981px\)\s*\{/);
    expect(desktopStart, "missing above-980px hero title rules").toBeGreaterThanOrEqual(0);
    const desktopEnd = css.indexOf("@media", desktopStart + 1);
    const desktopCss = css.slice(desktopStart, desktopEnd);
    const desktopLine = ruleBody(desktopCss, ".hero-title-line");
    expect(desktopLine).toMatch(/display:\s*block\s*;/);
    expect(desktopLine).toMatch(/white-space:\s*nowrap\s*;/);
  });

  it("keeps every visitor-facing link and full URL on the product domain", () => {
    const files = ["index.html", "404.html", "_headers", "app.js", "robots.txt"].map(readPublic);
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
    for (const source of [
      "assets/dashboard-hero.webp",
      "assets/dashboard-insights.webp",
      "assets/sessions-detail.webp",
      "assets/history-detail.webp",
    ]) {
      expect(existsSync(join(publicDirectory, source)), source).toBe(true);
    }

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
        sha256: "13ba8a1214a3f51bbffff1e7ad039bf05ede3c331c80561c30231a5d15017ae1",
        retiredSha256: [
          "9eb6706d56d169d2282ccba3b0a1fd6a5dbc1a59a8ad114da5e06b21e018b6c6",
          "9aa8c51e6026ee4f724226ba5850bd97d6e6772125368f1782bffed67b0f3245",
        ],
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
        sha256: "890cd3a1a0a3485a9a8521228aebc31f84a16ac6f1ed56814c622fac3b1e5034",
        retiredSha256: [
          "10e0a8a0e5358628a95cd9253980ef1cdebdb99b6c0bce1e240d5ad94e5fd3e8",
          "3aad57e87b8116f171f93d39c3ca260d4c8f4dc2bd4650827ee371348f200411",
        ],
        landscape: true,
      },
      {
        path: join(publicDirectory, "assets/dashboard-insights.webp"),
        minimumBytes: 20_000,
        exactWidth: 980,
        exactHeight: 732,
        sha256: "0a2369eebc7229df57f7296e06bc36e270784855be12c44791497a1a2b386457",
        landscape: true,
      },
      {
        path: join(publicDirectory, "assets/sessions-detail.webp"),
        minimumBytes: 20_000,
        exactWidth: 980,
        exactHeight: 732,
        sha256: "a59e0504c5bb0a7a10313ed6138ca08c8fe90618f823eb6f1551be205557564d",
        retiredSha256: [
          "516ca8ba3bae48db581b91cdcc9f0575ffe6cbd02bb60494466784b742c86b65",
        ],
        landscape: true,
      },
      {
        path: join(publicDirectory, "assets/history-detail.webp"),
        minimumBytes: 20_000,
        exactWidth: 980,
        exactHeight: 732,
        sha256: "a5fcd5f80eb4b29405041e7da655347fab51471a8590b5c6f7f35d10f9c08595",
        landscape: true,
      },
      {
        path: join(publicDirectory, "assets/social-card.webp"),
        minimumBytes: 20_000,
        exactWidth: 1_200,
        exactHeight: 630,
        sha256: "c7942bac7e5c16ad2d4e88980b77bd1abd49670f4f4c6d15a77bcb8cef2c5228",
        retiredSha256: [
          "98a7b5ca1c1c30b447453fc9bf461522a90bc404f92c59a2de598d240e8acdcf",
          "a94e9bece876af2316a48abdfa99d1a31943dc6ac0358ad50f487698aa188a43",
        ],
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
      if ("retiredSha256" in asset) {
        const digest = createHash("sha256").update(readFileSync(asset.path)).digest("hex");
        expect(asset.retiredSha256, `${asset.path} retired composition`).not.toContain(digest);
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
      "/assets/dashboard-insights.webp",
      "/assets/history-detail.webp",
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
      "/assets/dashboard-insights.webp",
      "/assets/history-detail.webp",
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

    expect(productImages).toHaveLength(5);
    for (const image of productImages) {
      const dimensions = imageDimensions(join(publicDirectory, image.source));
      expect(image.width, `${image.source} width`).toBe(dimensions.width);
      expect(image.height, `${image.source} height`).toBe(dimensions.height);
    }
  });

  it("maps each feature story to its verified real-app capture", () => {
    const html = readPublic("index.html");
    const hero = html.match(/<section\b[^>]*class="hero"[\s\S]*?<\/section>/)?.[0] ?? "";
    const quota = html.match(/<section\b[^>]*feature-story-quota[^>]*>[\s\S]*?<\/section>/)?.[0] ?? "";
    const trends = html.match(/<section\b[^>]*feature-story-trends[^>]*>[\s\S]*?<\/section>/)?.[0] ?? "";
    const sessions = html.match(/<section\b[^>]*feature-story-sessions[^>]*>[\s\S]*?<\/section>/)?.[0] ?? "";
    const history = html.match(/<section\b[^>]*feature-story-history[^>]*>[\s\S]*?<\/section>/)?.[0] ?? "";

    for (const block of [hero, quota]) {
      expect(block).toContain('srcset="/assets/dashboard-hero.webp"');
      expect(block).toContain('src="/assets/dashboard-hero.webp"');
    }
    expect(trends).toContain('srcset="/assets/dashboard-insights.webp"');
    expect(trends).toContain('src="/assets/dashboard-insights.webp"');
    expect(sessions).toContain('srcset="/assets/sessions-detail.webp"');
    expect(sessions).toContain('src="/assets/sessions-detail.webp"');
    expect(history).toContain('srcset="/assets/history-detail.webp"');
    expect(history).toContain('src="/assets/history-detail.webp"');
  });

  it("links each product capture to its same-origin full-size asset", async () => {
    const html = readPublic("index.html");
    const css = readPublic("styles.css");
    const { translations } = await loadAppModule();
    const productLinks = [...html.matchAll(
      /<a\b[^>]*class="product-image-link"[^>]*href="([^\"]+)"[^>]*>([\s\S]*?)<\/a>/g,
    )];

    expect(productLinks).toHaveLength(5);
    for (const [, href = "", contents = ""] of productLinks) {
      expect(href).toMatch(/^\/assets\/(?:dashboard-hero|dashboard-insights|sessions-detail|history-detail)\.webp$/);
      expect(contents).toContain(`src="${href}"`);
      expect(contents).toContain('data-i18n="viewImageFullSize"');
    }

    expect(translations.en.viewImageFullSize).toBe("View image full size");
    expect(translations["zh-Hans"].viewImageFullSize).toBe("查看完整尺寸图片");
    expect(ruleBody(css, ".view-image-full-size")).toMatch(/display:\s*none\s*;/);
    const mobileStart = css.search(/@media\s*\(max-width:\s*(?:759|760)px\)\s*\{/);
    const mobileCss = css.slice(Math.max(0, mobileStart));
    expect(ruleBody(mobileCss, ".view-image-full-size")).toMatch(/display:\s*inline-flex\s*;/);
  });

  it("describes Sessions event timing without claiming a duration field", async () => {
    const html = readPublic("index.html");
    const { translations } = await loadAppModule();
    const english = `${translations.en.featureSessionsBody}\n${translations.en.sessionsDetailAlt}`;
    const chinese = `${translations["zh-Hans"].featureSessionsBody}\n${translations["zh-Hans"].sessionsDetailAlt}`;

    expect(translations.en.featureSessionsBody).toBe(
      "Search and sort sessions, then review models, token details, event timing, and API-equivalent cost estimates.",
    );
    expect(translations["zh-Hans"].featureSessionsBody).toBe(
      "搜索和排序会话，查看模型、Token 明细、事件时间与 API 等价费用估算。",
    );
    expect(english).not.toMatch(/\bduration\b/i);
    expect(english).toMatch(/event timing/i);
    expect(chinese).not.toContain("时长");
    expect(chinese).toContain("事件时间");
    expect(html).not.toMatch(/(?:duration|时长)/i);
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

    const compactStart = css.search(/@media\s*\(max-width:\s*359px\)\s*\{/);
    expect(compactStart, "missing below-360px responsive rules").toBeGreaterThanOrEqual(0);
    const compactEnd = css.indexOf("@media", compactStart + 1);
    const compactCss = css.slice(compactStart, compactEnd);
    expect(ruleBody(compactCss, ".language-control button")).toMatch(/min-width:\s*44px\s*;/);

    expect(css).toMatch(/:focus-visible\s*\{[^}]*outline:\s*3px\s+solid\s+var\(--blue\)\s*;/s);
    expect(css).not.toMatch(/outline:\s*none\b/i);
    expect(css).toMatch(/@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{/);
    expect(css).toMatch(/@media\s*\(prefers-reduced-motion:\s*reduce\)[\s\S]*?transition:\s*none\s*!important\s*;/);
    expect(css).toMatch(/@media\s*\(forced-colors:\s*active\)\s*\{/);
    expect(css).toMatch(/@media\s*\(forced-colors:\s*active\)[\s\S]*?forced-color-adjust:\s*auto\s*;/);
    expect(ruleBody(css, '.language-control button[aria-pressed="true"]')).toMatch(
      /text-decoration:\s*underline\s*;/,
    );
    const forcedColorsCss = css.slice(css.search(/@media\s*\(forced-colors:\s*active\)\s*\{/));
    expect(
      ruleBody(forcedColorsCss, '.language-control button[aria-pressed="true"]'),
    ).toMatch(/outline:\s*2px\s+solid\s+ButtonText\s*;/);

    expect(css).not.toMatch(/github/i);
    expect(css).not.toMatch(/(?:linear|radial|conic)-gradient\s*\(/i);
    expect(css).not.toMatch(/::(?:before|after)\b/i);
    expect(css).not.toMatch(/(?:clip-path|mask|background-image)\s*:/i);
    expect(css).not.toMatch(/(?:data:image|<svg|\bplaceholder\b)/i);
    expect(`${readPublic("index.html")}\n${readPublic("404.html")}`).not.toMatch(/\sstyle\s*=|<style\b/i);
  });
});

describe("language resolution", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("prefers a supported explicit choice", async () => {
    const { resolveLanguage } = await loadAppModule();

    expect(resolveLanguage("zh-Hans", ["en-US"])).toBe("zh-Hans");
    expect(resolveLanguage("en", ["zh-CN"])).toBe("en");
  });

  it("selects Chinese from browser languages and otherwise defaults to English", async () => {
    const { resolveLanguage } = await loadAppModule();

    expect(resolveLanguage(null, ["en-US", "zh-CN"])).toBe("en");
    expect(resolveLanguage(null, ["fr-FR", "zh-CN", "en-US"])).toBe("zh-Hans");
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

  it.each([
    [
      "stored Chinese over an English browser",
      "zh-Hans",
      ["en-US"],
      "zh-Hans",
      "暂时无法开始下载",
      "暂时无法下载 — QuotaMonitor",
    ],
    [
      "stored English over a Chinese browser",
      "en",
      ["zh-CN"],
      "en",
      "Download temporarily unavailable",
      "Download unavailable — QuotaMonitor",
    ],
  ])("localizes a download error using %s", async (
    _label,
    saved,
    languages,
    expectedLocale,
    expectedHeading,
    expectedTitle,
  ) => {
    const { applyLanguage, resolveLanguage } = await loadAppModule();
    const heading = {
      dataset: { i18n: "downloadErrorTitle" },
      textContent: "initial server copy",
    };
    const documentElement = { lang: "en" };
    const documentStub = {
      body: { dataset: { page: "download-error" } },
      documentElement,
      title: "initial server title",
      querySelectorAll(selector: string) {
        return selector === "[data-i18n]" ? [heading] : [];
      },
    };
    vi.stubGlobal("document", documentStub);

    const locale = resolveLanguage(saved, languages);
    expect(locale).toBe(expectedLocale);
    expect(applyLanguage(locale)).toBe(expectedLocale);
    expect(documentElement.lang).toBe(expectedLocale);
    expect(heading.textContent).toBe(expectedHeading);
    expect(documentStub.title).toBe(expectedTitle);
  });
});
