# Quota Monitor AI-agent installation guide

Use this runbook only when a user explicitly asks you to install Quota Monitor
on their Mac. The goal is a verified installation of the latest official
release and the first usable quota reading. Preserve the user's existing settings,
provider accounts and history. Execute the applicable steps rather than only
returning commands.

## Safety boundaries

- Do not use `sudo`, run as root, install a package manager, or change shell
  startup files.
- Do not directly read or modify API keys, Keychain items, browser data, Codex
  or Claude credential files, `~/.codex`, `~/.claude`, or existing Quota Monitor
  history. Let the official provider client and Quota Monitor handle login.
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
   they choose the DMG path, follow that section, verify its published checksum,
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

## First usable quota

7. In first-run setup, choose the provider the user actually uses: Codex, Claude
   Code, or both. Use the current Agent/session context when that choice is clear.
   On an existing installation, retain its provider and display preferences.
8. Check the selected provider's availability in Quota Monitor. It can discover
   standalone CLIs and supported bundled desktop clients; do not install a second
   copy merely because a command is missing from the shell PATH. If the selected
   client or login is missing, guide the user through its official setup/login.
   The user handles browser authentication and OS authorization. Never request
   tokens in chat, copy credentials from another device, or replace an existing
   account to make the check pass.
9. Refresh once through the app and inspect the selected provider's status and
   actual quota window/percentage/reset information in the menu-bar popover or
   Dashboard. A missing provider window is not zero quota. An empty new history
   is valid; it is separate from live quota availability. Report authentication,
   rate-limit, network or unsupported-provider errors explicitly, and respect any
   displayed retry interval rather than repeatedly refreshing.
10. Close the main window and verify the menu-bar app remains available. If the
    user wants launch at login, use the app's setting and inspect the system's
    reported status. Do not claim reboot or sleep/wake testing from that setting.

Report installation/signature verification, provider setup, the first live quota
reading and menu-bar operation separately. If the user postpones login or a
required permission, report installation as complete and live quota as
UNVERIFIED; do not present an empty or fixture Dashboard as a real account result.

For isolated download/installation acceptance, the installer supports
`--app-dir <new-empty-directory> --no-open`. Do not open a second normal copy
against the user's existing profile. The repository's isolated UI QA deliberately
blocks live provider requests and Keychain access; fixture QA cannot certify
first login or a live quota response. Use a separate macOS user or clean test
system for that acceptance.
