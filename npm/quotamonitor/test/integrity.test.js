import assert from "node:assert/strict";
import test from "node:test";

import {
  assertChecksum,
  parseChecksumSidecar,
} from "../lib/integrity.js";

const hash = "a".repeat(64);
const filename = "QuotaMonitor-0.2.42.dmg";

test("parses the exact one-file SHA-256 sidecar format", () => {
  assert.equal(parseChecksumSidecar(`${hash}  ${filename}\n`, filename), hash);
  assert.equal(parseChecksumSidecar(`${hash} *${filename}`, filename), hash);
});

test("refuses sidecar path injection, extra lines, and wrong filenames", () => {
  assert.throws(
    () => parseChecksumSidecar(`${hash}  ../../${filename}`, filename),
    /does not name/,
  );
  assert.throws(
    () => parseChecksumSidecar(`${hash}  other.dmg`, filename),
    /does not name/,
  );
  assert.throws(
    () => parseChecksumSidecar(`${hash}  ${filename}\n${hash}  ${filename}`, filename),
    /exactly one/,
  );
});

test("checksum comparison fails closed", () => {
  assert.doesNotThrow(() => assertChecksum(hash, hash));
  assert.throws(() => assertChecksum(hash, "b".repeat(64)), /verification failed/);
  assert.throws(() => assertChecksum("invalid", hash), /verification failed/);
});
