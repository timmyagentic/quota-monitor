import { writeFile } from "node:fs/promises";
import path from "node:path";

import { MAX_DMG_BYTES } from "./constants.js";
import { compareVersions, parseNumericVersion } from "./version.js";

function decodeXml(value) {
  return value.replace(
    /&(amp|quot|apos|lt|gt|#\d+|#x[\da-fA-F]+);/g,
    (entity, name) => {
      switch (name) {
        case "amp":
          return "&";
        case "quot":
          return '"';
        case "apos":
          return "'";
        case "lt":
          return "<";
        case "gt":
          return ">";
        default: {
          const codePoint = name.startsWith("#x")
            ? Number.parseInt(name.slice(2), 16)
            : Number.parseInt(name.slice(1), 10);
          return String.fromCodePoint(codePoint);
        }
      }
    },
  );
}

function readSingleTag(item, tagName) {
  const escaped = tagName.replace(":", "\\:");
  const pattern = new RegExp(
    `<${escaped}\\b[^>]*>([^<]*)<\\/${escaped}>`,
    "g",
  );
  const matches = [...item.matchAll(pattern)];
  if (matches.length !== 1) {
    throw new Error(`Appcast item must contain exactly one <${tagName}>`);
  }

  return decodeXml(matches[0][1].trim());
}

function readEnclosure(item) {
  const matches = [...item.matchAll(/<enclosure\b([^>]*)\/?\s*>/g)];
  if (matches.length !== 1) {
    throw new Error("Appcast item must contain exactly one enclosure");
  }

  const attributes = new Map();
  const attributePattern = /([A-Za-z_:][\w:.-]*)\s*=\s*"([^"]*)"/g;
  for (const match of matches[0][1].matchAll(attributePattern)) {
    if (attributes.has(match[1])) {
      throw new Error(`Duplicate enclosure attribute: ${match[1]}`);
    }
    attributes.set(match[1], decodeXml(match[2]));
  }

  for (const required of ["url", "length", "sparkle:edSignature"]) {
    if (!attributes.has(required)) {
      throw new Error(`Enclosure is missing ${required}`);
    }
  }

  return attributes;
}

function parseItem(item) {
  const version = readSingleTag(item, "sparkle:version");
  const shortVersion = readSingleTag(item, "sparkle:shortVersionString");
  const minimumSystemVersion = readSingleTag(
    item,
    "sparkle:minimumSystemVersion",
  );

  parseNumericVersion(version, "appcast version");
  parseNumericVersion(shortVersion, "appcast short version");
  parseNumericVersion(minimumSystemVersion, "minimum macOS version");
  if (version !== shortVersion) {
    throw new Error(
      `Appcast version mismatch: ${version} != ${shortVersion}`,
    );
  }

  const enclosure = readEnclosure(item);
  const expectedURL =
    `https://github.com/timmyagentic/quota-monitor/releases/download/` +
    `v${version}/QuotaMonitor-${version}.dmg`;
  if (enclosure.get("url") !== expectedURL) {
    throw new Error(`Unexpected release URL for ${version}`);
  }

  const lengthText = enclosure.get("length");
  if (!/^\d+$/.test(lengthText)) {
    throw new Error(`Invalid enclosure length for ${version}`);
  }
  const length = Number.parseInt(lengthText, 10);
  if (!Number.isSafeInteger(length) || length <= 0 || length > MAX_DMG_BYTES) {
    throw new Error(`Unsafe enclosure length for ${version}`);
  }

  const signature = enclosure.get("sparkle:edSignature");
  const signatureBytes = Buffer.from(signature, "base64");
  if (
    signatureBytes.length !== 64 ||
    signatureBytes.toString("base64") !== signature
  ) {
    throw new Error(`Invalid Sparkle signature for ${version}`);
  }

  return {
    version,
    minimumSystemVersion,
    url: expectedURL,
    checksumURL: `${expectedURL}.sha256`,
    filename: `QuotaMonitor-${version}.dmg`,
    length,
    signature,
  };
}

export function rejectUnsafeXML(xml) {
  if (typeof xml !== "string" || xml.trim() === "") {
    throw new Error("The appcast is empty");
  }
  if (/<!\s*(?:DOCTYPE|ENTITY)\b/i.test(xml)) {
    throw new Error("The appcast contains a forbidden DTD or entity declaration");
  }
}

export function parseValidatedItems(serializedItems, macOSVersion) {
  parseNumericVersion(macOSVersion, "macOS version");
  const itemMatches = [
    ...serializedItems.matchAll(/<item\b[^>]*>[\s\S]*?<\/item>/g),
  ];
  if (itemMatches.length === 0) {
    throw new Error("The appcast contains no release items");
  }

  const compatible = itemMatches
    .map((match) => parseItem(match[0]))
    .filter(
      (release) =>
        compareVersions(release.minimumSystemVersion, macOSVersion) <= 0,
    )
    .sort((left, right) => compareVersions(right.version, left.version));

  if (compatible.length === 0) {
    throw new Error(`No Quota Monitor release supports macOS ${macOSVersion}`);
  }

  return compatible[0];
}

export async function selectReleaseFromAppcast({
  xml,
  macOSVersion,
  tempDirectory,
  runCommand,
}) {
  rejectUnsafeXML(xml);
  const appcastPath = path.join(tempDirectory, "appcast.xml");
  await writeFile(appcastPath, xml, { encoding: "utf8", mode: 0o600 });
  const { stdout } = await runCommand("/usr/bin/xmllint", [
    "--nonet",
    "--xpath",
    "//*[local-name()='item']",
    appcastPath,
  ]);
  return parseValidatedItems(stdout, macOSVersion);
}
