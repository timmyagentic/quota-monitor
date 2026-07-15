import {
  verifyAdminAuthorization,
  type AdminAuthCrypto,
} from "./admin-auth";

const ALLOWED_RANGES = new Set([7, 30, 90, 400]);
const ALLOWED_BRANDS = new Set(["quota-monitor", "codex-monitor"]);
const ALLOWED_CHANNELS = new Set(["developer-id", "app-store"]);
const TREND_DAYS = [7, 30, 90] as const;
const RETENTION_DAYS = 400;

const AGGREGATE_CLOSED_DAYS_SQL = `
INSERT INTO daily_version_counts (day, version, brand, channel, active_count)
SELECT day, version, brand, channel, COUNT(*)
FROM daily_active_observations
WHERE day < ?1
GROUP BY day, version, brand, channel
ON CONFLICT(day, version, brand, channel) DO UPDATE SET
  active_count = excluded.active_count
`;

const DELETE_CLOSED_OBSERVATIONS_SQL = `
DELETE FROM daily_active_observations
WHERE day < ?1
`;

const DELETE_EXPIRED_AGGREGATES_SQL = `
DELETE FROM daily_version_counts
WHERE day < ?1
`;

const PROVISIONAL_COUNTS_SQL = `
SELECT day, version, brand, channel, COUNT(*) AS active_count
FROM daily_active_observations
WHERE day = ?1
  AND (?2 IS NULL OR brand = ?3)
  AND (?4 IS NULL OR channel = ?5)
GROUP BY day, version, brand, channel
ORDER BY version DESC, brand, channel
`;

const HISTORICAL_COUNTS_SQL = `
SELECT day, version, brand, channel, active_count
FROM daily_version_counts
WHERE day >= ?1 AND day < ?2
  AND (?3 IS NULL OR brand = ?4)
  AND (?5 IS NULL OR channel = ?6)
ORDER BY day ASC, version DESC, brand, channel
`;

export type VersionDistributionFilters = {
  range: 7 | 30 | 90 | 400;
  brand: string | null;
  channel: string | null;
};

export type VersionCount = {
  day: string;
  version: string;
  brand: string;
  channel: string;
  activeCount: number;
};

export type VersionDistributionView = {
  today: string;
  filters: VersionDistributionFilters;
  provisional: VersionCount[];
  historical: VersionCount[];
};

export interface VersionDistributionDependencies {
  now?: () => Date;
  authCrypto?: AdminAuthCrypto;
}

type CountRow = {
  day: unknown;
  version: unknown;
  brand: unknown;
  channel: unknown;
  active_count: unknown;
};

function utcDay(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function dayOffset(day: string, offset: number): string {
  const date = new Date(`${day}T00:00:00.000Z`);
  date.setUTCDate(date.getUTCDate() + offset);
  return utcDay(date);
}

export async function aggregateClosedDays(
  database: D1Database,
  scheduledTime: number,
): Promise<void> {
  const today = utcDay(new Date(scheduledTime));
  const retentionCutoff = dayOffset(today, -RETENTION_DAYS);
  const aggregate = database
    .prepare(AGGREGATE_CLOSED_DAYS_SQL)
    .bind(today);
  const deleteRaw = database
    .prepare(DELETE_CLOSED_OBSERVATIONS_SQL)
    .bind(today);
  const deleteExpired = database
    .prepare(DELETE_EXPIRED_AGGREGATES_SQL)
    .bind(retentionCutoff);

  await database.batch([aggregate, deleteRaw, deleteExpired]);
}

export function parseVersionDistributionFilters(
  url: URL,
): VersionDistributionFilters {
  const parsedRange = Number(url.searchParams.get("range") ?? "30");
  const range = ALLOWED_RANGES.has(parsedRange)
    ? parsedRange as VersionDistributionFilters["range"]
    : 30;
  const requestedBrand = url.searchParams.get("brand");
  const requestedChannel = url.searchParams.get("channel");
  return {
    range,
    brand: requestedBrand !== null && ALLOWED_BRANDS.has(requestedBrand)
      ? requestedBrand
      : null,
    channel: requestedChannel !== null && ALLOWED_CHANNELS.has(requestedChannel)
      ? requestedChannel
      : null,
  };
}

function normalizedRows(rows: CountRow[]): VersionCount[] {
  const normalized: VersionCount[] = [];
  for (const row of rows) {
    const count = Number(row.active_count);
    if (
      typeof row.day !== "string" ||
      typeof row.version !== "string" ||
      typeof row.brand !== "string" ||
      typeof row.channel !== "string" ||
      !Number.isSafeInteger(count) ||
      count < 0
    ) {
      continue;
    }
    normalized.push({
      day: row.day,
      version: row.version,
      brand: row.brand,
      channel: row.channel,
      activeCount: count,
    });
  }
  return normalized;
}

async function loadVersionDistribution(
  database: D1Database,
  today: string,
  filters: VersionDistributionFilters,
): Promise<VersionDistributionView> {
  const queryDays = Math.max(filters.range, 90);
  const historicalStart = dayOffset(today, -queryDays);
  const [provisionalResult, historicalResult] = await Promise.all([
    database
      .prepare(PROVISIONAL_COUNTS_SQL)
      .bind(
        today,
        filters.brand,
        filters.brand,
        filters.channel,
        filters.channel,
      )
      .all<CountRow>(),
    database
      .prepare(HISTORICAL_COUNTS_SQL)
      .bind(
        historicalStart,
        today,
        filters.brand,
        filters.brand,
        filters.channel,
        filters.channel,
      )
      .all<CountRow>(),
  ]);
  return {
    today,
    filters,
    provisional: normalizedRows(provisionalResult.results),
    historical: normalizedRows(historicalResult.results),
  };
}

function escapeHTML(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function sum(rows: VersionCount[]): number {
  return rows.reduce((total, row) => total + row.activeCount, 0);
}

function rowsByDay(rows: VersionCount[]): Map<string, VersionCount[]> {
  const grouped = new Map<string, VersionCount[]>();
  for (const row of rows) {
    const dayRows = grouped.get(row.day) ?? [];
    dayRows.push(row);
    grouped.set(row.day, dayRows);
  }
  return grouped;
}

function semverParts(version: string): [number, number, number] | null {
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(version);
  if (match === null) return null;
  const values = match.slice(1).map(Number);
  const [major, minor, patch] = values;
  if (
    major === undefined ||
    minor === undefined ||
    patch === undefined ||
    !values.every(Number.isSafeInteger)
  ) {
    return null;
  }
  return [major, minor, patch];
}

function newestVersion(rows: VersionCount[]): string | null {
  let newest: { version: string; parts: [number, number, number] } | null = null;
  for (const row of rows) {
    const parts = semverParts(row.version);
    if (parts === null) continue;
    if (
      newest === null ||
      parts[0] > newest.parts[0] ||
      (parts[0] === newest.parts[0] && parts[1] > newest.parts[1]) ||
      (parts[0] === newest.parts[0] && parts[1] === newest.parts[1] && parts[2] > newest.parts[2])
    ) {
      newest = { version: row.version, parts };
    }
  }
  return newest?.version ?? null;
}

function selectedOption(
  value: string | number | null,
  selected: string | number | null,
): string {
  return value === selected ? " selected" : "";
}

function trendMarkup(
  historical: VersionCount[],
  today: string,
  days: number,
): string {
  const start = dayOffset(today, -days);
  const totals = rowsByDay(historical.filter((row) => row.day >= start));
  const values = [...totals.values()].map(sum);
  const average = values.length === 0
    ? 0
    : values.reduce((total, value) => total + value, 0) / values.length;
  const first = values[0] ?? 0;
  const last = values.at(-1) ?? 0;
  const change = last - first;
  const direction = change > 0 ? "+" : "";
  return `
          <article class="privacy-detail">
            <h3>${days}-day trend</h3>
            <p><strong>${average.toFixed(1)}</strong> average recorded daily check-ins</p>
            <p>${direction}${change} from first to latest recorded day</p>
          </article>`;
}

function anomalyMarkup(historical: VersionCount[]): string {
  const grouped = rowsByDay(historical);
  const days = [...grouped.keys()].sort();
  const latestDay = days.at(-1);
  if (latestDay === undefined) {
    return `
        <aside class="privacy-detail" aria-labelledby="anomaly-title">
          <h2 id="anomaly-title">Anomaly signal</h2>
          <p>No complete-day sample is available yet.</p>
        </aside>`;
  }
  const latestTotal = sum(grouped.get(latestDay) ?? []);
  const previousDays = days.slice(-8, -1);
  const previousTotals = previousDays.map((day) => sum(grouped.get(day) ?? []));
  const previousAverage = previousTotals.length === 0
    ? 0
    : previousTotals.reduce((total, value) => total + value, 0) / previousTotals.length;
  const isSpike = latestTotal >= 10 && previousAverage > 0 && latestTotal > previousAverage * 2;
  const detail = isSpike
    ? `${escapeHTML(latestDay)} is more than twice the prior 7-day average. Treat this as a possible retry or abuse spike, not exact growth.`
    : "No complete-day count is more than twice the prior 7-day average at the current threshold.";
  return `
        <aside class="privacy-detail" aria-labelledby="anomaly-title">
          <h2 id="anomaly-title">Anomaly signal</h2>
          <p>${detail}</p>
        </aside>`;
}

function tableRows(view: VersionDistributionView): string {
  const selectedStart = dayOffset(view.today, -view.filters.range);
  const rows = [
    ...view.provisional,
    ...view.historical.filter((row) => row.day >= selectedStart),
  ].sort((left, right) =>
    right.day.localeCompare(left.day) ||
    right.version.localeCompare(left.version) ||
    left.brand.localeCompare(right.brand) ||
    left.channel.localeCompare(right.channel)
  );
  const totals = new Map<string, number>();
  for (const row of rows) {
    totals.set(row.day, (totals.get(row.day) ?? 0) + row.activeCount);
  }
  if (rows.length === 0) {
    return '<tr><td colspan="6">No check-ins in this range.</td></tr>';
  }
  return rows.map((row) => {
    const total = totals.get(row.day) ?? 0;
    const share = total === 0 ? 0 : row.activeCount / total * 100;
    const status = row.day === view.today ? "Provisional" : "Complete";
    return `<tr>
              <td>${escapeHTML(row.day)}</td>
              <td>${escapeHTML(row.version)}</td>
              <td>${escapeHTML(row.brand)}</td>
              <td>${escapeHTML(row.channel)}</td>
              <td>${row.activeCount}</td>
              <td>${share.toFixed(1)}% (${status})</td>
            </tr>`;
  }).join("\n");
}

export function renderVersionDistributionHTML(
  view: VersionDistributionView,
): string {
  const historicalByDay = rowsByDay(view.historical);
  const completeDays = [...historicalByDay.keys()].sort();
  const latestCompleteDay = completeDays.at(-1) ?? null;
  const latestCompleteRows = latestCompleteDay === null
    ? []
    : historicalByDay.get(latestCompleteDay) ?? [];
  const latestCompleteTotal = sum(latestCompleteRows);
  const provisionalTotal = sum(view.provisional);
  const newest = newestVersion([...view.historical, ...view.provisional]);
  const adoptionRows = provisionalTotal > 0 ? view.provisional : latestCompleteRows;
  const adoptionTotal = sum(adoptionRows);
  const newestCount = newest === null
    ? 0
    : sum(adoptionRows.filter((row) => row.version === newest));
  const newestShare = adoptionTotal === 0 ? 0 : newestCount / adoptionTotal * 100;
  const trends = TREND_DAYS.map((days) =>
    trendMarkup(view.historical, view.today, days)
  ).join("");

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex, nofollow">
  <title>Version distribution — QuotaMonitor</title>
  <link rel="stylesheet" href="/styles.css">
</head>
<body data-page="version-distribution">
  <a class="skip-link" href="#main-content">Skip to version statistics</a>
  <header class="site-header">
    <div class="container header-inner">
      <a class="brand-lockup" href="/" aria-label="Quota Monitor home">
        <span class="brand-name">Quota Monitor</span>
      </a>
    </div>
  </header>
  <main id="main-content" class="installation-section">
    <div class="container">
      <header class="section-heading">
        <h1>Anonymous version distribution</h1>
        <p>Best-effort public unauthenticated sample. Counts are estimated active installations through date-scoped deduplication; they are not people, total installs, or exact measurements.</p>
      </header>

      <section class="privacy-layout" aria-label="Latest version check-in summary">
        <article class="privacy-detail">
          <h2>Latest complete-day check-ins</h2>
          <p><strong>${latestCompleteTotal}</strong></p>
          <p>${latestCompleteDay === null ? "No complete day" : escapeHTML(latestCompleteDay)}</p>
        </article>
        <article class="privacy-detail">
          <h2>Today provisional</h2>
          <p><strong>${provisionalTotal}</strong></p>
          <p>${escapeHTML(view.today)}; may change during the UTC day</p>
        </article>
        <article class="privacy-detail">
          <h2>Newest observed version</h2>
          <p><strong>${newest === null ? "No data" : escapeHTML(newest)}</strong></p>
          <p>${newestShare.toFixed(1)}% of ${provisionalTotal > 0 ? "today's provisional" : "latest complete-day"} check-ins</p>
        </article>
      </section>

      <section class="privacy-section" aria-labelledby="filters-title">
        <div class="privacy-layout">
          <div class="privacy-heading">
            <h2 id="filters-title">Range and dimensions</h2>
            <p>All filters are applied to aggregate counts and today's provisional groups.</p>
          </div>
          <form class="privacy-detail" method="get" action="/maintainer/versions">
            <label for="range">Range</label>
            <select id="range" name="range">
              <option value="7"${selectedOption(7, view.filters.range)}>7 days</option>
              <option value="30"${selectedOption(30, view.filters.range)}>30 days</option>
              <option value="90"${selectedOption(90, view.filters.range)}>90 days</option>
              <option value="400"${selectedOption(400, view.filters.range)}>400 days</option>
            </select>
            <label for="brand">Brand</label>
            <select id="brand" name="brand">
              <option value=""${selectedOption(null, view.filters.brand)}>All brands</option>
              <option value="quota-monitor"${selectedOption("quota-monitor", view.filters.brand)}>Quota Monitor</option>
              <option value="codex-monitor"${selectedOption("codex-monitor", view.filters.brand)}>Codex Monitor</option>
            </select>
            <label for="channel">Channel</label>
            <select id="channel" name="channel">
              <option value=""${selectedOption(null, view.filters.channel)}>All channels</option>
              <option value="developer-id"${selectedOption("developer-id", view.filters.channel)}>Developer ID</option>
              <option value="app-store"${selectedOption("app-store", view.filters.channel)}>App Store</option>
            </select>
            <button class="button button-primary" type="submit">Apply filters</button>
          </form>
          ${anomalyMarkup(view.historical)}
        </div>
      </section>

      <section class="privacy-section" aria-labelledby="trends-title">
        <div class="section-heading">
          <h2 id="trends-title">Check-in trends</h2>
          <p>Recorded daily averages are descriptive only; a missing or blocked check-in is not measured.</p>
        </div>
        <div class="privacy-layout">${trends}
        </div>
      </section>

      <section class="privacy-section" aria-labelledby="distribution-title">
        <div class="section-heading">
          <h2 id="distribution-title">Count and share by version</h2>
          <p>Today is provisional. Earlier rows come only from closed-day aggregates.</p>
        </div>
        <div class="product-window">
          <table>
            <thead>
              <tr><th scope="col">Day</th><th scope="col">Version</th><th scope="col">Brand</th><th scope="col">Channel</th><th scope="col">Count</th><th scope="col">Share</th></tr>
            </thead>
            <tbody>
              ${tableRows(view)}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  </main>
</body>
</html>`;
}

const PRIVATE_HEADERS = {
  "Cache-Control": "private, no-store",
  Vary: "Authorization",
} as const;

function privateText(
  body: string,
  status: number,
  headers: HeadersInit = {},
): Response {
  return new Response(body, {
    status,
    headers: {
      ...PRIVATE_HEADERS,
      "Content-Type": "text/plain; charset=utf-8",
      ...headers,
    },
  });
}

export async function handleVersionDistribution(
  request: Request,
  database: D1Database,
  secret: string | undefined,
  rateLimiter: RateLimit,
  dependencies: VersionDistributionDependencies = {},
): Promise<Response> {
  if (request.method !== "GET") {
    return privateText("Method Not Allowed", 405, { Allow: "GET" });
  }
  if (secret === undefined || secret.trim() === "") {
    return privateText("Service unavailable", 503);
  }

  const connectingIP = request.headers.get("CF-Connecting-IP");
  const rateLimitKey = connectingIP === null || connectingIP === ""
    ? "missing-cf-connecting-ip"
    : connectingIP;
  try {
    const { success } = await rateLimiter.limit({ key: rateLimitKey });
    if (!success) {
      return privateText("Too many requests", 429, { "Retry-After": "60" });
    }
  } catch {
    return privateText("Service unavailable", 503);
  }

  let authenticated = false;
  try {
    authenticated = await verifyAdminAuthorization(
      request.headers.get("Authorization"),
      secret,
      dependencies.authCrypto,
    );
  } catch {
    return privateText("Service unavailable", 503);
  }
  if (!authenticated) {
    return privateText("Authentication required", 401, {
      "WWW-Authenticate": 'Basic realm="QuotaMonitor version distribution", charset="UTF-8"',
    });
  }

  try {
    const now = dependencies.now ?? (() => new Date());
    const today = utcDay(now());
    const filters = parseVersionDistributionFilters(new URL(request.url));
    const view = await loadVersionDistribution(database, today, filters);
    return new Response(renderVersionDistributionHTML(view), {
      headers: {
        ...PRIVATE_HEADERS,
        "Content-Type": "text/html; charset=utf-8",
      },
    });
  } catch {
    return privateText("Service unavailable", 503);
  }
}
