# Quota Monitor installer

Install the latest delivered [Quota Monitor](https://github.com/timmyagentic/quota-monitor) macOS release:

```bash
npx --yes quotamonitor@latest install
```

The installer supports macOS 14 or later on Apple Silicon and requires Node.js
20.17 or later. It contains no application binary, has no dependencies or npm
lifecycle install scripts, and never uses `sudo`.

It resolves the newest compatible release from Quota Monitor's official
Appcast, then verifies all of the following before installing:

- the exact GitHub Release URL and byte length;
- the published SHA-256 checksum;
- the Appcast's pinned Sparkle Ed25519 signature;
- the DMG and app Developer ID signatures;
- the app bundle ID, version, distribution channel, and Team ID; and
- Apple's Gatekeeper assessment.

By default the app is installed in `/Applications`, or `~/Applications` when
the system Applications folder is not writable. An existing current version is
verified without being replaced. Replacing an older copy is always explicit:

```bash
npx --yes quotamonitor@latest install --replace
```

Quit Quota Monitor before using `--replace`. Other options:

```text
--app-dir <directory>  Install into a specific application directory
--no-open              Do not open Quota Monitor after installation
```

The npm installer version is independent from the Quota Monitor app version;
the installer reads the delivered release feed each time it runs. For manual
DMG installation, see the [project install section](https://github.com/timmyagentic/quota-monitor#install).
To delegate installation safely, use the
[AI-agent guide](https://github.com/timmyagentic/quota-monitor#install-with-an-ai-agent).
