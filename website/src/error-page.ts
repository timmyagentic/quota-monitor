type ErrorPageCopy = {
  lang: "en" | "zh-Hans";
  title: string;
  heading: string;
  description: string;
  actionsLabel: string;
  retry: string;
  backHome: string;
};

const COPY = {
  en: {
    lang: "en",
    title: "Download unavailable — QuotaMonitor",
    heading: "Download temporarily unavailable",
    description: "We could not retrieve the latest release. Please try again shortly.",
    actionsLabel: "Download actions",
    retry: "Try again",
    backHome: "Back home",
  },
  zh: {
    lang: "zh-Hans",
    title: "暂时无法下载 — QuotaMonitor",
    heading: "暂时无法开始下载",
    description: "目前无法获取最新版本，请稍后重试。",
    actionsLabel: "下载操作",
    retry: "重试",
    backHome: "返回首页",
  },
} as const satisfies Record<"en" | "zh", ErrorPageCopy>;

function escapeHTML(value: string): string {
  const entities: Record<string, string> = {
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  };
  return value.replace(/[&<>"']/g, (character) => entities[character] ?? character);
}

function prefersChinese(acceptLanguage: string | null): boolean {
  if (!acceptLanguage) {
    return false;
  }

  const supported = acceptLanguage
    .split(",")
    .map((entry, index) => {
      const [rawLanguage = "", ...parameters] = entry.trim().split(";");
      const language = rawLanguage.toLowerCase();
      const qualityParameter = parameters
        .map((parameter) => parameter.trim().match(/^q=(0(?:\.\d+)?|1(?:\.0+)?)$/i)?.[1])
        .find((quality) => quality !== undefined);
      const quality = qualityParameter === undefined ? 1 : Number(qualityParameter);
      const locale = language === "zh" || language.startsWith("zh-")
        ? "zh"
        : language === "en" || language.startsWith("en-") || language === "*"
          ? "en"
          : undefined;
      return { index, locale, quality };
    })
    .filter(
      (preference): preference is { index: number; locale: "en" | "zh"; quality: number } =>
        preference.locale !== undefined && preference.quality > 0,
    )
    .sort((left, right) => right.quality - left.quality || left.index - right.index);

  return supported[0]?.locale === "zh";
}

export function renderDownloadError(acceptLanguage: string | null): string {
  const copy = prefersChinese(acceptLanguage) ? COPY.zh : COPY.en;

  return `<!doctype html>
<html lang="${escapeHTML(copy.lang)}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex">
  <title data-i18n="downloadErrorMetaTitle">${escapeHTML(copy.title)}</title>
  <link rel="stylesheet" href="/styles.css">
</head>
<body data-page="download-error">
  <main id="main-content" class="not-found" aria-labelledby="download-error-title">
    <div class="container not-found-content">
      <p class="not-found-eyebrow">Quota Monitor</p>
      <h1 id="download-error-title" data-i18n="downloadErrorTitle">${escapeHTML(copy.heading)}</h1>
      <p data-i18n="downloadErrorDescription">${escapeHTML(copy.description)}</p>
      <nav class="not-found-actions" aria-label="${escapeHTML(copy.actionsLabel)}" data-i18n-aria-label="downloadErrorActionsLabel">
        <a href="/download" class="button button-primary" data-i18n="downloadErrorRetry">${escapeHTML(copy.retry)}</a>
        <a href="/" class="button button-secondary" data-i18n="downloadErrorBackHome">${escapeHTML(copy.backHome)}</a>
      </nav>
    </div>
  </main>
  <script type="module" src="/app.js"></script>
</body>
</html>`;
}
