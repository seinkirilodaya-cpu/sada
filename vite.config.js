import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Pengaturan build standar Vite + React.
// Port ikut variabel PORT kalau disediakan (mis. oleh alat pratinjau),
// supaya tidak bentrok kalau 5173 sedang dipakai proses lain.
export default defineConfig({
  plugins: [react()],
  server: {
    port: Number(process.env.PORT) || 5173,
  },
});
