// -------------------------------------------------------------------------------------
// The one Supabase client the app uses, typed against the database schema.
// database.types.ts is generated from the migrations: run `npm run db:types`.
// -------------------------------------------------------------------------------------
import { createClient } from '@supabase/supabase-js';
import type { Database } from './database.types';
import { parseEnv } from './env';

// SECURITY REVIEW FIX J01: name each variable. Passing the whole import.meta.env object
// made Vite inline EVERY VITE_* variable from the build environment into the public
// bundle, including any that are never used (for example a key added to Netlify by mistake).
// Never pass import.meta.env as a whole; scripts/security-guards.test.ts checks this.
const env = parseEnv({
  VITE_SUPABASE_URL: import.meta.env.VITE_SUPABASE_URL,
  VITE_SUPABASE_PUBLISHABLE_KEY: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
});

export const supabase = createClient<Database>(env.supabaseUrl, env.supabaseKey, {
  auth: {
    // PKCE: the sign-in link returns a one-time code rather than tokens in the URL.
    flowType: 'pkce',
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
});
