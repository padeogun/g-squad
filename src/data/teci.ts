// -------------------------------------------------------------------------------------
// TECi: who is in or through TEC's training programme, and the TECi Coordinator's checks
// (decision of 23 Oct 2026; migration 22).
//   * Verifying a stage records who and when. The database stamps both itself (the caller,
//     now), so the time sent here only signals "verify"; it is never trusted.
//   * The TECi Coordinator (or Operations Lead) may add someone who has completed a TECi
//     level and is not in a team yet, through public.create_member with no unit.
// Row-level security decides whose records are returned; nothing here widens that.
// -------------------------------------------------------------------------------------
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';

// Only what the TECi list needs: no contact, birthday or family details.
export interface TeciPerson {
  id: string;
  first_name: string;
  surname: string;
  status: 'active' | 'paused' | 'left';
  teci_stage_id: string | null;
  teci_verified_at: string | null;
}

export const useTeciPeople = () =>
  useQuery({
    queryKey: ['people', 'teci'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('people')
        .select('id, first_name, surname, status, teci_stage_id, teci_verified_at')
        .is('anonymised_at', null)
        .neq('status', 'left')
        .order('surname')
        .order('first_name');
      if (error) throw error;
      return data as TeciPerson[];
    },
  });

// Set a stage and verify it in one change (the database clears a verification when a stage
// changes without one, so the two always go together here).
export function useVerifyTeci() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ personId, stageId }: { personId: string; stageId: string }) => {
      const { error } = await supabase
        .from('people')
        .update({ teci_stage_id: stageId, teci_verified_at: new Date().toISOString() })
        .eq('id', personId)
        // A change refused by row-level security returns no row; this makes it an error.
        .select('id')
        .single();
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['people'] }),
  });
}

// Add a TECi graduate with no team: name, optional email, and the stage completed.
export function useAddGraduate() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { first_name: string; surname: string; email: string; teci_stage_id: string }) => {
      const { error } = await supabase.rpc('create_member', {
        p_person: {
          first_name: v.first_name.trim(),
          surname: v.surname.trim(),
          email: v.email.trim() || null,
          teci_stage_id: v.teci_stage_id,
          // Asks the database to record the stage as verified by the TECi Coordinator now.
          teci_verified_at: new Date().toISOString(),
        },
        // No team yet: allowed only for the TECi Coordinator and Operations Lead.
        p_unit: null as unknown as string,
      });
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['people'] }),
  });
}

// Members in or through TECi (with a stage), then those not started; unverified first.
export function teciOrder(a: TeciPerson, b: TeciPerson): number {
  const rank = (p: TeciPerson) => (p.teci_stage_id ? (p.teci_verified_at ? 1 : 0) : 2);
  return rank(a) - rank(b) || a.surname.localeCompare(b.surname) || a.first_name.localeCompare(b.first_name);
}
