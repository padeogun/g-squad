// -------------------------------------------------------------------------------------
// Shared lookups used by many screens: units, purposes, team roles, stages and communities.
// Everyone signed in at the church can read these (RLS: *_read policies), so they are cached
// app-wide and refreshed after any reference form saves (queryKey prefix 'ref').
// -------------------------------------------------------------------------------------
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';

// Throws the Supabase error so TanStack Query shows it; returns rows otherwise.
async function rows<T>(p: PromiseLike<{ data: T[] | null; error: unknown }>): Promise<T[]> {
  const { data, error } = await p;
  if (error) throw error;
  return data ?? [];
}

export const useUnits = () =>
  useQuery({
    queryKey: ['ref', 'units'],
    queryFn: () =>
      rows(
        supabase
          .from('units')
          .select('id, name, purpose_id, target_headcount, regular_monthly_need, is_active, objectives, scope')
          .order('name'),
      ),
  });

export const usePurposes = () =>
  useQuery({ queryKey: ['ref', 'purposes'], queryFn: () => rows(supabase.from('purposes').select('id, name').order('name')) });

export const useChurchRoles = () =>
  useQuery({
    queryKey: ['ref', 'church_roles'],
    queryFn: () => rows(supabase.from('church_roles').select('id, name, unit_id, is_active, is_rota_role, permanence, default_key').order('name')),
  });

export const useTeciStages = () =>
  useQuery({
    queryKey: ['ref', 'teci_stages'],
    queryFn: () => rows(supabase.from('teci_stages').select('id, stage_no, name').order('stage_no')),
  });

export const useLeadershipStages = () =>
  useQuery({
    queryKey: ['ref', 'leadership_stages'],
    queryFn: () => rows(supabase.from('leadership_stages').select('id, sort_order, name').order('sort_order')),
  });

export const useCommunities = () =>
  useQuery({
    queryKey: ['ref', 'greatness_communities'],
    queryFn: () =>
      rows(supabase.from('greatness_communities').select('id, name, type_id, is_active, community_types(name)').order('name')),
  });

// Leaders' display names (readable church-wide), for owners and "added by" labels.
export const useLeaders = () =>
  useQuery({
    queryKey: ['leaders'],
    queryFn: () => rows(supabase.from('app_users').select('id, display_name, is_active, person_id, created_at').order('display_name')),
  });

// Turns a list into an id -> item map, for quick label lookups in tables.
export function byId<T extends { id: string }>(list: T[] | undefined): Map<string, T> {
  return new Map((list ?? []).map((x) => [x.id, x]));
}
