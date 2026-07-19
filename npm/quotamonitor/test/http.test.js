import assert from "node:assert/strict";
import test from "node:test";

import { assertAllowedURL } from "../lib/http.js";

const allowed = new Set(["github.com", "release-assets.githubusercontent.com"]);

test("URL policy allows only explicit HTTPS release hosts", () => {
  assert.equal(
    assertAllowedURL("https://github.com/timmyagentic/quota-monitor", allowed).hostname,
    "github.com",
  );
  for (const url of [
    "http://github.com/timmyagentic/quota-monitor",
    "https://user@github.com/timmyagentic/quota-monitor",
    "https://github.com:8443/timmyagentic/quota-monitor",
    "https://example.com/QuotaMonitor.dmg",
  ]) {
    assert.throws(() => assertAllowedURL(url, allowed), /untrusted download URL/);
  }
});
