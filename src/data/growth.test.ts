// Tests for settling in (migration 34): the eight steps' states and who shows as settling in.
import { describe, expect, it } from 'vitest';
import { daysBetween, doneCount, isSettling, JOURNEY, journeyFor } from './growth';

describe('settling in', () => {
  it('has eight steps, two read from the record', () => {
    expect(JOURNEY).toHaveLength(8);
    expect(JOURNEY.filter((j) => j.auto).map((j) => j.key)).toEqual(['buddy', 'community']);
  });

  it('counts days between London dates', () => {
    expect(daysBetween('2026-11-01', '2026-11-24')).toBe(23);
    expect(daysBetween('2026-03-28', '2026-03-30')).toBe(2);
  });

  it('marks steps done, due, late or for later', () => {
    const items = journeyFor('2026-10-01', '2026-11-24', [{ step: 'welcomed', done_on: '2026-10-02' }], true, false);
    const by = Object.fromEntries(items.map((i) => [i.key, i.state]));
    expect(by.welcomed).toBe('done');
    expect(by.buddy).toBe('done');
    expect(by.values_session).toBe('late'); // due day 30, now day 54
    expect(by.community).toBe('due'); // due day 60, now day 54
    expect(by.day_90_conversation).toBe('later');
    expect(items.find((i) => i.key === 'welcomed')!.doneOn).toBe('2026-10-02');
    expect(items.find((i) => i.key === 'day_30_conversation')!.dueOn).toBe('2026-10-31');
    expect(doneCount(items)).toBe(2);
  });

  it('shows new members for 120 days, longer only once steps are being recorded', () => {
    const none = journeyFor('2026-01-01', '2026-11-24', [], false, false);
    expect(isSettling('2026-10-01', '2026-11-24', none, 0)).toBe(true);
    expect(isSettling('2026-01-01', '2026-11-24', none, 0)).toBe(false); // joined before it was in use
    expect(isSettling('2026-01-01', '2026-11-24', none, 1)).toBe(true); // a slow start, steps left
    const all = journeyFor(
      '2026-01-01',
      '2026-11-24',
      JOURNEY.filter((j) => !j.auto).map((j) => ({ step: j.key as never, done_on: '2026-02-01' })),
      true,
      true,
    );
    expect(isSettling('2026-01-01', '2026-11-24', all, 6)).toBe(false);
    expect(isSettling('2025-01-01', '2026-11-24', none, 1)).toBe(false);
    expect(isSettling('2026-12-01', '2026-11-24', none, 0)).toBe(false);
  });
});
