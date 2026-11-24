// -------------------------------------------------------------------------------------
// The four focus areas (migration 33, decision of 24 Nov 2026). The global church assesses
// everything against them; the definitions below are TEC's own words (Paul, 24 Nov 2026).
//   Events   aims named before approval (one primary), each area rated 0-4 afterwards, with
//            counts only (never names).
//   Teams    a quarterly conversation, one note per area (what went well, what next).
//   Members  one area to grow in and a next step in the one-to-one; never a score (R20).
// The database decides who may write what and when (app.project_focus_write_guard,
// app.project_outcome_guard, app.unit_reflection_guard); these hooks only read and save.
// -------------------------------------------------------------------------------------
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Database } from '../lib/database.types';

export type FocusArea = Database['public']['Enums']['focus_area'];
export type GrowthProgress = Database['public']['Enums']['growth_progress'];
export type ProjectFocus = Database['public']['Tables']['project_focus']['Row'];
export type FocusReview = Database['public']['Tables']['project_focus_review']['Row'];
export type ProjectOutcomes = Database['public']['Tables']['project_outcomes']['Row'];
export type UnitReflection = Database['public']['Tables']['unit_focus_reflections']['Row'];

export interface FocusAreaInfo {
  key: FocusArea;
  name: string;
  short: string; // one line for cards and select options
  definition: string; // TEC's definition, shown as help
}

// In the order the global church lists them.
export const FOCUS_AREAS: FocusAreaInfo[] = [
  {
    key: 'discipleship',
    name: 'Discipleship & Maturity',
    short: 'Courses, the Greatness Track and maturity habits',
    definition:
      'Engagement in discipleship courses and the Greatness Track Program, and in maturity habits: evangelism, prayer, water and Holy Spirit baptism.',
  },
  {
    key: 'assimilation',
    name: 'Assimilation',
    short: 'Connected, at home, living ASHLIE',
    definition:
      'Church: every visitor engaged within 48 hours of their visit and connected to a community. G-Squad: every member feels part of the family, is active in a community and has adopted ASHLIE, at home with the whole G-Squad and not only their own team.',
  },
  {
    key: 'pastoral_care',
    name: 'Pastoral Care',
    short: 'Check-ins, one-to-ones, celebrating special moments',
    definition:
      'Checking in with members so no one goes through difficult times alone; regular one-to-ones with their team’s leadership; birthdays, wedding anniversaries and other special moments celebrated.',
  },
  {
    key: 'soul_winning',
    name: 'Soul Winning',
    short: 'Bringing people to Jesus',
    definition: 'Every effort to bring more people to accept Jesus as their Lord and Saviour.',
  },
];

export const focusName = (k: FocusArea | null | undefined) => FOCUS_AREAS.find((a) => a.key === k)?.name ?? '';

// Five levels for how far an event achieved an area (finer than three, Paul 24 Nov 2026).
// Events are rated; people never are.
export const RATINGS = [
  { value: 0, label: 'Not achieved' },
  { value: 1, label: 'A little' },
  { value: 2, label: 'Partly' },
  { value: 3, label: 'Mostly' },
  { value: 4, label: 'Fully' },
] as const;
export const ratingLabel = (n: number | null | undefined) => RATINGS.find((r) => r.value === n)?.label ?? 'Not rated';

// The event's counts, each tied to the area it shows. Counts only, never names.
export const OUTCOME_FIELDS: Array<{ key: keyof Omit<ProjectOutcomes, 'project_id' | 'church_id' | 'updated_by' | 'updated_at'>; label: string; area: FocusArea }> = [
  { key: 'first_time_guests', label: 'First-time guests', area: 'soul_winning' },
  { key: 'decisions_for_christ', label: 'Decisions for Christ', area: 'soul_winning' },
  { key: 'guests_contacted_48h', label: 'Guests contacted within 48 hours', area: 'assimilation' },
  { key: 'connected_to_community', label: 'Connected to a community', area: 'assimilation' },
  { key: 'next_step_signups', label: 'Signed up for a next step (course, Greatness Track, baptism)', area: 'discipleship' },
  { key: 'care_followups', label: 'Prayer or care follow-ups', area: 'pastoral_care' },
];

export const GROWTH_PROGRESS: Array<{ value: GrowthProgress; label: string }> = [
  { value: 'done', label: 'Done' },
  { value: 'in_progress', label: 'Under way' },
  { value: 'not_yet', label: 'Not yet' },
];

// ---------- pure helpers (tested) ----------

// The aims can change only while the event is a draft or waiting for a decision.
export const aimsEditable = (status: string) => status === 'draft' || status === 'submitted';

// The review is written once the event has started, and until it is closed.
export const reviewOpen = (status: string, startsAt: string, now: Date = new Date()) =>
  (status === 'approved' || status === 'in_progress') && new Date(startsAt).getTime() <= now.getTime();

// What stops the aims from being ready for approval, in plain words.
export function aimProblems(rows: Array<Pick<ProjectFocus, 'is_primary' | 'intended_outcome'>>): string[] {
  const out: string[] = [];
  if (rows.length === 0) out.push('Name at least one focus area.');
  const primaries = rows.filter((r) => r.is_primary).length;
  if (rows.length > 0 && primaries === 0) out.push('Choose which focus area is primary.');
  if (primaries > 1) out.push('Only one focus area can be primary.');
  if (rows.some((r) => r.intended_outcome.trim() === '')) out.push('Each focus area needs an intended outcome.');
  return out;
}

// A target or count typed in a box: blank is "none", otherwise a whole number 0..100000.
export function parseCount(x: string): { ok: true; value: number | null } | { ok: false } {
  const t = x.trim();
  if (t === '') return { ok: true, value: null };
  if (!/^\d+$/.test(t)) return { ok: false };
  const n = Number(t);
  return n <= 100000 ? { ok: true, value: n } : { ok: false };
}

// Quarters start on 1 Jan, 1 Apr, 1 Jul and 1 Oct (London dates as yyyy-mm-dd).
export function quarterOf(isoDate: string): string {
  const [y, m] = isoDate.split('-').map(Number);
  const qm = Math.floor((m - 1) / 3) * 3 + 1;
  return `${y}-${String(qm).padStart(2, '0')}-01`;
}
export function previousQuarter(q: string): string {
  const [y, m] = q.split('-').map(Number);
  return m === 1 ? `${y - 1}-10-01` : `${y}-${String(m - 3).padStart(2, '0')}-01`;
}
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
export function quarterName(q: string): string {
  const [y, m] = q.split('-').map(Number);
  return `${MONTHS[m - 1]}–${MONTHS[m + 1]} ${y}`;
}

// Rated events per level (0..4) into how many were rated and how many reached "mostly" or more.
export function ratingSpread(counts: number[]): { rated: number; mostlyOrMore: number } {
  const rated = counts.reduce((a, b) => a + b, 0);
  const mostlyOrMore = (counts[3] ?? 0) + (counts[4] ?? 0);
  return { rated, mostlyOrMore };
}

// ---------- events ----------
const refreshEvent = (qc: ReturnType<typeof useQueryClient>, projectId: string) => {
  void qc.invalidateQueries({ queryKey: ['focus', projectId] });
  void qc.invalidateQueries({ queryKey: ['readiness', projectId] });
};

export const useProjectFocus = (projectId: string) =>
  useQuery({
    queryKey: ['focus', projectId, 'aims'],
    queryFn: async () => {
      const { data, error } = await supabase.from('project_focus').select('*').eq('project_id', projectId);
      if (error) throw error;
      return data;
    },
  });

// Saving an aim. Making one primary first clears the old primary (one primary per event).
export function useSaveAim(projectId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (a: { area: FocusArea; is_primary: boolean; intended_outcome: string; target_count: number | null }) => {
      if (a.is_primary) {
        const { error: e1 } = await supabase
          .from('project_focus')
          .update({ is_primary: false })
          .eq('project_id', projectId)
          .eq('is_primary', true)
          .neq('area', a.area);
        if (e1) throw e1;
      }
      const { error } = await supabase
        .from('project_focus')
        .upsert({ project_id: projectId, ...a, intended_outcome: a.intended_outcome.trim() }, { onConflict: 'project_id,area' });
      if (error) throw error;
    },
    onSuccess: () => refreshEvent(qc, projectId),
  });
}

export function useRemoveAim(projectId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (area: FocusArea) => {
      const { error } = await supabase.from('project_focus').delete().eq('project_id', projectId).eq('area', area);
      if (error) throw error;
    },
    onSuccess: () => refreshEvent(qc, projectId),
  });
}

export const useFocusReviews = (projectId: string) =>
  useQuery({
    queryKey: ['focus', projectId, 'reviews'],
    queryFn: async () => {
      const { data, error } = await supabase.from('project_focus_review').select('*').eq('project_id', projectId);
      if (error) throw error;
      return data;
    },
  });

export function useSaveReview(projectId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (r: { area: FocusArea; rating: number; story: string }) => {
      const { error } = await supabase
        .from('project_focus_review')
        .upsert({ project_id: projectId, area: r.area, rating: r.rating, story: r.story.trim() || null }, { onConflict: 'project_id,area' });
      if (error) throw error;
    },
    onSuccess: () => refreshEvent(qc, projectId),
  });
}

export const useProjectOutcomes = (projectId: string) =>
  useQuery({
    queryKey: ['focus', projectId, 'outcomes'],
    queryFn: async () => {
      const { data, error } = await supabase.from('project_outcomes').select('*').eq('project_id', projectId).maybeSingle();
      if (error) throw error;
      return data;
    },
  });

export function useSaveOutcomes(projectId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (counts: Partial<Record<(typeof OUTCOME_FIELDS)[number]['key'], number | null>>) => {
      const { error } = await supabase.from('project_outcomes').upsert({ project_id: projectId, ...counts }, { onConflict: 'project_id' });
      if (error) throw error;
    },
    onSuccess: () => refreshEvent(qc, projectId),
  });
}

// ---------- teams ----------
export const useUnitReflections = (unitId: string, quarters: string[]) =>
  useQuery({
    queryKey: ['reflections', unitId, quarters],
    enabled: !!unitId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('unit_focus_reflections')
        .select('*')
        .eq('unit_id', unitId)
        .in('quarter_start', quarters);
      if (error) throw error;
      return data;
    },
  });

// Saving a note; clearing both boxes removes it (an empty note is not kept).
export function useSaveReflection(unitId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (r: { quarter_start: string; area: FocusArea; went_well: string; next_step: string }) => {
      const went = r.went_well.trim();
      const next = r.next_step.trim();
      if (!went && !next) {
        const { error } = await supabase
          .from('unit_focus_reflections')
          .delete()
          .eq('unit_id', unitId)
          .eq('quarter_start', r.quarter_start)
          .eq('area', r.area);
        if (error) throw error;
        return;
      }
      const { error } = await supabase.from('unit_focus_reflections').upsert(
        { unit_id: unitId, quarter_start: r.quarter_start, area: r.area, went_well: went || null, next_step: next || null },
        { onConflict: 'unit_id,quarter_start,area' },
      );
      if (error) throw error;
    },
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['reflections', unitId] }),
  });
}

// ---------- the quarter at a glance (counts only) ----------
export const SUMMARY_READERS = ['gsquad_coordinator', 'resident_pastor', 'purpose_head', 'operations_lead', 'pastoral_lead'] as const;

export interface FocusSummary {
  quarter_start: string;
  quarter_end: string;
  areas: Array<{
    area: FocusArea;
    events_aimed: number;
    events_primary: number;
    events_rated: number;
    rating_counts: number[];
    members_growing: number;
    teams_talked: number;
  }>;
  outcomes: Record<'events' | (typeof OUTCOME_FIELDS)[number]['key'], number>;
  gsquad: {
    members: number;
    in_community: number;
    one_to_ones: number;
    steps_done: number;
    steps_followed_up: number;
    open_checkins: number;
    celebrations_opted_in: number;
    recognitions: number;
    in_teci: number;
    water_baptisms: number;
    spirit_baptisms: number;
  };
}

export const useFocusSummary = (quarter: string, enabled: boolean) =>
  useQuery({
    queryKey: ['focus_summary', quarter],
    enabled,
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('focus_areas_summary', { p_quarter: quarter });
      if (error) throw error;
      return data as unknown as FocusSummary;
    },
  });
