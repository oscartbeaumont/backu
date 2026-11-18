import { cloudflare } from "@cloudflare/vite-plugin";
import solid from "@solidjs/vite-plugin";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [
    // The Cloudflare plugin owns the Worker build, including the client
    // assets: Solid's start-mode SSR bundle is exposed as the `ssr`
    // environment's entry, so `cloudflare.config.ts` can point at
    // `virtual:solid-ssr-handler` and there is no separate assets directory.
    cloudflare({ viteEnvironment: { name: "ssr" } }),
    solid({
      start: true,
      ssr: true,
      extensions: [".jsx", ".tsx"],
    }),
  ],
  server: {
    port: 3000,
  },
  build: {
    target: "esnext",
    assetsInlineLimit: 0,
  },
});
