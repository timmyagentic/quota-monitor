import assert from "node:assert/strict";
import test from "node:test";

import {
  assertAppleSilicon,
  assertSupportedPlatform,
} from "../lib/platform.js";
import { compareVersions, parseNumericVersion } from "../lib/version.js";

test("platform checks reject root and non-macOS", () => {
  assert.throws(
    () => assertSupportedPlatform({ platform: "darwin", userID: 0 }),
    /sudo or as root/,
  );
  assert.throws(
    () => assertSupportedPlatform({ platform: "linux", userID: 501 }),
    /only be installed on macOS/,
  );
  assert.doesNotThrow(() =>
    assertSupportedPlatform({ platform: "darwin", userID: 501 }),
  );
});

test("hardware check accepts Apple Silicon even when Node may run under Rosetta", async () => {
  await assert.doesNotReject(
    assertAppleSilicon(async (executable, args) => {
      assert.equal(executable, "/usr/sbin/sysctl");
      assert.deepEqual(args, ["-n", "hw.optional.arm64"]);
      return { stdout: "1\n", stderr: "", exitCode: 0 };
    }),
  );
  await assert.rejects(
    assertAppleSilicon(async () => ({ stdout: "0\n", stderr: "", exitCode: 0 })),
    /Apple Silicon/,
  );
});

test("numeric versions compare macOS and app releases without lexical mistakes", () => {
  assert.equal(compareVersions("14.10", "14.9"), 1);
  assert.equal(compareVersions("0.2.42", "0.2.42"), 0);
  assert.equal(compareVersions("0.2.9", "0.2.10"), -1);
  assert.throws(() => parseNumericVersion("14.beta"), /Invalid version/);
});
