import { defineConfig } from "vite";
import solid from "@solidjs/vite-plugin";

export default defineConfig({
  plugins: [
    solid({
      // Solid 2 start mode: the plugin owns entries, dev/preview serving and
      // the production build. `nodeServer` emits a runnable Node handler.
      start: { nodeServer: true },
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
