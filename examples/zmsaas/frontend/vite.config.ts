import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { solidStart } from '@solidjs/start/config';
import tailwindcss from '@tailwindcss/vite';
import { nitro } from 'nitro/vite';
import { defineConfig } from 'vite';

const rootDir = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [
    solidStart({
      middleware: './src/middleware.ts',
    }),
    tailwindcss(),
    nitro(),
  ],
  resolve: {
    alias: {
      '@': resolve(rootDir, './src'),
      '~': resolve(rootDir, './src'),
    },
  },
  server: {
    port: 3000,
  },
});
