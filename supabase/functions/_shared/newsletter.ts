// -------------------------------------------------------------------------------------
// The Greatness Brief: turning an issue's content (built by the database, migration 27)
// into an email, plus the small rules the Edge Functions share.
//
// Pure TypeScript with no Deno or network code, so the same file is:
//   * run by the send-newsletter Edge Function to make each member's email;
//   * imported by the app to show editors and approvers the exact email (Preview);
//   * unit-tested by Vitest (src/lib/newsletter-email.test.ts).
//
// Every piece of text from the database is escaped before it goes into HTML. The email uses
// tables and inline styles because many email programs ignore style sheets. Decision of
// 25 Oct 2026: the full issue is in the email; personal links (RSVP, reactions, unsubscribe)
// lead to a confirmation page in the app, so a mail scanner opening links changes nothing.
// -------------------------------------------------------------------------------------

export interface Gathering {
  id: string;
  name: string;
  starts_at: string;
  ends_at: string;
  tag: string | null;
  site: string | null;
  excluded?: boolean;
}
export interface Celebration {
  kind: 'birthday' | 'anniversary' | 'new_member';
  name: string;
  day: number | null;
  month: number | null;
}
export interface TeamUpdate {
  id: string;
  unit: string | null;
  body: string;
  excluded?: boolean;
}
export interface Recognition {
  id: string;
  letter: string;
  value: string;
  name: string;
  description: string;
  excluded?: boolean;
}
export interface Item {
  id: string;
  kind: 'win' | 'notice';
  title: string | null;
  body: string;
  names_a_person?: boolean;
  agreement_ticked?: boolean;
}
export interface IssueContent {
  issue_id?: string;
  issue_month: string; // "2026-11-01"
  headline: string | null;
  standfirst: string | null;
  pastor_word: string | null;
  pastor_name: string | null;
  gatherings: Gathering[];
  celebrations: Celebration[];
  baptisms: { water: number; holy_spirit: number };
  team_updates: TeamUpdate[];
  recognitions: Recognition[];
  items: Item[];
}

export const REACTIONS = [
  { key: 'heart', emoji: '❤️', label: 'Love it' },
  { key: 'pray', emoji: '🙏', label: 'Praying' },
  { key: 'fire', emoji: '🔥', label: 'On fire' },
  { key: 'clap', emoji: '👏', label: 'Well done' },
] as const;

// Raw link tokens for one member, from public.newsletter_next_recipients.
export interface MemberLinks {
  unsubscribe: string;
  react: Partial<Record<(typeof REACTIONS)[number]['key'], string>>;
  rsvp?: Record<string, string>;
}

export interface RenderOptions {
  appUrl: string; // e.g. https://tecmanchester-g-squad.netlify.app (no trailing slash)
  firstName?: string | null;
  links?: MemberLinks | null; // null: test or preview (links go to a "test link" page)
  test?: boolean; // adds [TEST] to the subject and a banner
  churchName?: string;
}

// TEC colours (tokens.json): brand blue, lime accent, ink, muted text, tint.
const C = { blue: '#1B4F93', lime: '#BFD000', ink: '#0E1E3A', muted: '#4A5B73', tint: '#F4F9C8', line: '#D9E3EF', page: '#F3F6FA' };
const FONT = "Inter, 'Segoe UI', Helvetica, Arial, sans-serif";
const HEAD = "Lexend, 'Segoe UI', Helvetica, Arial, sans-serif";
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

// Escapes text for HTML element content and attribute values.
export function esc(s: unknown): string {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Escaped text with line breaks kept (paragraph text typed by editors and Team Leads).
function paras(s: string | null | undefined): string {
  return esc(s ?? '').replace(/\r?\n/g, '<br>');
}

// "2026-11-01" -> "November 2026".
export function monthLabel(issueMonth: string): string {
  const m = Number(issueMonth.slice(5, 7)) - 1;
  return `${MONTHS[m] ?? ''} ${issueMonth.slice(0, 4)}`.trim();
}

// A gathering's date and time in London time, e.g. "Sat 14 Nov, 6:00pm".
export function whenLabel(startsAt: string): string {
  const d = new Date(startsAt);
  if (Number.isNaN(d.getTime())) return '';
  const date = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London', weekday: 'short', day: 'numeric', month: 'short' }).format(d);
  const time = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London', hour: 'numeric', minute: '2-digit', hour12: true })
    .format(d)
    .replace(/\s/g, '')
    .toLowerCase();
  return `${date}, ${time}`;
}

// "12 November" for celebrations (day and month only, never the year: R18).
function dayMonth(c: Celebration): string {
  if (!c.day || !c.month) return '';
  return `${c.day} ${MONTHS[c.month - 1] ?? ''}`;
}

// The page a personal link opens. Tokens are URL-safe already (hex), but encode anyway.
export function linkUrl(appUrl: string, token: string | null | undefined): string {
  return `${appUrl}/e/${token ? encodeURIComponent(token) : 'test'}`;
}

// What will actually be printed: excluded items left out (the editor view marks them).
export function visible(c: IssueContent): IssueContent {
  return {
    ...c,
    gatherings: (c.gatherings ?? []).filter((g) => !g.excluded),
    team_updates: (c.team_updates ?? []).filter((t) => !t.excluded),
    recognitions: (c.recognitions ?? []).filter((r) => !r.excluded),
    celebrations: c.celebrations ?? [],
    items: c.items ?? [],
    baptisms: c.baptisms ?? { water: 0, holy_spirit: 0 },
  };
}

export function subjectFor(c: IssueContent, test = false): string {
  const base = `The Greatness Brief · ${monthLabel(c.issue_month)}`;
  const s = c.headline ? `${base}: ${c.headline}` : base;
  // Subjects are a single line: no line breaks from the headline.
  return (test ? '[TEST] ' : '') + s.replace(/[\r\n]+/g, ' ').slice(0, 200);
}

// ---------- HTML ----------
function section(title: string, inner: string): string {
  return `<tr><td style="padding:24px 32px 0 32px;">
<p style="margin:0 0 10px 0;font:700 12px ${HEAD};letter-spacing:.14em;text-transform:uppercase;color:${C.blue};">${esc(title)}</p>
${inner}
</td></tr>`;
}

function button(href: string, label: string): string {
  return `<a href="${esc(href)}" style="display:inline-block;padding:8px 16px;border-radius:999px;background:${C.blue};color:#ffffff;font:600 13px ${FONT};text-decoration:none;">${esc(label)}</a>`;
}

export function renderHtml(content: IssueContent, o: RenderOptions): string {
  const c = visible(content);
  const month = monthLabel(c.issue_month);
  const church = o.churchName ?? 'The Elevation Church Manchester';
  const parts: string[] = [];

  if (o.test) {
    parts.push(`<tr><td style="padding:12px 32px;background:#FFF1CC;color:#6E4600;font:600 13px ${FONT};">
Test email: links in it do nothing. Members have not been sent this.</td></tr>`);
  }

  // Masthead.
  parts.push(`<tr><td style="padding:28px 32px;background:${C.blue};">
<p style="margin:0;font:700 12px ${HEAD};letter-spacing:.18em;color:${C.lime};">THE GREATNESS BRIEF</p>
<p style="margin:6px 0 0 0;font:600 13px ${FONT};color:#DCE7F5;">${esc(church)} · G-Squad · ${esc(month)}</p>
</td></tr>`);

  // Headline, standfirst and greeting.
  const hello = o.firstName ? `<p style="margin:0 0 12px 0;font:400 15px ${FONT};color:${C.ink};">Hi ${esc(o.firstName)},</p>` : '';
  parts.push(`<tr><td style="padding:28px 32px 0 32px;">${hello}
${c.headline ? `<h1 style="margin:0;font:700 26px/1.25 ${HEAD};color:${C.ink};">${esc(c.headline)}</h1>` : ''}
${c.standfirst ? `<p style="margin:10px 0 0 0;font:400 16px/1.5 ${FONT};color:${C.muted};">${esc(c.standfirst)}</p>` : ''}
</td></tr>`);

  if (c.pastor_word) {
    parts.push(
      section(
        'A word from the Pastor',
        `<div style="padding:16px 18px;border-left:4px solid ${C.lime};background:${C.page};font:400 15px/1.6 ${FONT};color:${C.ink};">${paras(c.pastor_word)}${
          c.pastor_name ? `<p style="margin:10px 0 0 0;font:600 14px ${FONT};color:${C.muted};">${esc(c.pastor_name)}</p>` : ''
        }</div>`,
      ),
    );
  }

  if (c.gatherings.length) {
    const rows = c.gatherings
      .map((g) => {
        const rsvp = o.links ? o.links.rsvp?.[g.id] : undefined;
        const href = linkUrl(o.appUrl, o.links ? rsvp : null);
        const where = [whenLabel(g.starts_at), g.site].filter(Boolean).join(' · ');
        return `<tr><td style="padding:12px 0;border-bottom:1px solid ${C.line};">
${g.tag ? `<span style="display:inline-block;padding:2px 8px;border-radius:999px;background:${C.tint};color:#3D4300;font:700 11px ${FONT};letter-spacing:.06em;">${esc(g.tag)}</span><br>` : ''}
<span style="font:600 16px ${HEAD};color:${C.ink};">${esc(g.name)}</span><br>
<span style="font:400 14px ${FONT};color:${C.muted};">${esc(where)}</span><br>
<span style="display:inline-block;margin-top:8px;">${o.links && !rsvp ? '' : button(href, "I'll be there")}</span>
</td></tr>`;
      })
      .join('');
    parts.push(section('Upcoming gatherings', `<table role="presentation" width="100%" cellpadding="0" cellspacing="0">${rows}</table>`));
  }

  const groups: [Celebration['kind'], string][] = [
    ['birthday', 'Birthdays'],
    ['anniversary', 'Anniversaries'],
    ['new_member', 'Welcome to the G-Squad'],
  ];
  const celebrations = groups
    .map(([kind, label]) => {
      const list = c.celebrations.filter((x) => x.kind === kind);
      if (!list.length) return '';
      const names = list.map((x) => (kind === 'new_member' ? esc(x.name) : `${esc(x.name)} <span style="color:${C.muted};">${esc(dayMonth(x))}</span>`)).join('<br>');
      return `<p style="margin:0 0 4px 0;font:600 14px ${FONT};color:${C.ink};">${esc(label)}</p><p style="margin:0 0 14px 0;font:400 14px/1.6 ${FONT};color:${C.ink};">${names}</p>`;
    })
    .join('');
  if (celebrations) parts.push(section('Celebrating', celebrations));

  const b = c.baptisms;
  if (b.water > 0 || b.holy_spirit > 0) {
    const bits = [
      b.water > 0 ? `${b.water} ${b.water === 1 ? 'person was' : 'people were'} baptised in water` : '',
      b.holy_spirit > 0 ? `${b.holy_spirit} received the baptism of the Holy Spirit` : '',
    ].filter(Boolean);
    parts.push(section('Baptisms last month', `<p style="margin:0;font:400 15px/1.6 ${FONT};color:${C.ink};">${esc(bits.join(', and '))}. Praise God!</p>`));
  }

  if (c.team_updates.length) {
    const rows = c.team_updates
      .map(
        (t) => `<p style="margin:0 0 4px 0;font:600 14px ${FONT};color:${C.blue};">${esc(t.unit ?? 'Team')}</p>
<p style="margin:0 0 14px 0;font:400 15px/1.6 ${FONT};color:${C.ink};">${paras(t.body)}</p>`,
      )
      .join('');
    parts.push(section('From the teams', rows));
  }

  const wins = c.items.filter((i) => i.kind === 'win');
  if (wins.length || c.recognitions.length) {
    const cards = [
      ...wins.map(
        (w) => `<div style="margin:0 0 10px 0;padding:14px 16px;border-radius:12px;background:${C.tint};font:400 15px/1.5 ${FONT};color:#2E3300;">
${w.title ? `<strong style="font:600 15px ${HEAD};">${esc(w.title)}</strong><br>` : ''}${paras(w.body)}</div>`,
      ),
      ...c.recognitions.map(
        (r) => `<div style="margin:0 0 10px 0;padding:14px 16px;border-radius:12px;background:${C.tint};font:400 15px/1.5 ${FONT};color:#2E3300;">
<span style="font:700 12px ${FONT};color:${C.blue};">${esc(r.value)} · Values in Action</span><br>
<strong>${esc(r.name)}</strong>: ${paras(r.description)}</div>`,
      ),
    ].join('');
    parts.push(section('Wins and testimonies', cards));
  }

  const notices = c.items.filter((i) => i.kind === 'notice');
  if (notices.length) {
    parts.push(
      section(
        'Notices',
        notices
          .map(
            (n) => `<p style="margin:0 0 12px 0;font:400 15px/1.6 ${FONT};color:${C.ink};">${n.title ? `<strong>${esc(n.title)}</strong><br>` : ''}${paras(n.body)}</p>`,
          )
          .join(''),
      ),
    );
  }

  // Reactions.
  const react = REACTIONS.map((r) => {
    const tok = o.links ? o.links.react?.[r.key] : null;
    if (o.links && !tok) return '';
    return `<a href="${esc(linkUrl(o.appUrl, tok))}" title="${esc(r.label)}" style="display:inline-block;margin:0 6px;padding:8px 12px;border-radius:999px;border:1px solid ${C.line};font:400 20px ${FONT};text-decoration:none;">${r.emoji}</a>`;
  }).join('');
  parts.push(`<tr><td style="padding:28px 32px 0 32px;text-align:center;">
<p style="margin:0 0 10px 0;font:600 14px ${FONT};color:${C.ink};">How did this issue land with you?</p>${react}</td></tr>`);

  // Footer.
  const unsub = linkUrl(o.appUrl, o.links ? o.links.unsubscribe : null);
  parts.push(`<tr><td style="padding:28px 32px;font:400 12px/1.6 ${FONT};color:${C.muted};">
You receive The Greatness Brief as a member of the G-Squad at ${esc(church)}. Birthdays and other celebrations appear only for members who chose to share them.<br>
<a href="${esc(unsub)}" style="color:${C.muted};">Stop receiving The Greatness Brief</a>
</td></tr>`);

  return `<!doctype html>
<html lang="en-GB"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light"><title>${esc(subjectFor(c, o.test))}</title></head>
<body style="margin:0;padding:0;background:${C.page};">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${C.page};"><tr><td align="center" style="padding:24px 12px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border:1px solid ${C.line};border-radius:16px;overflow:hidden;">
${parts.join('\n')}
</table></td></tr></table></body></html>`;
}

// ---------- Plain text (for email programs that prefer it, and for accessibility) ----------
export function renderText(content: IssueContent, o: RenderOptions): string {
  const c = visible(content);
  const out: string[] = [];
  if (o.test) out.push('TEST EMAIL: links in it do nothing.', '');
  out.push(`THE GREATNESS BRIEF · ${monthLabel(c.issue_month)}`, '');
  if (o.firstName) out.push(`Hi ${o.firstName},`, '');
  if (c.headline) out.push(c.headline);
  if (c.standfirst) out.push(c.standfirst);
  if (c.pastor_word) out.push('', 'A WORD FROM THE PASTOR', c.pastor_word, c.pastor_name ?? '');
  if (c.gatherings.length) {
    out.push('', 'UPCOMING GATHERINGS');
    for (const g of c.gatherings) {
      const tok = o.links ? o.links.rsvp?.[g.id] : null;
      out.push(`- ${g.name}, ${whenLabel(g.starts_at)}${g.site ? `, ${g.site}` : ''}`);
      if (!o.links || tok) out.push(`  I'll be there: ${linkUrl(o.appUrl, tok)}`);
    }
  }
  const cel = c.celebrations;
  if (cel.length) {
    out.push('', 'CELEBRATING');
    for (const x of cel) out.push(`- ${x.name}${x.kind === 'new_member' ? ' (new to the G-Squad)' : `, ${dayMonth(x)}${x.kind === 'anniversary' ? ' (anniversary)' : ''}`}`);
  }
  if (c.baptisms.water > 0 || c.baptisms.holy_spirit > 0) {
    out.push('', 'BAPTISMS LAST MONTH', `Water: ${c.baptisms.water}. Holy Spirit: ${c.baptisms.holy_spirit}.`);
  }
  if (c.team_updates.length) {
    out.push('', 'FROM THE TEAMS');
    for (const t of c.team_updates) out.push(`${t.unit ?? 'Team'}: ${t.body}`);
  }
  const wins = c.items.filter((i) => i.kind === 'win');
  if (wins.length || c.recognitions.length) {
    out.push('', 'WINS AND TESTIMONIES');
    for (const w of wins) out.push(`- ${w.title ? `${w.title}: ` : ''}${w.body}`);
    for (const r of c.recognitions) out.push(`- ${r.name} (${r.value}): ${r.description}`);
  }
  const notices = c.items.filter((i) => i.kind === 'notice');
  if (notices.length) {
    out.push('', 'NOTICES');
    for (const n of notices) out.push(`- ${n.title ? `${n.title}: ` : ''}${n.body}`);
  }
  out.push('', `Stop receiving The Greatness Brief: ${linkUrl(o.appUrl, o.links ? o.links.unsubscribe : null)}`);
  return out.join('\n');
}

// ---------- Sending helpers ----------

// Resend accepts at most 100 emails per batch call.
export const BATCH_MAX = 100;

// A key that is the same if the same batch is sent again (after a failure part-way), so the
// email service sends it only once. Recipients come back in a stable order (by person id).
export function batchKey(issueId: string, recipientIds: string[]): string {
  return `gsquad-${issueId}-${recipientIds[0] ?? 'none'}-${recipientIds.length}`.slice(0, 250);
}

// The one-click unsubscribe headers (RFC 8058) for a member's email.
export function unsubscribeHeaders(functionsUrl: string, token: string): Record<string, string> {
  return {
    'List-Unsubscribe': `<${functionsUrl}/email-link?t=${encodeURIComponent(token)}>`,
    'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click',
  };
}

// Email link tokens: 32 to 256 URL-safe characters (as public.redeem_email_link checks).
export function isToken(t: unknown): t is string {
  return typeof t === 'string' && t.length >= 32 && t.length <= 256 && /^[A-Za-z0-9_-]+$/.test(t);
}

// The "From" address must look like `Name <address@domain>` or a bare address.
export function validFrom(v: string | undefined): string | null {
  if (!v) return null;
  const s = v.trim();
  return /^([^<>\r\n]{1,80} )?<?[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+>?$/.test(s) ? s : null;
}
