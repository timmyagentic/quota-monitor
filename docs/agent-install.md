# Quota Monitor AI-agent installation guide

Use this runbook only when a user explicitly asks you to install Quota Monitor
on their Mac. The goal is a verified installation of the latest official
release, not a general machine setup.

## Safety boundaries

- Do not use `sudo`, run as root, install a package manager, or change shell
  startup files.
- Do not read or modify API keys, Keychain items, browser data, Codex or Claude
  credentials, `~/.codex`, `~/.claude`, or existing Quota Monitor history.
- Do not replace an existing `QuotaMonitor.app` until you have shown its path
  and version to the user and received confirmation.
- Stop and report the exact failure if platform, download, checksum, signature,
  Gatekeeper, or bundle verification fails. Never claim partial success.

## Procedure

1. Confirm the Mac is running macOS 14 or later on Apple Silicon. The official
   Developer ID release is currently arm64-only.
2. Confirm `node`, `npm`, and `npx` are already available. If they are not, ask
   whether the user wants to use the [manual notarized DMG](https://github.com/timmyagentic/quota-monitor#dmg)
   instead; do not install Node.js or Homebrew without separate permission. If
   they approve the DMG path, follow that section, verify its published checksum,
   then report the installed app's Developer ID and Gatekeeper result.
3. Run the explicit installer command:

   ```bash
   npx --yes quotamonitor@latest install
   ```

4. For a new or replacement install, the installer must report all four checks:
   SHA-256, Sparkle Ed25519, Developer ID, and Gatekeeper. If the current version
   is already installed, it performs no download and must report only the
   Developer ID and Gatekeeper checks it actually reruns. It installs into
   `/Applications` when writable and otherwise into `~/Applications`.
5. If it reports an older existing copy, show the user the version and path.
   After the user confirms replacement, make sure Quota Monitor is not running
   and rerun:

   ```bash
   npx --yes quotamonitor@latest install --replace
   ```

6. Report the final app version, absolute installation path, Developer ID Team
   ID (`4356B4HF9R`), and successful Gatekeeper result. Open the app unless the
   user asked you not to.

The npm package contains no app binary and no npm lifecycle install script. It
downloads only the version published in the official Quota Monitor Appcast and
pins the release repository, filename, Sparkle public key, bundle identifier,
distribution channel, and Developer ID Team ID.
