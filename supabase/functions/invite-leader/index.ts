// -------------------------------------------------------------------------------------
// Edge Function: invite-leader
//
// Invites a leader by email and gives them their G-Squad roles in one step.
//   POST { email, display_name, roles: [{ role, unit_id?, purpose_id? }] }
//   Authorization: Bearer <the signed-in inviter's access token>
//
// Why a server function: sending a Supabase Auth invite needs the secret (service-role) key,
// which must never reach the browser. The secret key is used for EXACTLY two things here:
// sending the invite, and deleting that brand-new auth user again if the next step fails.
// The leader's account row and roles are inserted with the CALLER's token, so the database's
// row-level security and role-grant guard decide what is allowed, exactly as in the app.
// -------------------------------------------------------------------------------------
import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import { checkGrants, corsHeaders, parseOrigins, validateInvite, type AppRole } from './logic.ts';

// Web addresses allowed to call this function from a browser, and to receive the invite link.
// Set ALLOWED_ORIGINS (comma-separated) as a function secret to change them.
const ALLOWED = parseOrigins(Deno.env.get('ALLOWED_ORIGINS'), [
  'https://tecmanchester-g-squad.netlify.app',
  'http://localhost:5173',
  'http://127.0.0.1:5173',
]);

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
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
  const raw = await req.text();
  if (raw.length > 4000) return json(413, { error: 'Request too large' }, cors);
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

  // Undo the invite if the account or roles can't be saved, so no half-made account is left.
  async function rollback(withAccountRow: boolean) {
    if (withAccountRow) await asCaller.from('app_users').delete().eq('id', newId);
    await admin.auth.admin.deleteUser(newId);
  }

  // The leader's account row, as the caller: joins the caller's church automatically.
  const { error: accountError } = await asCaller.from('app_users').insert({ id: newId, display_name: invite.display_name });
  if (accountError) {
    await rollback(false);
    return json(403, { error: 'You are not allowed to add leaders' }, cors);
  }

  // Their roles, as the caller: the database guard has the final say.
  const { error: roleError } = await asCaller.from('role_assignments').insert(
    invite.roles.map((r) => ({ user_id: newId, role: r.role, unit_id: r.unit_id ?? null, purpose_id: r.purpose_id ?? null })),
  );
  if (roleError) {
    await rollback(true);
    return json(403, { error: roleError.message || 'These roles could not be given' }, cors);
  }

  return json(200, { id: newId }, cors);
});
