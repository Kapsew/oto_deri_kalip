import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // Workspace paketleri kaynak TS olarak yayımlanıyor (main -> src/index.ts).
  // Vite sembolik bağlantıları çözüp kendisi derliyor; bu yüzden ayrıca
  // bir derleme adımı gerekmiyor. optimizeDeps'ten hariç tutmak, geliştirme
  // sırasında paket içi değişikliklerin anında yansımasını sağlıyor.
  optimizeDeps: {
    exclude: ["@odk/geometry", "@odk/patterns"],
  },
  build: {
    target: "es2022",
    sourcemap: true,
  },
});
