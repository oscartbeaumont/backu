import { defineConfig } from "cf/config";

/**
 * The landing page: the Solid SSR output in `dist/server` served behind the
 * client bundle, which `@solidjs/vite-plugin` and `wrangler.config.ts` place in
 * `dist/client`.
 */
export default defineConfig({
  worker: {
    name: "backu",
    compatibilityDate: "2026-11-17",
    compatibilityFlags: ["nodejs_compat"],
    entrypoint: "dist/server/server.js",
    workersDev: false,
    previewUrls: true,
    observability: {
      enabled: true,
    },
    assets: {
      notFoundHandling: "none",
    },
    domains: ["backu.otbeaumont.me"],
  },
});
