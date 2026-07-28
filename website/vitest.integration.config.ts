import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  const versionStatsMigrations = await readD1Migrations(
    `${import.meta.dirname}/migrations/version-stats`,
  );
  const privateBetaMigrations = await readD1Migrations(
    `${import.meta.dirname}/migrations/private-beta`,
  );

  return {
    plugins: [
      cloudflareTest({
        main: "./src/worker.ts",
        miniflare: {
          compatibilityDate: "2026-07-15",
          compatibilityFlags: ["nodejs_compat"],
          d1Databases: ["VERSION_STATS_DB", "PRIVATE_BETA_DB"],
          bindings: {
            VERSION_STATS_TEST_MIGRATIONS: versionStatsMigrations,
            PRIVATE_BETA_TEST_MIGRATIONS: privateBetaMigrations,
          },
        },
      }),
    ],
    test: {
      include: ["tests/d1.integration.test.ts"],
      setupFiles: ["./tests/d1-integration-setup.ts"],
    },
  };
});
