export const ADMIN_AUTHORIZATION_MAX_BYTES = 1_024;

const BASIC_PREFIX = "Basic ";
const BASIC_VALUE_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });

export interface AdminAuthCrypto {
  digest(bytes: Uint8Array): Promise<ArrayBuffer>;
  timingSafeEqual(left: ArrayBuffer, right: ArrayBuffer): boolean;
  decode?: (base64: string) => Uint8Array;
}

function decodeBase64(value: string): Uint8Array {
  const decoded = atob(value);
  const bytes = new Uint8Array(decoded.length);
  for (let index = 0; index < decoded.length; index += 1) {
    bytes[index] = decoded.charCodeAt(index);
  }
  return bytes;
}

function suppliedCredentials(
  authorization: string | null,
  decode: (base64: string) => Uint8Array,
): string {
  if (
    authorization === null ||
    encoder.encode(authorization).byteLength > ADMIN_AUTHORIZATION_MAX_BYTES ||
    !authorization.startsWith(BASIC_PREFIX)
  ) {
    return "";
  }

  const encoded = authorization.slice(BASIC_PREFIX.length);
  if (!BASIC_VALUE_PATTERN.test(encoded)) {
    return "";
  }

  try {
    const decoded = decoder.decode(decode(encoded));
    const separator = decoded.indexOf(":");
    if (separator < 1) {
      return "";
    }
    return decoded;
  } catch {
    return "";
  }
}

function defaultCrypto(): AdminAuthCrypto {
  return {
    digest: (bytes) => crypto.subtle.digest("SHA-256", bytes),
    timingSafeEqual: (left, right) => crypto.subtle.timingSafeEqual(left, right),
  };
}

export async function verifyAdminAuthorization(
  authorization: string | null,
  secret: string,
  authCrypto: AdminAuthCrypto = defaultCrypto(),
): Promise<boolean> {
  const supplied = suppliedCredentials(
    authorization,
    authCrypto.decode ?? decodeBase64,
  );
  const expected = `admin:${secret}`;
  const [suppliedHash, expectedHash] = await Promise.all([
    authCrypto.digest(encoder.encode(supplied)),
    authCrypto.digest(encoder.encode(expected)),
  ]);
  return authCrypto.timingSafeEqual(suppliedHash, expectedHash);
}
