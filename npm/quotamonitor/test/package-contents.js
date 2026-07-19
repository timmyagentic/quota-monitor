import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const expectedFiles = [
  "LICENSE",
  "README.md",
  "bin/quotamonitor.js",
  "lib/appcast.js",
  "lib/cli.js",
  "lib/constants.js",
  "lib/http.js",
  "lib/installer.js",
  "lib/integrity.js",
  "lib/macos.js",
  "lib/platform.js",
  "lib/run-command.js",
  "lib/version.js",
  "package.json",
].sort();

const { stdout } = await execFileAsync("npm", ["pack", "--dry-run", "--json"], {
  encoding: "utf8",
  maxBuffer: 2 * 1024 * 1024,
});
const report = JSON.parse(stdout);
assert.equal(report.length, 1);
const actualFiles = report[0].files.map((file) => file.path).sort();
assert.deepEqual(actualFiles, expectedFiles);
assert.equal(report[0].name, "quotamonitor");
assert.equal(report[0].version, "0.1.0");
assert.equal(report[0].files.find((file) => file.path === "bin/quotamonitor.js").mode, 493);

console.log(`Package contents verified (${actualFiles.length} files)`);
