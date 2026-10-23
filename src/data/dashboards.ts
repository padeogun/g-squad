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
