import { build } from "esbuild";
import { mkdir } from "node:fs/promises";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { writeLicenses } from "./write-licenses.mjs";

const directory = dirname(fileURLToPath(import.meta.url));
const assets = resolve(directory, "../public", "ui");
await mkdir(assets, { recursive: true });
const result = await build({
  absWorkingDir: directory,
  entryPoints: ["Controls.jsx"],
  outfile: join(assets, "controls.js"),
  bundle: true,
  minify: true,
  format: "esm",
  target: "es2022",
  jsx: "automatic",
  legalComments: "eof",
  metafile: true,
  define: { "process.env.NODE_ENV": '"production"' },
});
await writeLicenses(
  result.metafile,
  directory,
  join(assets, "controls.LICENSE.txt"),
);
