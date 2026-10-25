// -------------------------------------------------------------------------------------
// Dashboard figures from the database (migration 20). The functions check who is asking and
// return counts only (church) or the caller's own unit's figures (unit); the shapes below
// mirror the JSON they build. Also: the capacity calendar (migration 6) and the outstanding
// project inputs list (v_project_inputs, readable church-wide).
// -------------------------------------------------------------------------------------
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';

export interface EngagementMix {
  active: number;
  occasional: number;
  new: number;
  inactive: number;
  paused: number;
}

export interface ChurchDashboard {
  as_of: string;
  volunteers: number;
  team_places: number;
  multi_unit: number;
  units: number;
  purposes: number;
  engagement: EngagementMix;
  over_limit: number;
  checkins_open: number;
  inputs_outstanding: number;
  inputs_overdue: number;
  units_table: {
    unit_id: string;
    name: string;
    purpose: string | null;
    headcount: number;
    target: number | null;
    active: number;
    open_8_weeks: number;
    // Null when the caller may not read this unit's one-to-ones (security review 12, R01).
    one_to_ones_quarter: number | null;
  }[];
  next_sunday: {
    grid_id: string;
    service_date: string;
    status: 'draft' | 'finalised' | 'approved';
    version: number;
    units_needed: number;
    open_slots: number;
  } | null;
}

export interface UnitDashboard {
  as_of: string;
  headcount: number;
  target: number | null;
  engagement: EngagementMix;
  open_8_weeks: number;
  // Only one-to-ones the caller may read; null (and visible false) when they may read none
  // in this unit, e.g. the Operations Lead (security review 12, R01).
  one_to_ones_quarter: number | null;
  one_to_ones_visible: boolean;
  checkins_open: number;
  pipeline: { stage: string; count: number }[];
  members: {
    person_id: string;
    engagement: keyof EngagementMix | 'left';
    slots_this_month: number;
    slot_limit: number;
    // Migration 28: the limit in hours across all serving.
    hours_this_month: number;
    hours_limit: number;
    holiday_from: string | null;
    holiday_to: string | null;
    last_one_to_one: string | null;
  }[];
}

export const useChurchDashboard = (enabled: boolean) =>
  useQuery({
    queryKey: ['dashboard', 'church'],
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('church_dashboard');
      if (error) throw error;
      return data as unknown as ChurchDashboard;
    },
  });

export const useUnitDashboard = (unitId: string) =>
  useQuery({
    queryKey: ['dashboard', 'unit', unitId],
    enabled: !!unitId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('unit_dashboard', { p_unit: unitId });
      if (error) throw error;
      return data as unknown as UnitDashboard;
    },
  });

// Spare capacity per unit per month for a year: slots members offer minus regular need and
// project demand. Negative = shortfall.
export const useCapacity = (year: number, enabled: boolean) =>
  useQuery({
    queryKey: ['capacity', year],
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('capacity_calendar', { p_year: year });
      if (error) throw error;
      return data as { unit_id: string; unit_name: string; month: string; spare: number }[];
    },
  });

// Inputs still owed on projects, oldest due first (Church Dashboard list).
export const useOutstandingInputs = (enabled: boolean) =>
  useQuery({
    queryKey: ['inputs', 'outstanding'],
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('v_project_inputs')
        .select('id, title, due_on, display_status, project_id, requested_from_user_id')
        .neq('display_status', 'received')
        .order('due_on')
        .limit(20);
      if (error) throw error;
      // Project and leader names for those rows (both readable church-wide).
      const projectIds = [...new Set(data.map((i) => i.project_id!).filter(Boolean))];
      const userIds = [...new Set(data.map((i) => i.requested_from_user_id!).filter(Boolean))];
      const [projects, users] = await Promise.all([
        projectIds.length ? supabase.from('projects').select('id, name').in('id', projectIds) : { data: [], error: null },
        userIds.length ? supabase.from('app_users').select('id, display_name').in('id', userIds) : { data: [], error: null },
      ]);
      if (projects.error) throw projects.error;
      if (users.error) throw users.error;
      const pName = new Map((projects.data ?? []).map((p) => [p.id, p.name]));
      const uName = new Map((users.data ?? []).map((u) => [u.id, u.display_name]));
      return data.map((i) => ({
        ...i,
        project: pName.get(i.project_id!) ?? 'Project',
        owedBy: uName.get(i.requested_from_user_id!) ?? 'Leader',
      }));
    },
  });

// Roles that see the church dashboard (mirrors public.church_dashboard()).
export const DASHBOARD_ROLES = [
  'resident_pastor',
  'purpose_head',
  'unit_lead',
  'deputy_unit_lead',
  'gsquad_coordinator',
  'operations_lead',
  'pastoral_lead',
] as const;

// Roles that see the capacity calendar (mirrors public.capacity_calendar(): narrower than the
// dashboard roles, so the TECi Coordinator and pastoral lead don't get a call the database
// refuses; security review 12, R04).
export const CAPACITY_ROLES = ['resident_pastor', 'purpose_head', 'gsquad_coordinator', 'unit_lead', 'deputy_unit_lead', 'operations_lead'] as const;

// Months with a shortfall for each unit: { unitName -> ['Mar', 'Apr'] } (dashboard summary).
export function shortfalls(rows: { unit_name: string; month: string; spare: number }[]): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const r of rows) {
    if (Number(r.spare) >= 0) continue;
    const m = new Date(`${r.month.slice(0, 10)}T12:00:00Z`).toLocaleDateString('en-GB', { month: 'short', timeZone: 'UTC' });
    out.set(r.unit_name, [...(out.get(r.unit_name) ?? []), m]);
  }
  return out;
}

// ---------- Fair share, rest and leaders' load (migration 30) ----------
export interface FairShare {
  month: string;
  members: number;
  bands: { none: number; up_to_3: number; three_to_6: number; six_to_9: number; over_9: number };
  // Percentage of all hours; null when nobody served or there are fewer than 10 members
  // (SECURITY REVIEW 20, F01: the busiest fifth is then always at least two people).
  busiest_fifth_share: number | null;
  not_asked_3_months: number;
  leaders_over: number;
}

// Counts only, for the Church Dashboard audience (public.fair_share).
export const useFairShare = (month: string, enabled: boolean) =>
  useQuery({
    queryKey: ['dashboard', 'fair_share', month],
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('fair_share', { p_month: month });
      if (error) throw error;
      return data as unknown as FairShare;
    },
  });

// By name, for the G-Squad Coordinator, Resident Pastor, Operations Lead and Pastoral Lead.
export const LEADER_CARE_ROLES = ['gsquad_coordinator', 'resident_pastor', 'operations_lead', 'pastoral_lead'] as const;
export const useLeadersCarryingTooMuch = (enabled: boolean) =>
  useQuery({
    queryKey: ['dashboard', 'leaders_load'],
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('leaders_carrying_too_much');
      if (error) throw error;
      return data ?? [];
    },
  });

// The bands in reading order, with their labels.
export const HOUR_BANDS: { key: keyof FairShare['bands']; label: string }[] = [
  { key: 'none', label: 'Not serving' },
  { key: 'up_to_3', label: 'Up to 3 h' },
  { key: 'three_to_6', label: '3 to 6 h' },
  { key: 'six_to_9', label: '6 to 9 h' },
  { key: 'over_9', label: 'Over 9 h' },
];

// Width of a band's bar as a percentage of the largest band (0 when there are no members).
export function bandWidth(count: number, bands: FairShare['bands']): number {
  const max = Math.max(...Object.values(bands));
  return max > 0 ? Math.round((count / max) * 100) : 0;
}

// ---------- Serving rules (SECURITY REVIEW 20, F03) ----------
// The four church-wide serving rules on the Dashboard's Serving rules card, checked before
// saving. Before, a cleared box was sent as 0: for "Sundays off a month" that switched the
// rest rule off for everyone without a word, and every save sent all four values, so a page
// left open overwrote a change someone else had made since. The database still decides (its
// checks and church_settings_guard); this only stops slips and sends just what changed.
export interface ServingRules {
  serving_limit_per_month: number;
  hours_per_slot: number;
  sundays_off_per_month: number;
  leader_roles_max: number;
}
export const SERVING_RULES: { key: keyof ServingRules; label: string; min: number; max: number; step: number }[] = [
  { key: 'serving_limit_per_month', label: 'Usual slots a month', min: 1, max: 31, step: 1 },
  { key: 'hours_per_slot', label: 'Hours in a usual slot', min: 0.5, max: 16, step: 0.5 },
  { key: 'sundays_off_per_month', label: 'Sundays off a month', min: 0, max: 3, step: 1 },
  { key: 'leader_roles_max', label: 'Leadership roles at once', min: 1, max: 10, step: 1 },
];

export function servingRulesPatch(
  edits: Partial<Record<keyof ServingRules, string>>,
  current: ServingRules,
): { patch: Partial<ServingRules>; error?: string } {
  const patch: Partial<ServingRules> = {};
  for (const r of SERVING_RULES) {
    const raw = edits[r.key];
    if (raw === undefined) continue;
    const text = raw.trim();
    const n = Number(text);
    if (text === '' || !Number.isFinite(n) || n < r.min || n > r.max || Math.round(n / r.step) * r.step !== n) {
      const steps = r.step === 1 ? 'a whole number' : 'in half-hours';
      return { patch: {}, error: `${r.label}: ${steps} from ${r.min} to ${r.max}.` };
    }
    if (n !== Number(current[r.key])) patch[r.key] = n;
  }
  return { patch };
}
