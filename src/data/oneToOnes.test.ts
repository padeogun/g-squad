// Tests for one-to-one quarter helpers and which leadership questions apply on a day.
import { describe, expect, it } from 'vitest';
import {
  heldOnMax,
  heldOnProblem,
  promptsFor,
  quarterEnd,
  quarterLabel,
  quarterStart,
  recentQuarters,
  saveErrorMessage,
  walkAccess,
  type Prompt,
} from './oneToOnes';

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

// Security review 17.
describe('held on', () => {
  it('never offers a date after today (W02)', () => {
    expect(heldOnMax('2026-10-01', '2026-10-25')).toBe('2026-10-25');
    expect(heldOnMax('2026-07-01', '2026-10-25')).toBe('2026-09-30');
  });
  it('refuses a future date, and a date outside the quarter of an existing one-to-one', () => {
    expect(heldOnProblem('2026-10-26', '2026-10-25', null)).toMatch(/today or earlier/);
    expect(heldOnProblem('2026-09-30', '2026-10-25', '2026-10-01')).toMatch(/October to December 2026/);
    expect(heldOnProblem('', '2026-10-25', null)).toMatch(/Give the date/);
    expect(heldOnProblem('2026-10-02', '2026-10-25', '2026-10-01')).toBeNull();
  });
});

describe('walkAccess (W05)', () => {
  it('offers an empty box only to the Team Lead writing a new one-to-one', () => {
    expect(walkAccess({ isNew: true, canWrite: true, isWriter: true, isWide: false })).toBe('edit');
    expect(walkAccess({ isNew: true, canWrite: false, isWriter: false, isWide: true })).toBe('none');
  });
  it('offers the logged button to the writer even when they no longer lead the team, and to the Coordinator and Resident Pastor', () => {
    expect(walkAccess({ isNew: false, canWrite: false, isWriter: true, isWide: false })).toBe('ask');
    expect(walkAccess({ isNew: false, canWrite: false, isWriter: false, isWide: true })).toBe('ask');
  });
  it('offers nothing to a Purpose Head', () => {
    expect(walkAccess({ isNew: false, canWrite: false, isWriter: false, isWide: false })).toBe('none');
  });
});

describe('saveErrorMessage (W04)', () => {
  it('says the one-to-one was saved when a later step failed', () => {
    expect(saveErrorMessage({ code: '42501', message: 'Only the Team Lead who wrote this one-to-one can record this' }, true)).toMatch(
      /^The one-to-one was saved, but not everything with it: Only the Team Lead/,
    );
  });
  it('explains a second one-to-one for the same quarter instead of "That name is already in use"', () => {
    expect(saveErrorMessage({ code: '23505', message: 'duplicate key' }, false)).toMatch(/already recorded for this member this quarter/);
  });
});
