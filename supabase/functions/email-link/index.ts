// -------------------------------------------------------------------------------------
// Edge Function: email-link (slice 6)
//
// Uses a member's personal link from The Greatness Brief (RSVP, reaction or unsubscribe).
// Members do not sign in, so the link's random token is the only proof; the database stores
// only its SHA-256 hash (migration 5) and checks expiry and purpose.
//
//   POST { "token": "…", "confirm": false }  from the app's /e/<token> page: says what the link
//        is for (public.peek_email_link) and changes nothing.
//   POST { "token": "…", "confirm": true }   the member pressed Confirm: uses it
//        (public.redeem_email_link).
//   POST ?t=<token> with body "List-Unsubscribe=One-Click"  an email program's one-click
//        unsubscribe (RFC 8058). Unsubscribe links only.
//
// Opening a link (GET) never changes anything: mail scanners open links before people do.
// The service-role key is used only for the two database functions above, which accept the
// service role alone.
// -------------------------------------------------------------------------------------
import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import { corsHeaders, defaultOrigins, parseOrigins } from '../invite-leader/logic.ts';
import { isToken } from '../_shared/newsletter.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ALLOWED = parseOrigins(Deno.env.get('ALLOWED_ORIGINS'), defaultOrigins(SUPABASE_URL));
const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

function json(status: number, body: unknown, cors: Record<string, string> = {}): Response {
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

  const raw = await req.text();
  if (raw.length > 1000) return json(413, { error: 'Request too large' }, cors);

  // One-click unsubscribe from an email program (no Origin header, form body).
  const url = new URL(req.url);
  const oneClickToken = url.searchParams.get('t');
  if (oneClickToken !== null) {
    if (!/List-Unsubscribe=One-Click/.test(raw) || !isToken(oneClickToken)) return json(400, { error: 'Bad request' });
    const { data: peek } = await admin.rpc('peek_email_link', { p_token: oneClickToken });
    if ((peek as { purpose?: string } | null)?.purpose !== 'unsubscribe') return json(400, { error: 'Bad request' });
    const { error } = await admin.rpc('redeem_email_link', { p_token: oneClickToken });
    return error ? json(500, { error: 'Try again later' }) : json(200, { done: 'unsubscribe' });
  }

  // From the app's confirmation page.
  if (!origin || !ALLOWED.includes(origin)) return json(403, { error: 'Not allowed from this site' }, cors);
  let body: { token?: unknown; confirm?: unknown };
  try {
    body = JSON.parse(raw);
  } catch {
    return json(400, { error: 'Body must be JSON' }, cors);
  }
  if (!isToken(body.token)) return json(200, { purpose: 'invalid' }, cors);

  const { data: peek, error: pErr } = await admin.rpc('peek_email_link', { p_token: body.token });
  if (pErr) return json(500, { error: 'Try again later' }, cors);
  if (body.confirm !== true) return json(200, peek, cors);
  if ((peek as { purpose?: string }).purpose === 'invalid') return json(200, peek, cors);

  const { data: done, error: rErr } = await admin.rpc('redeem_email_link', { p_token: body.token });
  if (rErr) return json(500, { error: 'Try again later' }, cors);
  return json(200, { ...(peek as object), done }, cors);
});
