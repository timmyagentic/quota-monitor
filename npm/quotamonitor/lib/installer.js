import { chmod, lstat, mkdir, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { selectReleaseFromAppcast } from "./appcast.js";
import {
  APPCAST_HOSTS,
  APPCAST_URL,
  APP_NAME,
  GITHUB_RELEASE_HOSTS,
  MAX_APPCAST_BYTES,
  MAX_CHECKSUM_BYTES,
  MAX_DMG_BYTES,
} from "./constants.js";
import { downloadFile, getText } from "./http.js";
import {
  assertChecksum,
  parseChecksumSidecar,
  verifySparkleSignature,
} from "./integrity.js";
import {
  attachDMG,
  detachDMG,
  installAtomically,
  isAppRunning,
  openApplication,
  verifyBundle,
  verifyDMG,
} from "./macos.js";
import {
  assertAppleSilicon,
  assertSupportedPlatform,
  pathExists,
  readMacOSVersion,
  resolveInstallDirectory,
} from "./platform.js";
import { runCommand } from "./run-command.js";
import { compareVersions } from "./version.js";

function defaultProgress(message) {
  console.log(`→ ${message}`);
}

export async function installQuotaMonitor(
  { appDirectory, replace = false, open = true } = {},
  {
    commandRunner = runCommand,
    progress = defaultProgress,
    getTextImpl = getText,
    downloadFileImpl = downloadFile,
  } = {},
) {
  assertSupportedPlatform();
  progress("Checking this Mac and the delivered release feed");
  await assertAppleSilicon(commandRunner);
  const macOSVersion = await readMacOSVersion(commandRunner);
  const tempDirectory = await mkdtemp(
    path.join(os.tmpdir(), "quotamonitor-installer-"),
  );
  await chmod(tempDirectory, 0o700);
  const mountDirectory = path.join(tempDirectory, "mount");
  let mounted = false;
  let primaryError = null;
  let interrupted = false;
  let interruptAnnounced = false;
  const handleInterrupt = () => {
    interrupted = true;
    if (!interruptAnnounced) {
      interruptAnnounced = true;
      progress("Interrupt received; finishing the current step and cleaning up");
    }
  };
  const throwIfInterrupted = () => {
    if (interrupted) {
      throw new Error("Installation interrupted");
    }
  };
  process.on("SIGINT", handleInterrupt);
  process.on("SIGTERM", handleInterrupt);

  try {
    const appcast = await getTextImpl(APPCAST_URL, {
      allowedHosts: APPCAST_HOSTS,
      maxBytes: MAX_APPCAST_BYTES,
    });
    throwIfInterrupted();
    const release = await selectReleaseFromAppcast({
      xml: appcast,
      macOSVersion,
      tempDirectory,
      runCommand: commandRunner,
    });
    throwIfInterrupted();
    const installDirectory = await resolveInstallDirectory(appDirectory);
    const destination = path.join(installDirectory, APP_NAME);

    if (await pathExists(destination)) {
      const existing = await verifyBundle(destination, {
        runCommand: commandRunner,
      });
      const versionComparison = compareVersions(existing.version, release.version);
      if (versionComparison > 0) {
        throw new Error(
          `Installed version ${existing.version} is newer than delivered version ${release.version}; refusing to downgrade`,
        );
      }
      if (versionComparison === 0) {
        let openWarning = null;
        if (open) {
          try {
            await openApplication(destination, commandRunner);
          } catch (error) {
            openWarning = error.message;
          }
        }
        return {
          status: "already-current",
          version: release.version,
          destination,
          checks: ["Developer ID", "Gatekeeper"],
          openWarning,
        };
      }
      if (!replace) {
        throw new Error(
          `Quota Monitor ${existing.version} already exists at ${destination}. Quit it, confirm replacement, then rerun with --replace`,
        );
      }
      if (await isAppRunning(commandRunner)) {
        throw new Error("Quota Monitor is running. Quit it before using --replace");
      }
    }

    progress(`Downloading Quota Monitor ${release.version}`);
    const checksumText = await getTextImpl(release.checksumURL, {
      allowedHosts: GITHUB_RELEASE_HOSTS,
      maxBytes: MAX_CHECKSUM_BYTES,
    });
    throwIfInterrupted();
    const expectedChecksum = parseChecksumSidecar(
      checksumText,
      release.filename,
    );
    const dmgPath = path.join(tempDirectory, release.filename);
    const downloaded = await downloadFileImpl(release.url, dmgPath, {
      allowedHosts: GITHUB_RELEASE_HOSTS,
      expectedBytes: release.length,
      maxBytes: MAX_DMG_BYTES,
    });
    throwIfInterrupted();

    progress("Verifying SHA-256 and Sparkle Ed25519 signatures");
    assertChecksum(downloaded.sha256, expectedChecksum);
    await verifySparkleSignature(dmgPath, release.signature, release.length);
    await verifyDMG(dmgPath, commandRunner);
    throwIfInterrupted();

    progress("Checking the Developer ID signature and Apple notarization");
    await mkdir(mountDirectory, { mode: 0o700 });
    await attachDMG(dmgPath, mountDirectory, commandRunner);
    mounted = true;
    throwIfInterrupted();
    const sourceBundle = path.join(mountDirectory, APP_NAME);
    const sourceInfo = await lstat(sourceBundle);
    if (!sourceInfo.isDirectory() || sourceInfo.isSymbolicLink()) {
      throw new Error(`The DMG does not contain a real ${APP_NAME} bundle`);
    }
    await verifyBundle(sourceBundle, {
      expectedVersion: release.version,
      expectedMinimumSystemVersion: release.minimumSystemVersion,
      runCommand: commandRunner,
    });
    throwIfInterrupted();

    progress(`Installing into ${installDirectory}`);
    const installed = await installAtomically({
      sourceBundle,
      installDirectory,
      release,
      replaceExisting: replace,
      runCommand: commandRunner,
    });

    let openWarning = null;
    if (open) {
      try {
        await openApplication(installed.destination, commandRunner);
      } catch (error) {
        openWarning = error.message;
      }
    }

    return {
      status: "installed",
      version: release.version,
      destination: installed.destination,
      checks: [
        "SHA-256",
        "Sparkle Ed25519",
        "Developer ID",
        "Gatekeeper",
      ],
      backupRetained: installed.backupRetained,
      openWarning,
    };
  } catch (error) {
    primaryError = error;
    throw error;
  } finally {
    let cleanupError = null;
    if (mounted) {
      try {
        await detachDMG(mountDirectory, commandRunner);
      } catch (error) {
        cleanupError = error;
      }
    }
    try {
      await rm(tempDirectory, { recursive: true, force: true });
    } catch (error) {
      cleanupError ??= error;
    }
    process.off("SIGINT", handleInterrupt);
    process.off("SIGTERM", handleInterrupt);
    if (cleanupError) {
      if (primaryError) {
        throw new Error(
          `${primaryError.message}; cleanup also failed: ${cleanupError.message}`,
          { cause: primaryError },
        );
      }
      throw new Error(`Installation succeeded, but cleanup failed: ${cleanupError.message}`);
    }
  }
}
