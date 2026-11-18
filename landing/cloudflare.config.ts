import { defineConfig } from "cf/config";

/**
 * The landing page: Solid's start-mode SSR handler, served by the Worker, with
 * the client bundle that `@cloudflare/vite-plugin` builds alongside it.
 */
export default defineConfig({
  worker: {
    name: "backu",
    compatibilityDate: "2026-11-17",
    compatibilityFlags: ["nodejs_compat"],
    entrypoint: "virtual:solid-ssr-handler",
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
