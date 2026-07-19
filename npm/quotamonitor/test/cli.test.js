import assert from "node:assert/strict";
import test from "node:test";

import { main, parseArguments } from "../lib/cli.js";

test("parses an explicit install without hidden lifecycle behavior", () => {
  assert.deepEqual(
    parseArguments([
      "install",
      "--app-dir",
      "/tmp/Applications",
      "--replace",
      "--no-open",
    ]),
    {
      action: "install",
      appDirectory: "/tmp/Applications",
      replace: true,
      open: false,
    },
  );
});

test("rejects unknown commands and missing option values", () => {
  assert.throws(() => parseArguments(["upgrade"]), /Unknown command/);
  assert.throws(
    () => parseArguments(["install", "--app-dir"]),
    /requires a directory/,
  );
  assert.throws(
    () => parseArguments(["install", "--force"]),
    /Unknown option/,
  );
});

test("help and version do not invoke the installer", async () => {
  assert.equal(await main(["--help"]), 0);
  assert.equal(await main(["--version"]), 0);
});
