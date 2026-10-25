// Tests for one-to-one quarter helpers and which leadership questions apply on a day.
import { describe, expect, it } from 'vitest';
import { promptsFor, quarterEnd, quarterLabel, quarterStart, recentQuarters, type Prompt } from './oneToOnes';

describe('quarters', () => {
  it('finds the quarter a day is in', () => {
    expect(quarterStart('2026-10-25')).toBe('2026-10-01');
    expect(quarterStart('2026-03-31')).toBe('2026-01-01');
    expect(quarterEnd('2026-10-01')).toBe('2026-12-31');
    expect(quarterEnd('2027-01-01')).toBe('2027-03-31');
  });
  it('names a quarter', () => {
    expect(quarterLabel('2026-10-01')).toBe('October to December 2026');
  });
  it('lists recent quarters across a year end', () => {
    expect(recentQuarters('2027-02-10', 2)).toEqual(['2027-01-01', '2026-10-01', '2026-07-01']);
  });
});

describe('promptsFor', () => {
  const p = (id: string, s: string, e: string, on = true) => ({ id, starts_on: s, ends_on: e, is_active: on }) as Prompt;
  it('keeps switched-on questions whose period covers the day', () => {
    const list = [p('a', '2026-10-01', '2026-12-31'), p('b', '2026-01-01', '2026-03-31'), p('c', '2026-10-01', '2026-12-31', false)];
    expect(promptsFor(list, '2026-10-25').map((x) => x.id)).toEqual(['a']);
  });
});
