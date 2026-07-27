import { applyD1Migrations, type D1Migration } from "cloudflare:test";
import { env } from "cloudflare:workers";

declare global {
  namespace Cloudflare {
    interface Env {
      VERSION_STATS_TEST_MIGRATIONS: D1Migration[];
      PRIVATE_BETA_TEST_MIGRATIONS: D1Migration[];
    }
  }
}

await applyD1Migrations(
  env.VERSION_STATS_DB,
  env.VERSION_STATS_TEST_MIGRATIONS,
);
await applyD1Migrations(
  env.PRIVATE_BETA_DB,
  env.PRIVATE_BETA_TEST_MIGRATIONS,
);
