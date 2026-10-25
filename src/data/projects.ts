// -------------------------------------------------------------------------------------
// Projects and events (slice 4): projects, their High-level Event Planning form, volunteers
// needed (team demand), the input tracker and action points. Everyone signed in reads them
// (projects are church-wide, for the calendar and dashboards); who may change what is decided
// by row-level security and the guards in migrations 8 and 24. public.project_readiness()
// reports the approval checks and who may manage or approve, so the page shows the right buttons.
// Sunday services are projects too, but they live under Sunday Operations, not here.
// Pure helpers (London time, plan section status) are at the bottom and unit-tested.
// -------------------------------------------------------------------------------------
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Database } from '../lib/database.types';
import { supabase } from '../lib/supabase';

type T = Database['public']['Tables'];
export type Project = T['projects']['Row'];
export type EventPlan = T['event_plans']['Row'];
export type PlanAction = T['event_plan_actions']['Row'];
export type Input = Database['public']['Views']['v_project_inputs']['Row'];
export type ProjectStatus = Database['public']['Enums']['project_status'];

async function rows<R>(p: PromiseLike<{ data: R[] | null; error: unknown }>): Promise<R[]> {
  const { data, error } = await p;
  if (error) throw error;
  return data ?? [];
}

// Every project except Sunday services (those are under Sunday Operations).
export const useProjects = () =>
  useQuery({
    queryKey: ['projects'],
    queryFn: () => rows(supabase.from('projects').select('*').eq('is_sunday_service', false).order('starts_at')),
  });

export const useProject = (id: string | undefined) =>
  useQuery({
    queryKey: ['projects', id],
    enabled: !!id,
    queryFn: async () => {
      const { data, error } = await supabase.from('projects').select('*').eq('id', id!).maybeSingle();
      if (error) throw error;
      return data;
    },
  });

export const useEventPlan = (projectId: string | undefined) =>
  useQuery({
    queryKey: ['event_plan', projectId],
    enabled: !!projectId,
    queryFn: async () => {
      const { data, error } = await supabase.from('event_plans').select('*').eq('project_id', projectId!).maybeSingle();
      if (error) throw error;
      return data;
    },
  });

export const useActions = (projectId: string | undefined) =>
  useQuery({
    queryKey: ['plan_actions', projectId],
    enabled: !!projectId,
    queryFn: () => rows(supabase.from('event_plan_actions').select('*').eq('project_id', projectId!).order('created_at')),
  });

// Inputs with the worked-out Overdue status (v_project_inputs, R9).
export const useInputs = (projectId: string | undefined) =>
  useQuery({
    queryKey: ['inputs', projectId],
    enabled: !!projectId,
    queryFn: () => rows(supabase.from('v_project_inputs').select('*').eq('project_id', projectId!).order('due_on')),
  });

// Inputs still asked of this leader, across projects (the "Requested from you" list).
export const useMyInputs = (userId: string | undefined) =>
  useQuery({
    queryKey: ['inputs', 'mine', userId],
    enabled: !!userId,
    queryFn: () =>
      rows(
        supabase
          .from('v_project_inputs')
          .select('*')
          .eq('requested_from_user_id', userId!)
          .neq('status', 'received')
          .order('due_on'),
      ),
  });

export interface Readiness {
  status: ProjectStatus;
  is_event: boolean;
  lead_time: { size: string; weeks_to_go: number; weeks_needed: number; ok: boolean } | null;
  committee: { needed: boolean; ok: boolean } | null;
  budget: { status: string; ok: boolean } | null;
  shortfall: string | null;
  shortfall_action: string | null;
  inputs_outstanding: number;
  inputs_overdue: number;
  review_done: boolean | null;
  can_manage: boolean;
  can_approve: boolean;
}

// The approval checks; refused (and then not shown) for roles outside planning.
export const useReadiness = (projectId: string | undefined) =>
  useQuery({
    queryKey: ['readiness', projectId],
    enabled: !!projectId,
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('project_readiness', { p_project: projectId! });
      if (error) throw error;
      return data as unknown as Readiness;
    },
  });

// Refreshes everything on a project page that a change can affect.
export function useRefreshProject(id: string) {
  const qc = useQueryClient();
  return () => {
    for (const k of [['projects'], ['readiness', id], ['event_plan', id], ['inputs'], ['plan_actions', id], ['demand', id]])
      qc.invalidateQueries({ queryKey: k });
  };
}

export const useProjectTypes = () =>
  useQuery({
    queryKey: ['ref', 'project_types'],
    queryFn: () => rows(supabase.from('project_types').select('id, name, default_level, is_active').order('name')),
  });

export const useSites = () =>
  useQuery({ queryKey: ['ref', 'sites'], queryFn: () => rows(supabase.from('sites').select('id, name').order('name')) });

// Roles that may start a project (mirrors projects_insert; Team Leads for their own team).
export const PROJECT_CREATORS = ['operations_lead', 'gsquad_coordinator', 'resident_pastor', 'purpose_head', 'unit_lead'] as const;

// ---------- Words ----------
export const STATUS_LABEL: Record<ProjectStatus, string> = {
  draft: 'Draft',
  submitted: 'Submitted',
  approved: 'Approved',
  in_progress: 'In progress',
  done: 'Done',
  cancelled: 'Cancelled',
};
export const STATUS_TONE: Record<ProjectStatus, 'neutral' | 'info' | 'ok' | 'warn' | 'danger'> = {
  draft: 'neutral',
  submitted: 'warn',
  approved: 'ok',
  in_progress: 'info',
  done: 'ok',
  cancelled: 'neutral',
};
export const SHORTFALL_ACTIONS = [
  { value: 'move', label: 'Move the date' },
  { value: 'scale_down', label: 'Scale it down' },
  { value: 'borrow', label: 'Borrow volunteers from another unit' },
  { value: 'recruit', label: 'Recruit more volunteers' },
];

// ---------- London time ----------
// Project times are stored as instants (UTC). Leaders type and read them as London wall-clock
// time, whatever their device's time zone, so the conversions name Europe/London explicitly.
const TZ = 'Europe/London';

function londonParts(d: Date) {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: TZ,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(d);
  const get = (t: string) => Number(parts.find((p) => p.type === t)?.value);
  return { y: get('year'), m: get('month'), d: get('day'), h: get('hour'), min: get('minute') };
}

// "2027-01-09" + "11:00" in London -> ISO instant. Handles GMT and British Summer Time.
export function londonToIso(date: string, time: string): string {
  const [y, m, d] = date.split('-').map(Number);
  const [h, min] = time.split(':').map(Number);
  const wanted = Date.UTC(y, m - 1, d, h, min);
  // Start from the wall time read as UTC, then correct by London's offset at that instant
  // (twice, so a guess on the other side of a clock change settles).
  let t = wanted;
  for (let i = 0; i < 2; i++) {
    const p = londonParts(new Date(t));
    t += wanted - Date.UTC(p.y, p.m - 1, p.d, p.h, p.min);
  }
  return new Date(t).toISOString();
}

// ISO instant -> London date ("2027-01-09") and time ("11:00") for form fields.
export function isoToLondon(iso: string): { date: string; time: string } {
  const p = londonParts(new Date(iso));
  const two = (n: number) => String(n).padStart(2, '0');
  return { date: `${p.y}-${two(p.m)}-${two(p.d)}`, time: `${two(p.h)}:${two(p.min)}` };
}

// "Saturday 9 January 2027, 11:00 – 15:00" (or across days: "… 11:00 – Sunday 10 January 2027, 13:00").
export function formatWhen(startIso: string, endIso: string): string {
  const day = (iso: string) =>
    new Intl.DateTimeFormat('en-GB', { timeZone: TZ, weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' })
      .format(new Date(iso))
      .replace(',', '');
  const s = isoToLondon(startIso);
  const e = isoToLondon(endIso);
  return s.date === e.date ? `${day(startIso)}, ${s.time} – ${e.time}` : `${day(startIso)}, ${s.time} – ${day(endIso)}, ${e.time}`;
}

// ---------- High-level Event Planning: sections and their status ----------
export interface PlanField {
  key: keyof EventPlan;
  label: string;
  type: 'text' | 'textarea' | 'select' | 'boolean' | 'number' | 'person';
  options?: { value: string; label: string }[];
  max?: number;
  hint?: string;
}
export interface PlanSection {
  no: number;
  title: string;
  fields: PlanField[];
}

const yesNo = (label: string, key: keyof EventPlan, hint?: string): PlanField => ({ key, label, type: 'boolean', hint });
const area = (label: string, key: keyof EventPlan, max = 2000, hint?: string): PlanField => ({ key, label, type: 'textarea', max, hint });

// Follows TEC's TECM High-level Event Planning workbook (12 sections). Budget decisions
// (approve / reject) are not fields here: Finance or the Resident Pastor make them with buttons.
export const PLAN_SECTIONS: PlanSection[] = [
  {
    no: 1,
    title: 'Event profile',
    fields: [
      {
        key: 'size',
        label: 'Size',
        type: 'select',
        options: [
          { value: 'small', label: 'Small (under 100)' },
          { value: 'medium', label: 'Medium (100 to 200)' },
          { value: 'large', label: 'Large (over 200)' },
        ],
      },
      {
        key: 'complexity',
        label: 'Complexity',
        type: 'select',
        options: [
          { value: 'low', label: 'Low' },
          { value: 'moderate', label: 'Moderate' },
          { value: 'high', label: 'High' },
        ],
      },
    ],
  },
  {
    no: 2,
    title: 'Initiation: why, alignment, who',
    fields: [
      area('Why are we doing this?', 'purpose_why'),
      area('Spiritual outcome', 'spiritual_outcome'),
      area('Alignment with the church vision', 'alignment'),
      area('Who is it for?', 'target_audience', 1000),
    ],
  },
  {
    no: 3,
    title: 'Leadership and ownership',
    fields: [
      yesNo('A planning committee is in place', 'has_planning_committee', 'Needed for a High complexity event'),
      area('Committee members', 'committee_members', 1000),
    ],
  },
  {
    no: 4,
    title: 'Feasibility',
    fields: [
      {
        key: 'calendar_check',
        label: 'Church calendar checked',
        type: 'select',
        options: [
          { value: 'not_checked', label: 'Not checked yet' },
          { value: 'confirmed', label: 'Confirmed: no clashes' },
          { value: 'conflict', label: 'Clashes with something' },
        ],
      },
      {
        key: 'venue_kind',
        label: 'Venue',
        type: 'select',
        options: [
          { value: 'internal', label: 'Our own venue' },
          { value: 'external', label: 'External venue' },
        ],
      },
      { key: 'venue_name', label: 'Venue name', type: 'text', max: 200 },
    ],
  },
  {
    no: 5,
    title: 'Budget',
    fields: [
      { key: 'budget_estimate_gbp', label: 'Estimate in £ (past events plus 10%)', type: 'number' },
      {
        key: 'funding',
        label: 'Funding',
        type: 'select',
        options: [
          { value: 'free', label: 'Free' },
          { value: 'ticketed', label: 'Ticketed' },
          { value: 'ministry_budget', label: 'Ministry budget' },
        ],
      },
      area('Money-handling plan', 'money_handling_plan', 2000, 'Needed for a ticketed event'),
    ],
  },
  {
    no: 6,
    title: 'Resources and logistics',
    fields: [area('Resources needed', 'required_resources'), area('Gaps to fill', 'resource_gaps')],
  },
  {
    no: 7,
    title: 'Event design',
    fields: [
      { key: 'setup_minutes', label: 'Set-up (minutes)', type: 'number' },
      { key: 'packdown_minutes', label: 'Pack-down (minutes)', type: 'number' },
      area('Main attraction', 'main_attraction', 1000),
      area('Engagement', 'engagement', 1000),
      area('Side activities', 'side_activities', 1000),
    ],
  },
  {
    no: 8,
    title: 'Event operations',
    fields: [
      area('Media plan', 'media_plan'),
      area('Logistics plan', 'logistics_plan'),
      yesNo('Childcare needed', 'childcare_needed'),
      yesNo('Risk assessment needed', 'risk_assessment_needed'),
      area('Safeguarding notes', 'safeguarding_notes', 2000, 'Visible to every leader: no names or personal details'),
    ],
  },
  {
    no: 9,
    title: 'Communications',
    fields: [
      yesNo('Communications plan done', 'comms_plan_done'),
      area('Strategy', 'comms_strategy'),
      {
        key: 'assets_status',
        label: 'Design assets',
        type: 'select',
        options: [
          { value: 'not_started', label: 'Not started' },
          { value: 'in_progress', label: 'In progress' },
          { value: 'done', label: 'Done' },
        ],
      },
      { key: 'signup_method', label: 'How people sign up', type: 'text', max: 500 },
      area('Follow-up plan', 'followup_plan', 1000),
    ],
  },
  {
    no: 10,
    title: 'Experience',
    fields: [area('Guest journey', 'guest_journey'), area('Hospitality', 'hospitality'), area('Decor', 'decor', 1000)],
  },
  {
    no: 11,
    title: 'Execution',
    fields: [{ key: 'on_day_lead_person_id', label: 'On-the-day lead', type: 'person' }, area('Quality checklist', 'qc_checklist')],
  },
  {
    no: 12,
    title: 'Review',
    fields: [
      area('Impact', 'review_impact', 4000),
      yesNo('Accounts done', 'review_accounts_done'),
      area('Stop / start / continue', 'review_operational', 4000),
      area('Feedback', 'review_feedback', 4000),
    ],
  },
];

export type Tone = 'ok' | 'warn' | 'danger' | 'info' | 'neutral';
const filled = (v: unknown) => v !== null && v !== undefined && String(v).trim() !== '';

// One section's status chip, from what has been filled in (a guide, not a rule; the rules
// that block approval are in the "Before approval" card).
export function sectionStatus(no: number, p: EventPlan, openActions = 0): { label: string; tone: Tone } {
  const done = { label: 'Complete', tone: 'ok' as Tone };
  const todo = { label: 'Not started', tone: 'neutral' as Tone };
  let s: { label: string; tone: Tone };
  switch (no) {
    case 1:
      s = done;
      break;
    case 2:
      s = filled(p.purpose_why) && filled(p.target_audience) ? done : filled(p.purpose_why) || filled(p.target_audience) ? { label: 'In progress', tone: 'info' } : todo;
      break;
    case 3:
      s = p.complexity === 'high' && !p.has_planning_committee ? { label: 'Committee needed', tone: 'danger' } : p.has_planning_committee ? { label: 'Committee formed', tone: 'ok' } : done;
      break;
    case 4:
      s = p.calendar_check === 'conflict' ? { label: 'Calendar clash', tone: 'danger' } : p.calendar_check === 'confirmed' && p.venue_kind ? { label: 'No clashes', tone: 'ok' } : p.calendar_check === 'confirmed' || p.venue_kind ? { label: 'In progress', tone: 'info' } : todo;
      break;
    case 5:
      s =
        p.budget_status === 'approved' ? { label: 'Budget approved', tone: 'ok' }
        : p.budget_status === 'not_needed' ? { label: 'No budget needed', tone: 'ok' }
        : p.budget_status === 'rejected' ? { label: 'Budget rejected', tone: 'danger' }
        : { label: 'Awaiting Finance', tone: 'warn' };
      break;
    case 6:
      s = filled(p.required_resources) ? done : todo;
      break;
    case 7:
      s = filled(p.main_attraction) ? done : filled(p.engagement) || filled(p.side_activities) ? { label: 'In progress', tone: 'info' } : todo;
      break;
    case 8:
      s = filled(p.logistics_plan) || filled(p.media_plan) ? (filled(p.logistics_plan) && filled(p.media_plan) ? done : { label: 'In progress', tone: 'info' }) : todo;
      break;
    case 9:
      s = p.comms_plan_done && p.assets_status === 'done' ? done : p.comms_plan_done || p.assets_status === 'in_progress' ? { label: 'Assets in progress', tone: 'info' } : todo;
      break;
    case 10:
      s = filled(p.guest_journey) ? done : filled(p.hospitality) || filled(p.decor) ? { label: 'In progress', tone: 'info' } : todo;
      break;
    case 11:
      s = p.on_day_lead_person_id ? done : todo;
      break;
    default:
      s = p.review_completed_at ? { label: 'Review complete', tone: 'ok' } : { label: 'After the event', tone: 'neutral' };
  }
  // Open action points keep a finished section from reading as complete.
  if (openActions > 0 && s.tone === 'ok') return { label: `${openActions} action${openActions > 1 ? 's' : ''} open`, tone: 'warn' };
  return s;
}
