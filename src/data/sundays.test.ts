// Timing helpers behind the service grid: end times, gaps, service length, deadlines.
import { describe, expect, it } from 'vitest';
import { endOf, finaliseDeadline, formatDuration, gaps, longDate, nextSunday, parsePoints, serviceSpan, toTime } from './sundays';

const seg = (starts_at: string, duration_minutes: number) => ({ starts_at, duration_minutes });

describe('service grid timing', () => {
  it('works out end times, including past midnight', () => {
    expect(endOf(seg('10:00:00', 25))).toBe('10:25');
    expect(toTime(24 * 60 + 5)).toBe('00:05');
  });

  it('flags gaps and overlaps between consecutive segments', () => {
    const g = gaps([seg('10:00', 25), seg('10:27', 3), seg('10:30', 15), seg('10:40', 5)]);
    expect(g.get(1)).toBe(2); // 2-minute gap before the 2nd segment
    expect(g.has(2)).toBe(false); // back to back
    expect(g.get(3)).toBe(-5); // 5-minute overlap
  });

  it('gives the span of the whole service', () => {
    expect(serviceSpan([seg('10:00', 25), seg('12:39', 1)])).toEqual({ start: '10:00', end: '12:40', minutes: 160 });
    expect(serviceSpan([])).toBeNull();
    expect(formatDuration(160)).toBe('2 h 40 min');
    expect(formatDuration(45)).toBe('45 min');
    expect(formatDuration(60)).toBe('1 h');
  });
});

describe('dates', () => {
  it('finalise deadline is the Thursday before', () => {
    expect(finaliseDeadline('2026-10-25')).toBe('2026-10-22');
  });

  it('next Sunday is today when today is Sunday, else the coming one', () => {
    expect(nextSunday(new Date(2026, 9, 25))).toBe('2026-10-25');
    expect(nextSunday(new Date(2026, 9, 23))).toBe('2026-10-25');
  });

  it('formats a long date in UK style', () => {
    expect(longDate('2026-10-25')).toBe('Sunday 25 October 2026');
  });
});

describe('sub-points', () => {
  it('one per line, trimmed, blanks dropped, at most 20', () => {
    expect(parsePoints(' Prayer of thanksgiving \n\n Welcome online ')).toEqual(['Prayer of thanksgiving', 'Welcome online']);
    expect(parsePoints(Array.from({ length: 25 }, (_, i) => `p${i}`).join('\n'))).toHaveLength(20);
  });
});
