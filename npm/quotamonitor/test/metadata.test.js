import assert from "node:assert/strict";
import { createRequire } from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const packageJSON = require("../package.json");

test("package metadata has no dependencies or lifecycle install hooks", () => {
  assert.equal(packageJSON.dependencies, undefined);
  assert.equal(packageJSON.devDependencies, undefined);
  assert.equal(packageJSON.cpu, undefined);
  for (const lifecycle of ["preinstall", "install", "postinstall", "prepare"]) {
    assert.equal(packageJSON.scripts[lifecycle], undefined);
  }
  assert.deepEqual(packageJSON.bin, { quotamonitor: "bin/quotamonitor.js" });
  assert.equal(
    packageJSON.repository.url,
    "git+https://github.com/timmyagentic/quota-monitor.git",
  );
});
