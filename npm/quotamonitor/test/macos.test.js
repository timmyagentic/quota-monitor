import assert from "node:assert/strict";
import {
  cp,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { installAtomically, verifyBundle, verifyDMG } from "../lib/macos.js";

async function withFakeBundle(callback) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "qm-bundle-test-"));
  const bundle = path.join(directory, "QuotaMonitor.app");
  await mkdir(path.join(bundle, "Contents"), { recursive: true });
  try {
    await callback(bundle);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

function bundleRunner({ teamID = "4356B4HF9R" } = {}) {
  const values = new Map([
    ["CFBundleIdentifier", "dev.tjzhou.QuotaMonitor"],
    ["CFBundleShortVersionString", "0.2.42"],
    ["CFBundleVersion", "0.2.42"],
    ["QMDistributionChannel", "developer-id"],
    ["LSMinimumSystemVersion", "14.0"],
  ]);
  const calls = [];
  const runner = async (executable, args) => {
    calls.push({ executable, args });
    if (executable === "/usr/libexec/PlistBuddy") {
      const key = args[1].slice("Print :".length);
      return { stdout: `${values.get(key)}\n`, stderr: "", exitCode: 0 };
    }
    if (executable === "/usr/bin/codesign" && args[0] === "-dv") {
      return {
        stdout: "",
        stderr: `Identifier=dev.tjzhou.QuotaMonitor\nTeamIdentifier=${teamID}\n`,
        exitCode: 0,
      };
    }
    return { stdout: "", stderr: "", exitCode: 0 };
  };
  return { runner, calls };
}

test("bundle verification pins metadata, Team ID, and Gatekeeper command", async () => {
  await withFakeBundle(async (bundle) => {
    const { runner, calls } = bundleRunner();
    const result = await verifyBundle(bundle, {
      expectedVersion: "0.2.42",
      expectedMinimumSystemVersion: "14.0",
      runCommand: runner,
    });
    assert.deepEqual(result, { version: "0.2.42", minimumOS: "14.0" });
    assert.ok(
      calls.some(
        ({ executable, args }) =>
          executable === "/usr/bin/codesign" &&
          args.includes("--deep") &&
          args.at(-1) === bundle,
      ),
    );
    assert.ok(
      calls.some(
        ({ executable, args }) =>
          executable === "/usr/sbin/spctl" &&
          args.includes("execute") &&
          args.at(-1) === bundle,
      ),
    );
  });
});

test("bundle verification refuses another Developer ID team", async () => {
  await withFakeBundle(async (bundle) => {
    const { runner } = bundleRunner({ teamID: "EVILTEAM01" });
    await assert.rejects(
      verifyBundle(bundle, { runCommand: runner }),
      /Developer ID identity verification failed/,
    );
  });
});

test("DMG verification uses codesign and Gatekeeper without shell strings", async () => {
  const calls = [];
  await verifyDMG("/tmp/QuotaMonitor.dmg", async (executable, args) => {
    calls.push({ executable, args });
    return { stdout: "", stderr: "", exitCode: 0 };
  });
  assert.deepEqual(calls, [
    {
      executable: "/usr/bin/codesign",
      args: ["--verify", "--verbose=2", "/tmp/QuotaMonitor.dmg"],
    },
    {
      executable: "/usr/sbin/spctl",
      args: [
        "--assess",
        "--type",
        "open",
        "--context",
        "context:primary-signature",
        "--verbose=2",
        "/tmp/QuotaMonitor.dmg",
      ],
    },
  ]);
});

test("atomic installation never replaces an app that appeared without consent", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "qm-race-test-"));
  const sourceBundle = path.join(directory, "Source.app");
  await mkdir(sourceBundle);
  await mkdir(path.join(directory, "QuotaMonitor.app"));
  try {
    await assert.rejects(
      installAtomically({
        sourceBundle,
        installDirectory: directory,
        release: { version: "0.2.42", minimumSystemVersion: "14.0" },
        runCommand: async () => {
          throw new Error("command runner must not be reached");
        },
      }),
      /appeared.*confirming whether it may be replaced/,
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("atomic installation restores the previous app when final verification fails", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "qm-rollback-test-"));
  const sourceBundle = path.join(directory, "Source.app");
  const destination = path.join(directory, "QuotaMonitor.app");
  await mkdir(path.join(sourceBundle, "Contents"), { recursive: true });
  await mkdir(path.join(destination, "Contents"), { recursive: true });
  await writeFile(path.join(sourceBundle, "new-marker"), "new");
  await writeFile(path.join(destination, "old-marker"), "old");
  let stagingVerified = false;

  const runner = async (executable, args, options) => {
    if (executable === "/usr/bin/ditto") {
      await cp(args.at(-2), args.at(-1), { recursive: true });
      return { stdout: "", stderr: "", exitCode: 0 };
    }
    if (executable === "/usr/bin/pgrep") {
      assert.deepEqual(options, { allowedExitCodes: [0, 1] });
      return { stdout: "", stderr: "", exitCode: 1 };
    }

    const commandPath = args.at(-1);
    const bundlePath = commandPath.endsWith("Info.plist")
      ? path.dirname(path.dirname(commandPath))
      : commandPath;
    const isDestination = bundlePath === destination;
    const isStaging = path.basename(bundlePath).startsWith(".QuotaMonitor.install-");

    if (executable === "/usr/libexec/PlistBuddy") {
      if (isDestination && stagingVerified) {
        throw new Error("injected final verification failure");
      }
      const key = args[1].slice("Print :".length);
      const version = isDestination ? "0.2.41" : "0.2.42";
      const values = new Map([
        ["CFBundleIdentifier", "dev.tjzhou.QuotaMonitor"],
        ["CFBundleShortVersionString", version],
        ["CFBundleVersion", version],
        ["QMDistributionChannel", "developer-id"],
        ["LSMinimumSystemVersion", "14.0"],
      ]);
      return { stdout: `${values.get(key)}\n`, stderr: "", exitCode: 0 };
    }
    if (executable === "/usr/bin/codesign" && args[0] === "-dv") {
      return {
        stdout: "",
        stderr: "Identifier=dev.tjzhou.QuotaMonitor\nTeamIdentifier=4356B4HF9R\n",
        exitCode: 0,
      };
    }
    if (executable === "/usr/sbin/spctl" && isStaging) {
      stagingVerified = true;
    }
    return { stdout: "", stderr: "", exitCode: 0 };
  };

  try {
    await assert.rejects(
      installAtomically({
        sourceBundle,
        installDirectory: directory,
        release: { version: "0.2.42", minimumSystemVersion: "14.0" },
        replaceExisting: true,
        runCommand: runner,
      }),
      /injected final verification failure/,
    );
    assert.equal(await readFile(path.join(destination, "old-marker"), "utf8"), "old");
    assert.ok(!(await readdir(directory)).some((name) => name.includes(".backup-")));
    assert.ok(!(await readdir(directory)).some((name) => name.includes(".install-")));
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
