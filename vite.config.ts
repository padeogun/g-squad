/// <reference types="vitest/config" />
// Vite builds the app; Vitest (configured below) runs the unit tests in a simulated browser.
import react from '@vitejs/plugin-react';
import { defineConfig, loadEnv } from 'vite';
import { isSecretKey } from './src/lib/env.ts';

export default defineConfig(({ mode }) => {
  // SECURITY REVIEW FIX J01: stop the build if any VITE_* variable (from .env files or the
  // Netlify/CI environment) holds a Supabase secret or service-role key. VITE_* values can
  // end up in the public bundle, and the check in src/lib/env.ts only runs in the browser,
  // after the key has already been published.
  const viteEnv = loadEnv(mode, process.cwd(), 'VITE_');
  for (const [name, value] of Object.entries(viteEnv)) {
    if (isSecretKey(value)) {
      throw new Error(`${name} holds a Supabase secret key. Only the publishable key may be used in VITE_* variables.`);
    }
  }

  return {
    plugins: [react()],
    build: {
      // No source maps in production: the code is reviewable on GitHub instead.
      sourcemap: false,
    },
    test: {
      environment: 'jsdom',
      setupFiles: ['./src/test/setup.ts'],
      // Tests get dummy Supabase settings; no network calls are made.
      env: {
        VITE_SUPABASE_URL: 'https://example.supabase.co',
        VITE_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_test',
      },
    },
  };
});
