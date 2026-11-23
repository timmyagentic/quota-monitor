import { readFile, writeFile, mkdir, rm } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { resolve, join, basename } from "node:path";
import { execFileSync } from "node:child_process";
import { build } from "esbuild";
import { writeLicenses } from "./write-licenses.mjs";
import { createHash } from "node:crypto";

const here = fileURLToPath(new URL(".", import.meta.url));

const settings = JSON.parse(await readFile(join(here, "build.json"), "utf8"));
const dest = resolve(here, settings.publicDirectory);
const output = join(dest, "product-ui");
await mkdir(output, { recursive: true });
const shim = join(here, ".render.mjs");
try {
  await build({
    entryPoints: [join(here, "render.jsx")],
    outfile: shim,
    format: "esm",
    bundle: true,
    platform: "node",
    packages: "external",
    jsx: "automatic",
    logLevel: "silent",
  });
  const { render } = await import(pathToFileURL(shim).href);
  const styles = new Map(),
    files = new Map();
  for (const name of ["index", ...(settings.documents || [])]) {
    const template =
      name === "index" ? "template.html" : "pages/" + name + ".html";
    const html = (await readFile(join(here, template), "utf8")).replace(
      /<!--product:([a-z-]+)-->/g,
      (_, part) => {
        const fragment = render(part).replace(
          / style="([^"]*)"/g,
          (_attribute, value) => {
            const id = createHash("sha256")
              .update(value)
              .digest("hex")
              .slice(0, 12);
            styles.set(id, value);
            return ' data-product-initial-style="' + id + '"';
          },
        );
        return (
          '<div class="pi-surface" data-product-surface="' +
          part +
          '">' +
          fragment +
          "</div>"
        );
      },
    );
    files.set(name + ".html", html);
  }
  const browserBuild = await build({
    metafile: true,
    entryPoints: [join(here, "client.jsx")],
    outfile: join(output, "product.js"),
    format: "esm",
    bundle: true,
    minify: true,
    legalComments: "eof",
    target: "es2022",
    jsx: "automatic",
    define: { "process.env.NODE_ENV": '"production"' },
    plugins: [
      {
        name: "external-sonner-styles",
        setup(ctx) {
          ctx.onLoad(
            { filter: /sonner[/\\]dist[/\\]index\.mjs$/ },
            async (args) => {
              const code = await readFile(args.path, "utf8");
              // The stylesheet is served from the same origin. Avoid Sonner's duplicate inline style under CSP.
              return {
                contents: code.replace(/^__insertCSS\([^\n]+\);?$/m, ""),
                loader: "js",
              };
            },
          );
        },
      },
    ],
  });
  await writeLicenses(
    browserBuild.metafile,
    here,
    join(output, "licenses.txt"),
  );
  const cli = join(here, "node_modules/.bin/tailwindcss");
  execFileSync(
    process.execPath,
    [
      cli,
      "-i",
      join(here, "style.css"),
      "-o",
      join(output, "product.css"),
      "--minify",
    ],
    { cwd: here, stdio: "pipe" },
  );
  const cssFile = join(output, "product.css");
  const dynamicCss = [...styles]
    .map(
      ([id, rule]) => '[data-product-initial-style="' + id + '"]{' + rule + "}",
    )
    .join("\n");
  await writeFile(
    cssFile,
    [(await readFile(cssFile, "utf8")).trimEnd(), dynamicCss].filter(Boolean).join("\n") + "\n",
  );
  const integrity =
    "sha384-" +
    createHash("sha384")
      .update(await readFile(join(output, "product.js")))
      .digest("base64");
  if (settings.key === "mailintro") {
    const headers = await readFile(join(here, "headers.template"), "utf8");
    await writeFile(
      join(dest, "_headers"),
      headers.replace("script-src 'none'", "script-src '" + integrity + "'"),
    );
  }
  for (const [name, html] of files)
    await writeFile(
      join(dest, name),
      html.replace("__PRODUCT_INTEGRITY__", integrity),
    );
  console.log(basename(dest) + "/index.html and product-ui assets built");
} finally {
  await rm(shim, { force: true });
}
