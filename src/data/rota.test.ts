// The rota layout: one row per role and slot, a cell where a Sunday needs that slot or
// someone already fills it, and nothing assigned ever hidden.
import { describe, expect, it } from 'vitest';
import { buildEvents, buildRota, fitsLimit, monthBounds, placeHours } from './rota';
import { weeklyDates } from './projects';

const sundays = [
  { service_date: '2026-11-01', project_id: 'p1' },
  { service_date: '2026-11-08', project_id: 'p2' },
];

describe('monthBounds', () => {
  it('gives the first and last day', () => {
    expect(monthBounds('2026-11-15')).toEqual({ from: '2026-11-01', to: '2026-11-30' });
    expect(monthBounds('2028-02-01')).toEqual({ from: '2028-02-01', to: '2028-02-29' });
  });
});

describe('buildRota', () => {
  it('makes a row per slot a role needs', () => {
    const rows = buildRota(
      sundays,
      [
        { project_id: 'p1', church_role_id: 'cam', on_date: '2026-11-01', slots_needed: 2 },
        { project_id: 'p2', church_role_id: 'cam', on_date: '2026-11-08', slots_needed: 1 },
      ],
      [],
    );
    expect(rows).toHaveLength(2); // camera needs 2 people on the 1st
    expect(rows[0].cells.size).toBe(2); // slot 1 on both Sundays
    expect(rows[1].cells.has('2026-11-01')).toBe(true); // slot 2 only on the 1st
    expect(rows[1].cells.has('2026-11-08')).toBe(false);
  });

  it('fills cells with assignments and never hides extra ones', () => {
    const rows = buildRota(
      sundays,
      [{ project_id: 'p1', church_role_id: 'cam', on_date: '2026-11-01', slots_needed: 1 }],
      [
        { id: 'a1', person_id: 'ada', status: 'planned', church_role_id: 'cam', serve_date: '2026-11-01' },
        { id: 'a2', person_id: 'bo', status: 'planned', church_role_id: 'cam', serve_date: '2026-11-01' },
        { id: 'a3', person_id: 'cy', status: 'planned', church_role_id: null, serve_date: '2026-11-08' },
      ],
    );
    const cam = rows.filter((r) => r.roleId === 'cam');
    expect(cam).toHaveLength(2); // the extra assignment gets its own row
    expect(cam[0].cells.get('2026-11-01')?.assignment?.person_id).toBe('ada');
    expect(cam[1].cells.get('2026-11-01')?.assignment?.person_id).toBe('bo');
    const any = rows.find((r) => r.roleId === null);
    expect(any?.cells.get('2026-11-08')?.assignment?.person_id).toBe('cy');
  });
});

// Migration 28: events and team activities, and the limit in hours.

describe('buildEvents', () => {
  const projects = [{ id: 'p1', name: 'Harvest outreach' }];
  it('makes one group per project and day, with a place per person needed, filled in a stable order', () => {
    const g = buildEvents(
      [
        { project_id: 'p1', church_role_id: null, on_date: '2026-11-14', slots_needed: 2, hours: 4 },
        { project_id: 'p1', church_role_id: 'r1', on_date: '2026-11-07', slots_needed: 1, hours: null },
        { project_id: 'other', church_role_id: null, on_date: '2026-11-07', slots_needed: 1, hours: 1 },
      ],
      projects,
      [{ id: 'b', project_id: 'p1', person_id: 'x', status: 'planned', church_role_id: null, serve_date: '2026-11-14' }],
    );
    expect(g.map((x) => [x.date, x.hours, x.slots.length])).toEqual([
      ['2026-11-07', 3, 1], // no hours given: the church's usual hours
      ['2026-11-14', 4, 2],
    ]);
    expect(g[1].slots[0].assignment?.person_id).toBe('x');
    expect(g[1].slots[1].assignment).toBeNull();
  });
  it('keeps people booked beyond the places asked for', () => {
    const g = buildEvents(
      [{ project_id: 'p1', church_role_id: null, on_date: '2026-11-14', slots_needed: 1, hours: 2 }],
      projects,
      [
        { id: 'a', project_id: 'p1', person_id: 'x', status: 'planned', church_role_id: null, serve_date: '2026-11-14' },
        { id: 'b', project_id: 'p1', person_id: 'y', status: 'planned', church_role_id: null, serve_date: '2026-11-14' },
      ],
    );
    expect(g[0].slots).toHaveLength(2);
  });
});

// SECURITY REVIEW 19 (Z03, Z06, Z07): hours as the database counts them; nothing booked hidden.
describe('placeHours', () => {
  const demand = [
    { project_id: 'p1', church_role_id: null, on_date: '2026-11-14', slots_needed: 1, hours: null },
    { project_id: 'p1', church_role_id: null, on_date: '2026-11-14', slots_needed: 1, hours: 0.5 },
    { project_id: 'p1', church_role_id: 'r1', on_date: '2026-11-21', slots_needed: 1, hours: 1 },
    { project_id: 'p1', church_role_id: null, on_date: '2026-11-21', slots_needed: 1, hours: 4 },
  ];
  it('counts a row with no hours at the usual hours, and the larger of two rows', () => {
    expect(placeHours(demand, 'p1', null, '2026-11-14', 3)).toBe(3);
  });
  it("uses the role's own row, else the any-role row, else nothing", () => {
    expect(placeHours(demand, 'p1', 'r1', '2026-11-21', 3)).toBe(1);
    expect(placeHours(demand, 'p1', 'r2', '2026-11-21', 3)).toBe(4);
    expect(placeHours(demand, 'p1', 'r2', '2026-11-28', 3)).toBeNull();
    expect(placeHours(demand, 'p2', null, '2026-11-14', 3)).toBeNull();
  });
});

describe('buildEvents (review 19)', () => {
  it('shows hours per place when they differ, and a booking with no place left', () => {
    const g = buildEvents(
      [
        { project_id: 'p1', church_role_id: 'r1', on_date: '2026-11-21', slots_needed: 1, hours: 1 },
        { project_id: 'p1', church_role_id: 'r2', on_date: '2026-11-21', slots_needed: 1, hours: 8 },
      ],
      [{ id: 'p1', name: 'Harvest outreach' }, { id: 'p9', name: 'Old rehearsal' }],
      [{ id: 'z', project_id: 'p9', person_id: 'q', status: 'planned', church_role_id: null, serve_date: '2026-11-03', hours: 2 }],
      3,
    );
    expect(g.map((x) => [x.name, x.hours, x.open])).toEqual([
      ['Old rehearsal', 2, false],
      ['Harvest outreach', null, true],
    ]);
    expect(g[1].slots.map((x) => x.hours)).toEqual([1, 8]);
    expect(g[0].slots[0].assignment?.person_id).toBe('q');
  });
});

describe('fitsLimit', () => {
  it('counts hours across all serving', () => {
    expect(fitsLimit({ hours_used: 8, hours_limit: 9 }, 1)).toBe(true);
    expect(fitsLimit({ hours_used: 8, hours_limit: 9 }, 1.5)).toBe(false);
  });
});

describe('weeklyDates', () => {
  it('repeats weekly up to the end date or the project end, whichever is first', () => {
    expect(weeklyDates('2026-11-05', '2026-11-26', '2026-12-31')).toEqual(['2026-11-05', '2026-11-12', '2026-11-19', '2026-11-26']);
    expect(weeklyDates('2026-11-05', '2026-12-31', '2026-11-15')).toEqual(['2026-11-05', '2026-11-12']);
    expect(weeklyDates('2026-11-05', '2026-11-05', '2026-11-30')).toEqual(['2026-11-05']);
  });
});
