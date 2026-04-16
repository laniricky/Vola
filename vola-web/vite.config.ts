import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  // Prevent Vite from obscuring Rust errors
  clearScreen: false,
  server: {
    // Tauri expects a fixed port, fail if that port is not available
    port: 5173,
    strictPort: true,
  },
  // To access the Tauri environment variables set by the CLI with information about the current target
  envPrefix: ['VITE_', 'TAURI_'],
});
