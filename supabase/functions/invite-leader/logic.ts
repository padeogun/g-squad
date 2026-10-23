// -------------------------------------------------------------------------------------
// Pure rules for the invite-leader Edge Function: input checks, who may grant which role,
// and CORS. No Deno or network code here, so the same file is unit-tested by Vitest
// (src/... tests import it) and run by the Edge Function.
//
// The database is still the real gate: the account and roles are inserted AS THE CALLER, so
// row-level security and app.role_assignment_guard apply. These checks run first only so that
// a refused request never creates a Supabase Auth user or sends an email.
// -------------------------------------------------------------------------------------

export type AppRole =
  | 'resident_pastor'
  | 'purpose_head'
  | 'gsquad_coordinator'
  | 'teci_coordinator'
  | 'unit_lead'
  | 'operations_lead'
  | 'pastoral_lead'
  | 'newsletter_editor'
  | 'finance';

export const ALL_ROLES: readonly AppRole[] = [
  'resident_pastor',
  'purpose_head',
  'gsquad_coordinator',
  'teci_coordinator',
  'unit_lead',
  'operations_lead',
  'pastoral_lead',
  'newsletter_editor',
  'finance',
];

// Roles only the Resident Pastor may give (migration 10, F01). Purpose Head joins this list
// while Purpose Heads may read pastoral notes; the database checks that setting, so here we
// treat Purpose Head as senior too and let the Resident Pastor grant it (the safe direction).
export const SENIOR_ROLES: readonly AppRole[] = [
  'resident_pastor',
  'gsquad_coordinator',
  'teci_coordinator',
  'pastoral_lead',
  'purpose_head',
];

// Who may use the invite function at all (decision of 23 Oct 2026).
export const INVITER_ROLES: readonly AppRole[] = ['operations_lead', 'gsquad_coordinator', 'resident_pastor'];

export interface RoleRequest {
  role: AppRole;
  unit_id?: string | null;
  purpose_id?: string | null;
}

export interface InviteRequest {
  email: string;
  display_name: string;
  roles: RoleRequest[];
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Same shape the database accepts for people.email (migration 3, F17).
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

// Checks and normalises the request body. Returns the clean request or a list of problems.
export function validateInvite(body: unknown): { ok: true; value: InviteRequest } | { ok: false; errors: string[] } {
  const errors: string[] = [];
  if (typeof body !== 'object' || body === null) return { ok: false, errors: ['Body must be a JSON object'] };
  const b = body as Record<string, unknown>;

  const email = typeof b.email === 'string' ? b.email.trim().toLowerCase() : '';
  if (!email || email.length > 254 || !EMAIL.test(email)) errors.push('A valid email address is required');

  const name = typeof b.display_name === 'string' ? b.display_name.trim().replace(/\s+/g, ' ') : '';
  // Control characters are refused: the name appears in emails and on every screen.
  // eslint-disable-next-line no-control-regex
  if (!name || name.length > 100 || /[\u0000-\u001f\u007f]/.test(name)) errors.push('A name of 1 to 100 characters is required');

  const rawRoles = Array.isArray(b.roles) ? b.roles : [];
  if (rawRoles.length < 1 || rawRoles.length > 5) errors.push('Give between 1 and 5 roles');

  const roles: RoleRequest[] = [];
  const seen = new Set<string>();
  for (const r of rawRoles) {
    if (typeof r !== 'object' || r === null) {
      errors.push('Each role must be an object');
      continue;
    }
    const rr = r as Record<string, unknown>;
    const role = rr.role as AppRole;
    if (!ALL_ROLES.includes(role)) {
      errors.push('Unknown role');
      continue;
    }
    const unit_id = rr.unit_id == null || rr.unit_id === '' ? null : String(rr.unit_id);
    const purpose_id = rr.purpose_id == null || rr.purpose_id === '' ? null : String(rr.purpose_id);
    if (unit_id && !UUID.test(unit_id)) errors.push('Unit id is not valid');
    if (purpose_id && !UUID.test(purpose_id)) errors.push('Purpose id is not valid');
    // Scoped roles need their scope; other roles must not carry one.
    if (role === 'unit_lead' && !unit_id) errors.push('A Unit Lead needs a unit');
    if (role === 'purpose_head' && !purpose_id) errors.push('A Purpose Head needs a purpose');
    if (role !== 'unit_lead' && unit_id) errors.push('Only a Unit Lead has a unit');
    if (role !== 'purpose_head' && purpose_id) errors.push('Only a Purpose Head has a purpose');
    const key = `${role}|${unit_id ?? ''}|${purpose_id ?? ''}`;
    if (seen.has(key)) continue; // ignore exact duplicates
    seen.add(key);
    roles.push({ role, unit_id, purpose_id });
  }

  if (errors.length) return { ok: false, errors: [...new Set(errors)] };
  return { ok: true, value: { email, display_name: name, roles } };
}

// May a caller holding `callerRoles` give every role in `requested`? Mirrors the database rules
// so a refusal happens before any account or email exists.
export function checkGrants(callerRoles: AppRole[], requested: RoleRequest[]): string | null {
  const has = (r: AppRole) => callerRoles.includes(r);
  if (!INVITER_ROLES.some(has)) return 'Only the Operations Lead, the G-Squad Coordinator or the Resident Pastor can invite leaders';
  for (const r of requested) {
    if (SENIOR_ROLES.includes(r.role) && !has('resident_pastor')) {
      return 'Only the Resident Pastor can give this role';
    }
    if (r.role === 'operations_lead' && !has('resident_pastor') && !has('operations_lead')) {
      return 'Only the Resident Pastor or an Operations Lead can give the Operations Lead role';
    }
  }
  return null;
}

// SECURITY REVIEW FIX K07: the built-in list holds the live app only. Local development
// addresses are added only when the function itself runs on a local Supabase stack, so a
// production invite link can never be pointed at http://localhost.
export const PRODUCTION_ORIGINS = ['https://tecmanchester-g-squad.netlify.app'];
const LOCAL_ORIGINS = ['http://localhost:5173', 'http://127.0.0.1:5173'];
export function defaultOrigins(supabaseUrl: string | undefined): string[] {
  const local = /^http:\/\/(localhost|127\.0\.0\.1|kong|host\.docker\.internal)(:\d+)?(\/|$)/i.test(supabaseUrl ?? '');
  return local ? [...PRODUCTION_ORIGINS, ...LOCAL_ORIGINS] : [...PRODUCTION_ORIGINS];
}

// SECURITY REVIEW FIX K01: Supabase re-sends an invitation to an address that was invited but
// has not accepted yet, and returns that EXISTING user rather than a new one. Only a user created
// by this request may be deleted when a later step fails. "Created by this request" = created no
// earlier than a few seconds before the request started (both clocks are Supabase's own).
export const FRESH_USER_SLACK_MS = 5_000;
export function isFreshUser(createdAt: string | undefined, requestStartedMs: number): boolean {
  const t = Date.parse(createdAt ?? '');
  return Number.isFinite(t) && t >= requestStartedMs - FRESH_USER_SLACK_MS;
}

// SECURITY REVIEW FIX K05: only our own business-rule messages (raised by the guards with
// code 42501, or P0001/23514) go back to the caller; anything else (constraint and column
// names, internal details) is replaced by a plain sentence.
export function safeDbMessage(err: { code?: string; message?: string } | null | undefined, fallback: string): string {
  const msg = err?.message ?? '';
  if (!msg || /row-level security/i.test(msg)) return fallback;
  if (err?.code === '42501' || err?.code === 'P0001' || err?.code === '23514') return msg.slice(0, 200);
  return fallback;
}

// SECURITY REVIEW FIX K06: refuse large bodies before reading them (Content-Length), then
// check the real size in bytes once read (a header can be absent or wrong).
export const MAX_BODY_BYTES = 4000;
export function bodyTooLarge(contentLength: string | null): boolean {
  if (contentLength == null) return false;
  const n = Number(contentLength);
  return !Number.isFinite(n) || n < 0 || n > MAX_BODY_BYTES;
}

// SECURITY REVIEW FIX K08: at most this many invitations per church per hour (by default), so
// a mistake or a stolen admin session cannot use up the project's email allowance, which would
// also stop every leader's sign-in emails. Set INVITES_PER_HOUR as a function secret to change it.
export function invitesPerHour(raw: string | undefined): number {
  const n = Number(raw);
  return Number.isInteger(n) && n >= 1 && n <= 200 ? n : 20;
}

// CORS: only the app's own web addresses may call the function from a browser.
export function parseOrigins(raw: string | undefined, fallback: string[]): string[] {
  const list = (raw ?? '')
    .split(',')
    .map((s) => s.trim().replace(/\/+$/, ''))
    .filter((s) => /^https?:\/\/[^/\s]+$/.test(s));
  return list.length ? list : fallback;
}

export function corsHeaders(origin: string | null, allowed: string[]): Record<string, string> {
  const headers: Record<string, string> = {
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Max-Age': '600',
    Vary: 'Origin',
  };
  if (origin && allowed.includes(origin)) headers['Access-Control-Allow-Origin'] = origin;
  return headers;
}
