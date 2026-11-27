// -------------------------------------------------------------------------------------
// The app's sections, in sidebar order. Each entry says which build slice delivers it, so
// screens not yet built show a "coming in slice N" page instead of a broken link.
// Slice numbers follow the G-Squad Planner Build Plan.
// -------------------------------------------------------------------------------------

import type { AppRole } from '../auth/useMe';

export interface NavItem {
  label: string;
  path: string;
  slice: number;
  // Shown only to these roles (a courtesy: the database decides what each can read or change).
  // Omitted = shown to every signed-in leader.
  roles?: AppRole[];
  // True once the screen exists; until then the route shows a "coming in slice N" page.
  built?: boolean;
}

export interface NavGroup {
  label: string;
  items: NavItem[];
}

export const NAV: NavGroup[] = [
  {
    label: 'Overview',
    items: [
      { label: 'Dashboard', path: '/', slice: 3, built: true },
      {
        label: 'Capacity calendar',
        path: '/capacity',
        slice: 3,
        built: true,
        roles: ['resident_pastor', 'purpose_head', 'gsquad_coordinator', 'unit_lead', 'deputy_unit_lead', 'operations_lead'],
      },
      { label: 'My Unit', path: '/my-unit', slice: 1, built: true },
      // Migration 35: counts only, for the roles that read the monthly report.
      {
        label: 'Maturity report',
        path: '/maturity',
        slice: 7,
        built: true,
        roles: ['gsquad_coordinator', 'resident_pastor', 'purpose_head', 'operations_lead', 'pastoral_lead'],
      },
      // Migration 37: monthly reports of teams' reporting programmes (the team's own leaders too).
      {
        label: 'Programme reports',
        path: '/programme-reports',
        slice: 7,
        built: true,
        roles: ['gsquad_coordinator', 'resident_pastor', 'purpose_head', 'operations_lead', 'pastoral_lead', 'unit_lead', 'deputy_unit_lead'],
      },
    ],
  },
  {
    label: 'People and Teams',
    items: [
      { label: 'Members', path: '/members', slice: 1, built: true },
      // The TECi Coordinator's list: who is in or through TECi, and stage verification.
      {
        label: 'TECi',
        path: '/teci',
        slice: 3,
        built: true,
        roles: ['teci_coordinator', 'gsquad_coordinator', 'resident_pastor', 'operations_lead'],
      },
      // Team Leads hold them; the Purpose Head, Coordinator and Resident Pastor read them.
      {
        label: 'One-to-ones',
        path: '/one-to-ones',
        slice: 5,
        built: true,
        roles: ['unit_lead', 'purpose_head', 'gsquad_coordinator', 'resident_pastor'],
      },
    ],
  },
  {
    label: 'Sundays and events',
    items: [
      { label: 'Sunday Operations', path: '/sundays', slice: 2, built: true },
      { label: 'Rota', path: '/rota', slice: 2, built: true },
      { label: 'Sunday check-in', path: '/check-in', slice: 2, built: true, roles: ['unit_lead', 'operations_lead'] },
      { label: 'Projects and events', path: '/projects', slice: 4, built: true },
      // Migration 37: the year's projects together, as the leadership approves them.
      { label: 'Year plan', path: '/year-plan', slice: 4, built: true },
    ],
  },
  {
    label: 'Communication',
    items: [
      {
        label: 'The Greatness Brief',
        path: '/newsletter',
        slice: 6,
        built: true,
        roles: ['newsletter_editor', 'gsquad_coordinator', 'resident_pastor', 'operations_lead'],
      },
    ],
  },
  {
    label: 'Admin',
    items: [
      {
        label: 'Leaders',
        path: '/admin/leaders',
        slice: 1,
        built: true,
        roles: ['operations_lead', 'gsquad_coordinator', 'resident_pastor'],
      },
      { label: 'Reference forms', path: '/admin', slice: 1, built: true },
    ],
  },
];

// Screens not built yet (the dashboard has its own home page meanwhile).
export const PLACEHOLDER_ITEMS: NavItem[] = NAV.flatMap((g) => g.items).filter((i) => i.path !== '/' && !i.built);

// The sidebar for one leader: items they can use, and no empty groups.
export function navFor(roles: AppRole[]): NavGroup[] {
  return NAV.map((g) => ({ ...g, items: g.items.filter((i) => !i.roles || i.roles.some((r) => roles.includes(r))) })).filter(
    (g) => g.items.length > 0,
  );
}
