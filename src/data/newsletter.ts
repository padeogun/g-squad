// -------------------------------------------------------------------------------------
// The Greatness Brief (slice 6): issues, their content, approval and sending.
// The database decides everything that matters (migrations 5, 6, 8 and 27): who reads and
// edits issues (editors, the G-Squad Coordinator, the Resident Pastor, the Operations Lead),
// the approval order (R17), named items needing agreement (R18), what the content holds, and
// when and to whom it is sent. These hooks read and write through it; the helpers at the
// bottom only decide which buttons to offer, and are unit-tested.
// -------------------------------------------------------------------------------------
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Database } from '../lib/database.types';
import { supabase } from '../lib/supabase';
import { REACTIONS, type IssueContent } from '../../supabase/functions/_shared/newsletter.ts';
import type { AppRole } from '../auth/useMe';

type T = Database['public']['Tables'];
export type Issue = T['newsletter_issues']['Row'];
export type IssueItem = T['newsletter_items']['Row'];
export type IssueStatus = Database['public']['Enums']['issue_status'];
export type Settings = T['church_settings']['Row'];

export const useIssues = () =>
  useQuery({
    queryKey: ['newsletter_issues'],
    queryFn: async () => {
      const { data, error } = await supabase.from('newsletter_issues').select('*').order('issue_month', { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
  });

export const useIssue = (id: string | undefined) =>
  useQuery({
    queryKey: ['newsletter_issues', id],
    enabled: !!id,
    queryFn: async () => {
      const { data, error } = await supabase.from('newsletter_issues').select('*').eq('id', id!).maybeSingle();
      if (error) throw error;
      return data;
    },
  });

// The issue's content as the email will show it (public.newsletter_issue_content).
export const useIssueContent = (id: string | undefined) =>
  useQuery({
    queryKey: ['newsletter_content', id],
    enabled: !!id,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('newsletter_issue_content', { p_issue: id! });
      if (error) throw error;
      return data as unknown as IssueContent;
    },
  });

// Counts only: how many received it, RSVPs per gathering, reactions.
export const useIssueStats = (id: string | undefined, enabled: boolean) =>
  useQuery({
    queryKey: ['newsletter_stats', id],
    enabled: !!id && enabled,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('newsletter_issue_stats', { p_issue: id! });
      if (error) throw error;
      return data ?? [];
    },
  });

export const useRecipientCount = () =>
  useQuery({
    queryKey: ['newsletter_recipients'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('newsletter_recipient_count');
      if (error) throw error;
      return data as number;
    },
  });

export const useSettings = () =>
  useQuery({
    queryKey: ['church_settings'],
    queryFn: async () => {
      const { data, error } = await supabase.from('church_settings').select('*').maybeSingle();
      if (error) throw error;
      return data;
    },
  });

// Refreshes everything shown on an issue's page after a change.
export function useRefreshIssue() {
  const qc = useQueryClient();
  return (id?: string) =>
    Promise.all([
      qc.invalidateQueries({ queryKey: ['newsletter_issues'] }),
      qc.invalidateQueries({ queryKey: ['newsletter_content', id] }),
      qc.invalidateQueries({ queryKey: ['newsletter_stats', id] }),
    ]);
}

// Asks the send-newsletter Edge Function to send due issues now (after "Send now"), or a
// test to the test list. The function's error message is passed on when it gives one.
export async function callSender(body: { action: 'tick' } | { action: 'test'; issue_id: string }): Promise<{ sent?: number }> {
  const { data, error } = await supabase.functions.invoke('send-newsletter', { body });
  if (error) {
    const ctx = (error as { context?: Response }).context;
    const msg = ctx ? ((await ctx.json().catch(() => null)) as { error?: string } | null)?.error : null;
    throw new Error(msg ?? 'The email service could not be reached. Try again later.');
  }
  return (data ?? {}) as { sent?: number };
}

// ---------- Words ----------
export const STATUS_LABEL: Record<IssueStatus, string> = {
  draft: 'Draft',
  awaiting_coordinator: 'With the G-Squad Coordinator',
  awaiting_pastor: 'With the Resident Pastor',
  approved: 'Approved',
  sent: 'Sent',
};
export const STATUS_TONE: Record<IssueStatus, 'neutral' | 'info' | 'warn' | 'ok'> = {
  draft: 'neutral',
  awaiting_coordinator: 'info',
  awaiting_pastor: 'info',
  approved: 'ok',
  sent: 'ok',
};

export const EDITOR_ROLES: AppRole[] = ['newsletter_editor', 'operations_lead'];
export const STARTER_ROLES: AppRole[] = ['newsletter_editor', 'gsquad_coordinator', 'operations_lead'];
export const READER_ROLES: AppRole[] = ['newsletter_editor', 'gsquad_coordinator', 'resident_pastor', 'operations_lead'];

// ---------- Helpers (unit-tested) ----------

// Months an issue can be started for: this month and the next 12, first days, newest last.
export function startableMonths(today: string, taken: string[]): string[] {
  const out: string[] = [];
  let y = Number(today.slice(0, 4));
  let m = Number(today.slice(5, 7));
  for (let i = 0; i <= 12; i++) {
    const iso = `${y}-${String(m).padStart(2, '0')}-01`;
    if (!taken.includes(iso)) out.push(iso);
    m += 1;
    if (m > 12) {
      m = 1;
      y += 1;
    }
  }
  return out;
}

// The approval steps for the Stepper: editors, Coordinator, Resident Pastor, sent.
export function approvalSteps(status: IssueStatus): { label: string; note: string; state: 'done' | 'current' | 'todo' }[] {
  const order: IssueStatus[] = ['draft', 'awaiting_coordinator', 'awaiting_pastor', 'approved', 'sent'];
  const at = order.indexOf(status);
  const state = (i: number) => (at > i ? 'done' : at === i ? 'current' : 'todo') as 'done' | 'current' | 'todo';
  return [
    { label: 'Editors', note: at === 0 ? 'Writing now' : 'Sent for approval', state: state(0) },
    { label: 'G-Squad Coordinator', note: 'Approves first', state: state(1) },
    { label: 'Resident Pastor', note: 'Final approval', state: state(2) },
    { label: 'Sent', note: 'Any edit after approval goes back to the Coordinator', state: status === 'sent' ? 'done' : at === 3 ? 'current' : 'todo' },
  ];
}

// What this leader may do with the issue now. A courtesy only: the database refuses the rest.
export function issueActions(issue: Pick<Issue, 'status' | 'send_started_at'>, roles: AppRole[], sendingNow: boolean) {
  const has = (...r: AppRole[]) => r.some((x) => roles.includes(x));
  const open = issue.status !== 'sent' && !sendingNow;
  return {
    edit: open && has(...EDITOR_ROLES),
    submit: open && issue.status === 'draft' && has(...EDITOR_ROLES),
    coordinatorApprove: open && issue.status === 'awaiting_coordinator' && has('gsquad_coordinator'),
    pastorApprove: open && issue.status === 'awaiting_pastor' && has('resident_pastor'),
    sendBack: open && ['awaiting_coordinator', 'awaiting_pastor', 'approved'].includes(issue.status) && has('gsquad_coordinator', 'resident_pastor', ...EDITOR_ROLES),
    sendNow: open && issue.status === 'approved' && has('gsquad_coordinator', 'resident_pastor'),
    test: issue.status !== 'sent' && has(...READER_ROLES),
  };
}

// While the sending job holds the issue (15 minutes from when it started).
export function isSending(sendStartedAt: string | null, now = Date.now()): boolean {
  if (!sendStartedAt) return false;
  return now - Date.parse(sendStartedAt) < 15 * 60_000;
}

// Test addresses typed one per line or separated by commas: cleaned, lower case, no repeats.
export function parseTestList(raw: string): { list: string[]; bad: string[] } {
  const parts = raw
    .split(/[\s,;]+/)
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  const list = [...new Set(parts)];
  const bad = list.filter((x) => !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(x) || x.length > 254);
  return { list, bad };
}

// Toggles an id in the issue's "left out" list.
export function toggleExcluded(excluded: string[], id: string): string[] {
  return excluded.includes(id) ? excluded.filter((x) => x !== id) : [...excluded, id];
}

// ---------- The public link page (/e/<token>) ----------
export interface Peek {
  purpose: 'rsvp' | 'react' | 'unsubscribe' | 'invalid';
  reaction?: string | null;
  event?: string | null;
  used?: boolean;
  done?: string;
}

// The question and the thank-you for each kind of link.
export function linkWords(p: Peek): { ask: string; button: string; done: string } {
  if (p.purpose === 'rsvp') return { ask: `Let the team know you'll be at ${p.event ?? 'this gathering'}?`, button: "Yes, I'll be there", done: `Thank you. We look forward to seeing you at ${p.event ?? 'the gathering'}.` };
  if (p.purpose === 'react') {
    const r = REACTIONS.find((x) => x.key === p.reaction);
    return { ask: `Send your reaction to this issue: ${r ? `${r.emoji} ${r.label}` : ''}?`, button: 'Send', done: 'Thank you. Your reaction has been counted (editors see totals only).' };
  }
  if (p.purpose === 'unsubscribe') return { ask: 'Stop receiving The Greatness Brief by email?', button: 'Stop the emails', done: 'Done. You will not receive The Greatness Brief any more. Ask your Team Lead if you would like it again.' };
  return { ask: '', button: '', done: '' };
}
