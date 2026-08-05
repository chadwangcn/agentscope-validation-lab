import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

const backendProxy = {
  target: 'http://127.0.0.1:18280',
  rewrite: (path: string) => path.replace(/^\/lab/, ''),
};

export default defineConfig({
  base: '/lab/',
  plugins: [react()],
  server: {
    proxy: {
      '/lab/api': backendProxy,
      '/lab/health': backendProxy,
      '/lab/status': backendProxy,
      '/lab/ws': { ...backendProxy, target: 'ws://127.0.0.1:18280', ws: true },
    },
  },
});
