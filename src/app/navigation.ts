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
      { label: 'Dashboard', path: '/', slice: 3 },
      { label: 'My Unit', path: '/my-unit', slice: 1 },
    ],
  },
  {
    label: 'People and Teams',
    items: [
      { label: 'Members', path: '/members', slice: 1 },
      { label: 'One-to-ones', path: '/one-to-ones', slice: 5 },
    ],
  },
  {
    label: 'Sundays and events',
    items: [
      { label: 'Service grid', path: '/service-grid', slice: 2 },
      { label: 'Rota', path: '/rota', slice: 2 },
      { label: 'Projects and events', path: '/projects', slice: 4 },
    ],
  },
  {
    label: 'Communication',
    items: [{ label: 'Newsletter', path: '/newsletter', slice: 6 }],
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
