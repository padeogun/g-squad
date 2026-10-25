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

// Used ONLY to ask for a sign-in email (signInWithOtp), never for a session.
// Why a second client: with PKCE, the emailed link and code are tied to a secret kept in the
// browser that asked for them, so a link opened on another device (or in an email app's own
// browser) cannot sign in. The emails no longer carry a sign-in URL with tokens in it (they
// link to /auth/confirm with a one-time hash, see src/lib/email-sign-in.ts), so asking without
// PKCE puts nothing in an address bar. The main client above, still PKCE, then exchanges the
// hash or the 6-digit code for the session.
export const emailRequestClient = createClient<Database>(env.supabaseUrl, env.supabaseKey, {
  auth: {
    flowType: 'implicit',
    persistSession: false,
    autoRefreshToken: false,
    detectSessionInUrl: false,
    storageKey: 'gsquad-email-request', // its own key, so it never touches the real session
  },
});
