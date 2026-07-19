import {
  createPublicKey,
  timingSafeEqual,
  verify as verifySignature,
} from "node:crypto";
import { readFile, stat } from "node:fs/promises";

import { SPARKLE_PUBLIC_KEY } from "./constants.js";

export function parseChecksumSidecar(text, expectedFilename) {
  const lines = text.split(/\r?\n/).filter((line) => line.trim() !== "");
  if (lines.length !== 1) {
    throw new Error("The checksum file must contain exactly one non-empty line");
  }

  const match = lines[0].match(/^([\da-fA-F]{64})[ \t]+\*?([A-Za-z0-9._-]+)$/);
  if (!match || match[2] !== expectedFilename) {
    throw new Error(`The checksum file does not name ${expectedFilename}`);
  }

  return match[1].toLowerCase();
}

export function assertChecksum(actual, expected) {
  const actualBytes = Buffer.from(actual, "hex");
  const expectedBytes = Buffer.from(expected, "hex");
  if (
    actualBytes.length !== 32 ||
    expectedBytes.length !== 32 ||
    !timingSafeEqual(actualBytes, expectedBytes)
  ) {
    throw new Error("SHA-256 verification failed");
  }
}

export async function verifySparkleSignature(
  filePath,
  signatureBase64,
  expectedBytes,
) {
  const fileInfo = await stat(filePath);
  if (fileInfo.size !== expectedBytes) {
    throw new Error(
      `Sparkle verification size mismatch: expected ${expectedBytes}, received ${fileInfo.size}`,
    );
  }

  const rawPublicKey = Buffer.from(SPARKLE_PUBLIC_KEY, "base64");
  const spkiPrefix = Buffer.from("302a300506032b6570032100", "hex");
  const publicKey = createPublicKey({
    key: Buffer.concat([spkiPrefix, rawPublicKey]),
    format: "der",
    type: "spki",
  });
  const signature = Buffer.from(signatureBase64, "base64");
  const contents = await readFile(filePath);

  if (!verifySignature(null, contents, publicKey, signature)) {
    throw new Error("Sparkle Ed25519 signature verification failed");
  }
}
