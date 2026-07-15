type ErrorPageCopy = {
  lang: "en" | "zh-Hans";
  title: string;
  heading: string;
  description: string;
  actionsLabel: string;
};

const COPY = {
  en: {
    lang: "en",
    title: "Download unavailable — QuotaMonitor",
    heading: "Download temporarily unavailable",
    description: "We could not retrieve the latest release. Please try again shortly.",
    actionsLabel: "Download actions",
  },
  zh: {
    lang: "zh-Hans",
    title: "暂时无法下载 — QuotaMonitor",
    heading: "暂时无法开始下载",
    description: "目前无法获取最新版本，请稍后重试。",
    actionsLabel: "下载操作",
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
  <title>${escapeHTML(copy.title)}</title>
  <link rel="stylesheet" href="/styles.css">
</head>
<body>
  <main>
    <p class="eyebrow">QuotaMonitor</p>
    <h1>${escapeHTML(copy.heading)}</h1>
    <p>${escapeHTML(copy.description)}</p>
    <nav aria-label="${escapeHTML(copy.actionsLabel)}">
      <a href="/download">重试 / Retry</a>
      <a href="/">返回首页 / Back home</a>
    </nav>
  </main>
</body>
</html>`;
}
