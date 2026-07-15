import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const websiteDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");
const scenarioPath = join(websiteDirectory, "design", "showcase-scenario.json");
const generatorPath = join(
  websiteDirectory,
  "scripts",
  "generate-showcase-fixtures.mjs",
);
const fixedNow = "2026-07-15T12:00:00.000Z";
const forbiddenSyntheticData =
  /\/Users\/|\/Volumes\/|github\.com|timmy|token=|api[_-]?key|sk-/i;

type Scenario = {
  sessionCount: number;
  codexSessionCount: number;
  claudeSessionCount: number;
  activeDayOffsets: number[];
  providers: string[];
  codexModels: string[];
  claudeModels: string[];
  projectRoot: string;
  projectSlugs: string[];
  titles: string[];
  selectedSessionIndex: number;
  selectedSessionEventCount: number;
};

type JSONRecord = Record<string, unknown>;

function asRecord(value: unknown): JSONRecord | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as JSONRecord)
    : undefined;
}

function listFiles(root: string): string[] {
  if (!existsSync(root)) {
    return [];
  }

  return readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const path = join(root, entry.name);
    return entry.isDirectory() ? listFiles(path) : [path];
  });
}

function readJSONL(path: string): JSONRecord[] {
  return readFileSync(path, "utf8")
    .split(/\r?\n/)
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as JSONRecord);
}

function timestampFromLine(line: JSONRecord): string | undefined {
  if (typeof line.timestamp === "string") {
    return line.timestamp;
  }

  const payload = asRecord(line.payload);
  return typeof payload?.timestamp === "string" ? payload.timestamp : undefined;
}

function tokenCountLines(lines: JSONRecord[]): JSONRecord[] {
  return lines.filter((line) => {
    const payload = asRecord(line.payload);
    return line.type === "event_msg" && payload?.type === "token_count";
  });
}

function generatedFileMap(home: string): Map<string, string> {
  const files = [
    ...listFiles(join(home, ".codex")),
    ...listFiles(join(home, ".claude")),
  ].sort();

  return new Map(
    files.map((path) => [relative(home, path), readFileSync(path, "utf8")]),
  );
}

describe("showcase fixture generator", () => {
  it("requires explicit opt-in before replacing showcase data", () => {
    const protectedHome = mkdtempSync(join(tmpdir(), "quota-monitor-showcase-protected-"));
    const indexPath = join(protectedHome, ".codex", "session_index.jsonl");
    const sentinel = '{"id":"keep-me"}\n';

    try {
      mkdirSync(dirname(indexPath), { recursive: true });
      writeFileSync(indexPath, sentinel, "utf8");

      expect(() =>
        execFileSync(
          process.execPath,
          [generatorPath, protectedHome, `--now=${fixedNow}`],
          { encoding: "utf8", stdio: "pipe" },
        ),
      ).toThrow(/--allow-showcase-overwrite/);
      expect(readFileSync(indexPath, "utf8")).toBe(sentinel);
      expect(existsSync(join(protectedHome, ".codex", "sessions", "showcase"))).toBe(false);
    } finally {
      rmSync(protectedHome, { recursive: true, force: true });
    }
  });

  it("generates a reproducible, dense, synthetic month of app history", () => {
    const scenario = JSON.parse(readFileSync(scenarioPath, "utf8")) as Scenario;
    const firstHome = mkdtempSync(join(tmpdir(), "quota-monitor-showcase-a-"));
    const secondHome = mkdtempSync(join(tmpdir(), "quota-monitor-showcase-b-"));

    try {
      for (const home of [firstHome, secondHome]) {
        execFileSync(
          process.execPath,
          [generatorPath, home, "--allow-showcase-overwrite", `--now=${fixedNow}`],
          { encoding: "utf8" },
        );
      }

      expect(scenario.sessionCount).toBe(28);
      expect(scenario.sessionCount).toBeGreaterThanOrEqual(24);
      expect(scenario.codexSessionCount).toBe(16);
      expect(scenario.claudeSessionCount).toBe(12);
      expect(scenario.activeDayOffsets).toHaveLength(22);
      expect(new Set(scenario.activeDayOffsets).size).toBe(22);
      expect(Math.min(...scenario.activeDayOffsets)).toBe(-29);
      expect(Math.max(...scenario.activeDayOffsets)).toBe(0);
      expect(scenario.activeDayOffsets.length).toBeGreaterThanOrEqual(18);
      expect(new Set(scenario.providers)).toEqual(new Set(["codex", "claude"]));
      expect(new Set(scenario.codexModels)).toEqual(
        new Set(["gpt-5.5", "gpt-5.5-fast", "gpt-5.5-flex"]),
      );
      expect(new Set(scenario.claudeModels)).toEqual(
        new Set([
          "claude-opus-4-8",
          "claude-sonnet-4-5-20250929",
          "claude-haiku-4-5-20251001",
        ]),
      );
      expect(
        new Set([...scenario.codexModels, ...scenario.claudeModels]).size,
      ).toBeGreaterThanOrEqual(5);
      expect(scenario.projectRoot).toBe("/showcase/projects");
      expect(scenario.projectSlugs.length).toBeGreaterThanOrEqual(6);
      expect(scenario.projectSlugs.every((slug) => /^[a-z][a-z0-9-]+$/.test(slug))).toBe(true);
      expect(scenario.titles).toHaveLength(scenario.sessionCount);
      expect(new Set(scenario.titles).size).toBe(scenario.sessionCount);
      expect(scenario.selectedSessionIndex).toBeGreaterThanOrEqual(0);
      expect(scenario.selectedSessionIndex).toBeLessThan(scenario.codexSessionCount);
      expect(scenario.selectedSessionEventCount).toBe(8);
      expect(scenario.selectedSessionEventCount).toBeGreaterThanOrEqual(6);

      const codexRoot = join(firstHome, ".codex", "sessions", "showcase");
      const claudeRoot = join(firstHome, ".claude", "projects");
      const indexPath = join(firstHome, ".codex", "session_index.jsonl");
      const codexSessionFiles = listFiles(codexRoot).filter((path) => path.endsWith(".jsonl"));
      const claudeSessionFiles = listFiles(claudeRoot).filter((path) => path.endsWith(".jsonl"));
      const sessionFiles = [...codexSessionFiles, ...claudeSessionFiles];
      const indexLines = readJSONL(indexPath);
      const parsedByFile = new Map(
        sessionFiles.map((path) => [path, readJSONL(path)]),
      );
      const generated = {
        codexSessions: codexSessionFiles.length,
        claudeSessions: claudeSessionFiles.length,
        latestTimestamp: Number.NEGATIVE_INFINITY,
        codexQuotaBuckets: new Set<number>(),
      };

      expect(generated.codexSessions).toBe(scenario.codexSessionCount);
      expect(generated.claudeSessions).toBe(scenario.claudeSessionCount);
      expect(generated.codexSessions + generated.claudeSessions).toBe(
        scenario.sessionCount,
      );
      expect(indexLines).toHaveLength(scenario.codexSessionCount);

      const actualDayOffsets = new Set<number>();
      const nowDay = Math.floor(Date.parse(fixedNow) / 86_400_000);
      for (const lines of parsedByFile.values()) {
        const firstTimestamp = lines.map(timestampFromLine).find(Boolean);
        expect(firstTimestamp).toBeTypeOf("string");
        actualDayOffsets.add(
          Math.floor(Date.parse(firstTimestamp!) / 86_400_000) - nowDay,
        );

        for (const line of lines) {
          const timestamp = timestampFromLine(line);
          if (timestamp) {
            generated.latestTimestamp = Math.max(
              generated.latestTimestamp,
              Date.parse(timestamp),
            );
          }
        }
      }
      for (const line of indexLines) {
        if (typeof line.updated_at === "string") {
          generated.latestTimestamp = Math.max(
            generated.latestTimestamp,
            Date.parse(line.updated_at),
          );
        }
      }

      expect(actualDayOffsets).toEqual(new Set(scenario.activeDayOffsets));
      expect(generated.latestTimestamp).toBeGreaterThanOrEqual(
        Date.parse("2026-07-15T07:00:00.000Z"),
      );

      for (const path of codexSessionFiles) {
        const lines = parsedByFile.get(path)!;
        const usageLines = tokenCountLines(lines);
        expect(usageLines.length, relative(firstHome, path)).toBeGreaterThanOrEqual(2);
        expect(usageLines.length, relative(firstHome, path)).toBeLessThanOrEqual(8);

        let previousTotal = 0;
        for (const line of usageLines) {
          const payload = asRecord(line.payload)!;
          const info = asRecord(payload.info)!;
          const totals = asRecord(info.total_token_usage)!;
          expect(totals.total_tokens).toBeTypeOf("number");
          expect(totals.total_tokens as number).toBeGreaterThan(previousTotal);
          previousTotal = totals.total_tokens as number;

          const rateLimits = asRecord(payload.rate_limits);
          for (const bucket of ["primary", "secondary"]) {
            const windowMinutes = asRecord(rateLimits?.[bucket])?.window_minutes;
            if (typeof windowMinutes === "number") {
              generated.codexQuotaBuckets.add(windowMinutes);
            }
          }
        }
      }
      expect(generated.codexQuotaBuckets).toEqual(new Set([300, 10080]));

      for (const path of claudeSessionFiles) {
        const lines = parsedByFile.get(path)!;
        const usageLines = lines.filter((line) => line.type === "assistant");
        expect(usageLines.length, relative(firstHome, path)).toBeGreaterThanOrEqual(2);
        expect(usageLines.length, relative(firstHome, path)).toBeLessThanOrEqual(8);
        for (const line of usageLines) {
          const usage = asRecord(asRecord(line.message)?.usage);
          expect(usage?.input_tokens).toBeTypeOf("number");
          expect(usage?.output_tokens).toBeTypeOf("number");
          expect(usage).not.toHaveProperty("total_token_usage");
        }
      }

      const selectedTitle = scenario.titles[scenario.selectedSessionIndex]!;
      const selectedMetadata = indexLines.find(
        (line) => line.thread_name === selectedTitle,
      );
      expect(selectedMetadata).toBeDefined();
      const selectedFile = codexSessionFiles.find((path) =>
        parsedByFile.get(path)!.some((line) => {
          const payload = asRecord(line.payload);
          return line.type === "session_meta" && payload?.id === selectedMetadata?.id;
        }),
      );
      expect(selectedFile).toBeDefined();
      expect(tokenCountLines(parsedByFile.get(selectedFile!)!)).toHaveLength(
        scenario.selectedSessionEventCount,
      );

      const allGeneratedFiles = [...sessionFiles, indexPath];
      for (const path of allGeneratedFiles) {
        expect(() => readJSONL(path), relative(firstHome, path)).not.toThrow();
        expect(relative(firstHome, path)).not.toMatch(forbiddenSyntheticData);
        expect(readFileSync(path, "utf8")).not.toMatch(forbiddenSyntheticData);
      }
      expect(JSON.stringify(scenario)).not.toMatch(forbiddenSyntheticData);

      expect(generatedFileMap(secondHome)).toEqual(generatedFileMap(firstHome));
    } finally {
      rmSync(firstHome, { recursive: true, force: true });
      rmSync(secondHome, { recursive: true, force: true });
    }
  });
});
