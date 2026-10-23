// -------------------------------------------------------------------------------------
// Sunday operations data: Sundays (service grids), their segments, the units and roles each
// Sunday needs (team demand), and reusable text blocks. Everyone signed in reads grids
// (grids_read); the Operations Lead builds them and the Resident Pastor approves (migration 8).
// Pure timing helpers are at the bottom and unit-tested in sundays.test.ts.
// -------------------------------------------------------------------------------------
import { useQuery } from '@tanstack/react-query';
import type { Database } from '../lib/database.types';
import { supabase } from '../lib/supabase';

export type Grid = Database['public']['Tables']['service_grids']['Row'];
export type Segment = Database['public']['Tables']['service_segments']['Row'];
export type Demand = Database['public']['Tables']['team_demand']['Row'];
export type Block = Database['public']['Tables']['reusable_blocks']['Row'];

// Throws the Supabase error so TanStack Query shows it; returns rows otherwise.
async function rows<T>(p: PromiseLike<{ data: T[] | null; error: unknown }>): Promise<T[]> {
  const { data, error } = await p;
  if (error) throw error;
  return data ?? [];
}

// All Sundays, newest first (the list screen splits them into coming and past).
export const useSundays = () =>
  useQuery({
    queryKey: ['grids'],
    queryFn: () => rows(supabase.from('service_grids').select('*').order('service_date', { ascending: false })),
  });

export const useGrid = (id: string | undefined) =>
  useQuery({
    queryKey: ['grids', id],
    enabled: !!id,
    queryFn: async () => {
      const { data, error } = await supabase.from('service_grids').select('*').eq('id', id!).maybeSingle();
      if (error) throw error;
      return data;
    },
  });

export const useSegments = (gridId: string | undefined) =>
  useQuery({
    queryKey: ['segments', gridId],
    enabled: !!gridId,
    queryFn: () => rows(supabase.from('service_segments').select('*').eq('grid_id', gridId!).order('position')),
  });

// Units and roles this Sunday needs: team demand on the Sunday's project for its date.
export const useDemand = (projectId: string | undefined) =>
  useQuery({
    queryKey: ['demand', projectId],
    enabled: !!projectId,
    queryFn: () => rows(supabase.from('team_demand').select('*').eq('project_id', projectId!).order('created_at')),
  });

export const useBlocks = () =>
  useQuery({ queryKey: ['ref', 'reusable_blocks'], queryFn: () => rows(supabase.from('reusable_blocks').select('*').order('name')) });

export const useGridBlocks = (gridId: string | undefined) =>
  useQuery({
    queryKey: ['grid_blocks', gridId],
    enabled: !!gridId,
    queryFn: () => rows(supabase.from('service_grid_blocks').select('block_id, position').eq('grid_id', gridId!).order('position')),
  });

// ---------- Pure helpers ----------

// "10:00:00" or "10:00" -> minutes after midnight.
export function toMinutes(t: string): number {
  const [h, m] = t.split(':').map(Number);
  return h * 60 + m;
}

// Minutes after midnight -> "10:05".
export function toTime(mins: number): string {
  const m = ((mins % 1440) + 1440) % 1440;
  return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
}

export interface Timed {
  starts_at: string;
  duration_minutes: number;
}

// End time of a segment ("10:00" + 25 min -> "10:25").
export const endOf = (s: Timed) => toTime(toMinutes(s.starts_at) + s.duration_minutes);

// Gaps and overlaps between consecutive segments, keyed by the index of the LATER segment.
// A positive number is a gap in minutes; negative is an overlap.
export function gaps(segments: Timed[]): Map<number, number> {
  const out = new Map<number, number>();
  for (let i = 1; i < segments.length; i++) {
    const diff = toMinutes(segments[i].starts_at) - (toMinutes(segments[i - 1].starts_at) + segments[i - 1].duration_minutes);
    if (diff !== 0) out.set(i, diff);
  }
  return out;
}

// Start and end of the whole service, and its length in minutes.
export function serviceSpan(segments: Timed[]): { start: string; end: string; minutes: number } | null {
  if (segments.length === 0) return null;
  const start = Math.min(...segments.map((s) => toMinutes(s.starts_at)));
  const end = Math.max(...segments.map((s) => toMinutes(s.starts_at) + s.duration_minutes));
  return { start: toTime(start), end: toTime(end), minutes: end - start };
}

// "2 h 40 min" / "45 min".
export function formatDuration(mins: number): string {
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return h ? `${h} h${m ? ` ${m} min` : ''}` : `${m} min`;
}

// The grid is finalised by the Thursday before the service (spec).
export function finaliseDeadline(serviceDate: string): string {
  const d = new Date(`${serviceDate}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() - 3);
  return d.toISOString().slice(0, 10);
}

// The next Sunday on or after a date (for "Set up a Sunday").
export function nextSunday(from: Date = new Date()): string {
  const d = new Date(Date.UTC(from.getFullYear(), from.getMonth(), from.getDate(), 12));
  d.setUTCDate(d.getUTCDate() + ((7 - d.getUTCDay()) % 7));
  return d.toISOString().slice(0, 10);
}

// "Sunday 25 October 2026" from "2026-10-25" (no time zone shifts: noon UTC). Built from
// parts because browsers differ on whether en-GB puts a comma after the weekday.
export function longDate(isoDate: string): string {
  const d = new Date(`${isoDate}T12:00:00Z`);
  const part = (o: Intl.DateTimeFormatOptions) => d.toLocaleDateString('en-GB', { ...o, timeZone: 'UTC' });
  return `${part({ weekday: 'long' })} ${part({ day: 'numeric' })} ${part({ month: 'long' })} ${part({ year: 'numeric' })}`;
}

// "Thu 22 Oct" style short date (from parts, as longDate).
export function shortDate(isoDate: string): string {
  const d = new Date(`${isoDate}T12:00:00Z`);
  const part = (o: Intl.DateTimeFormatOptions) => d.toLocaleDateString('en-GB', { ...o, timeZone: 'UTC' });
  return `${part({ weekday: 'short' })} ${part({ day: 'numeric' })} ${part({ month: 'short' })}`;
}

// Sub-points are typed one per line; blank lines dropped, each trimmed, at most 20 (database limit).
export function parsePoints(text: string): string[] {
  return text
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean)
    .slice(0, 20);
}

// Today's date as "2026-10-25" in the device's own time zone (Sunday morning in the UK
// must count as Sunday, not Saturday evening UTC).
export function todayIso(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
