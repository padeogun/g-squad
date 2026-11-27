// -------------------------------------------------------------------------------------
// Goal-based projects, team programmes and monthly programme reports (migration 37,
// decisions of 27 Nov 2026).
//   * A goal-based project has milestones and outputs instead of a run of show, may stay open
//     for months, sits at church, purpose or team level, and is decided by the Resident Pastor
//     with the leadership (usually in the year plan).
//   * A team programme is one of a team's core routine functions. One that coordinates a core
//     deliverable reports monthly in an area (maturity, evangelism, assimilation); one geared
//     to presentation does not.
//   * A monthly programme report holds the counts the Team Lead types; the counts the app
//     already holds come from projects linked to the programme (programme_report_figures).
// The database checks every call; these helpers only shape what the screens show.
// -------------------------------------------------------------------------------------
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Database } from '../lib/database.types';

type T = Database['public']['Tables'];
export type Programme = T['unit_programmes']['Row'];
export type Milestone = T['project_milestones']['Row'];
export type ProgrammeReport = T['programme_reports']['Row'];
export type ProgrammeArea = Database['public']['Enums']['programme_area'];

// What the app counts itself, from projects linked to the team's programmes in the area.
export interface AppFigures {
  month: string;
  linked_activities: number;
  gsquad_participation: number;
  decisions_for_christ: number;
  first_time_guests: number;
  guests_contacted_48h: number;
  connected_to_community: number;
}

export interface FieldDef {
  key: string;
  label: string;
}

// Each area's report, in Paul's words (27 Nov 2026). "typed" fields match the database's
// app.programme_typed_keys; "app" fields are worked out from linked projects.
export const AREAS: Record<ProgrammeArea, { label: string; typed: FieldDef[]; app: FieldDef[] }> = {
  maturity: {
    label: 'Maturity',
    typed: [
      { key: 'classes_held', label: 'Classes held' },
      { key: 'people_completing', label: 'People completing them' },
      { key: 'decisions_other', label: 'Decisions for Christ not recorded on an event' },
    ],
    app: [
      { key: 'gsquad_participation', label: 'G-Squad members taking part' },
      { key: 'decisions_for_christ', label: 'Decisions for Christ at linked events' },
      { key: 'linked_activities', label: 'Linked activities in the app' },
    ],
  },
  evangelism: {
    label: 'Evangelism',
    typed: [
      { key: 'outreach_sessions', label: 'Outreach sessions' },
      { key: 'people_reached', label: 'People taking part or reached' },
      { key: 'decisions_other', label: 'Decisions for Christ not recorded on an event' },
    ],
    app: [
      { key: 'gsquad_participation', label: 'G-Squad members taking part' },
      { key: 'decisions_for_christ', label: 'Decisions for Christ at linked events' },
      { key: 'linked_activities', label: 'Linked outreach in the app' },
    ],
  },
  assimilation: {
    label: 'Assimilation',
    typed: [
      { key: 'visitors_welcomed', label: 'Visitors welcomed' },
      { key: 'onboarded_48h', label: 'Onboarded within 48 hours' },
      { key: 'connected_to_communities', label: 'Connected to a Greatness Community' },
    ],
    app: [
      { key: 'first_time_guests', label: 'First-time guests at linked events' },
      { key: 'guests_contacted_48h', label: 'Guests contacted within 48 hours (linked events)' },
      { key: 'connected_to_community', label: 'Connected to a community (linked events)' },
      { key: 'gsquad_participation', label: 'G-Squad members taking part' },
    ],
  },
};
export const AREA_KEYS = Object.keys(AREAS) as ProgrammeArea[];

// A typed figure: a whole number from 0 to 100000, or blank. Returns the value to store or an
// error message (the database checks the same).
export function parseFigure(raw: string): { value: number | null; error?: string } {
  const t = raw.trim();
  if (t === '') return { value: null };
  if (!/^\d+$/.test(t)) return { value: null, error: 'A whole number' };
  const n = Number(t);
  if (n > 100000) return { value: null, error: 'Too large' };
  return { value: n };
}

// Decisions for Christ for a report: those at linked events plus those the team typed.
export function totalDecisions(app: Partial<AppFigures> | undefined, typed: Record<string, unknown>): number {
  const other = typeof typed.decisions_other === 'number' ? typed.decisions_other : 0;
  return (app?.decisions_for_christ ?? 0) + other;
}

// Sum one typed figure over several reports (church totals on the reports page).
export function sumTyped(reports: Pick<ProgrammeReport, 'figures'>[], key: string): number {
  return reports.reduce((n, r) => {
    const v = (r.figures as Record<string, unknown> | null)?.[key];
    return n + (typeof v === 'number' ? v : 0);
  }, 0);
}

// The first day of a month, from any date in it (YYYY-MM-DD).
export const monthStart = (iso: string) => `${iso.slice(0, 7)}-01`;

// Milestones still to meet, and whether a goal-based project can close.
export const openMilestones = (ms: Pick<Milestone, 'done_on'>[]) => ms.filter((m) => !m.done_on).length;

export const useProgrammes = () =>
  useQuery({
    queryKey: ['programmes'],
    queryFn: async () => {
      const { data, error } = await supabase.from('unit_programmes').select('*').order('name');
      if (error) throw error;
      return data;
    },
  });

export const useMilestones = (projectId: string | undefined) =>
  useQuery({
    queryKey: ['milestones', projectId],
    enabled: !!projectId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('project_milestones')
        .select('*')
        .eq('project_id', projectId!)
        .order('due_on')
        .order('sort_order');
      if (error) throw error;
      return data;
    },
  });

// Every report for one month that this leader may read (the database decides which).
export const useProgrammeReports = (month: string) =>
  useQuery({
    queryKey: ['programme-reports', month],
    queryFn: async () => {
      const { data, error } = await supabase.from('programme_reports').select('*').eq('report_month', month);
      if (error) throw error;
      return data;
    },
  });

export const useAppFigures = (unitId: string | undefined, area: ProgrammeArea, month: string, enabled = true) =>
  useQuery({
    queryKey: ['programme-figures', unitId, area, month],
    enabled: !!unitId && enabled,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('programme_report_figures', { p_unit: unitId!, p_area: area, p_month: month });
      if (error) throw error;
      return data as unknown as AppFigures;
    },
  });
