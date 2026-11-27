// -------------------------------------------------------------------------------------
// Leadership stage history, the discipleship pathway, and the quarterly Maturity report
// (migration 35, decisions of 25 Nov 2026). "Members" are G-Squad members.
//   Stage history  written by the database whenever a leadership stage is set or changed;
//                  read by those who can read the member.
//   Pathway        Encounter, Foundation, Community, Depth, Sending (a reference list the
//                  December retreat may change). Treated like the faith fields: read and
//                  written only through logged functions, by the same people.
//   Report         maturity_report(quarter): counts only, never names, for the roles that
//                  read the monthly report. The database checks every call.
// -------------------------------------------------------------------------------------
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Database } from '../lib/database.types';
import type { MentorKind } from './growth';

export type StageChange = Database['public']['Tables']['leadership_stage_changes']['Row'];
export type PathwayStage = Database['public']['Tables']['pathway_stages']['Row'];
export type PathwayEntry = Database['public']['Functions']['get_person_pathway']['Returns'][number];

// Who may open the report (the database checks again; this only decides what is offered).
export const MATURITY_READERS = ['gsquad_coordinator', 'resident_pastor', 'purpose_head', 'operations_lead', 'pastoral_lead'] as const;

export interface MaturityReport {
  quarter_start: string;
  quarter_end: string;
  leadership: {
    stages: Array<{ stage: string; members: number }>;
    no_stage: number;
    moves_up: number;
    members_moved_up: number;
    leadership_courses: number;
  };
  pathway: {
    stages: Array<{ stage: string; stage_no: number; members: number }>;
    not_recorded: number;
    moved_on: number;
    first_recorded: number;
  };
  members: number;
  courses: Array<{
    course: string;
    kind: 'discipleship' | 'leadership';
    completed: number;
  }>;
  water_baptisms: number;
  spirit_baptisms: number;
  new_members: number;
  settled_in: number;
  day_30_held: number;
  day_90_held: number;
  pairings: Array<{ kind: MentorKind; open: number; started: number }>;
  one_to_ones: number;
}

// A move is to a later stage; the first entry (no "from") is where someone started.
export function describeChange(c: Pick<StageChange, 'from_stage_id' | 'to_stage_id'>, stageName: (id: string | null) => string): string {
  if (!c.from_stage_id) return c.to_stage_id ? `Started at ${stageName(c.to_stage_id)}` : 'Stage cleared';
  if (!c.to_stage_id) return `Stage cleared (was ${stageName(c.from_stage_id)})`;
  return `${stageName(c.from_stage_id)} → ${stageName(c.to_stage_id)}`;
}

// The member's current pathway stage: the latest entry by date reached (then by when recorded).
export function currentPathway<T extends { reached_on: string; recorded_at: string }>(entries: T[]): T | null {
  if (entries.length === 0) return null;
  return [...entries].sort((a, b) =>
    a.reached_on === b.reached_on ? a.recorded_at.localeCompare(b.recorded_at) : a.reached_on.localeCompare(b.reached_on),
  )[entries.length - 1];
}

// Percent of a whole, rounded, for the report's bars; 0 when there is no whole.
export const share = (part: number, whole: number) => (whole > 0 ? Math.round((part / whole) * 100) : 0);

export const useStageHistory = (personId: string) =>
  useQuery({
    queryKey: ['maturity', 'stage_history', personId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('leadership_stage_changes')
        .select('*')
        .eq('person_id', personId)
        .order('changed_on', { ascending: false })
        .order('changed_at', { ascending: false });
      if (error) throw error;
      return data;
    },
  });

export const usePathwayStages = () =>
  useQuery({
    queryKey: ['maturity', 'pathway_stages'],
    queryFn: async () => {
      const { data, error } = await supabase.from('pathway_stages').select('*').order('stage_no');
      if (error) throw error;
      return data;
    },
  });

// Every read is logged by the database, so it runs only once the leader asks to see it.
export const usePathway = (personId: string, enabled: boolean) =>
  useQuery({
    queryKey: ['maturity', 'pathway', personId],
    enabled,
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_person_pathway', {
        p_person: personId,
      });
      if (error) throw error;
      return data;
    },
  });

export function useSetPathway(personId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (a: { stageId: string; reachedOn: string }) => {
      const { error } = await supabase.rpc('set_person_pathway', {
        p_person: personId,
        p_stage: a.stageId,
        p_reached_on: a.reachedOn,
      });
      if (error) throw error;
    },
    onSuccess: () =>
      void qc.invalidateQueries({
        queryKey: ['maturity', 'pathway', personId],
      }),
  });
}

export function useRemovePathway(personId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (entryId: string) => {
      const { error } = await supabase.rpc('remove_person_pathway', {
        p_entry: entryId,
      });
      if (error) throw error;
    },
    onSuccess: () =>
      void qc.invalidateQueries({
        queryKey: ['maturity', 'pathway', personId],
      }),
  });
}

export const useMaturityReport = (quarter: string, enabled: boolean) =>
  useQuery({
    queryKey: ['maturity', 'report', quarter],
    enabled,
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('maturity_report', {
        p_quarter: quarter,
      });
      if (error) throw error;
      return data as unknown as MaturityReport;
    },
  });
