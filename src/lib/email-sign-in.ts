// -------------------------------------------------------------------------------------
// Sign-in links that survive email link scanners.
//
// Why: work email systems (Microsoft 365 Safe Links and the like) open every link in an
// email before the person does. Supabase's own link (…/auth/v1/verify?token=…) signs in on
// that first opening, so the scanner used the one-time link and the leader's own click then
// failed with "Email link is invalid or has expired" (seen in the auth logs, 25 Oct 2026).
//
// Now the emails (supabase/templates/*.html) link to the app itself with a token hash
// (?token_hash=…&type=…). Opening that page changes nothing; the leader presses "Sign in",
// and only then is the hash exchanged for a session (verifyOtp). The hash needs no secret
// kept in the browser that asked for it, so the link also works on another device. Each email
// also carries an 8-digit code as a second way in.
// -------------------------------------------------------------------------------------

export type EmailLinkType = 'invite' | 'email';

export interface EmailLink {
  tokenHash: string;
  type: EmailLinkType;
}

// Supabase token hashes are hex (optionally "pkce_"-prefixed). Anything else is refused,
// so a crafted address can't push odd text into the request.
const HASH = /^(pkce_)?[A-Za-z0-9_-]{16,200}$/;

// Reads ?token_hash=…&type=… from a query string. "magiclink" is the older name for "email".
export function parseEmailLink(search: string): EmailLink | null {
  const q = new URLSearchParams(search);
  const tokenHash = q.get('token_hash') ?? '';
  const raw = q.get('type') ?? '';
  const type: EmailLinkType | null = raw === 'invite' ? 'invite' : raw === 'email' || raw === 'magiclink' ? 'email' : null;
  if (!type || !HASH.test(tokenHash)) return null;
  return { tokenHash, type };
}

// A code as typed: spaces and dashes dropped. Supabase sends 6 to 10 digits (G-Squad uses 8,
// review 22 L03); any length in that range is passed on, so changing the setting needs no release.
export function cleanCode(input: string): string | null {
  const digits = input.replace(/[\s-]/g, '');
  return /^\d{6,10}$/.test(digits) ? digits : null;
}
