export function parseNumericVersion(value, label = "version") {
  if (typeof value !== "string" || !/^\d+(?:\.\d+){1,3}$/.test(value)) {
    throw new Error(`Invalid ${label}: ${String(value)}`);
  }

  return value.split(".").map((part) => Number.parseInt(part, 10));
}

export function parseBuildVersion(value, label = "build version") {
  if (typeof value !== "string" || !/^\d+(?:\.\d+){0,3}$/.test(value)) {
    throw new Error(`Invalid ${label}: ${String(value)}`);
  }

  const parts = value.split(".").map((part) => Number.parseInt(part, 10));
  if (parts.some((part) => !Number.isSafeInteger(part))) {
    throw new Error(`Invalid ${label}: ${String(value)}`);
  }
  return parts;
}

export function compareBuildVersions(left, right) {
  const leftParts = parseBuildVersion(left);
  const rightParts = parseBuildVersion(right);
  const length = Math.max(leftParts.length, rightParts.length);

  for (let index = 0; index < length; index += 1) {
    const difference = (leftParts[index] ?? 0) - (rightParts[index] ?? 0);
    if (difference !== 0) {
      return difference < 0 ? -1 : 1;
    }
  }
  return 0;
}

export function compareVersions(left, right) {
  const leftParts = parseNumericVersion(left);
  const rightParts = parseNumericVersion(right);
  const length = Math.max(leftParts.length, rightParts.length);

  for (let index = 0; index < length; index += 1) {
    const difference = (leftParts[index] ?? 0) - (rightParts[index] ?? 0);
    if (difference !== 0) {
      return difference < 0 ? -1 : 1;
    }
  }

  return 0;
}
