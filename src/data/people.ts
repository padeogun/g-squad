// -------------------------------------------------------------------------------------
// Members (people) and their unit memberships.
// What each leader sees is decided by row-level security (app.can_read_person): a Unit Lead
// sees their own unit's members, the Operations Lead and senior roles see more. These hooks
// just ask for everything and receive what the database allows.
// Faith fields are NOT here: they are read and written only through get_person_faith /
// set_person_faith (see faith helpers at the bottom), which check access and log every view.
// -------------------------------------------------------------------------------------
import { useQuery } from '@tanstack/react-query';
import type { Database } from '../lib/database.types';
import { supabase } from '../lib/supabase';

export type Person = Database['public']['Tables']['people']['Row'];
export type PersonInsert = Database['public']['Tables']['people']['Insert'];
export type Membership = Database['public']['Tables']['unit_memberships']['Row'];
export type Faith = Database['public']['Functions']['get_person_faith']['Returns'][number];

// Columns shown in lists and the form (never select('*') on people: anonymised and consent
// columns are not needed on screen).
const PERSON_COLUMNS =
  'id, first_name, other_names, surname, date_joined, date_left, status, birth_day, birth_month, email, area, ' +
  'marital_status, anniversary_day, anniversary_month, teci_stage_id, greatness_community_id, ' +
  'newsletter_subscribed, celebration_opt_in, created_by, anonymised_at';

export const usePeople = () =>
  useQuery({
    queryKey: ['people'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('people')
        .select(PERSON_COLUMNS)
        .is('anonymised_at', null)
        .order('surname')
        .order('first_name');
      if (error) throw error;
      return data as unknown as Person[];
    },
  });

export const usePerson = (id: string | undefined) =>
  useQuery({
    queryKey: ['people', id],
    enabled: !!id,
    queryFn: async () => {
      const { data, error } = await supabase.from('people').select(PERSON_COLUMNS).eq('id', id!).maybeSingle();
      if (error) throw error;
      return data as unknown as Person | null;
    },
  });

// Live memberships (pending or active) the leader can see, for lists and My Unit.
export const useMemberships = () =>
  useQuery({
    queryKey: ['memberships'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('unit_memberships')
        .select('id, person_id, unit_id, church_role_id, is_team_leader, leadership_stage_id, status, joined_on, ended_on')
        .neq('status', 'ended');
      if (error) throw error;
      return data as Membership[];
    },
  });

// "Ada Obi" style display name.
export const fullName = (p: Pick<Person, 'first_name' | 'surname'>) => `${p.first_name} ${p.surname}`;

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
// "14 Mar" from day and month (no year is ever held).
export const dayMonth = (d: number | null, m: number | null) => (d && m ? `${d} ${MONTHS.at(m - 1)}` : '');

// ---------- Faith fields (logged functions only) ----------

// Returns the faith record, an empty record if none is saved yet, or 'restricted' if this
// leader may not see faith fields for the person (the function refuses, and nothing is shown).
export async function fetchFaith(personId: string): Promise<Faith | 'restricted' | null> {
  const { data, error } = await supabase.rpc('get_person_faith', { p_person: personId });
  if (error) {
    if (error.code === '42501') return 'restricted';
    throw error;
  }
  return (data as Faith[])[0] ?? null;
}

export interface FaithInput {
  salvation_date: string | null;
  water_baptism: boolean;
  water_baptism_date: string | null;
  holy_spirit_baptism: boolean;
  holy_spirit_baptism_date: string | null;
  speaks_in_tongues: boolean;
  speaks_in_tongues_date: string | null;
}

export async function saveFaith(personId: string, f: FaithInput): Promise<void> {
  // A date is kept only while its tick is set (the table has the same rule).
  const { error } = await supabase.rpc('set_person_faith', {
    p_person: personId,
    p_salvation_date: f.salvation_date as string,
    p_water_baptism: f.water_baptism,
    p_water_baptism_date: (f.water_baptism ? f.water_baptism_date : null) as string,
    p_holy_spirit_baptism: f.holy_spirit_baptism,
    p_holy_spirit_baptism_date: (f.holy_spirit_baptism ? f.holy_spirit_baptism_date : null) as string,
    p_speaks_in_tongues: f.speaks_in_tongues,
    p_speaks_in_tongues_date: (f.speaks_in_tongues ? f.speaks_in_tongues_date : null) as string,
  });
  if (error) throw error;
}
