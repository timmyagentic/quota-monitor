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
  hydrateRelease: (fetcher?: typeof fetch) => Promise<unknown>;
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
    expect(config.assets.html_handling).toBe("auto-trailing-slash");
    expect(config.assets.run_worker_first).toBe(true);
    expect(config.d1_databases).toEqual([
      {
        binding: "VERSION_STATS_DB",
        database_name: "quota-monitor-version-stats",
        database_id: "d4001c95-442b-4ad0-80ee-0c06747637d9",
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
    expect(config.secrets).toEqual({
      required: ["VERSION_STATS_ADMIN_TOKEN"],
    });
    expect(config.logpush).toBe(false);
    expect(config.tail_consumers).toEqual([]);
    expect(config.streaming_tail_consumers).toEqual([]);
    expect(config.observability).toEqual({
      enabled: true,
      logs: {
        enabled: true,
        invocation_logs: false,
        persist: true,
        destinations: [],
      },
      traces: {
        enabled: false,
        persist: false,
        destinations: [],
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
    const generatedBindings = readFileSync(
      join(websiteDirectory, "worker-configuration.d.ts"),
      "utf8",
    );
    expect(generatedBindings).toMatch(/VERSION_STATS_ADMIN_TOKEN:\s*string;/);
  });

  it("ignores local Worker secret files from every repository directory", () => {
    const ignore = readFileSync(join(repositoryDirectory, ".gitignore"), "utf8");

    for (const pattern of [".env", ".env.*", ".dev.vars", ".dev.vars.*"]) {
      expect(ignore.split("\n"), pattern).toContain(pattern);
    }
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
    expect(html).toContain('<a href="/privacy" data-i18n="privacyNav">');
    expect(html).toContain('href="/privacy" data-i18n="privacyPolicyLink"');
    expect(html).toContain('data-i18n="privacyProviderSummary"');
    expect(html).toContain('id="installation"');
    expect(html.match(/href="\/download"/g)).toHaveLength(2);
    expect(html).toContain("Know your quota. Keep your flow.");
    expect(html).toContain("Keep Codex and Claude Code quota percentages visible in the menu bar, then click for reset times, token trends, API-equivalent cost estimates, and session details.");
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
    const files = ["index.html", "privacy.html", "404.html", "_headers", "app.js", "robots.txt"].map(readPublic);
    const combined = files.join("\n");

    expect(combined).not.toMatch(/github/i);

    for (const url of combined.match(/https?:\/\/[^"'\s<]+/g) ?? []) {
      expect(
        url.startsWith("https://quota-monitor.timmyagentic.com/") ||
          url === "https://schema.org",
        url,
      ).toBe(true);
    }

    for (const html of files.slice(0, 3)) {
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
    const html = `${readPublic("index.html")}\n${readPublic("privacy.html")}\n${readPublic("404.html")}`;
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
    const html = `${readPublic("index.html")}\n${readPublic("privacy.html")}\n${readPublic("404.html")}`;

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

  it("publishes a canonical, external-asset-only privacy page", () => {
    const html = readPublic("privacy.html");
    const css = readPublic("styles.css");

    expect(html).toContain('<body data-page="privacy">');
    expect(html).toContain('<main id="main-content" class="privacy-policy-page">');
    expect(html).toContain(
      '<link rel="canonical" href="https://quota-monitor.timmyagentic.com/privacy">',
    );
    expect(html).toContain('href="/styles.css"');
    expect(html).toContain('type="module" src="/app.js"');
    expect(html).toContain('class="privacy-policy-list"');
    expect(html).toContain(
      `content="How Quota Monitor's anonymous daily active installation check-in works, what it excludes, and how long aggregate counts are retained."`,
    );
    expect(html).not.toContain("optional anonymous daily active installation check-in");
    expect(html).not.toMatch(/<style\b|\sstyle\s*=|\son[a-z]+\s*=|javascript:/i);
    expect(html).not.toMatch(/github/i);
    expect(ruleBody(css, ".privacy-policy-layout")).toMatch(/max-width:\s*880px\s*;/);
    expect(ruleBody(css, ".privacy-policy-section")).toMatch(/border:\s*1px\s+solid\s+var\(--line\)\s*;/);
    expect(ruleBody(css, ".privacy-policy-list")).toMatch(/list-style:\s*disc\s*;/);
    expect(ruleBody(css, ".text-link")).toMatch(/text-decoration:\s*underline\s*;/);
    const mobileCss = css.slice(css.search(/@media\s*\(max-width:\s*(?:759|760)px\)\s*\{/));
    expect(ruleBody(mobileCss, ".privacy-policy-page")).toMatch(/padding:\s*52px\s+0\s*;/);
  });

  it("states the exact automatic anonymous check-in, retention, and edge contract in both languages", async () => {
    const html = readPublic("privacy.html");
    const { translations } = await loadAppModule();
    const policies = [translations.en, translations["zh-Hans"]];

    expect(html).toContain('data-i18n="privacyPolicyWireBody"');
    expect(html).toContain('data-i18n="privacyPolicyScopeBody"');
    expect(html).toContain('data-i18n="privacyPolicyRetentionBody"');
    expect(html).toContain('data-i18n="privacyPolicyOptOutBody"');

    expect(translations.en.privacyPolicyIntro).toBe(
      "Eligible Quota Monitor builds automatically send one anonymous daily active installation check-in. These counts estimate active installations, never users.",
    );
    expect(translations["zh-Hans"].privacyPolicyIntro).toBe(
      "符合条件的 Quota Monitor 构建会自动发送每日一次的匿名活跃安装检查。统计结果估算的是活跃安装量，绝不是用户数。",
    );
    expect(translations.en.privacyStatisticsBody).toBe(
      "The check-in JSON payload contains only six documented fields, and neither it nor the D1 raw or aggregate datasets contain a stable installation or device ID. The service is not designed to link installations across UTC days; Cloudflare network processing is disclosed separately in the full policy.",
    );
    expect(translations["zh-Hans"].privacyStatisticsBody).toBe(
      "检查 JSON payload 只包含公开说明的六个字段；它和 D1 原始及聚合数据集都不包含稳定安装 ID 或设备 ID。服务的设计目的不是跨 UTC 日关联安装；Cloudflare 的网络处理在完整政策中单独披露。",
    );
    expect(translations.en.privacyPolicyTokenBody).toBe(
      "The random token rotates every UTC day. A failed request reuses it only within the same UTC day. If the app version changes that day, a later check-in can reclassify the same record. The check-in JSON payload and D1 raw or aggregate datasets contain no stable installation or device ID, and the service is not designed to link installations across UTC days. This statement does not cover Cloudflare's separate network-boundary processing, which is disclosed below.",
    );
    expect(translations["zh-Hans"].privacyPolicyTokenBody).toBe(
      "随机令牌在每个 UTC 日轮换。失败请求只会在同一个 UTC 日内复用它。如果当天应用版本发生变化，后续检查可以对同一条记录重新分类。检查 JSON payload 与 D1 原始或聚合数据集都不包含稳定安装 ID 或设备 ID，服务的设计目的不是跨 UTC 日关联安装。该说明不涵盖 Cloudflare 单独的网络边界处理，相关内容见下文披露。",
    );
    expect(translations.en.privacyPolicyOptOutBody).toBe(
      "Reporting starts automatically in eligible production builds and runs at most once per UTC day for each version context. Local QA and builds without an approved reporting context do not send check-ins. Anonymous rows cannot be individually found or deleted because no stable ID or deletion handle exists; they follow the live raw-row and D1 Time Travel retention above.",
    );
    expect(translations["zh-Hans"].privacyPolicyOptOutBody).toBe(
      "报告会在符合条件的正式构建中自动启动，并且每个版本上下文在每个 UTC 日最多发送一次。本地 QA 以及没有获准报告上下文的构建不会发送检查。匿名行无法单独定位或删除，因为不存在稳定 ID 或删除句柄；它们遵循上述实时原始行和 D1 Time Travel 保留规则。",
    );
    expect(readPublic("index.html")).toContain(translations.en.privacyStatisticsBody);
    expect(html).toContain(translations.en.privacyPolicyTokenBody);
    expect(html).toContain(translations.en.privacyPolicyOptOutBody);

    for (const policy of policies) {
      const wire = policy.privacyPolicyWireBody;
      const scope = policy.privacyPolicyScopeBody;
      const identity = policy.privacyPolicyTokenBody;
      const processing = policy.privacyPolicyProcessingBody;
      const edge = policy.privacyPolicyCloudflareBody;
      const retention = policy.privacyPolicyRetentionBody;
      const optOut = policy.privacyPolicyOptOutBody;
      const excluded = policy.privacyPolicyExcludedBody;
      const provider = policy.privacyPolicyProviderBody;
      const website = policy.privacyPolicyWebsiteBody;

      for (const value of [scope, wire, identity, processing, edge, retention, optOut, excluded, provider, website]) {
        if (typeof value !== "string") {
          throw new Error("missing localized privacy policy value");
        }
        expect(value.trim()).not.toBe("");
      }
    }

    const englishPolicy = Object.entries(translations.en)
      .filter(([key]) => key.startsWith("privacyPolicy"))
      .map(([, value]) => value)
      .join("\n");
    const chinesePolicy = Object.entries(translations["zh-Hans"])
      .filter(([key]) => key.startsWith("privacyPolicy"))
      .map(([, value]) => value)
      .join("\n");

    expect(translations.en.privacyPolicyWireBody).toContain(
      "exactly six fields: schema (the number 1), UTC day (YYYY-MM-DD), a fresh random daily token, app version, brand, and distribution channel",
    );
    expect(translations["zh-Hans"].privacyPolicyWireBody).toContain(
      "恰好六个字段：schema（数字 1）、UTC 日期（YYYY-MM-DD）、当天新生成的随机令牌、应用版本、品牌和分发渠道",
    );
    expect(englishPolicy).toMatch(/failed request reuses it only within the same UTC day/i);
    expect(englishPolicy).toMatch(/Quota Monitor and CodexMonitor-branded builds[\s\S]*brand field[\s\S]*quota-monitor[\s\S]*codex-monitor/i);
    expect(englishPolicy).toMatch(/version changes that day[\s\S]*reclassify/i);
    expect(englishPolicy).toMatch(/one deduplicated active-installation record per token per UTC day/i);
    expect(englishPolicy).toMatch(/check-in JSON payload and D1 raw or aggregate datasets contain no stable installation or device ID/i);
    expect(englishPolicy).toMatch(/not designed to link installations across UTC days/i);
    expect(englishPolicy).toMatch(/does not cover Cloudflare's separate network-boundary processing/i);
    expect(englishPolicy).toMatch(/date-domain-separated SHA-256 hash/i);
    expect(englishPolicy).toMatch(/original token is never written to D1 or the app's custom logs/i);
    expect(englishPolicy).toMatch(/source IP[\s\S]*best-effort Workers RateLimit binding/i);
    expect(englishPolicy).toMatch(/CDN, WAF, and network-error logging[\s\S]*not[\s\S]*log-free/i);
    expect(englishPolicy).toMatch(/next successful closed-day aggregation/i);
    expect(englishPolicy).toMatch(/not an exact one-hour promise/i);
    expect(englishPolicy).toMatch(/7 days on the Free plan or 30 days on a Paid plan/i);
    expect(englishPolicy).toMatch(/retained for 400 days[\s\S]*private maintainer dashboard/i);
    expect(englishPolicy).toMatch(/starts automatically in eligible production builds/i);
    expect(englishPolicy).toMatch(/Local QA[\s\S]*do not send check-ins/i);
    expect(englishPolicy).toMatch(/anonymous rows[\s\S]*live raw-row and D1 Time Travel retention/i);
    expect(englishPolicy).toMatch(/name or account details[\s\S]*email[\s\S]*persistent identifier/i);
    expect(englishPolicy).toMatch(/system or hardware information[\s\S]*session titles/i);
    expect(englishPolicy).toMatch(/prompts, messages, or history[\s\S]*quota or usage values/i);
    expect(englishPolicy).toMatch(/token counts or cost estimates[\s\S]*file paths[\s\S]*credentials/i);
    expect(englishPolicy).toMatch(/API or authentication tokens/i);
    expect(englishPolicy).toMatch(/session and history data stays[\s\S]*local SQLite database/i);
    expect(englishPolicy).toMatch(/live Codex or Claude Code quota refresh[\s\S]*corresponding provider services/i);
    expect(englishPolicy).toMatch(/separate from anonymous version statistics[\s\S]*provider's privacy terms/i);
    expect(englishPolicy).toMatch(/language choice in localStorage/i);
    expect(englishPolicy).toMatch(/no cookies, client analytics, or third-party UI runtime/i);

    expect(chinesePolicy).toMatch(/失败请求只会在同一个 UTC 日内复用它/);
    expect(chinesePolicy).toMatch(/Quota Monitor 和 CodexMonitor 品牌构建[\s\S]*brand 字段[\s\S]*quota-monitor[\s\S]*codex-monitor/);
    expect(chinesePolicy).toMatch(/当天应用版本发生变化[\s\S]*重新分类/);
    expect(chinesePolicy).toMatch(/每个令牌在每个 UTC 日最多保留一条去重后的活跃安装记录/);
    expect(chinesePolicy).toMatch(/检查 JSON payload 与 D1 原始或聚合数据集都不包含稳定安装 ID 或设备 ID/);
    expect(chinesePolicy).toMatch(/设计目的不是跨 UTC 日关联安装/);
    expect(chinesePolicy).toMatch(/不涵盖 Cloudflare 单独的网络边界处理/);
    expect(chinesePolicy).toMatch(/日期域隔离的 SHA-256 哈希/);
    expect(chinesePolicy).toMatch(/原始令牌绝不会写入 D1 或应用自定义日志/);
    expect(chinesePolicy).toMatch(/源 IP[\s\S]*尽力而为的 Workers RateLimit binding/);
    expect(chinesePolicy).toMatch(/CDN、WAF 和网络错误日志[\s\S]*完全无日志/);
    expect(chinesePolicy).toMatch(/下一次成功完成的已结束日期聚合后/);
    expect(chinesePolicy).toMatch(/并非精确的一小时承诺/);
    expect(chinesePolicy).toMatch(/Free 计划 7 天或 Paid 计划 30 天/);
    expect(chinesePolicy).toMatch(/保留 400 天[\s\S]*私有维护者仪表盘/);
    expect(chinesePolicy).toMatch(/符合条件的正式构建中自动启动/);
    expect(chinesePolicy).toMatch(/本地 QA[\s\S]*不会发送检查/);
    expect(chinesePolicy).toMatch(/匿名行无法单独定位或删除[\s\S]*实时原始行和 D1 Time Travel 保留规则/);
    expect(chinesePolicy).toMatch(/会话和历史数据[\s\S]*本地 SQLite 数据库/);
    expect(chinesePolicy).toMatch(/Codex 或 Claude Code 实时额度刷新[\s\S]*对应的服务提供方/);
    expect(chinesePolicy).toMatch(/独立于匿名版本统计[\s\S]*服务提供方的隐私条款/);
    expect(chinesePolicy).toMatch(/localStorage/);
    expect(chinesePolicy).toMatch(/不使用 Cookie、客户端分析或第三方 UI runtime/);
  });

  it("ships complete, correctly sized raster design and production assets", () => {
    for (const source of [
      "assets/menu-bar-popover.webp",
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
        path: join(publicDirectory, "assets/menu-bar-popover.webp"),
        minimumBytes: 10_000,
        exactWidth: 386,
        exactHeight: 661,
        sha256: "1a68b4f07fde23161d46e8f6126f6c61d4c77735b619d94e9e04a0b765e9ad1a",
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
      "/assets/menu-bar-popover.webp",
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
      "/assets/menu-bar-popover.webp",
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

    expect(productImages).toHaveLength(6);
    for (const image of productImages) {
      const dimensions = imageDimensions(join(publicDirectory, image.source));
      expect(image.width, `${image.source} width`).toBe(dimensions.width);
      expect(image.height, `${image.source} height`).toBe(dimensions.height);
    }
  });

  it("maps each feature story to its verified real-app capture", () => {
    const html = readPublic("index.html");
    const hero = html.match(/<section\b[^>]*class="hero"[\s\S]*?<\/section>/)?.[0] ?? "";
    const menu = html.match(/<section\b[^>]*feature-story-menu[^>]*>[\s\S]*?<\/section>/)?.[0] ?? "";
    const quota = html.match(/<section\b[^>]*feature-story-quota[^>]*>[\s\S]*?<\/section>/)?.[0] ?? "";
    const trends = html.match(/<section\b[^>]*feature-story-trends[^>]*>[\s\S]*?<\/section>/)?.[0] ?? "";
    const sessions = html.match(/<section\b[^>]*feature-story-sessions[^>]*>[\s\S]*?<\/section>/)?.[0] ?? "";
    const history = html.match(/<section\b[^>]*feature-story-history[^>]*>[\s\S]*?<\/section>/)?.[0] ?? "";

    for (const block of [hero, quota]) {
      expect(block).toContain('srcset="/assets/dashboard-hero.webp"');
      expect(block).toContain('src="/assets/dashboard-hero.webp"');
    }
    expect(menu).toContain('srcset="/assets/menu-bar-popover.webp"');
    expect(menu).toContain('src="/assets/menu-bar-popover.webp"');
    expect(trends).toContain('srcset="/assets/dashboard-insights.webp"');
    expect(trends).toContain('src="/assets/dashboard-insights.webp"');
    expect(sessions).toContain('srcset="/assets/sessions-detail.webp"');
    expect(sessions).toContain('src="/assets/sessions-detail.webp"');
    expect(history).toContain('srcset="/assets/history-detail.webp"');
    expect(history).toContain('src="/assets/history-detail.webp"');
  });

  it("documents the compact menu-bar readout and click-to-open popover in both languages", async () => {
    const html = readPublic("index.html");
    const { translations } = await loadAppModule();

    expect(html).toContain('<span class="menu-readout-sample" aria-hidden="true"><span>7d</span><strong>4%</strong></span>');
    expect(html).toContain('data-i18n="menuReadoutTitle"');
    expect(html).toContain('data-i18n="menuPopoverTitle"');
    expect(translations.en.featureMenuBody).toMatch(/available 5-hour or 7-day quota/i);
    expect(translations.en.featureMenuBody).toContain("7d 4%");
    expect(translations.en.menuReadoutBody).toMatch(/Codex, Claude Code, both side by side, or only the gauge icon/i);
    expect(translations.en.menuPopoverBody).toMatch(/reset countdowns[\s\S]*model-specific limits[\s\S]*reset cards/i);
    expect(translations["zh-Hans"].featureMenuBody).toMatch(/5 小时或 7 天额度/);
    expect(translations["zh-Hans"].featureMenuBody).toContain("7d 4%");
    expect(translations["zh-Hans"].menuReadoutBody).toMatch(/Codex、Claude Code、两者并排，或只保留仪表图标/);
    expect(translations["zh-Hans"].menuPopoverBody).toMatch(/重置倒计时[\s\S]*模型独立额度[\s\S]*主动重置卡/);
  });

  it("links each product capture to its same-origin full-size asset", async () => {
    const html = readPublic("index.html");
    const css = readPublic("styles.css");
    const { translations } = await loadAppModule();
    const productLinks = [...html.matchAll(
      /<a\b[^>]*class="product-image-link"[^>]*href="([^\"]+)"[^>]*>([\s\S]*?)<\/a>/g,
    )];

    expect(productLinks).toHaveLength(6);
    for (const [, href = "", contents = ""] of productLinks) {
      expect(href).toMatch(/^\/assets\/(?:menu-bar-popover|dashboard-hero|dashboard-insights|sessions-detail|history-detail)\.webp$/);
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

  it("never requests release metadata on a page without release nodes", async () => {
    const { hydrateRelease } = await loadAppModule();
    const fetcher = vi.fn<typeof fetch>();
    const documentStub = {
      body: { dataset: { page: "privacy" } },
      getElementById: vi.fn(() => null),
      querySelectorAll: vi.fn(() => []),
    };
    vi.stubGlobal("document", documentStub);

    await expect(hydrateRelease(fetcher)).resolves.toBe(false);
    expect(fetcher).not.toHaveBeenCalled();
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
    [
      "stored Chinese on the privacy page",
      "zh-Hans",
      ["en-US"],
      "zh-Hans",
      "匿名版本统计隐私政策",
      "隐私政策 — Quota Monitor",
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
    const page = expectedTitle === "隐私政策 — Quota Monitor" ? "privacy" : "download-error";
    const heading = {
      dataset: {
        i18n: page === "privacy" ? "privacyPolicyTitle" : "downloadErrorTitle",
      },
      textContent: "initial server copy",
    };
    const documentElement = { lang: "en" };
    const documentStub = {
      body: { dataset: { page } },
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
