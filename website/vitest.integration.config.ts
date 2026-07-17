import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  const migrations = await readD1Migrations(
    `${import.meta.dirname}/migrations`,
  );

  return {
    plugins: [
      cloudflareTest({
        main: "./src/worker.ts",
        miniflare: {
          compatibilityDate: "2026-07-15",
          compatibilityFlags: ["nodejs_compat"],
          d1Databases: ["VERSION_STATS_DB"],
          bindings: { TEST_MIGRATIONS: migrations },
        },
      }),
    ],
    test: {
      include: ["tests/d1.integration.test.ts"],
      setupFiles: ["./tests/d1-integration-setup.ts"],
    },
  };
});
