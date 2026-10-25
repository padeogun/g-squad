// -------------------------------------------------------------------------------------
// Care and growth (slice 5): the quarterly Team Lead one-to-one, its focus areas, the
// leadership's questions for a period, and Values in Action recognitions.
// Focus areas (decisions of 23 and 25 Oct 2026): ASHLIE values (a value lived out and one to
// grow in: notes, never scored, R20), sense of family, competence in role, personal walk with
// God (restricted: read through get_one_to_one_walk, every view logged), and ad hoc questions
// set by the G-Squad Coordinator. Who reads and writes is decided by the database
// (migrations 7, 11, 22 and 26).
// Pure quarter helpers are at the bottom and unit-tested.
// -------------------------------------------------------------------------------------
import { useQuery } from '@tanstack/react-query';
import type { Database } from '../lib/database.types';
import { supabase } from '../lib/supabase';

type T = Database['public']['Tables'];
export type OneToOne = T['one_to_ones']['Row'];
export type Prompt = T['one_to_one_prompts']['Row'];
export type Answer = T['one_to_one_answers']['Row'];
export type CoreValue = T['core_values']['Row'];
export type Feeling = Database['public']['Enums']['serving_feeling'];
export type Support = Database['public']['Enums']['support_need'];

async function rows<R>(p: PromiseLike<{ data: R[] | null; error: unknown }>): Promise<R[]> {
  const { data, error } = await p;
  if (error) throw error;
  return data ?? [];
}

// One team's one-to-ones for one quarter (only those this leader may read come back).
export const useOneToOnes = (unitId: string, quarter: string) =>
  useQuery({
    queryKey: ['one_to_ones', unitId, quarter],
    enabled: !!unitId,
    queryFn: () => rows(supabase.from('one_to_ones').select('*').eq('unit_id', unitId).eq('quarter_start', quarter)),
  });

export const useOneToOne = (id: string | undefined) =>
  useQuery({
    queryKey: ['one_to_ones', 'one', id],
    enabled: !!id,
    queryFn: async () => {
      const { data, error } = await supabase.from('one_to_ones').select('*').eq('id', id!).maybeSingle();
      if (error) throw error;
      return data;
    },
  });

export const usePrompts = () =>
  useQuery({ queryKey: ['ref', 'one_to_one_prompts'], queryFn: () => rows(supabase.from('one_to_one_prompts').select('*').order('starts_on', { ascending: false })) });

export const useAnswers = (otoId: string | undefined) =>
  useQuery({
    queryKey: ['one_to_one_answers', otoId],
    enabled: !!otoId,
    queryFn: () => rows(supabase.from('one_to_one_answers').select('*').eq('one_to_one_id', otoId!)),
  });

export const useCoreValues = () =>
  useQuery({
    queryKey: ['ref', 'core_values'],
    queryFn: () => rows(supabase.from('core_values').select('*').eq('is_active', true).order('sort_order')),
  });

// Values in Action counts by value for a unit (R20: by value, never per person).
export const useValueCounts = (unitId: string, from: string, to: string) =>
  useQuery({
    queryKey: ['values_in_action', unitId, from, to],
    enabled: !!unitId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('values_in_action_counts', { p_from: from, p_to: to, p_unit: unitId });
      if (error) throw error;
      return data as { letter: string; value_name: string; recognitions: number }[];
    },
  });

// ---------- Words ----------
export const FEELINGS: { value: Feeling; label: string }[] = [
  { value: 'thriving', label: 'Thriving' },
  { value: 'doing_well', label: 'Doing well' },
  { value: 'finding_it_hard', label: 'Finding it hard' },
  { value: 'overstretched', label: 'Overstretched' },
];
export const SUPPORT: { value: Support; label: string }[] = [
  { value: 'none', label: 'None needed' },
  { value: 'training', label: 'Training' },
  { value: 'fewer_slots', label: 'Fewer slots' },
  { value: 'change_of_role', label: 'A change of role' },
  { value: 'pastoral_check_in', label: 'A pastoral check-in' },
];

// ---------- Quarters ----------
// "2026-10-25" -> "2026-10-01" (the first day of its calendar quarter).
export function quarterStart(isoDate: string): string {
  const y = isoDate.slice(0, 4);
  const m = Number(isoDate.slice(5, 7));
  const q = Math.floor((m - 1) / 3) * 3 + 1;
  return `${y}-${String(q).padStart(2, '0')}-01`;
}

// The last day of a quarter: "2026-10-01" -> "2026-12-31".
export function quarterEnd(qStart: string): string {
  const y = Number(qStart.slice(0, 4));
  const m = Number(qStart.slice(5, 7)) + 2;
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return `${y}-${String(m).padStart(2, '0')}-${String(last).padStart(2, '0')}`;
}

// "2026-10-01" -> "October to December 2026".
export function quarterLabel(qStart: string): string {
  const names = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  const m = Number(qStart.slice(5, 7)) - 1;
  return `${names[m]} to ${names[m + 2]} ${qStart.slice(0, 4)}`;
}

// This quarter and the previous `back` quarters, newest first.
export function recentQuarters(todayIso: string, back = 4): string[] {
  const out: string[] = [];
  let q = quarterStart(todayIso);
  for (let i = 0; i <= back; i++) {
    out.push(q);
    const y = Number(q.slice(0, 4));
    const m = Number(q.slice(5, 7)) - 3;
    q = m < 1 ? `${y - 1}-${String(m + 12).padStart(2, '0')}-01` : `${y}-${String(m).padStart(2, '0')}-01`;
  }
  return out;
}

// The leadership questions being asked on a day.
export function promptsFor(prompts: Prompt[], day: string): Prompt[] {
  return prompts.filter((p) => p.is_active && p.starts_on <= day && day <= p.ends_on);
}
