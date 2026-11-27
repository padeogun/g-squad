// -------------------------------------------------------------------------------------
// Settling in, courses and mentors (migration 34, decision of 24 Nov 2026). "Members" are
// G-Squad members.
//   Settling in   eight steps for a new member: six ticked by their Team Lead (or the
//                 Coordinator), two read from the record (a buddy named; a Greatness Community).
//   Courses       which discipleship and leadership courses a member has completed, with dates.
//   Mentors       a buddy, a leader with an apprentice, or "each one disciples one"; one live
//                 pairing of each kind, ended rather than rewritten.
// The database decides who writes (app.growth_record_guard and row-level security).
// -------------------------------------------------------------------------------------
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Database } from '../lib/database.types';

export type AssimilationStep = Database['public']['Enums']['assimilation_step'];
export type MentorKind = Database['public']['Enums']['mentor_kind'];
export type StepRow = Database['public']['Tables']['assimilation_steps']['Row'];
export type CourseType = Database['public']['Tables']['course_types']['Row'];
export type CourseCompletion = Database['public']['Tables']['course_completions']['Row'];
export type Pairing = Database['public']['Tables']['member_mentors']['Row'];

// The eight steps in the order they usually happen. `auto` steps are read from the record.
// `dueDays`: days after joining by which it should have happened (shown as due, then late).
export type JourneyKey = AssimilationStep | 'buddy' | 'community';
export const JOURNEY: Array<{ key: JourneyKey; label: string; auto?: boolean; dueDays: number }> = [
  { key: 'welcomed', label: 'Welcomed by their Team Lead', dueDays: 7 },
  { key: 'buddy', label: 'Buddy named', auto: true, dueDays: 7 },
  { key: 'values_session', label: 'TEC culture and ASHLIE values session', dueDays: 30 },
  { key: 'first_serve_with_buddy', label: 'First serve alongside their buddy', dueDays: 30 },
  { key: 'day_30_conversation', label: '30-day conversation', dueDays: 30 },
  { key: 'community', label: 'Joined a Greatness Community', auto: true, dueDays: 60 },
  { key: 'met_other_teams', label: 'Spent time with another team', dueDays: 90 },
  { key: 'day_90_conversation', label: '90-day conversation', dueDays: 90 },
];

// How long after joining a member shows as settling in (unless every step is done).
export const SETTLING_DAYS = 120;

export const MENTOR_KINDS: Array<{ value: MentorKind; label: string; mentorLabel: string; hint: string }> = [
  { value: 'buddy', label: 'Buddy', mentorLabel: 'Their buddy', hint: 'Walks beside a new member through settling in.' },
  { value: 'apprentice', label: 'Apprentice', mentorLabel: 'Their leader', hint: 'A leader growing someone towards leading.' },
  { value: 'discipleship', label: 'Each one disciples one', mentorLabel: 'Discipled by', hint: 'One member helping another grow in faith.' },
];
export const mentorKind = (k: MentorKind) => MENTOR_KINDS.find((m) => m.value === k)!;

// ---------- pure helpers (tested) ----------
const DAY = 86400000;
const toDay = (iso: string) => Date.parse(iso + 'T00:00:00Z');
export const daysBetween = (fromIso: string, toIso: string) => Math.round((toDay(toIso) - toDay(fromIso)) / DAY);

export type StepState = 'done' | 'due' | 'late' | 'later';
export interface JourneyItem {
  key: JourneyKey;
  label: string;
  auto: boolean;
  state: StepState;
  doneOn: string | null;
  dueOn: string;
}

// The eight steps for one member, each done, due (within its window), late, or for later.
export function journeyFor(
  joinedOn: string,
  today: string,
  steps: Array<Pick<StepRow, 'step' | 'done_on'>>,
  hasBuddy: boolean,
  inCommunity: boolean,
): JourneyItem[] {
  const age = daysBetween(joinedOn, today);
  return JOURNEY.map((j) => {
    const row = steps.find((s) => s.step === j.key);
    const done = j.key === 'buddy' ? hasBuddy : j.key === 'community' ? inCommunity : !!row;
    const dueOn = new Date(toDay(joinedOn) + j.dueDays * DAY).toISOString().slice(0, 10);
    // Late a week after its due date; due from a fortnight before it.
    const state: StepState = done ? 'done' : age > j.dueDays + 7 ? 'late' : age >= j.dueDays - 14 ? 'due' : 'later';
    return { key: j.key, label: j.label, auto: !!j.auto, state, doneOn: row?.done_on ?? null, dueOn };
  });
}

export const doneCount = (items: JourneyItem[]) => items.filter((i) => i.state === 'done').length;

// Shown as settling in: joined within SETTLING_DAYS; or, within a year of joining, once a step
// has been recorded and some are still to do (so a slow start is not lost after four months).
// Members who joined before this was in use, with nothing recorded, are not listed as late.
export function isSettling(joinedOn: string, today: string, items: JourneyItem[], recorded: number): boolean {
  const age = daysBetween(joinedOn, today);
  if (age < 0) return false;
  if (age <= SETTLING_DAYS) return true;
  return age <= 365 && recorded > 0 && doneCount(items) < items.length;
}

// ---------- settling in ----------
export const useSteps = (personIds: string[]) => {
  const ids = [...new Set(personIds)].sort();
  return useQuery({
    queryKey: ['growth', 'steps', ids],
    enabled: ids.length > 0,
    queryFn: async () => {
      const { data, error } = await supabase.from('assimilation_steps').select('*').in('person_id', ids);
      if (error) throw error;
      return data;
    },
  });
};

export function useToggleStep(personId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (a: { step: AssimilationStep; done: boolean; doneOn?: string }) => {
      if (a.done) {
        const { error } = await supabase.from('assimilation_steps').insert({ person_id: personId, step: a.step, ...(a.doneOn ? { done_on: a.doneOn } : {}) });
        if (error) throw error;
      } else {
        const { error } = await supabase.from('assimilation_steps').delete().eq('person_id', personId).eq('step', a.step);
        if (error) throw error;
      }
    },
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['growth'] }),
  });
}

// ---------- courses ----------
export const useCourseTypes = () =>
  useQuery({
    queryKey: ['course_types'],
    queryFn: async () => {
      const { data, error } = await supabase.from('course_types').select('*').order('sort_order');
      if (error) throw error;
      return data;
    },
  });

export const useCourses = (personId: string) =>
  useQuery({
    queryKey: ['growth', 'courses', personId],
    queryFn: async () => {
      const { data, error } = await supabase.from('course_completions').select('*').eq('person_id', personId).order('completed_on');
      if (error) throw error;
      return data;
    },
  });

export function useRecordCourse(personId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (a: { courseId: string; completedOn: string }) => {
      const { error } = await supabase.from('course_completions').insert({ person_id: personId, course_type_id: a.courseId, completed_on: a.completedOn });
      if (error) throw error;
    },
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['growth'] }),
  });
}

export function useRemoveCourse(personId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('course_completions').delete().eq('id', id).eq('person_id', personId);
      if (error) throw error;
    },
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['growth'] }),
  });
}

// ---------- mentors ----------
// Pairings where these people are being helped (live ones first).
export const usePairings = (personIds: string[]) => {
  const ids = [...new Set(personIds)].sort();
  return useQuery({
    queryKey: ['growth', 'pairings', ids],
    enabled: ids.length > 0,
    queryFn: async () => {
      const { data, error } = await supabase.from('member_mentors').select('*').in('person_id', ids).order('started_on', { ascending: false });
      if (error) throw error;
      return data;
    },
  });
};

// Pairings where this person is the buddy, leader or discipler (that the reader may see).
export const useSupporting = (personId: string) =>
  useQuery({
    queryKey: ['growth', 'supporting', personId],
    queryFn: async () => {
      const { data, error } = await supabase.from('member_mentors').select('*').eq('mentor_person_id', personId).is('ended_on', null);
      if (error) throw error;
      return data;
    },
  });

export function useStartPairing(personId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (a: { mentorId: string; kind: MentorKind }) => {
      const { error } = await supabase.from('member_mentors').insert({ person_id: personId, mentor_person_id: a.mentorId, kind: a.kind });
      if (error) throw error;
    },
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['growth'] }),
  });
}

// Decision of 25 Nov 2026: the G-Squad Coordinator may remove a pairing at any time (the
// database lets others take one back only on the day it was named, while still open).
export function useRemovePairing(personId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('member_mentors').delete().eq('id', id).eq('person_id', personId);
      if (error) throw error;
    },
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['growth'] }),
  });
}

export function useEndPairing(personId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (a: { id: string; endedOn: string }) => {
      const { error } = await supabase.from('member_mentors').update({ ended_on: a.endedOn }).eq('id', a.id).eq('person_id', personId);
      if (error) throw error;
    },
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['growth'] }),
  });
}
