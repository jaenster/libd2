import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // The wasm is ~2 MB of embedded game tables; keep it a plain public asset so it is fetched once
  // and cached by URL rather than inlined or hashed into a bundle.
  assetsInclude: ["**/*.wasm"],
  server: { port: 5174 },
});
