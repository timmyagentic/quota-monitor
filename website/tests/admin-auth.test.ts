import { describe, expect, it, vi } from "vitest";
import {
  ADMIN_AUTHORIZATION_MAX_BYTES,
  verifyAdminAuthorization,
  type AdminAuthCrypto,
} from "../src/admin-auth";

const SECRET = "correct horse battery staple";

function basic(username: string, password: string): string {
  return `Basic ${btoa(`${username}:${password}`)}`;
}

function recordingCrypto(): {
  crypto: AdminAuthCrypto;
  digested: string[];
  compared: Uint8Array[][];
} {
  const digested: string[] = [];
  const compared: Uint8Array[][] = [];

  return {
    digested,
    compared,
    crypto: {
      async digest(bytes: Uint8Array): Promise<ArrayBuffer> {
        digested.push(new TextDecoder().decode(bytes));
        const result = new Uint8Array(32);
        result.fill(digested.length === 1 ? 0x11 : 0x22);
        if (digested[0] === digested[1]) {
          result.fill(0x11);
        }
        return result.buffer;
      },
      timingSafeEqual(left: ArrayBuffer, right: ArrayBuffer): boolean {
        const leftBytes = new Uint8Array(left);
        const rightBytes = new Uint8Array(right);
        compared.push([leftBytes, rightBytes]);
        return leftBytes.length === rightBytes.length &&
          leftBytes.every((value, index) => value === rightBytes[index]);
      },
    },
  };
}

describe("maintainer Basic authentication", () => {
  it("accepts only the fixed admin username and configured secret", async () => {
    const valid = recordingCrypto();
    const wrongUser = recordingCrypto();
    const wrongSecret = recordingCrypto();

    await expect(
      verifyAdminAuthorization(basic("admin", SECRET), SECRET, valid.crypto),
    ).resolves.toBe(true);
    await expect(
      verifyAdminAuthorization(basic("maintainer", SECRET), SECRET, wrongUser.crypto),
    ).resolves.toBe(false);
    await expect(
      verifyAdminAuthorization(basic("admin", "wrong"), SECRET, wrongSecret.crypto),
    ).resolves.toBe(false);

    expect(valid.digested).toEqual([`admin:${SECRET}`, `admin:${SECRET}`]);
  });

  it("SHA-256 hashes both supplied and expected credentials before one constant-time comparison", async () => {
    const recording = recordingCrypto();

    await verifyAdminAuthorization(
      basic("admin", "incorrect"),
      SECRET,
      recording.crypto,
    );

    expect(recording.digested).toEqual([
      "admin:incorrect",
      `admin:${SECRET}`,
    ]);
    expect(recording.compared).toHaveLength(1);
    expect(recording.compared[0]?.[0]).toHaveLength(32);
    expect(recording.compared[0]?.[1]).toHaveLength(32);
  });

  it.each([
    ["missing header", null],
    ["empty header", ""],
    ["wrong scheme", basic("admin", SECRET).replace("Basic", "Bearer")],
    ["missing base64", "Basic"],
    ["invalid base64 alphabet", "Basic !!!"],
    ["invalid UTF-8", `Basic ${btoa(String.fromCharCode(0xff))}`],
    ["missing separator", `Basic ${btoa("admin")}`],
    ["empty username", basic("", SECRET)],
  ])("rejects a malformed %s without throwing", async (_label, authorization) => {
    const recording = recordingCrypto();

    await expect(
      verifyAdminAuthorization(authorization, SECRET, recording.crypto),
    ).resolves.toBe(false);
    expect(recording.digested).toHaveLength(2);
    expect(recording.compared).toHaveLength(1);
  });

  it("rejects an oversized Authorization value before decoding it", async () => {
    const recording = recordingCrypto();
    const decode = vi.fn(() => {
      throw new Error("oversized input must not be decoded");
    });
    const authorization = `Basic ${"A".repeat(ADMIN_AUTHORIZATION_MAX_BYTES)}`;

    await expect(
      verifyAdminAuthorization(authorization, SECRET, {
        ...recording.crypto,
        decode,
      }),
    ).resolves.toBe(false);

    expect(decode).not.toHaveBeenCalled();
    expect(recording.digested).toHaveLength(2);
    expect(recording.compared).toHaveLength(1);
  });
});
