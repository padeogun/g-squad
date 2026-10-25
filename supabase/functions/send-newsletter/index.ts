// -------------------------------------------------------------------------------------
// Edge Function: send-newsletter (slice 6)
//
// Two requests:
//   POST { "action": "tick" }
//     From the database's pg_cron job every 15 minutes, or from the app just after "Send now".
//     Needs no sign-in: it can only send issues that are approved and due (the database
//     decides which, in public.newsletter_claim_due) and each one only once. Uses the secret
//     (service-role) key, which never leaves the server.
//   POST { "action": "test", "issue_id": "…" }   Authorization: Bearer <signed-in user>
//     Sends the issue as it stands to the church's test list. Who may, how often (10 a day)
//     and to whom are decided by public.newsletter_test_send, called AS THE CALLER.
//
// Function secrets (Supabase > Edge Functions > Secrets):
//   RESEND_API_KEY   the Resend API key (never in the app or the repository)
//   NEWSLETTER_FROM  e.g. "The Greatness Brief <brief@tecmanchester.org>", on the domain
//                    verified in Resend
//   APP_URL          optional; the app's address for links (defaults to the live app)
//   ALLOWED_ORIGINS  optional; as invite-leader
// Until the DPIA is signed only the test list receives email (church_settings.newsletter_live).
// -------------------------------------------------------------------------------------
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.118.0';
import { corsHeaders, defaultOrigins, parseOrigins, PRODUCTION_ORIGINS } from '../invite-leader/logic.ts';
import {
  BATCH_MAX,
  batchKey,
  renderHtml,
  renderText,
  subjectFor,
  unsubscribeHeaders,
  validFrom,
  type IssueContent,
  type MemberLinks,
} from '../_shared/newsletter.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_KEY = Deno.env.get('RESEND_API_KEY') ?? '';
const FROM = validFrom(Deno.env.get('NEWSLETTER_FROM'));
const ALLOWED = parseOrigins(Deno.env.get('ALLOWED_ORIGINS'), defaultOrigins(SUPABASE_URL));
// Links in emails go to the app; only an allowed origin may be used for them.
const APP_URL = parseOrigins(Deno.env.get('APP_URL'), PRODUCTION_ORIGINS)[0];
const FUNCTIONS_URL = `${SUPABASE_URL}/functions/v1`;
// Batches per run: keeps one run well inside the function's time limit; the next run carries on.
const MAX_BATCHES_PER_RUN = 10;
const BATCH_SIZE = 50;

function json(status: number, body: unknown, cors: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

interface OutEmail {
  from: string;
  to: string[];
  subject: string;
  html: string;
  text: string;
  headers?: Record<string, string>;
}

// One batch call to Resend. Returns the message ids in the same order, or an error message
// that is safe to store (never the API key or an address).
async function sendBatch(emails: OutEmail[], key: string): Promise<{ ids: string[] } | { error: string }> {
  let res: Response;
  try {
    res = await fetch('https://api.resend.com/emails/batch', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND_KEY}`, 'Content-Type': 'application/json', 'Idempotency-Key': key },
      body: JSON.stringify(emails),
    });
  } catch {
    return { error: 'The email service could not be reached' };
  }
  if (res.status === 429) return { error: 'The email service limit was reached; sending continues later' };
  if (!res.ok) {
    console.error('resend batch failed', res.status);
    return { error: `The email service refused the batch (${res.status})` };
  }
  const body = (await res.json().catch(() => null)) as { data?: { id: string }[] } | null;
  const ids = (body?.data ?? []).map((d) => d.id);
  if (ids.length !== emails.length) return { error: 'The email service gave an unexpected answer' };
  return { ids };
}

// ---------- tick: send whatever is due ----------
async function tick(admin: SupabaseClient): Promise<Response> {
  const { data: due, error } = await admin.rpc('newsletter_claim_due');
  if (error) return json(500, { error: 'Could not check for due issues' });
  const results: Record<string, string> = {};

  for (const issue of (due ?? []) as { issue_id: string; live: boolean }[]) {
    const { data: content, error: cErr } = await admin.rpc('newsletter_send_content', { p_issue: issue.issue_id });
    if (cErr || !content) {
      await admin.rpc('newsletter_finish', { p_issue: issue.issue_id, p_error: 'The approved content could not be read' });
      results[issue.issue_id] = 'error';
      continue;
    }
    const c = content as IssueContent;
    const subject = subjectFor(c, !issue.live);
    let failure: string | null = null;

    for (let n = 0; n < MAX_BATCHES_PER_RUN && !failure; n++) {
      const { data: rows, error: rErr } = await admin.rpc('newsletter_next_recipients', { p_issue: issue.issue_id, p_limit: BATCH_SIZE });
      if (rErr) {
        failure = 'Could not list recipients';
        break;
      }
      const list = (rows ?? []) as { person_id: string | null; email: string; first_name: string | null; links: MemberLinks | null }[];
      if (!list.length) break;

      const emails: OutEmail[] = list.slice(0, BATCH_MAX).map((r) => ({
        from: FROM!,
        to: [r.email],
        subject,
        html: renderHtml(c, { appUrl: APP_URL, firstName: r.first_name, links: r.links, test: !issue.live }),
        text: renderText(c, { appUrl: APP_URL, firstName: r.first_name, links: r.links, test: !issue.live }),
        headers: r.links ? unsubscribeHeaders(FUNCTIONS_URL, r.links.unsubscribe) : undefined,
      }));
      const sent = await sendBatch(emails, batchKey(issue.issue_id, list.map((r) => r.person_id ?? r.email)));
      if ('error' in sent) {
        failure = sent.error;
        break;
      }
      const { error: dErr } = await admin.rpc('newsletter_record_deliveries', {
        p_issue: issue.issue_id,
        p_rows: list.map((r, i) => (r.person_id ? { person_id: r.person_id, provider_id: sent.ids[i] } : { test_address: r.email, provider_id: sent.ids[i] })),
      });
      if (dErr) failure = 'Sent, but could not record who received it';
    }

    const { data: outcome } = await admin.rpc('newsletter_finish', { p_issue: issue.issue_id, p_error: failure });
    results[issue.issue_id] = String(outcome ?? 'error');
  }
  return json(200, { issues: results });
}

// ---------- test: the issue as it stands, to the test list ----------
async function testSend(req: Request, issueId: string, cors: Record<string, string>): Promise<Response> {
  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.startsWith('Bearer ')) return json(401, { error: 'Sign in first' }, cors);
  const asCaller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: user, error: uErr } = await asCaller.auth.getUser();
  if (uErr || !user.user) return json(401, { error: 'Sign in first' }, cors);

  // The database checks the caller's role and the daily limit, logs the send, and returns the list.
  const { data: list, error: lErr } = await asCaller.rpc('newsletter_test_send', { p_issue: issueId });
  if (lErr) {
    const known = ['23514', '54000', '42501'].includes(lErr.code ?? '');
    return json(known ? 403 : 500, { error: known ? lErr.message : 'The test could not be sent' }, cors);
  }
  const { data: content, error: cErr } = await asCaller.rpc('newsletter_issue_content', { p_issue: issueId });
  if (cErr || !content) return json(403, { error: 'Not allowed' }, cors);
  const c = content as IssueContent;
  const to = ((list ?? []) as string[]).slice(0, 10);
  const emails: OutEmail[] = to.map((addr) => ({
    from: FROM!,
    to: [addr],
    subject: subjectFor(c, true),
    html: renderHtml(c, { appUrl: APP_URL, links: null, test: true }),
    text: renderText(c, { appUrl: APP_URL, links: null, test: true }),
  }));
  // A fresh key each time: a test is meant to be sent again after an edit.
  const sent = await sendBatch(emails, `gsquad-test-${issueId}-${crypto.randomUUID()}`);
  if ('error' in sent) return json(502, { error: sent.error }, cors);
  return json(200, { sent: emails.length }, cors);
}

Deno.serve(async (req) => {
  const origin = req.headers.get('Origin');
  const cors = corsHeaders(origin, ALLOWED);
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'Method not allowed' }, cors);
  if (!RESEND_KEY || !FROM) return json(503, { error: 'The email service is not set up yet' }, cors);

  const raw = await req.text();
  if (raw.length > 2000) return json(413, { error: 'Request too large' }, cors);
  let body: { action?: unknown; issue_id?: unknown };
  try {
    body = JSON.parse(raw || '{}');
  } catch {
    return json(400, { error: 'Body must be JSON' }, cors);
  }

  if (body.action === 'tick') {
    const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
    return tick(admin).then((r) => {
      // A browser may call tick after "Send now": let it read the answer.
      for (const [k, v] of Object.entries(cors)) r.headers.set(k, v);
      return r;
    });
  }
  if (body.action === 'test') {
    // A browser request from one of our sites only.
    if (!origin || !ALLOWED.includes(origin)) return json(403, { error: 'Not allowed from this site' }, cors);
    if (typeof body.issue_id !== 'string' || !/^[0-9a-f-]{36}$/i.test(body.issue_id)) return json(400, { error: 'Give the issue' }, cors);
    return testSend(req, body.issue_id, cors);
  }
  return json(400, { error: 'Unknown action' }, cors);
});
