import { constants as fsConstants } from "node:fs";
import { access, lstat, mkdir, realpath } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { APP_NAME, MINIMUM_MACOS_VERSION } from "./constants.js";
import { compareVersions, parseNumericVersion } from "./version.js";

async function pathExists(value) {
  try {
    await lstat(value);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") {
      return false;
    }
    throw error;
  }
}

async function canonicalWritableDirectory(directory) {
  await mkdir(directory, { recursive: true, mode: 0o755 });
  const info = await lstat(directory);
  if (!info.isDirectory() || info.isSymbolicLink()) {
    throw new Error(`Installation directory is not a real directory: ${directory}`);
  }
  await access(directory, fsConstants.W_OK);
  return realpath(directory);
}

export function assertSupportedPlatform({
  platform = process.platform,
  userID = typeof process.getuid === "function" ? process.getuid() : null,
} = {}) {
  if (userID === 0) {
    throw new Error("Do not run this installer with sudo or as root");
  }
  if (platform !== "darwin") {
    throw new Error("Quota Monitor can only be installed on macOS");
  }
}

export async function assertAppleSilicon(runCommand) {
  const { stdout } = await runCommand("/usr/sbin/sysctl", [
    "-n",
    "hw.optional.arm64",
  ]);
  if (stdout.trim() !== "1") {
    throw new Error("The current Quota Monitor release requires Apple Silicon");
  }
}

export async function readMacOSVersion(runCommand) {
  const { stdout } = await runCommand("/usr/bin/sw_vers", ["-productVersion"]);
  const version = stdout.trim();
  parseNumericVersion(version, "macOS version");
  if (compareVersions(version, MINIMUM_MACOS_VERSION) < 0) {
    throw new Error(
      `Quota Monitor requires macOS ${MINIMUM_MACOS_VERSION} or later; this Mac runs ${version}`,
    );
  }
  return version;
}

export async function resolveInstallDirectory(requestedDirectory) {
  if (requestedDirectory) {
    return canonicalWritableDirectory(path.resolve(requestedDirectory));
  }

  const systemDirectory = "/Applications";
  const userDirectory = path.join(os.homedir(), "Applications");
  const systemApp = path.join(systemDirectory, APP_NAME);
  const userApp = path.join(userDirectory, APP_NAME);
  const [systemExists, userExists] = await Promise.all([
    pathExists(systemApp),
    pathExists(userApp),
  ]);

  if (systemExists && userExists) {
    throw new Error(
      `Quota Monitor exists in both ${systemDirectory} and ${userDirectory}; remove one copy or pass --app-dir`,
    );
  }
  if (systemExists) {
    return canonicalWritableDirectory(systemDirectory);
  }
  if (userExists) {
    return canonicalWritableDirectory(userDirectory);
  }

  try {
    return await canonicalWritableDirectory(systemDirectory);
  } catch (error) {
    if (error?.code !== "EACCES" && error?.code !== "EPERM") {
      throw error;
    }
    return canonicalWritableDirectory(userDirectory);
  }
}

export { pathExists };
