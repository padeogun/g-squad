// -------------------------------------------------------------------------------------
// The app's sections, in sidebar order. Each entry says which build slice delivers it, so
// screens not yet built show a "coming in slice N" page instead of a broken link.
// Slice numbers follow the G-Squad Planner Build Plan.
// -------------------------------------------------------------------------------------

export interface NavItem {
  label: string;
  path: string;
  slice: number;
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
    items: [{ label: 'Reference forms', path: '/admin', slice: 1 }],
  },
];

// Every item except the dashboard, which has its own home page.
export const PLACEHOLDER_ITEMS: NavItem[] = NAV.flatMap((g) => g.items).filter((i) => i.path !== '/');
