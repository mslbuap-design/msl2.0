import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    // host:true expone el dev server en la red local, igual que el
    // auto-detect de IP que usa services/api.js para encontrar el backend.
    host: true,
    port: 3000,
  },
  build: {
    outDir: 'dist',
    sourcemap: false,
  },
});
