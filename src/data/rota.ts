// -------------------------------------------------------------------------------------
// Rota data: assignments (who serves where on which Sunday), the units and roles each Sunday
// needs, and who can serve (public.rota_candidates, migration 19).
// Row-level security decides what each leader sees: a Unit Lead their own unit's slots, the
// Operations Lead and G-Squad Coordinator everything. The assignment guard (migration 8)
// enforces the monthly limit (R1/R2), holidays (R10) and unit membership on every slot.
// The pure helper buildRota() is unit-tested in rota.test.ts.
// -------------------------------------------------------------------------------------
import { useQuery } from '@tanstack/react-query';
import type { Database } from '../lib/database.types';
import { supabase } from '../lib/supabase';

export type Assignment = Database['public']['Tables']['assignments']['Row'];
export type Candidate = Database['public']['Functions']['rota_candidates']['Returns'][number];

// First and last day of the month containing `month` ("2026-11-01" -> "2026-11-30").
export function monthBounds(month: string): { from: string; to: string } {
  const [y, m] = month.split('-').map(Number);
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return { from: `${y}-${String(m).padStart(2, '0')}-01`, to: `${y}-${String(m).padStart(2, '0')}-${last}` };
}

// Sunday services (grid + its project) in a month.
export const useMonthSundays = (month: string) =>
  useQuery({
    queryKey: ['grids', 'month', month],
    queryFn: async () => {
      const { from, to } = monthBounds(month);
      const { data, error } = await supabase
        .from('service_grids')
        .select('id, project_id, service_date, status, version')
        .gte('service_date', from)
        .lte('service_date', to)
        .order('service_date');
      if (error) throw error;
      return data;
    },
  });

// One unit's demand across the month's Sunday projects.
export const useUnitDemand = (unitId: string, projectIds: string[]) =>
  useQuery({
    queryKey: ['demand', 'unit', unitId, projectIds],
    enabled: !!unitId && projectIds.length > 0,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('team_demand')
        .select('id, project_id, unit_id, church_role_id, on_date, slots_needed')
        .eq('unit_id', unitId)
        .in('project_id', projectIds);
      if (error) throw error;
      return data;
    },
  });

// One unit's live slots (planned or served) in a date range.
export const useUnitAssignments = (unitId: string, from: string, to: string) =>
  useQuery({
    queryKey: ['assignments', unitId, from, to],
    enabled: !!unitId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('assignments')
        .select('id, project_id, person_id, unit_id, church_role_id, serve_date, status, override_reason')
        .eq('unit_id', unitId)
        .gte('serve_date', from)
        .lte('serve_date', to)
        .in('status', ['planned', 'served', 'no_show']);
      if (error) throw error;
      return data as Assignment[];
    },
  });

// Who can serve in a unit on a date (fewest slots this month first).
export const useCandidates = (unitId: string, date: string | null) =>
  useQuery({
    queryKey: ['candidates', unitId, date],
    enabled: !!unitId && !!date,
    // Slot counts change as people are assigned; always fetch fresh for the picker.
    staleTime: 0,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('rota_candidates', { p_unit: unitId, p_date: date! });
      if (error) throw error;
      return data as Candidate[];
    },
  });

// ---------- Pure helper: lay out a unit's month as rows of slots ----------

export interface DemandRow {
  project_id: string;
  church_role_id: string | null;
  on_date: string;
  slots_needed: number;
}

export interface RotaSlot {
  roleId: string | null; // null = any role
  date: string;
  projectId: string;
  assignment: Pick<Assignment, 'id' | 'person_id' | 'status' | 'church_role_id'> | null;
}

export interface RotaRow {
  roleId: string | null;
  // One cell per Sunday; a role needing 2 people on a Sunday becomes 2 rows (slot 1, slot 2).
  slotNo: number;
  cells: Map<string, RotaSlot>; // by date
}

// Rows: for each role, as many rows as the most people it needs on any one Sunday. Cells are
// filled with that role's assignments on that date in a stable order; assignments for a role
// with no demand (or beyond the demand) are kept in extra rows so nothing assigned is hidden.
export function buildRota(
  sundays: { service_date: string; project_id: string }[],
  demand: DemandRow[],
  assignments: Pick<Assignment, 'id' | 'person_id' | 'status' | 'church_role_id' | 'serve_date'>[],
): RotaRow[] {
  const key = (r: string | null) => r ?? '*';
  const roles = new Map<string, string | null>();
  const need = new Map<string, number>(); // role|date -> people needed
  for (const d of demand) {
    roles.set(key(d.church_role_id), d.church_role_id);
    const k = `${key(d.church_role_id)}|${d.on_date}`;
    need.set(k, (need.get(k) ?? 0) + d.slots_needed);
  }
  const byRoleDate = new Map<string, typeof assignments>();
  for (const a of assignments) {
    roles.set(key(a.church_role_id), a.church_role_id);
    const k = `${key(a.church_role_id)}|${a.serve_date}`;
    byRoleDate.set(k, [...(byRoleDate.get(k) ?? []), a].sort((x, y) => x.id.localeCompare(y.id)));
  }
  const projectOf = new Map(sundays.map((s) => [s.service_date, s.project_id]));

  const rows: RotaRow[] = [];
  for (const [rk, roleId] of roles) {
    const depth = Math.max(
      1,
      ...sundays.map((s) => Math.max(need.get(`${rk}|${s.service_date}`) ?? 0, byRoleDate.get(`${rk}|${s.service_date}`)?.length ?? 0)),
    );
    for (let slotNo = 1; slotNo <= depth; slotNo++) {
      const cells = new Map<string, RotaSlot>();
      for (const s of sundays) {
        const needed = need.get(`${rk}|${s.service_date}`) ?? 0;
        const assigned = byRoleDate.get(`${rk}|${s.service_date}`) ?? [];
        const a = assigned[slotNo - 1] ?? null;
        // A cell exists if the Sunday needs this slot or someone already fills it.
        if (slotNo <= needed || a) cells.set(s.service_date, { roleId, date: s.service_date, projectId: projectOf.get(s.service_date)!, assignment: a });
      }
      rows.push({ roleId, slotNo, cells });
    }
  }
  return rows;
}
