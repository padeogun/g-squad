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
  unit_lead: 'Unit Lead',
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

// Units this leader leads (Unit Lead role), for My Unit and the member form.
export function ledUnitIds(me: Me | null | undefined): string[] {
  return (me?.roles ?? []).filter((r) => r.role === 'unit_lead' && r.unit_id).map((r) => r.unit_id!);
}

// Roles that may read faith fields (the database checks this, plus "the person's Unit Lead").
export const FAITH_READERS: AppRole[] = ['resident_pastor', 'gsquad_coordinator', 'teci_coordinator'];
// Roles that may invite leaders (decision of 23 Oct 2026; migration 13).
export const INVITERS: AppRole[] = ['operations_lead', 'gsquad_coordinator', 'resident_pastor'];

// Roles in the order they are offered, with who may give them (mirrors the database guard).
const SENIOR: AppRole[] = ['resident_pastor', 'gsquad_coordinator', 'teci_coordinator', 'pastoral_lead', 'purpose_head'];
const ROLE_ORDER: AppRole[] = [
  'unit_lead',
  'newsletter_editor',
  'finance',
  'operations_lead',
  'purpose_head',
  'gsquad_coordinator',
  'teci_coordinator',
  'pastoral_lead',
  'resident_pastor',
];

// Which roles this leader may give, so the form only offers those.
export function grantableRoles(me: Me | null | undefined): AppRole[] {
  const rp = hasRole(me, 'resident_pastor');
  const ops = hasRole(me, 'operations_lead');
  return ROLE_ORDER.filter((r) => {
    if (SENIOR.includes(r)) return rp;
    if (r === 'operations_lead') return rp || ops;
    return true;
  });
}
