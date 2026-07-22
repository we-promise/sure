import { defineConfig } from "vite";
import { resolve } from "path";

export default defineConfig({
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: {
    target: "safari15",
    outDir: "dist",
    emptyOutDir: true,
    rollupOptions: {
      input: {
        main: resolve(__dirname, "index.html"),
        bridge: resolve(__dirname, "src/bridge.ts"),
      },
      output: {
        entryFileNames: (chunk) => (chunk.name === "bridge" ? "bridge.js" : "assets/[name]-[hash].js"),
        format: "es",
      },
    },
  },
});
