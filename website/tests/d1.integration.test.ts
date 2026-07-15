import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { aggregateClosedDays } from "../src/version-distribution";

const SCHEDULED_TIME = Date.parse("2026-07-16T23:15:00.000Z");

async function rowCount(query: string, bindings: unknown[] = []): Promise<number> {
  const row = await env.VERSION_STATS_DB
    .prepare(query)
    .bind(...bindings)
    .first<{ count: number }>();
  return row?.count ?? 0;
}

describe("real D1 closed-day aggregation", () => {
  it("rolls back aggregation and raw cleanup when its third statement fails", async () => {
    const database = env.VERSION_STATS_DB;
    await database.batch([
      database.prepare(`
        INSERT INTO daily_active_observations
          (day, token_hash, version, brand, channel)
        VALUES ('2026-07-15', 'rollback-token', '9.9.9', 'quota-monitor', 'developer-id')
      `),
      database.prepare(`
        INSERT INTO daily_version_counts
          (day, version, brand, channel, active_count)
        VALUES ('2025-06-10', '9.9.8', 'quota-monitor', 'developer-id', 1)
      `),
    ]);
    await database.prepare(`
      CREATE TRIGGER fail_retention_delete
      BEFORE DELETE ON daily_version_counts
      WHEN OLD.day = '2025-06-10'
      BEGIN
        SELECT RAISE(ABORT, 'synthetic retention failure');
      END
    `).run();

    try {
      await expect(aggregateClosedDays(database, SCHEDULED_TIME)).rejects.toThrow();
      await expect(
        rowCount(
          "SELECT COUNT(*) AS count FROM daily_active_observations WHERE token_hash = ?1",
          ["rollback-token"],
        ),
      ).resolves.toBe(1);
      await expect(
        rowCount(
          "SELECT COUNT(*) AS count FROM daily_version_counts WHERE version = ?1",
          ["9.9.9"],
        ),
      ).resolves.toBe(0);
      await expect(
        rowCount(
          "SELECT COUNT(*) AS count FROM daily_version_counts WHERE version = ?1",
          ["9.9.8"],
        ),
      ).resolves.toBe(1);
    } finally {
      await database.prepare("DROP TRIGGER IF EXISTS fail_retention_delete").run();
      await database
        .prepare("DELETE FROM daily_active_observations WHERE token_hash = ?1")
        .bind("rollback-token")
        .run();
      await database
        .prepare("DELETE FROM daily_version_counts WHERE version IN ('9.9.8', '9.9.9')")
        .run();
    }
  });

  it("is idempotent, retains today's raw row, deletes historical raw rows, and keeps day 400", async () => {
    const database = env.VERSION_STATS_DB;
    await database.batch([
      database.prepare(`
        INSERT INTO daily_active_observations
          (day, token_hash, version, brand, channel)
        VALUES ('2026-07-15', 'historical-a', '1.2.3', 'quota-monitor', 'developer-id')
      `),
      database.prepare(`
        INSERT INTO daily_active_observations
          (day, token_hash, version, brand, channel)
        VALUES ('2026-07-15', 'historical-b', '1.2.3', 'quota-monitor', 'developer-id')
      `),
      database.prepare(`
        INSERT INTO daily_active_observations
          (day, token_hash, version, brand, channel)
        VALUES ('2026-07-16', 'today', '1.2.4', 'quota-monitor', 'developer-id')
      `),
      database.prepare(`
        INSERT INTO daily_version_counts
          (day, version, brand, channel, active_count)
        VALUES ('2025-06-10', '1.0.0', 'quota-monitor', 'developer-id', 4)
      `),
      database.prepare(`
        INSERT INTO daily_version_counts
          (day, version, brand, channel, active_count)
        VALUES ('2025-06-11', '1.0.0', 'quota-monitor', 'developer-id', 5)
      `),
    ]);

    await expect(aggregateClosedDays(database, SCHEDULED_TIME)).resolves.toEqual({
      aggregateChanges: 1,
      rawDeleteChanges: 2,
      retentionDeleteChanges: 1,
    });
    await expect(aggregateClosedDays(database, SCHEDULED_TIME)).resolves.toEqual({
      aggregateChanges: 0,
      rawDeleteChanges: 0,
      retentionDeleteChanges: 0,
    });

    const rawDays = await database
      .prepare("SELECT day FROM daily_active_observations ORDER BY day")
      .all<{ day: string }>();
    expect(rawDays.results).toEqual([{ day: "2026-07-16" }]);

    const aggregateRows = await database
      .prepare(`
        SELECT day, version, active_count
        FROM daily_version_counts
        ORDER BY day, version
      `)
      .all<{ day: string; version: string; active_count: number }>();
    expect(aggregateRows.results).toEqual([
      { day: "2025-06-11", version: "1.0.0", active_count: 5 },
      { day: "2026-07-15", version: "1.2.3", active_count: 2 },
    ]);
  });
});
