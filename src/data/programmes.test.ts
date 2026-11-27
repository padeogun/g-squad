// Unit tests for the programme report helpers (migration 37): typed figures are whole numbers
// from 0 to 100000, decisions add linked events to typed ones, totals skip blanks.
import { describe, expect, it } from 'vitest';
import { AREAS, monthStart, openMilestones, parseFigure, sumTyped, totalDecisions } from './programmes';

describe('parseFigure', () => {
  it('accepts blanks and whole numbers', () => {
    expect(parseFigure('')).toEqual({ value: null });
    expect(parseFigure(' 12 ')).toEqual({ value: 12 });
    expect(parseFigure('0')).toEqual({ value: 0 });
  });
  it('refuses anything else', () => {
    expect(parseFigure('-1').error).toBeDefined();
    expect(parseFigure('1.5').error).toBeDefined();
    expect(parseFigure('abc').error).toBeDefined();
    expect(parseFigure('100001').error).toBeDefined();
  });
});

describe('report sums', () => {
  it('adds decisions at linked events to those typed', () => {
    expect(totalDecisions({ decisions_for_christ: 2 }, { decisions_other: 3 })).toBe(5);
    expect(totalDecisions(undefined, {})).toBe(0);
  });
  it('totals one figure across reports, skipping blanks', () => {
    expect(sumTyped([{ figures: { classes_held: 2 } }, { figures: { classes_held: null } }, { figures: {} }], 'classes_held')).toBe(2);
  });
  it('finds the month and open milestones', () => {
    expect(monthStart('2026-11-27')).toBe('2026-11-01');
    expect(openMilestones([{ done_on: null }, { done_on: '2026-11-01' }])).toBe(1);
  });
});

describe('areas', () => {
  // Must match app.programme_typed_keys in migration 37.
  it('types the fields the database accepts', () => {
    expect(AREAS.maturity.typed.map((f) => f.key)).toEqual(['classes_held', 'people_completing', 'decisions_other']);
    expect(AREAS.evangelism.typed.map((f) => f.key)).toEqual(['outreach_sessions', 'people_reached', 'decisions_other']);
    expect(AREAS.assimilation.typed.map((f) => f.key)).toEqual(['visitors_welcomed', 'onboarded_48h', 'connected_to_communities']);
  });
});
