import { createHash } from "node:crypto";
import { open, rm } from "node:fs/promises";

const USER_AGENT = "quotamonitor-installer/0.1 (+https://github.com/timmyagentic/quota-monitor)";

function assertAllowedURL(value, allowedHosts) {
  const url = new URL(value);
  if (
    url.protocol !== "https:" ||
    url.username !== "" ||
    url.password !== "" ||
    url.port !== "" ||
    !allowedHosts.has(url.hostname)
  ) {
    throw new Error(`Refusing untrusted download URL: ${url.href}`);
  }
  return url;
}

async function fetchWithRedirects(initialURL, { allowedHosts, signal }) {
  let currentURL = assertAllowedURL(initialURL, allowedHosts);

  for (let redirects = 0; redirects <= 5; redirects += 1) {
    const response = await fetch(currentURL, {
      redirect: "manual",
      signal,
      headers: {
        Accept: "application/octet-stream, application/xml, text/plain",
        "User-Agent": USER_AGENT,
      },
    });

    if (response.status >= 300 && response.status < 400) {
      if (redirects === 5) {
        throw new Error(`Too many redirects while downloading ${initialURL}`);
      }
      const location = response.headers.get("location");
      if (!location) {
        throw new Error(`Redirect from ${currentURL.href} has no location`);
      }
      currentURL = assertAllowedURL(new URL(location, currentURL), allowedHosts);
      continue;
    }

    if (!response.ok) {
      throw new Error(
        `Download failed with HTTP ${response.status}: ${currentURL.href}`,
      );
    }

    return response;
  }

  throw new Error(`Unable to download ${initialURL}`);
}

function contentLength(response) {
  const value = response.headers.get("content-length");
  if (value === null) {
    return null;
  }
  if (!/^\d+$/.test(value)) {
    throw new Error("The server returned an invalid Content-Length");
  }
  return Number.parseInt(value, 10);
}

async function withTimeout(operation, timeoutMs) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  timeout.unref?.();
  try {
    return await operation(controller.signal);
  } catch (error) {
    if (controller.signal.aborted) {
      throw new Error(`Download timed out after ${timeoutMs / 1000} seconds`);
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

export async function getText(
  url,
  { allowedHosts, maxBytes, timeoutMs = 30_000 },
) {
  return withTimeout(async (signal) => {
    const response = await fetchWithRedirects(url, { allowedHosts, signal });
    const declaredLength = contentLength(response);
    if (declaredLength !== null && declaredLength > maxBytes) {
      throw new Error(`Response exceeds the ${maxBytes}-byte safety limit`);
    }
    if (!response.body) {
      throw new Error("The server returned an empty response body");
    }

    const chunks = [];
    let bytes = 0;
    for await (const chunk of response.body) {
      const buffer = Buffer.from(chunk);
      bytes += buffer.length;
      if (bytes > maxBytes) {
        throw new Error(`Response exceeds the ${maxBytes}-byte safety limit`);
      }
      chunks.push(buffer);
    }

    return Buffer.concat(chunks).toString("utf8");
  }, timeoutMs);
}

export async function downloadFile(
  url,
  destination,
  {
    allowedHosts,
    expectedBytes,
    maxBytes,
    timeoutMs = 120_000,
  },
) {
  try {
    return await withTimeout(async (signal) => {
      const response = await fetchWithRedirects(url, { allowedHosts, signal });
      const declaredLength = contentLength(response);
      if (declaredLength !== null && declaredLength > maxBytes) {
        throw new Error(`Download exceeds the ${maxBytes}-byte safety limit`);
      }
      if (
        expectedBytes !== undefined &&
        declaredLength !== null &&
        declaredLength !== expectedBytes
      ) {
        throw new Error(
          `Content-Length mismatch: expected ${expectedBytes}, received ${declaredLength}`,
        );
      }
      if (!response.body) {
        throw new Error("The server returned an empty response body");
      }

      const file = await open(destination, "wx", 0o600);
      const hash = createHash("sha256");
      let bytes = 0;
      try {
        for await (const chunk of response.body) {
          const buffer = Buffer.from(chunk);
          bytes += buffer.length;
          if (bytes > maxBytes) {
            throw new Error(`Download exceeds the ${maxBytes}-byte safety limit`);
          }
          if (expectedBytes !== undefined && bytes > expectedBytes) {
            throw new Error(`Download is larger than the expected ${expectedBytes} bytes`);
          }
          hash.update(buffer);

          let offset = 0;
          while (offset < buffer.length) {
            const { bytesWritten } = await file.write(
              buffer,
              offset,
              buffer.length - offset,
            );
            if (bytesWritten === 0) {
              throw new Error("Unable to write the downloaded file");
            }
            offset += bytesWritten;
          }
        }
      } finally {
        await file.close();
      }

      if (expectedBytes !== undefined && bytes !== expectedBytes) {
        throw new Error(
          `Download size mismatch: expected ${expectedBytes}, received ${bytes}`,
        );
      }

      return { bytes, sha256: hash.digest("hex") };
    }, timeoutMs);
  } catch (error) {
    await rm(destination, { force: true }).catch(() => {});
    throw error;
  }
}

export { assertAllowedURL };
