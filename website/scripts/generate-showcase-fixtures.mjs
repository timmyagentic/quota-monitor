#!/usr/bin/env node

import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const scenarioPath = join(scriptDirectory, "..", "design", "showcase-scenario.json");
const scenario = JSON.parse(await readFile(scenarioPath, "utf8"));

const [qaHomeArgument, ...options] = process.argv.slice(2);
if (!qaHomeArgument || qaHomeArgument.startsWith("--")) {
  throw new Error(
    "Usage: node website/scripts/generate-showcase-fixtures.mjs <qa-home> --allow-showcase-overwrite [--now=<ISO-8601>]",
  );
}

const overwriteOption = "--allow-showcase-overwrite";
const nowOption = options.find((option) => option.startsWith("--now="));
const unknownOption = options.find(
  (option) => option !== overwriteOption && !option.startsWith("--now="),
);
if (unknownOption) {
  throw new Error(`Unknown option: ${unknownOption}`);
}
if (!options.includes(overwriteOption)) {
  throw new Error(
    `Refusing to replace showcase data without explicit ${overwriteOption} opt-in.`,
  );
}

const nowArgument = nowOption?.slice("--now=".length);
const now = new Date(nowArgument ?? Date.now());
const atOffset = (days, minutes = 0) =>
  new Date(now.getTime() + days * 86_400_000 + minutes * 60_000).toISOString();

if (Number.isNaN(now.getTime())) {
  throw new Error(`Invalid --now value: ${nowArgument}`);
}

const qaHome = resolve(qaHomeArgument);
const codexRoot = join(qaHome, ".codex");
const codexShowcaseRoot = join(codexRoot, "sessions", "showcase");
const claudeProjectsRoot = join(qaHome, ".claude", "projects");

const codexSessionId = (index) =>
  `c0de0000-0000-7000-8000-${String(index + 1).padStart(12, "0")}`;
const claudeSessionId = (index) =>
  `c1ad0000-0000-7000-8000-${String(index + 1).padStart(12, "0")}`;
const projectPath = (index) =>
  `${scenario.projectRoot}/${scenario.projectSlugs[index % scenario.projectSlugs.length]}`;
const projectDirectoryName = (path) => path.replaceAll("/", "-");
const dayOffsetForSession = (index) =>
  scenario.activeDayOffsets[
    (index + scenario.activeDayOffsets.length - 1) % scenario.activeDayOffsets.length
  ];
const baseMinuteForSession = (index) => -240 + (index % 8) * 20;
const eventCountForSession = (index) =>
  index === scenario.selectedSessionIndex
    ? scenario.selectedSessionEventCount
    : 2 + (index % 6);
const jsonLines = (lines) => `${lines.map((line) => JSON.stringify(line)).join("\n")}\n`;

await rm(codexShowcaseRoot, { recursive: true, force: true });
await mkdir(codexShowcaseRoot, { recursive: true });
await mkdir(claudeProjectsRoot, { recursive: true });

for (const slug of scenario.projectSlugs) {
  await rm(
    join(claudeProjectsRoot, projectDirectoryName(`${scenario.projectRoot}/${slug}`)),
    { recursive: true, force: true },
  );
}

const codexMetadata = [];
for (let index = 0; index < scenario.codexSessionCount; index += 1) {
  const id = codexSessionId(index);
  const cwd = projectPath(index);
  const model = scenario.codexModels[index % scenario.codexModels.length];
  const dayOffset = dayOffsetForSession(index);
  const baseMinute = baseMinuteForSession(index);
  const eventCount = eventCountForSession(index);
  const startedAt = atOffset(dayOffset, baseMinute);
  const lines = [
    {
      timestamp: startedAt,
      type: "session_meta",
      payload: {
        id,
        timestamp: startedAt,
        cwd,
        originator: "quota-monitor-showcase",
        cli_version: "1.0.0-showcase",
      },
    },
    {
      timestamp: atOffset(dayOffset, baseMinute + 2),
      type: "turn_context",
      payload: { model },
    },
  ];

  const cumulative = {
    input_tokens: 0,
    cached_input_tokens: 0,
    output_tokens: 0,
    reasoning_output_tokens: 0,
    total_tokens: 0,
  };

  for (let eventIndex = 0; eventIndex < eventCount; eventIndex += 1) {
    const input = 920 + index * 73 + eventIndex * 137;
    const cached = 180 + index * 19 + eventIndex * 31;
    const output = 240 + index * 29 + eventIndex * 47;
    const reasoning = 60 + index * 7 + eventIndex * 11;
    cumulative.input_tokens += input;
    cumulative.cached_input_tokens += cached;
    cumulative.output_tokens += output;
    cumulative.reasoning_output_tokens += reasoning;
    cumulative.total_tokens = cumulative.input_tokens + cumulative.output_tokens;

    const payload = {
      type: "token_count",
      info: { total_token_usage: { ...cumulative } },
    };
    if (
      index === scenario.selectedSessionIndex &&
      eventIndex === eventCount - 1
    ) {
      const nowEpoch = Math.floor(now.getTime() / 1000);
      payload.rate_limits = {
        primary: {
          used_percent: 42.5,
          window_minutes: 300,
          resets_at: nowEpoch + 3 * 60 * 60,
        },
        secondary: {
          used_percent: 61.8,
          window_minutes: 10080,
          resets_at: nowEpoch + 5 * 24 * 60 * 60,
        },
        plan_type: "plus",
      };
    }

    lines.push({
      timestamp: atOffset(dayOffset, baseMinute + 5 + eventIndex * 10),
      type: "event_msg",
      payload,
    });
  }

  const updatedAt = lines.at(-1).timestamp;
  const filename = `rollout-showcase-${String(index + 1).padStart(2, "0")}-${id}.jsonl`;
  await writeFile(join(codexShowcaseRoot, filename), jsonLines(lines), "utf8");
  codexMetadata.push({
    id,
    thread_name: scenario.titles[index],
    updated_at: updatedAt,
  });
}

await mkdir(codexRoot, { recursive: true });
await writeFile(
  join(codexRoot, "session_index.jsonl"),
  jsonLines(codexMetadata),
  "utf8",
);

for (let claudeIndex = 0; claudeIndex < scenario.claudeSessionCount; claudeIndex += 1) {
  const index = scenario.codexSessionCount + claudeIndex;
  const id = claudeSessionId(claudeIndex);
  const cwd = projectPath(index);
  const model = scenario.claudeModels[claudeIndex % scenario.claudeModels.length];
  const dayOffset = dayOffsetForSession(index);
  const baseMinute = baseMinuteForSession(index);
  const eventCount = eventCountForSession(index);
  const lines = [
    {
      type: "ai-title",
      aiTitle: scenario.titles[index],
      sessionId: id,
    },
  ];

  for (let eventIndex = 0; eventIndex < eventCount; eventIndex += 1) {
    const cacheFiveMinute = 70 + claudeIndex * 11 + eventIndex * 13;
    const cacheOneHour = 40 + claudeIndex * 7 + eventIndex * 9;
    lines.push({
      type: "assistant",
      timestamp: atOffset(dayOffset, baseMinute + 5 + eventIndex * 10),
      sessionId: id,
      uuid: `showcase-claude-${String(claudeIndex + 1).padStart(2, "0")}-event-${eventIndex + 1}`,
      cwd,
      version: "1.0.0-showcase",
      gitBranch: "showcase",
      message: {
        id: `msg_showcase_${String(claudeIndex + 1).padStart(2, "0")}_${eventIndex + 1}`,
        model,
        usage: {
          input_tokens: 620 + claudeIndex * 61 + eventIndex * 89,
          cache_creation_input_tokens: cacheFiveMinute + cacheOneHour,
          cache_creation: {
            ephemeral_5m_input_tokens: cacheFiveMinute,
            ephemeral_1h_input_tokens: cacheOneHour,
          },
          cache_read_input_tokens: 210 + claudeIndex * 37 + eventIndex * 43,
          output_tokens: 190 + claudeIndex * 23 + eventIndex * 41,
        },
      },
    });
  }

  const destination = join(claudeProjectsRoot, projectDirectoryName(cwd));
  await mkdir(destination, { recursive: true });
  await writeFile(join(destination, `${id}.jsonl`), jsonLines(lines), "utf8");
}

process.stdout.write(
  `Generated ${scenario.codexSessionCount} Codex and ${scenario.claudeSessionCount} Claude showcase sessions.\n`,
);
