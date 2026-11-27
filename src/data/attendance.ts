// -------------------------------------------------------------------------------------
// Event attendance, members' facts, team engagement and planning committees (migration 36,
// decisions of 27 Nov 2026). Attending maturity events (prayer, Bible study, or an event whose
// primary aim is Discipleship & Maturity) counts as a maturity habit, shown as facts and
// never as a score. Attending or serving at events counts as team engagement. Committee seats
// on live events count in leaders' load with their own limit. The database checks every call.
// -------------------------------------------------------------------------------------
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Database } from '../lib/database.types';

export type Candidate = Database['public']['Functions']['event_attendance_candidates']['Returns'][number];
export type CommitteeSeat = Database['public']['Tables']['project_committee_members']['Row'];

export interface PersonEngagement {
  quarter_start: string;
  events_attended: number;
  // SECURITY REVIEW 28 (Ann A01): null for a reader who may not see the member's faith; then
  // events_attended leaves maturity events out too.
  maturity_attended: number | null;
  events_served: number;
  committees: number;
}
export interface TeamEngagement {
  quarter_start: string;
  members: number;
  attended: number;
  attended_maturity: number | null;   // SECURITY REVIEW 28 (Ann A01): null unless the reader may see the team's faith
  served: number;
  on_committees: number;
}

// Days of an event a check-in can be for: from its first day to its last, never after today.
export function attendanceDays(startsAt: string, endsAt: string, today: string): string[] {
  const first = startsAt.slice(0, 10);
  const last = endsAt.slice(0, 10) < today ? endsAt.slice(0, 10) : today;
  const out: string[] = [];
  for (let d = new Date(first + 'T12:00:00Z'); d.toISOString().slice(0, 10) <= last; d.setUTCDate(d.getUTCDate() + 1)) {
    out.push(d.toISOString().slice(0, 10));
  }
  return out;
}

// The day a check-in list opens on: today if the event runs today, else its last day so far.
export const defaultAttendanceDay = (days: string[], today: string) => (days.includes(today) ? today : (days[days.length - 1] ?? ''));

// "Attended 4 events this quarter, 2 of them prayer or Bible study", as plain facts.
export function engagementFacts(e: PersonEngagement): string[] {
  const n = (k: number, one: string, many: string) => `${k} ${k === 1 ? one : many}`;
  // SECURITY REVIEW 28 (Ann A01): when maturity events are not shown, say so, so the count
  // is not read as every event the member came to.
  const maturity =
    e.maturity_attended === null
      ? ' (prayer, Bible study and discipleship events not shown)'
      : e.maturity_attended
        ? `, ${e.maturity_attended} of them prayer, Bible study or discipleship`
        : '';
  const facts = [
    `Attended ${n(e.events_attended, 'event', 'events')}${maturity}`,
    `Served at ${n(e.events_served, 'event', 'events')}`,
  ];
  if (e.committees) facts.push(`On ${n(e.committees, 'planning committee', 'planning committees')}`);
  return facts;
}

export const useCandidates = (projectId: string, day: string, enabled: boolean) =>
  useQuery({
    queryKey: ['attendance', projectId, day],
    enabled: enabled && !!day,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('event_attendance_candidates', { p_project: projectId, p_on: day });
      if (error) throw error;
      return data;
    },
  });

export function useMarkAttendance(projectId: string, day: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (a: { personId: string; attended: boolean }) => {
      if (a.attended) {
        const { error } = await supabase.from('event_attendance').insert({
          project_id: projectId,
          person_id: a.personId,
          attended_on: day,
        });
        if (error) throw error;
      } else {
        const { error } = await supabase
          .from('event_attendance')
          .delete()
          .eq('project_id', projectId)
          .eq('person_id', a.personId)
          .eq('attended_on', day);
        if (error) throw error;
      }
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['attendance', projectId] });
      void qc.invalidateQueries({ queryKey: ['engagement'] });
    },
  });
}

export const usePersonEngagement = (personId: string, quarter?: string) =>
  useQuery({
    queryKey: ['engagement', 'person', personId, quarter ?? 'now'],
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('person_engagement', {
        p_person: personId,
        ...(quarter ? { p_quarter: quarter } : {}),
      });
      if (error) throw error;
      return data as unknown as PersonEngagement;
    },
  });

export const useTeamEngagement = (unitId: string | undefined) =>
  useQuery({
    queryKey: ['engagement', 'team', unitId],
    enabled: !!unitId,
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('team_engagement', {
        p_unit: unitId!,
      });
      if (error) throw error;
      return data as unknown as TeamEngagement;
    },
  });

export const useCommittee = (projectId: string) =>
  useQuery({
    queryKey: ['committee', projectId],
    queryFn: async () => {
      const { data, error } = await supabase.from('project_committee_members').select('*').eq('project_id', projectId).order('created_at');
      if (error) throw error;
      return data;
    },
  });

export function useAddCommitteeMember(projectId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (a: { personId: string; role: string }) => {
      const { error } = await supabase.from('project_committee_members').insert({
        project_id: projectId,
        person_id: a.personId,
        role: a.role.trim() || null,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['committee', projectId] });
      void qc.invalidateQueries({ queryKey: ['dashboard'] });
    },
  });
}

export function useRemoveCommitteeMember(projectId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('project_committee_members').delete().eq('id', id).eq('project_id', projectId);
      if (error) throw error;
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['committee', projectId] });
      void qc.invalidateQueries({ queryKey: ['dashboard'] });
    },
  });
}
