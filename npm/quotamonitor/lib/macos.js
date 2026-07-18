import { randomUUID } from "node:crypto";
import { lstat, rename, rm } from "node:fs/promises";
import path from "node:path";

import {
  APP_BUNDLE_ID,
  APP_DISTRIBUTION_CHANNEL,
  APP_NAME,
  APP_TEAM_ID,
} from "./constants.js";
import { pathExists } from "./platform.js";
import { compareVersions } from "./version.js";

function escapePattern(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

async function readPlistValue(bundlePath, key, runCommand) {
  const plistPath = path.join(bundlePath, "Contents", "Info.plist");
  const { stdout } = await runCommand("/usr/libexec/PlistBuddy", [
    "-c",
    `Print :${key}`,
    plistPath,
  ]);
  return stdout.trim();
}

async function assertRealBundle(bundlePath) {
  const info = await lstat(bundlePath);
  if (!info.isDirectory() || info.isSymbolicLink()) {
    throw new Error(`Expected a real application bundle at ${bundlePath}`);
  }
}

export async function verifyBundle(
  bundlePath,
  {
    expectedVersion,
    expectedMinimumSystemVersion,
    runCommand,
  },
) {
  await assertRealBundle(bundlePath);
  const [bundleID, shortVersion, buildVersion, distributionChannel, minimumOS] =
    await Promise.all([
      readPlistValue(bundlePath, "CFBundleIdentifier", runCommand),
      readPlistValue(bundlePath, "CFBundleShortVersionString", runCommand),
      readPlistValue(bundlePath, "CFBundleVersion", runCommand),
      readPlistValue(bundlePath, "QMDistributionChannel", runCommand),
      readPlistValue(bundlePath, "LSMinimumSystemVersion", runCommand),
    ]);

  if (bundleID !== APP_BUNDLE_ID) {
    throw new Error(`Unexpected bundle identifier at ${bundlePath}`);
  }
  if (shortVersion !== buildVersion) {
    throw new Error(`Bundle version fields disagree at ${bundlePath}`);
  }
  if (expectedVersion && shortVersion !== expectedVersion) {
    throw new Error(
      `Expected Quota Monitor ${expectedVersion}, found ${shortVersion}`,
    );
  }
  if (
    expectedMinimumSystemVersion &&
    minimumOS !== expectedMinimumSystemVersion
  ) {
    throw new Error(
      `Expected minimum macOS ${expectedMinimumSystemVersion}, found ${minimumOS}`,
    );
  }
  if (distributionChannel !== APP_DISTRIBUTION_CHANNEL) {
    throw new Error(`Unexpected distribution channel at ${bundlePath}`);
  }

  await runCommand("/usr/bin/codesign", [
    "--verify",
    "--deep",
    "--strict",
    "--verbose=2",
    bundlePath,
  ]);
  const signature = await runCommand("/usr/bin/codesign", [
    "-dv",
    "--verbose=4",
    bundlePath,
  ]);
  const signatureDetails = `${signature.stdout}\n${signature.stderr}`;
  if (
    !new RegExp(`^Identifier=${escapePattern(APP_BUNDLE_ID)}$`, "m").test(
      signatureDetails,
    ) ||
    !new RegExp(`^TeamIdentifier=${escapePattern(APP_TEAM_ID)}$`, "m").test(
      signatureDetails,
    )
  ) {
    throw new Error(`Developer ID identity verification failed at ${bundlePath}`);
  }

  await runCommand("/usr/sbin/spctl", [
    "--assess",
    "--type",
    "execute",
    "--verbose=2",
    bundlePath,
  ]);

  return { version: shortVersion, minimumOS };
}

export async function verifyDMG(dmgPath, runCommand) {
  await runCommand("/usr/bin/codesign", [
    "--verify",
    "--verbose=2",
    dmgPath,
  ]);
  await runCommand("/usr/sbin/spctl", [
    "--assess",
    "--type",
    "open",
    "--context",
    "context:primary-signature",
    "--verbose=2",
    dmgPath,
  ]);
}

export async function attachDMG(dmgPath, mountPath, runCommand) {
  await runCommand("/usr/bin/hdiutil", [
    "attach",
    "-nobrowse",
    "-readonly",
    "-noautoopen",
    "-mountpoint",
    mountPath,
    dmgPath,
  ]);
}

export async function detachDMG(mountPath, runCommand) {
  try {
    await runCommand("/usr/bin/hdiutil", ["detach", mountPath]);
  } catch (error) {
    try {
      await runCommand("/usr/bin/hdiutil", ["detach", "-force", mountPath]);
    } catch {
      throw error;
    }
  }
}

export async function isAppRunning(runCommand) {
  const result = await runCommand(
    "/usr/bin/pgrep",
    ["-x", "QuotaMonitor"],
    { allowedExitCodes: [0, 1] },
  );
  return result.exitCode === 0;
}

export async function installAtomically({
  sourceBundle,
  installDirectory,
  release,
  replaceExisting = false,
  runCommand,
}) {
  const destination = path.join(installDirectory, APP_NAME);
  const nonce = `${process.pid}-${randomUUID()}`;
  const staging = path.join(installDirectory, `.QuotaMonitor.install-${nonce}.app`);
  const backup = path.join(installDirectory, `.QuotaMonitor.backup-${nonce}.app`);
  const hadExistingBundle = await pathExists(destination);
  let backupCreated = false;
  let installed = false;
  let backupRetained = null;

  try {
    if (hadExistingBundle) {
      if (!replaceExisting) {
        throw new Error(
          `An app appeared at ${destination} during installation; rerun after confirming whether it may be replaced`,
        );
      }
      const existing = await verifyBundle(destination, { runCommand });
      if (compareVersions(existing.version, release.version) >= 0) {
        throw new Error(
          `Refusing to replace Quota Monitor ${existing.version} with ${release.version}`,
        );
      }
      if (await isAppRunning(runCommand)) {
        throw new Error("Quota Monitor is running. Quit it before using --replace");
      }
    }

    await runCommand("/usr/bin/ditto", [
      "--rsrc",
      "--extattr",
      "--acl",
      sourceBundle,
      staging,
    ]);
    await verifyBundle(staging, {
      expectedVersion: release.version,
      expectedMinimumSystemVersion: release.minimumSystemVersion,
      runCommand,
    });

    try {
      if (hadExistingBundle) {
        await rename(destination, backup);
        backupCreated = true;
      }
      await rename(staging, destination);
      installed = true;

      await verifyBundle(destination, {
        expectedVersion: release.version,
        expectedMinimumSystemVersion: release.minimumSystemVersion,
        runCommand,
      });
    } catch (error) {
      const rollbackFailures = [];
      if (installed) {
        try {
          await rename(destination, staging);
          installed = false;
        } catch (rollbackError) {
          rollbackFailures.push(
            `could not move the failed app aside: ${rollbackError.message}`,
          );
        }
      }
      if (backupCreated && !(await pathExists(destination))) {
        try {
          await rename(backup, destination);
          backupCreated = false;
        } catch (rollbackError) {
          rollbackFailures.push(
            `could not restore the previous app: ${rollbackError.message}`,
          );
        }
      }

      if (rollbackFailures.length > 0 || backupCreated) {
        const backupDetail = backupCreated
          ? ` The previous app is retained at ${backup}.`
          : "";
        throw new Error(
          `Installation failed: ${error.message}. Automatic rollback was incomplete: ` +
            `${rollbackFailures.join("; ") || "the destination remained occupied"}.` +
            backupDetail,
          { cause: error },
        );
      }
      throw error;
    }

    if (backupCreated) {
      try {
        await rm(backup, { recursive: true, force: true });
        backupCreated = false;
      } catch {
        backupRetained = backup;
      }
    }

    return { destination, backupRetained };
  } finally {
    if (!installed) {
      await rm(staging, { recursive: true, force: true }).catch(() => {});
    }
  }
}

export async function openApplication(bundlePath, runCommand) {
  await runCommand("/usr/bin/open", [bundlePath]);
}
