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
  dashboardTrendsAlt: "Quota Monitor dashboard showing Codex and Claude Code token trends and projections with synthetic data",
  featureSessionsTitle: "Session drill-down",
  featureSessionsLead: "Open Sessions to inspect every run.",
  featureSessionsBody: "Search and sort sessions, then review models, token details, duration, and API-equivalent cost estimates.",
  sessionsDetailAlt: "Quota Monitor Sessions view showing searchable model, token, duration, and API-equivalent cost estimate details with synthetic data",
  featureHistoryTitle: "Local history",
  featureHistoryLead: "Keep a useful history without sending it to a separate website.",
  featureHistoryBody: "Quota Monitor indexes local Codex and Claude Code history into its local SQLite database, where you can review and manage it on your Mac.",
  privacyTitle: "Privacy first",
  privacyIntro: "Your history stays local; live quota refreshes still contact the corresponding provider services.",
  privacyLocalTitle: "Local by default",
  privacyLocalBody: "Session history is indexed in Quota Monitor's local SQLite database on your Mac. You decide what to keep or export.",
  privacyRefreshTitle: "Live quota refresh",
  privacyRefreshBody: "Current quota and usage are fetched from the corresponding Codex and Claude Code provider services.",
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
  dashboardTrendsAlt: "使用合成数据展示 Codex 与 Claude Code Token 趋势和预测的 Quota Monitor 仪表盘",
  featureSessionsTitle: "深入会话明细",
  featureSessionsLead: "打开“会话”，检查每一次运行。",
  featureSessionsBody: "搜索和排序会话，查看模型、Token 明细、时长与 API 等价费用估算。",
  sessionsDetailAlt: "使用合成数据展示可搜索的模型、Token、时长与 API 等价费用估算明细的 Quota Monitor 会话视图",
  featureHistoryTitle: "本地历史",
  featureHistoryLead: "保留实用历史记录，无需发送到另一个网站。",
  featureHistoryBody: "Quota Monitor 会把本地 Codex 与 Claude Code 历史索引到应用的本地 SQLite 数据库中，供你在 Mac 上查看和管理。",
  privacyTitle: "隐私优先",
  privacyIntro: "历史记录留在本地；实时额度刷新仍会联系对应的服务提供方。",
  privacyLocalTitle: "默认保存在本地",
  privacyLocalBody: "会话历史会索引到 Mac 上 Quota Monitor 的本地 SQLite 数据库。保留或导出哪些内容，由你决定。",
  privacyRefreshTitle: "实时额度刷新",
  privacyRefreshBody: "当前额度与用量会从 Codex 和 Claude Code 对应的服务提供方获取。",
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
  return values.some(
    (value) => typeof value === "string" && value.toLowerCase().startsWith("zh"),
  )
    ? "zh-Hans"
    : "en";
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

    const structuredNode = document.getElementById("software-application");
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

    document.querySelectorAll("[data-version]").forEach((node) => {
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
