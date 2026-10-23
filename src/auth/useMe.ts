// -------------------------------------------------------------------------------------
// The signed-in leader's own account and roles, for deciding what to SHOW (buttons, menu
// items, form sections). It never decides what data may be read or changed: row-level
// security in the database does that, so hiding a button here is a courtesy, not a control.
// -------------------------------------------------------------------------------------
import { useQuery } from '@tanstack/react-query';
import type { Database } from '../lib/database.types';
import { supabase } from '../lib/supabase';
import { useAuth } from './AuthProvider';

export type AppRole = Database['public']['Enums']['app_role'];

export interface Me {
  id: string;
  displayName: string;
  churchId: string;
  roles: { role: AppRole; unit_id: string | null; purpose_id: string | null }[];
}

// Plain-English names for roles, used across the app.
export const ROLE_LABELS: Record<AppRole, string> = {
  resident_pastor: 'Resident Pastor',
  purpose_head: 'Purpose Head',
  gsquad_coordinator: 'G-Squad Coordinator',
  teci_coordinator: 'TECi Coordinator',
  unit_lead: 'Team Lead',
  deputy_unit_lead: 'Deputy Team Lead',
  operations_lead: 'Operations Lead',
  pastoral_lead: 'Pastoral Lead',
  newsletter_editor: 'Newsletter editor',
  finance: 'Finance',
};

export function useMe() {
  const { session } = useAuth();
  const userId = session?.user.id;

  return useQuery({
    queryKey: ['me', userId],
    enabled: !!userId,
    // Roles change rarely; refresh every few minutes rather than on every screen.
    staleTime: 5 * 60_000,
    queryFn: async (): Promise<Me | null> => {
      const [account, roles] = await Promise.all([
        supabase.from('app_users').select('id, display_name, church_id').eq('id', userId!).maybeSingle(),
        supabase.from('role_assignments').select('role, unit_id, purpose_id').eq('user_id', userId!).eq('is_active', true),
      ]);
      if (account.error) throw account.error;
      if (roles.error) throw roles.error;
      // Signed in to Supabase but no active G-Squad account (not invited, or switched off).
      if (!account.data) return null;
      return {
        id: account.data.id,
        displayName: account.data.display_name,
        churchId: account.data.church_id,
        roles: roles.data,
      };
    },
  });
}

// Small helpers for "should this be shown?" checks.
export function hasRole(me: Me | null | undefined, ...roles: AppRole[]): boolean {
  return !!me && me.roles.some((r) => roles.includes(r.role));
}

// Units this leader leads (Team Lead role): the units they may CHANGE (members, rota, check-in).
export function ledUnitIds(me: Me | null | undefined): string[] {
  return (me?.roles ?? []).filter((r) => r.role === 'unit_lead' && r.unit_id).map((r) => r.unit_id!);
}

// Units this leader may VIEW as a team leader: those they lead, then those they deputise for
// (Deputy Team Lead: view-only, no one-to-ones; decision of 23 Oct 2026, migration 22).
export function viewedUnitIds(me: Me | null | undefined): string[] {
  const deputy = (me?.roles ?? []).filter((r) => r.role === 'deputy_unit_lead' && r.unit_id).map((r) => r.unit_id!);
  return [...new Set([...ledUnitIds(me), ...deputy])];
}

// The G-Squad Coordinator and Operations Lead are functions held by a Purpose Head or the
// Resident Pastor (decision of 23 Oct 2026). The database refuses them otherwise (migration 22).
export const NEEDS_SENIOR_HOLDER: AppRole[] = ['gsquad_coordinator', 'operations_lead'];
export const SENIOR_HOLDERS: AppRole[] = ['purpose_head', 'resident_pastor'];

// Roles that may read faith fields (the database checks this, plus "the person's Team Lead or Deputy").
export const FAITH_READERS: AppRole[] = ['resident_pastor', 'gsquad_coordinator', 'teci_coordinator'];
// Roles that may invite leaders (decision of 23 Oct 2026; migration 13).
export const INVITERS: AppRole[] = ['operations_lead', 'gsquad_coordinator', 'resident_pastor'];

// Roles in the order they are offered, with who may give them (mirrors the database guard).
const SENIOR: AppRole[] = ['resident_pastor', 'gsquad_coordinator', 'teci_coordinator', 'pastoral_lead', 'purpose_head'];
const ROLE_ORDER: AppRole[] = [
  'unit_lead',
  'deputy_unit_lead',
  'newsletter_editor',
  'finance',
  'operations_lead',
  'purpose_head',
  'gsquad_coordinator',
  'teci_coordinator',
  'pastoral_lead',
  'resident_pastor',
];

// Which roles this leader may give, so the form only offers those (mirrors migration 18:
// senior roles by the Resident Pastor or G-Squad Coordinator, the Resident Pastor role by the
// Resident Pastor only, the Operations Lead role also by an Operations Lead).
export function grantableRoles(me: Me | null | undefined): AppRole[] {
  const rp = hasRole(me, 'resident_pastor');
  const coord = hasRole(me, 'gsquad_coordinator');
  const ops = hasRole(me, 'operations_lead');
  return ROLE_ORDER.filter((r) => {
    if (r === 'resident_pastor') return rp;
    if (SENIOR.includes(r)) return rp || coord;
    if (r === 'operations_lead') return rp || coord || ops;
    return true;
  });
}
