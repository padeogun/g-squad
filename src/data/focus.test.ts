// Tests for the four focus areas' pure helpers (migration 33).
import { describe, expect, it } from 'vitest';
import {
  aimProblems,
  aimsEditable,
  FOCUS_AREAS,
  parseCount,
  previousQuarter,
  quarterName,
  quarterOf,
  ratingLabel,
  ratingSpread,
  reviewOpen,
} from './focus';

describe('the four focus areas', () => {
  it('lists the global church’s four, in order', () => {
    expect(FOCUS_AREAS.map((a) => a.key)).toEqual(['discipleship', 'assimilation', 'pastoral_care', 'soul_winning']);
  });
  it('labels ratings from not achieved to fully', () => {
    expect(ratingLabel(0)).toBe('Not achieved');
    expect(ratingLabel(4)).toBe('Fully');
    expect(ratingLabel(null)).toBe('Not rated');
  });
});

describe('when aims and reviews can be written', () => {
  it('aims change only while a draft or waiting', () => {
    expect(aimsEditable('draft')).toBe(true);
    expect(aimsEditable('submitted')).toBe(true);
    expect(aimsEditable('approved')).toBe(false);
    expect(aimsEditable('done')).toBe(false);
  });
  it('the review opens once the event starts and closes with it', () => {
    const now = new Date('2026-11-24T12:00:00Z');
    expect(reviewOpen('approved', '2026-11-24T11:00:00Z', now)).toBe(true);
    expect(reviewOpen('in_progress', '2026-11-20T11:00:00Z', now)).toBe(true);
    expect(reviewOpen('approved', '2026-11-25T11:00:00Z', now)).toBe(false);
    expect(reviewOpen('done', '2026-11-20T11:00:00Z', now)).toBe(false);
  });
});

describe('aimProblems', () => {
  it('asks for an aim, a primary, and an outcome', () => {
    expect(aimProblems([])).toEqual(['Name at least one focus area.']);
    expect(aimProblems([{ is_primary: false, intended_outcome: 'x' }])).toEqual(['Choose which focus area is primary.']);
    expect(aimProblems([{ is_primary: true, intended_outcome: ' ' }])).toEqual(['Each focus area needs an intended outcome.']);
    expect(aimProblems([{ is_primary: true, intended_outcome: 'a' }, { is_primary: false, intended_outcome: 'b' }])).toEqual([]);
  });
});

describe('parseCount', () => {
  it('takes blank as none and whole numbers up to 100000', () => {
    expect(parseCount('')).toEqual({ ok: true, value: null });
    expect(parseCount(' 12 ')).toEqual({ ok: true, value: 12 });
    expect(parseCount('-1')).toEqual({ ok: false });
    expect(parseCount('2.5')).toEqual({ ok: false });
    expect(parseCount('100001')).toEqual({ ok: false });
  });
});

describe('quarters', () => {
  it('finds the quarter of a date, the one before, and its name', () => {
    expect(quarterOf('2026-11-24')).toBe('2026-10-01');
    expect(quarterOf('2027-03-31')).toBe('2027-01-01');
    expect(previousQuarter('2027-01-01')).toBe('2026-10-01');
    expect(previousQuarter('2026-10-01')).toBe('2026-07-01');
    expect(quarterName('2026-10-01')).toBe('Oct–Dec 2026');
  });
});

describe('ratingSpread', () => {
  it('counts rated events and those mostly or fully achieved', () => {
    expect(ratingSpread([1, 0, 2, 3, 1])).toEqual({ rated: 7, mostlyOrMore: 4 });
    expect(ratingSpread([])).toEqual({ rated: 0, mostlyOrMore: 0 });
  });
});
