import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  parseValidatedItems,
  rejectUnsafeXML,
  selectReleaseFromAppcast,
} from "../lib/appcast.js";

const signature = Buffer.alloc(64, 7).toString("base64");

function item(
  version,
  {
    minimum = "14.0",
    url = `https://github.com/timmyagentic/quota-monitor/releases/download/v${version}/QuotaMonitor-${version}.dmg`,
    length = "7119537",
    extraAttributes = "",
  } = {},
) {
  return `<item>
    <sparkle:version>${version}</sparkle:version>
    <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>${minimum}</sparkle:minimumSystemVersion>
    <enclosure url="${url}" length="${length}" sparkle:edSignature="${signature}" ${extraAttributes}/>
  </item>`;
}

test("selects the highest compatible release instead of trusting item order", () => {
  const release = parseValidatedItems(
    `${item("0.2.41")}${item("0.2.43", { minimum: "15.0" })}${item("0.2.42")}`,
    "14.7",
  );
  assert.equal(release.version, "0.2.42");
  assert.equal(release.filename, "QuotaMonitor-0.2.42.dmg");
  assert.equal(release.length, 7119537);
});

test("refuses a release URL outside the exact official tag and filename", () => {
  assert.throws(
    () =>
      parseValidatedItems(
        item("0.2.42", { url: "https://example.com/QuotaMonitor.dmg" }),
        "14.0",
      ),
    /Unexpected release URL/,
  );
});

test("refuses duplicate enclosure fields", () => {
  assert.throws(
    () =>
      parseValidatedItems(
        item("0.2.42", { extraAttributes: 'url="https://example.com/x"' }),
        "14.0",
      ),
    /Duplicate enclosure attribute/,
  );
});

test("refuses invalid lengths and signatures", () => {
  assert.throws(
    () => parseValidatedItems(item("0.2.42", { length: "-1" }), "14.0"),
    /Invalid enclosure length/,
  );
  assert.throws(
    () =>
      parseValidatedItems(
        item("0.2.42").replace(signature, Buffer.alloc(10).toString("base64")),
        "14.0",
      ),
    /Invalid Sparkle signature/,
  );
});

test("refuses DTD and entity declarations before XML tooling runs", () => {
  assert.throws(
    () => rejectUnsafeXML('<!DOCTYPE x [<!ENTITY local SYSTEM "file:///etc/passwd">]>'),
    /forbidden DTD or entity/,
  );
  assert.throws(() => rejectUnsafeXML(""), /empty/);
});

test("writes the appcast privately and invokes xmllint without network access", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "qm-appcast-test-"));
  const xml = `<rss><channel>${item("0.2.42")}</channel></rss>`;
  const calls = [];
  try {
    const release = await selectReleaseFromAppcast({
      xml,
      macOSVersion: "14.0",
      tempDirectory: directory,
      runCommand: async (executable, args) => {
        calls.push({ executable, args });
        return { stdout: item("0.2.42"), stderr: "", exitCode: 0 };
      },
    });
    assert.equal(release.version, "0.2.42");
    assert.deepEqual(calls, [
      {
        executable: "/usr/bin/xmllint",
        args: [
          "--nonet",
          "--xpath",
          "//*[local-name()='item']",
          path.join(directory, "appcast.xml"),
        ],
      },
    ]);
    assert.equal(await readFile(path.join(directory, "appcast.xml"), "utf8"), xml);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
