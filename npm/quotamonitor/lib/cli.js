import { createRequire } from "node:module";

import { APP_TEAM_ID } from "./constants.js";
import { installQuotaMonitor } from "./installer.js";

const require = createRequire(import.meta.url);
const { version: installerVersion } = require("../package.json");

const HELP = `Quota Monitor installer ${installerVersion}

Usage:
  quotamonitor install [--app-dir <directory>] [--replace] [--no-open]
  quotamonitor --help
  quotamonitor --version

The installer supports macOS 14+ on Apple Silicon. It never uses sudo and
verifies the release checksum, Sparkle signature, Developer ID, and Apple
Gatekeeper assessment before installing QuotaMonitor.app.
`;

class UsageError extends Error {}

export function parseArguments(args) {
  if (args.length === 0 || args[0] === "--help" || args[0] === "-h") {
    return { action: "help" };
  }
  if (args[0] === "--version" || args[0] === "-v") {
    if (args.length !== 1) {
      throw new UsageError("--version does not accept additional arguments");
    }
    return { action: "version" };
  }
  if (args[0] !== "install") {
    throw new UsageError(`Unknown command: ${args[0]}`);
  }

  const options = { action: "install", replace: false, open: true };
  for (let index = 1; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--replace") {
      options.replace = true;
    } else if (argument === "--no-open") {
      options.open = false;
    } else if (argument === "--app-dir") {
      const value = args[index + 1];
      if (!value || value.startsWith("--")) {
        throw new UsageError("--app-dir requires a directory");
      }
      options.appDirectory = value;
      index += 1;
    } else {
      throw new UsageError(`Unknown option: ${argument}`);
    }
  }
  return options;
}

export async function main(args, dependencies = {}) {
  let parsed;
  try {
    parsed = parseArguments(args);
  } catch (error) {
    if (error instanceof UsageError) {
      console.error(`Error: ${error.message}\n\n${HELP}`);
      return 2;
    }
    throw error;
  }

  if (parsed.action === "help") {
    console.log(HELP);
    return 0;
  }
  if (parsed.action === "version") {
    console.log(installerVersion);
    return 0;
  }

  const result = await installQuotaMonitor(parsed, dependencies);
  const verb = result.status === "already-current" ? "Verified" : "Installed";
  console.log(`\n✓ ${verb} Quota Monitor ${result.version}`);
  console.log(`  Path: ${result.destination}`);
  console.log(`  Checks: ${result.checks.join(", ")}`);
  console.log(`  Developer ID Team: ${APP_TEAM_ID}`);
  if (result.backupRetained) {
    console.warn(`  Warning: old-version backup retained at ${result.backupRetained}`);
  }
  if (result.openWarning) {
    console.warn(`  Warning: installed successfully but could not open the app: ${result.openWarning}`);
  }
  return 0;
}

export { HELP, installerVersion };
