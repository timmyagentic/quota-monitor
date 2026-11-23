import { readFile, readdir, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";

// Collect notices from the exact dependency files esbuild included in this bundle.
export async function writeLicenses(meta, directory, destination) {
  const packages = new Map();
  for (const input of Object.keys(meta.inputs)) {
    const full = resolve(directory, input);
    const pos = full.lastIndexOf("/node_modules/");
    if (pos < 0) continue;
    const parts = full.slice(pos + "/node_modules/".length).split("/");
    const name = parts[0].startsWith("@")
      ? parts.slice(0, 2).join("/")
      : parts[0];
    packages.set(name, join(full.slice(0, pos), "node_modules", name));
  }
  const notices = [];
  for (const [name, root] of [...packages].sort(([a], [b]) =>
    a.localeCompare(b),
  )) {
    const manifest = JSON.parse(
      await readFile(join(root, "package.json"), "utf8"),
    );
    const files = (await readdir(root))
      .filter((f) => /^(license|licence|notice)(\.|$)/i.test(f))
      .sort();
    const text = await Promise.all(
      files.map((f) => readFile(join(root, f), "utf8").catch(() => "")),
    );
    notices.push(
      [
        name + " " + manifest.version,
        typeof manifest.license === "string" ? manifest.license : "",
        ...text.map((s) => s.trimEnd()),
      ]
        .filter(Boolean)
        .join("\n"),
    );
  }
  await writeFile(
    destination,
    notices.join("\n\n--------------------\n\n") + "\n",
  );
}
