const STORAGE_KEY = "quota-monitor-site-language";
const supported = new Set(["en", "zh-Hans"]);

const english = Object.freeze({
  metaTitle: "Quota Monitor — Know your quota. Keep your flow.",
  metaDescription: "Quota Monitor brings Codex and Claude Code quotas, token trends, API-equivalent cost estimates, and session details into one lightweight macOS menu-bar app.",
  ogTitle: "Quota Monitor — Know your quota. Keep your flow.",
  ogDescription: "See Codex and Claude Code quotas, token trends, API-equivalent cost estimates, and session details in one native macOS app.",
  ogImageAlt: "Quota Monitor product page with a native macOS dashboard window",
  brand: "Quota Monitor",
  appIconAlt: "Quota Monitor app icon",
  skipLink: "Skip to main content",
  primaryNavigationLabel: "Primary navigation",
  homeNav: "Home",
  homeLinkLabel: "Quota Monitor home",
  featuresNav: "Features",
  privacyNav: "Privacy",
  languageLabel: "Choose display language",
  chooseChinese: "Switch to Simplified Chinese",
  chooseEnglish: "Switch to English",
  heroTitleFirstLine: "Know your quota.",
  heroTitleSecondLine: " Keep your flow.",
  heroDescription: "Quota Monitor brings Codex and Claude Code quotas, token trends, API-equivalent cost estimates, and session details into one lightweight macOS menu-bar app.",
  downloadAction: "Download QuotaMonitor",
  exploreFeatures: "Explore features",
  downloadRequirementsLabel: "Download requirements and security",
  systemRequirement: "macOS 14+",
  signedStatus: "Developer ID signed",
  notarizedStatus: "Apple notarized",
  dashboardHeroAlt: "Quota Monitor dashboard showing Codex and Claude Code quota cards, token trends, and API-equivalent cost estimates with synthetic data",
  featureQuotaTitle: "Live quota clarity",
  featureQuotaLead: "See exact quota usage for Codex and Claude Code at a glance.",
  featureQuotaBody: "Know how much you have used and how much is left, when each window resets, and whether each provider is available.",
  dashboardQuotaAlt: "Quota Monitor dashboard showing active quota windows, used percentages, remaining capacity, and provider status with synthetic data",
  featureTrendsTitle: "Trends and forecast",
  featureTrendsLead: "Visualize token consumption over time for each tool.",
  featureTrendsBody: "Move from 7-day detail through yearly history, then use burn-rate projection, activity, and composition to understand where usage is heading.",
  dashboardTrendsAlt: "Quota Monitor dashboard showing activity metrics, a 12-month heatmap, and provider and model composition with synthetic data",
  featureSessionsTitle: "Session drill-down",
  featureSessionsLead: "Open Sessions to inspect every run.",
  featureSessionsBody: "Search and sort sessions, then review models, token details, event timing, and API-equivalent cost estimates.",
  sessionsDetailAlt: "Quota Monitor Sessions view showing searchable model, token, event timing, and API-equivalent cost estimate details with synthetic data",
  featureHistoryTitle: "Local history",
  featureHistoryLead: "Keep a useful history without sending it to a separate website.",
  featureHistoryBody: "Quota Monitor indexes local Codex and Claude Code history into its local SQLite database, where you can review and manage it on your Mac.",
  historyDetailAlt: "Quota Monitor History view showing 23 active days, daily model breakdowns, and synthetic session details",
  viewImageFullSize: "View image full size",
  privacyTitle: "Privacy first",
  privacyIntro: "Your history stays local. Anonymous daily active installation statistics are sent only after you explicitly opt in.",
  privacyStatisticsTitle: "Installation counts, never users",
  privacyStatisticsBody: "The optional check-in contains only six documented fields, rotates its random token every UTC day, and cannot identify an installation across days.",
  privacyProviderSummary: "Live quota refresh contacts the corresponding Codex or Claude Code provider services; that traffic is separate from anonymous statistics.",
  privacyPolicyLink: "Read the complete privacy policy",
  privacyMetaTitle: "Privacy policy — Quota Monitor",
  privacyMetaDescription: "How Quota Monitor's optional anonymous daily active installation check-in works, what it excludes, and how long aggregate counts are retained.",
  privacyPolicyEyebrow: "Privacy policy",
  privacyPolicyTitle: "Anonymous version statistics privacy policy",
  privacyPolicyIntro: "Quota Monitor sends an anonymous daily active installation check-in only after you explicitly opt in. These counts estimate active installations, never users.",
  privacyPolicyScopeBody: "This policy applies to Quota Monitor and CodexMonitor-branded builds that link to this page. The check-in's brand field distinguishes quota-monitor from codex-monitor.",
  privacyPolicyDataTitle: "What the optional check-in sends",
  privacyPolicyWireBody: "Each check-in contains exactly six fields: schema (the number 1), UTC day (YYYY-MM-DD), a fresh random daily token, app version, brand, and distribution channel. It contains no other app data.",
  privacyPolicyTokenBody: "The random token rotates every UTC day. A failed request reuses it only within the same UTC day. If the app version changes that day, a later check-in can reclassify the same record. There is no stable installation ID, device ID, or cross-day link.",
  privacyPolicyDedupeBody: "The service keeps at most one deduplicated active-installation record per token per UTC day. Retries do not increase the count.",
  privacyPolicyExcludedTitle: "What reporting never sends",
  privacyPolicyExcludedBody: "Reporting never sends: name or account details; email; a persistent identifier; system or hardware information; session titles; prompts, messages, or history; quota or usage values; token counts or cost estimates; file paths; credentials; or API or authentication tokens.",
  privacyPolicyProcessingTitle: "Processing and Cloudflare's network boundary",
  privacyPolicyProcessingBody: "The Worker sees the original token only in memory, then computes a date-domain-separated SHA-256 hash before D1. The original token is never written to D1 or the app's custom logs.",
  privacyPolicyCloudflareBody: "Cloudflare handles HTTPS, security controls, and rate limiting and therefore processes the source IP at its network boundary. The Worker passes the source IP only to a best-effort Workers RateLimit binding; it does not write the IP to D1 or custom logs. Cloudflare infrastructure, CDN, WAF, and network-error logging may retain operational data under Cloudflare's terms; we do not claim that those layers are log-free.",
  privacyPolicyRetentionTitle: "Retention and access",
  privacyPolicyRetentionBody: "Live raw rows are deleted after the next successful closed-day aggregation. Operational failures can delay that cleanup, so this is not an exact one-hour promise. After deletion, D1 Time Travel may still restore database state for 7 days on the Free plan or 30 days on a Paid plan. Aggregates contain only day, version, brand, channel, and counts, are retained for 400 days, and appear only in a private maintainer dashboard.",
  privacyPolicyOptOutTitle: "Your choice and opt-out",
  privacyPolicyOptOutBody: "Turning reporting off immediately stops later requests, deletes the local token and success state for that day, and suppresses same-UTC-day re-enablement until the next UTC day. Already received anonymous rows cannot be individually found or deleted because no stable ID or deletion handle exists; they follow the normal live-row and Time Travel retention above.",
  privacyPolicyProviderTitle: "Other app networking",
  privacyPolicyProviderBody: "Session and history data stays in the app's local SQLite database. If you use live Codex or Claude Code quota refresh, Quota Monitor contacts the corresponding provider services. This traffic is separate from anonymous version statistics and is governed by the provider's privacy terms.",
  privacyPolicyWebsiteTitle: "This website",
  privacyPolicyWebsiteBody: "The website stores only your language choice in localStorage. It uses no cookies, client analytics, or third-party UI runtime. Cloudflare processes network data at the boundary described above.",
  installationTitle: "Get started in minutes",
  installationIntro: "Install Quota Monitor like any other native Mac app.",
  stepOneTitle: "Download the latest DMG",
  stepOneBody: "Get the current Developer ID signed and Apple notarized disk image.",
  stepTwoTitle: "Drag Quota Monitor into Applications",
  stepTwoBody: "Move Quota Monitor to your Applications folder like any other Mac app.",
  stepThreeTitle: "Open and choose tools to track",
  stepThreeBody: "Select Codex, Claude Code, or both, then start monitoring quota right away.",
  finalTitle: "Know your quota. Keep your flow.",
  finalDescription: "Stay in control of your usage so you can keep building.",
  footerNavigationLabel: "Footer information",
  license: "MIT License",
  copyright: "© 2026 Quota Monitor",
  notFoundMetaTitle: "Page not found — Quota Monitor",
  notFoundMetaDescription: "The requested Quota Monitor page could not be found.",
  notFoundTitle: "Page not found",
  notFoundDescription: "The page you requested does not exist or may have moved.",
  backHome: "Back to Quota Monitor",
  downloadErrorMetaTitle: "Download unavailable — QuotaMonitor",
  downloadErrorTitle: "Download temporarily unavailable",
  downloadErrorDescription: "We could not retrieve the latest release. Please try again shortly.",
  downloadErrorActionsLabel: "Download actions",
  downloadErrorRetry: "Try again",
  downloadErrorBackHome: "Back home",
});

const simplifiedChinese = Object.freeze({
  metaTitle: "Quota Monitor — 看清额度，保持专注。",
  metaDescription: "Quota Monitor 把 Codex 与 Claude Code 的实时额度、Token 趋势、API 等价费用估算和会话明细，集中到一个轻量的 macOS 菜单栏应用。",
  ogTitle: "Quota Monitor — 看清额度，保持专注。",
  ogDescription: "在一个原生 macOS 应用中查看 Codex 与 Claude Code 的实时额度、Token 趋势、API 等价费用估算和会话明细。",
  ogImageAlt: "展示原生 macOS 仪表盘窗口的 Quota Monitor 产品页面",
  brand: "Quota Monitor",
  appIconAlt: "Quota Monitor 应用图标",
  skipLink: "跳到主要内容",
  primaryNavigationLabel: "主导航",
  homeNav: "首页",
  homeLinkLabel: "Quota Monitor 首页",
  featuresNav: "功能",
  privacyNav: "隐私",
  languageLabel: "选择显示语言",
  chooseChinese: "切换为简体中文",
  chooseEnglish: "切换为英文",
  heroTitleFirstLine: "看清额度，",
  heroTitleSecondLine: "保持专注。",
  heroDescription: "Quota Monitor 把 Codex 与 Claude Code 的实时额度、Token 趋势、API 等价费用估算和会话明细，集中到一个轻量的 macOS 菜单栏应用。",
  downloadAction: "下载 QuotaMonitor",
  exploreFeatures: "了解功能",
  downloadRequirementsLabel: "下载要求与安全信息",
  systemRequirement: "macOS 14+",
  signedStatus: "Developer ID 已签名",
  notarizedStatus: "Apple 已公证",
  dashboardHeroAlt: "使用合成数据展示 Codex 与 Claude Code 额度卡片、Token 趋势和 API 等价费用估算的 Quota Monitor 仪表盘",
  featureQuotaTitle: "实时额度，一目了然",
  featureQuotaLead: "快速查看 Codex 与 Claude Code 的准确额度使用情况。",
  featureQuotaBody: "了解已用和剩余额度、每个窗口的重置时间，以及对应服务是否可用。",
  dashboardQuotaAlt: "使用合成数据展示活跃额度窗口、已用比例、剩余容量和服务状态的 Quota Monitor 仪表盘",
  featureTrendsTitle: "趋势与预测",
  featureTrendsLead: "分别查看每个工具随时间变化的 Token 消耗。",
  featureTrendsBody: "从 7 天明细一路查看到年度历史，并结合消耗速度预测、活跃度与构成，判断用量走向。",
  dashboardTrendsAlt: "使用合成数据展示活跃度指标、12 个月热力图以及 provider 与模型构成的 Quota Monitor 仪表盘",
  featureSessionsTitle: "深入会话明细",
  featureSessionsLead: "打开“会话”，检查每一次运行。",
  featureSessionsBody: "搜索和排序会话，查看模型、Token 明细、事件时间与 API 等价费用估算。",
  sessionsDetailAlt: "使用合成数据展示可搜索的模型、Token、事件时间与 API 等价费用估算明细的 Quota Monitor 会话视图",
  featureHistoryTitle: "本地历史",
  featureHistoryLead: "保留实用历史记录，无需发送到另一个网站。",
  featureHistoryBody: "Quota Monitor 会把本地 Codex 与 Claude Code 历史索引到应用的本地 SQLite 数据库中，供你在 Mac 上查看和管理。",
  historyDetailAlt: "使用合成数据展示 23 个活跃日、每日模型构成与会话明细的 Quota Monitor 历史视图",
  viewImageFullSize: "查看完整尺寸图片",
  privacyTitle: "隐私优先",
  privacyIntro: "历史记录保留在本地。只有在你明确选择加入后，应用才会发送匿名每日活跃安装统计。",
  privacyStatisticsTitle: "统计安装量，不是用户数",
  privacyStatisticsBody: "可选检查只包含公开说明的六个字段；随机令牌每天按 UTC 轮换，无法跨日识别同一安装。",
  privacyProviderSummary: "实时额度刷新会联系对应的 Codex 或 Claude Code 服务提供方；这类流量与匿名统计相互独立。",
  privacyPolicyLink: "阅读完整隐私政策",
  privacyMetaTitle: "隐私政策 — Quota Monitor",
  privacyMetaDescription: "了解 Quota Monitor 可选的匿名每日活跃安装检查如何工作、明确排除哪些数据，以及聚合计数的保留期限。",
  privacyPolicyEyebrow: "隐私政策",
  privacyPolicyTitle: "匿名版本统计隐私政策",
  privacyPolicyIntro: "只有在你明确选择加入后，Quota Monitor 才会发送匿名每日活跃安装检查。统计结果估算的是活跃安装量，绝不是用户数。",
  privacyPolicyScopeBody: "本政策适用于 Quota Monitor 和 CodexMonitor 品牌构建（前提是构建指向本页）。检查中的 brand 字段会用 quota-monitor 和 codex-monitor 区分两者。",
  privacyPolicyDataTitle: "可选检查会发送什么",
  privacyPolicyWireBody: "每次检查发送恰好六个字段：schema（数字 1）、UTC 日期（YYYY-MM-DD）、当天新生成的随机令牌、应用版本、品牌和分发渠道，不包含其他应用数据。",
  privacyPolicyTokenBody: "随机令牌在每个 UTC 日轮换。失败请求只会在同一个 UTC 日内复用它。如果当天应用版本发生变化，后续检查可以对同一条记录重新分类。没有稳定安装 ID、设备 ID 或跨日关联。",
  privacyPolicyDedupeBody: "服务对每个令牌在每个 UTC 日最多保留一条去重后的活跃安装记录。重试不会增加计数。",
  privacyPolicyExcludedTitle: "报告绝不会发送什么",
  privacyPolicyExcludedBody: "报告绝不会发送：姓名或账户信息、电子邮件、持久标识符、系统或硬件信息、会话标题、提示词、消息或历史、额度或用量值、Token 数量或费用估算、文件路径、凭据，以及 API 或身份验证令牌。",
  privacyPolicyProcessingTitle: "处理方式与 Cloudflare 网络边界",
  privacyPolicyProcessingBody: "Worker 仅在内存中接触原始令牌，并在写入 D1 前计算日期域隔离的 SHA-256 哈希。原始令牌绝不会写入 D1 或应用自定义日志。",
  privacyPolicyCloudflareBody: "Cloudflare 负责 HTTPS、安全控制和限流，因此会在其网络边界处理源 IP。Worker 只把源 IP 交给尽力而为的 Workers RateLimit binding；不会将 IP 写入 D1 或自定义日志。Cloudflare 的基础设施、CDN、WAF 和网络错误日志可能依据 Cloudflare 条款保留运维数据；我们不会声称这些层完全无日志。",
  privacyPolicyRetentionTitle: "保留与访问",
  privacyPolicyRetentionBody: "实时原始行会在下一次成功完成的已结束日期聚合后删除。运维失败可能推迟清理，因此这并非精确的一小时承诺。删除后，D1 Time Travel 仍可能恢复数据库状态：Free 计划 7 天或 Paid 计划 30 天。聚合数据只包含日期、版本、品牌、渠道和计数，保留 400 天，并且仅显示在私有维护者仪表盘中。",
  privacyPolicyOptOutTitle: "你的选择与退出",
  privacyPolicyOptOutBody: "关闭报告会立即停止后续请求，删除本机当天的令牌和成功状态，并抑制同一 UTC 日内重新启用，直到下一个 UTC 日。已经接收的匿名行无法单独定位或删除，因为不存在稳定 ID 或删除句柄；它们遵循上述实时行和 Time Travel 保留规则。",
  privacyPolicyProviderTitle: "应用的其他网络访问",
  privacyPolicyProviderBody: "会话和历史数据保留在应用的本地 SQLite 数据库中。如果你使用 Codex 或 Claude Code 实时额度刷新，Quota Monitor 会联系对应的服务提供方。这类流量独立于匿名版本统计，并受相应服务提供方的隐私条款约束。",
  privacyPolicyWebsiteTitle: "本网站",
  privacyPolicyWebsiteBody: "网站只在 localStorage 中保存你的语言选择。不使用 Cookie、客户端分析或第三方 UI runtime。Cloudflare 按上述网络边界处理网络数据。",
  installationTitle: "几分钟即可开始",
  installationIntro: "像安装其他原生 Mac 应用一样安装 Quota Monitor。",
  stepOneTitle: "下载最新 DMG",
  stepOneBody: "获取当前经过 Developer ID 签名和 Apple 公证的磁盘映像。",
  stepTwoTitle: "把 Quota Monitor 拖入“应用程序”",
  stepTwoBody: "像其他 Mac 应用一样，把 Quota Monitor 移到“应用程序”文件夹。",
  stepThreeTitle: "打开应用并选择要跟踪的工具",
  stepThreeBody: "选择 Codex、Claude Code 或两者，然后立即开始监控额度。",
  finalTitle: "看清额度，保持专注。",
  finalDescription: "掌握用量，专注继续构建。",
  footerNavigationLabel: "页脚信息",
  license: "MIT 许可证",
  copyright: "© 2026 Quota Monitor",
  notFoundMetaTitle: "找不到页面 — Quota Monitor",
  notFoundMetaDescription: "找不到请求的 Quota Monitor 页面。",
  notFoundTitle: "找不到页面",
  notFoundDescription: "你请求的页面不存在，或已被移动。",
  backHome: "返回 Quota Monitor 首页",
  downloadErrorMetaTitle: "暂时无法下载 — QuotaMonitor",
  downloadErrorTitle: "暂时无法开始下载",
  downloadErrorDescription: "目前无法获取最新版本，请稍后重试。",
  downloadErrorActionsLabel: "下载操作",
  downloadErrorRetry: "重试",
  downloadErrorBackHome: "返回首页",
});

export const translations = Object.freeze({
  "en": english,
  "zh-Hans": simplifiedChinese,
});

function storedLanguage() {
  try {
    return typeof globalThis.localStorage === "undefined"
      ? null
      : globalThis.localStorage.getItem(STORAGE_KEY);
  } catch {
    return null;
  }
}

function browserLanguages() {
  try {
    return Array.isArray(globalThis.navigator?.languages)
      ? globalThis.navigator.languages
      : [];
  } catch {
    return [];
  }
}

export function resolveLanguage(saved = storedLanguage(), languages = browserLanguages()) {
  if (typeof saved === "string" && supported.has(saved)) {
    return saved;
  }

  const values = Array.isArray(languages) ? languages : [];
  for (const value of values) {
    if (typeof value !== "string") continue;
    const language = value.toLowerCase();
    if (language.startsWith("en")) return "en";
    if (language.startsWith("zh")) return "zh-Hans";
  }
  return "en";
}

function localizeAttributes(locale) {
  const bindings = [
    ["[data-i18n-alt]", "i18nAlt", "alt"],
    ["[data-i18n-aria-label]", "i18nAriaLabel", "aria-label"],
    ["[data-i18n-content]", "i18nContent", "content"],
  ];

  for (const [selector, dataKey, attribute] of bindings) {
    document.querySelectorAll(selector).forEach((node) => {
      const translationKey = node.dataset[dataKey];
      const value = translations[locale][translationKey];
      if (typeof value === "string") {
        node.setAttribute(attribute, value);
      }
    });
  }
}

export function applyLanguage(language) {
  const locale = supported.has(language) ? language : "en";
  if (typeof document === "undefined") {
    return locale;
  }

  document.documentElement.lang = locale;
  document.querySelectorAll("[data-i18n]").forEach((node) => {
    const translationKey = node.dataset.i18n;
    const value = translations[locale][translationKey];
    if (typeof value === "string") {
      node.textContent = value;
    }
  });
  localizeAttributes(locale);

  const page = document.body?.dataset.page;
  const titleKey = page === "not-found"
    ? "notFoundMetaTitle"
    : page === "download-error"
      ? "downloadErrorMetaTitle"
      : page === "privacy"
        ? "privacyMetaTitle"
        : "metaTitle";
  document.title = translations[locale][titleKey];
  document.querySelectorAll("[data-language]").forEach((button) => {
    button.setAttribute(
      "aria-pressed",
      String(button.dataset.language === locale),
    );
  });

  return locale;
}

export function persistLanguage(language, storage = undefined) {
  if (!supported.has(language)) {
    return false;
  }

  try {
    const target = storage ?? globalThis.localStorage;
    target.setItem(STORAGE_KEY, language);
    return true;
  } catch {
    return false;
  }
}

function validateRelease(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  const allowedKeys = new Set([
    "version",
    "filename",
    "size",
    "minimumSystemVersion",
  ]);
  const keys = Object.keys(value);
  if (keys.length !== allowedKeys.size || keys.some((key) => !allowedKeys.has(key))) {
    return null;
  }

  const { version, filename, size, minimumSystemVersion } = value;
  if (
    typeof version !== "string" ||
    !/^\d+\.\d+\.\d+$/.test(version) ||
    typeof filename !== "string" ||
    filename !== `QuotaMonitor-${version}.dmg` ||
    !Number.isSafeInteger(size) ||
    size < 1_000_000 ||
    typeof minimumSystemVersion !== "string" ||
    !/^\d+(?:\.\d+){0,2}$/.test(minimumSystemVersion)
  ) {
    return null;
  }

  return { version, filename, size, minimumSystemVersion };
}

function availableFetch() {
  try {
    return typeof globalThis.fetch === "function"
      ? globalThis.fetch.bind(globalThis)
      : null;
  } catch {
    return null;
  }
}

export async function hydrateRelease(fetcher = availableFetch()) {
  if (typeof document === "undefined" || typeof fetcher !== "function") {
    return false;
  }

  const structuredNode = document.getElementById("software-application");
  const versionNodes = document.querySelectorAll("[data-version]");
  if (structuredNode === null && versionNodes.length === 0) {
    return false;
  }

  try {
    const response = await fetcher("/api/release", {
      headers: { Accept: "application/json" },
    });
    if (!response?.ok) {
      return false;
    }

    const release = validateRelease(await response.json());
    if (!release) {
      return false;
    }

    let structuredData = null;
    if (structuredNode) {
      structuredData = JSON.parse(structuredNode.textContent ?? "");
      if (
        !structuredData ||
        typeof structuredData !== "object" ||
        structuredData["@type"] !== "SoftwareApplication"
      ) {
        return false;
      }
    }

    versionNodes.forEach((node) => {
      node.textContent = release.version;
    });
    if (structuredNode && structuredData) {
      structuredData.softwareVersion = release.version;
      structuredNode.textContent = JSON.stringify(structuredData, null, 2);
    }
    return true;
  } catch {
    return false;
  }
}

function initialize() {
  const language = resolveLanguage();
  applyLanguage(language);
  document.querySelectorAll("[data-language]").forEach((button) => {
    button.addEventListener("click", () => {
      const requested = button.dataset.language;
      if (!supported.has(requested)) {
        return;
      }
      persistLanguage(requested);
      applyLanguage(requested);
    });
  });
  void hydrateRelease();
}

if (typeof document !== "undefined") {
  document.documentElement.classList.add("js");
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initialize, { once: true });
  } else {
    initialize();
  }
}
