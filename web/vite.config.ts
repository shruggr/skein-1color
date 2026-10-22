// The two pages, built into ../www (committed: the tree is what an embedding
// app copies and a skein serves; nothing is built on the skein).
//
//   npm ci
//   SKEIN_DIR=../../skein npm run build     a skein checkout at lib/SKEIN_REV
//
// The owner's message to the instance is skein's own BRC-104 client
// (src/client/raw.ts `RawBox`, as skein-site bundles it), read from
// $SKEIN_DIR; its `node:crypto` is skein's browser shim (web/shims). Every
// package resolves from this directory's node_modules (package-lock.json).
// The one @1sat/actions action used (deploy1Color) is imported by file:
// the package entry re-exports every action (skein-site does the same).
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

const here = fileURLToPath(new URL(".", import.meta.url));
const skein = resolve(process.env.SKEIN_DIR ?? resolve(here, "../../skein"));
const rev = readFileSync(resolve(here, "lib/SKEIN_REV"), "utf8").trim();
if (!existsSync(resolve(skein, "src/client/raw.ts"))) {
  throw new Error(`${skein}: not a skein checkout (set SKEIN_DIR; lib/SKEIN_REV names the commit: ${rev})`);
}

export default defineConfig({
  // Relative: the pages are served under /<app>/color/ on any instance.
  base: "./",
  plugins: [react()],
  resolve: {
    alias: [
      { find: /^skein\//, replacement: skein + "/" },
      { find: /^node:crypto$/, replacement: resolve(skein, "web/shims/crypto.ts") },
      { find: /^@1sat-actions\//, replacement: resolve(here, "node_modules/@1sat/actions/dist") + "/" },
    ],
    dedupe: ["@bsv/sdk", "@ipld/dag-cbor", "multiformats", "react", "react-dom"],
  },
  build: {
    outDir: resolve(here, "../www"),
    emptyOutDir: true,
    assetsDir: "assets",
    sourcemap: false,
    // @1sat/connect is one prebuilt file of about 2 MB (README "Pages").
    chunkSizeWarningLimit: 2500,
    rollupOptions: {
      input: {
        deploy: resolve(here, "deploy/index.html"),
        tokens: resolve(here, "tokens/index.html"),
      },
    },
  },
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
  },
});
