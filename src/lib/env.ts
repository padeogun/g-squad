// -------------------------------------------------------------------------------------
// Reads and checks the app's public settings (Vite exposes only VITE_* variables).
// Only the project URL and the PUBLISHABLE key belong here: both are safe in the browser,
// because row-level security in the database decides what each user can see.
// The service-role / secret key must NEVER be put in a VITE_* variable.
// -------------------------------------------------------------------------------------

export interface AppEnv {
  supabaseUrl: string;
  supabaseKey: string;
}

// Exported separately so it can be unit-tested with any input.
export function parseEnv(raw: Record<string, string | undefined>): AppEnv {
  const supabaseUrl = raw.VITE_SUPABASE_URL?.trim();
  const supabaseKey = raw.VITE_SUPABASE_PUBLISHABLE_KEY?.trim();

  if (!supabaseUrl || !supabaseKey) {
    throw new Error(
      'Missing VITE_SUPABASE_URL or VITE_SUPABASE_PUBLISHABLE_KEY. Copy .env.example to .env.local and fill them in.',
    );
  }

  // Must be an https URL (local Supabase on http://127.0.0.1 is allowed for development).
  const url = new URL(supabaseUrl);
  const isLocal = url.hostname === '127.0.0.1' || url.hostname === 'localhost';
  if (url.protocol !== 'https:' && !isLocal) {
    throw new Error('VITE_SUPABASE_URL must use https.');
  }

  // Guard against pasting a secret key into the browser build by mistake.
  // (This runs in the browser, so on its own it is too late: vite.config.ts runs the same
  // isSecretKey check over every VITE_* variable and stops the build. SECURITY REVIEW FIX J01.)
  if (isSecretKey(supabaseKey)) {
    throw new Error('VITE_SUPABASE_PUBLISHABLE_KEY holds a secret key. Use the publishable key only.');
  }

  return { supabaseUrl: url.origin, supabaseKey };
}

// True for a Supabase secret key (new sb_secret_ format, or a legacy service-role JWT).
// Shared with vite.config.ts, which refuses to build if any VITE_* variable holds one.
export function isSecretKey(value: string): boolean {
  const v = value.trim();
  return v.toLowerCase().startsWith('sb_secret_') || looksLikeServiceRoleJwt(v);
}

// Legacy keys are JWTs; the service-role one carries "role":"service_role" in its payload.
function looksLikeServiceRoleJwt(key: string): boolean {
  const parts = key.split('.');
  if (parts.length !== 3) return false;
  try {
    const payload = JSON.parse(atob(parts[1].replace(/-/g, '+').replace(/_/g, '/')));
    return payload?.role === 'service_role';
  } catch {
    return false;
  }
}
