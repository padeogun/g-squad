// -------------------------------------------------------------------------------------
// Edge Function: invite-leader
//
// Invites a leader by email and gives them their G-Squad roles in one step.
//   POST { email, display_name, roles: [{ role, unit_id?, purpose_id? }] }
//   Authorization: Bearer <the signed-in inviter's access token>
//
// Why a server function: sending a Supabase Auth invite needs the secret (service-role) key,
// which must never reach the browser. The secret key is used for EXACTLY these things here:
// sending the invite, and deleting that brand-new auth user again if the next step fails
// (after checking, with one read of app_users, that no other request has given it an account).
// The leader's account row and roles are inserted with the CALLER's token, so the database's
// row-level security and role-grant guard decide what is allowed, exactly as in the app.
// -------------------------------------------------------------------------------------
import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import {
  bodyTooLarge,
  checkGrants,
  corsHeaders,
  defaultOrigins,
  invitesPerHour,
  isFreshUser,
  MAX_BODY_BYTES,
  parseOrigins,
  safeDbMessage,
  validateInvite,
  type AppRole,
} from './logic.ts';

// Web addresses allowed to call this function from a browser, and to receive the invite link.
// Set ALLOWED_ORIGINS (comma-separated) as a function secret to change them.
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
// SECURITY REVIEW FIX K07: localhost is allowed only when running on a local Supabase stack.
const ALLOWED = parseOrigins(Deno.env.get('ALLOWED_ORIGINS'), defaultOrigins(SUPABASE_URL));
const PER_HOUR = invitesPerHour(Deno.env.get('INVITES_PER_HOUR'));
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// Small JSON response helper with the CORS headers for this request.
function json(status: number, body: unknown, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

Deno.serve(async (req) => {
  // When this request started: tells a user created now from one that already existed (K01).
  const startedAt = Date.now();
  const origin = req.headers.get('Origin');
  const cors = corsHeaders(origin, ALLOWED);

  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'Method not allowed' }, cors);
  // Browsers always send Origin on a cross-site POST; refuse unknown sites outright. The
  // origin also becomes the invite link's return address, so it must be one of ours.
  if (!origin || !ALLOWED.includes(origin)) return json(403, { error: 'Not allowed from this site' }, cors);

  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.startsWith('Bearer ')) return json(401, { error: 'Sign in first' }, cors);

  // Small bodies only: a name, an email and up to five roles.
  // SECURITY REVIEW FIX K06: check the declared size before reading, and the real size in bytes after.
  if (bodyTooLarge(req.headers.get('Content-Length'))) return json(413, { error: 'Request too large' }, cors);
  const raw = await req.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) return json(413, { error: 'Request too large' }, cors);
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return json(400, { error: 'Body must be JSON' }, cors);
  }
  const parsed = validateInvite(body);
  if (!parsed.ok) return json(400, { error: parsed.errors.join('. ') }, cors);
  const invite = parsed.value;

  // A client that acts as the signed-in caller: every query is subject to row-level security.
  const asCaller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await asCaller.auth.getUser();
  if (userError || !userData.user) return json(401, { error: 'Sign in first' }, cors);
  const callerId = userData.user.id;

  // The caller's own active roles (RLS lets everyone read their own).
  const { data: myRoles, error: rolesError } = await asCaller
    .from('role_assignments')
    .select('role')
    .eq('user_id', callerId)
    .eq('is_active', true);
  if (rolesError) return json(500, { error: 'Could not check your roles' }, cors);
  const refusal = checkGrants((myRoles ?? []).map((r) => r.role as AppRole), invite.roles);
  if (refusal) return json(403, { error: refusal }, cors);

  // SECURITY REVIEW FIX K08: a per-church hourly limit on new accounts (RLS: the caller sees
  // only their own church's accounts), checked before any email is sent.
  const since = new Date(startedAt - 3600_000).toISOString();
  const { count: recent, error: countError } = await asCaller
    .from('app_users')
    .select('id', { count: 'exact', head: true })
    .gte('created_at', since);
  if (countError) return json(500, { error: 'Could not check recent invitations' }, cors);
  if ((recent ?? 0) >= PER_HOUR) return json(429, { error: 'Too many invitations this hour. Try again later' }, cors);

  // Secret-key client: used only for the invite and its rollback below.
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: invited, error: inviteError } = await admin.auth.admin.inviteUserByEmail(invite.email, {
    redirectTo: origin + '/',
  });
  if (inviteError || !invited.user) {
    // 422 = the address already has an account. Only admins reach this point, so saying so is fine.
    if (inviteError?.status === 422 || /already/i.test(inviteError?.message ?? '')) {
      return json(409, { error: 'This email address already has an account' }, cors);
    }
    if (inviteError?.status === 429) {
      return json(429, { error: 'Too many emails sent. Try again later' }, cors);
    }
    console.error('invite failed', inviteError?.status); // no email address in logs
    return json(502, { error: 'The invitation email could not be sent' }, cors);
  }
  const newId = invited.user.id;

  // SECURITY REVIEW FIX K01: an address with a pending (not yet accepted) invitation comes back
  // as that EXISTING user, possibly with an account and roles here or in another church. Before,
  // the account insert then failed and the "rollback" deleted that person's login, account and
  // roles with the secret key (no guard applies to the secret key). Now: stop, change nothing.
  if (!isFreshUser(invited.user.created_at, startedAt)) {
    return json(409, { error: 'This email address already has an account or a pending invitation' }, cors);
  }

  // Undo the invite if the account or roles can't be saved, so no half-made account is left.
  // Only ever for the user this request created (above); and if an account row exists that this
  // request did not make (a second, simultaneous invite of the same address), leave it alone.
  async function rollback(withAccountRow: boolean) {
    if (withAccountRow) {
      await asCaller.from('app_users').delete().eq('id', newId);
    } else {
      const { data: other, error: otherError } = await admin.from('app_users').select('id').eq('id', newId).maybeSingle();
      if (otherError || other) return;
    }
    await admin.auth.admin.deleteUser(newId);
  }

  // The leader's account row, as the caller: joins the caller's church automatically.
  const { error: accountError } = await asCaller.from('app_users').insert({ id: newId, display_name: invite.display_name });
  if (accountError) {
    await rollback(false);
    if (accountError.code === '23505') {
      return json(409, { error: 'This email address already has an account or a pending invitation' }, cors);
    }
    return json(403, { error: 'You are not allowed to add leaders' }, cors);
  }

  // Their roles, as the caller: the database guard has the final say.
  const { error: roleError } = await asCaller.from('role_assignments').insert(
    invite.roles.map((r) => ({ user_id: newId, role: r.role, unit_id: r.unit_id ?? null, purpose_id: r.purpose_id ?? null })),
  );
  if (roleError) {
    await rollback(true);
    // SECURITY REVIEW FIX K05: only our own rule messages are passed on, not raw database errors.
    return json(403, { error: safeDbMessage(roleError, 'These roles could not be given') }, cors);
  }

  return json(200, { id: newId }, cors);
});
