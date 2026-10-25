// Tests for project helpers: London time either side of the clock changes, the date line,
// and the event plan section status.
import { describe, expect, it } from 'vitest';
import { budgetButtons, formatWhen, isoToLondon, isPastProject, londonToIso, safeHttpsUrl, sectionStatus, type EventPlan } from './projects';

describe('London time', () => {
  it('converts winter (GMT) and summer (BST) wall-clock times', () => {
    expect(londonToIso('2027-01-09', '11:00')).toBe('2027-01-09T11:00:00.000Z');
    expect(londonToIso('2027-07-10', '11:00')).toBe('2027-07-10T10:00:00.000Z');
  });
  it('handles the days the clocks change', () => {
    // 28 March 2027: clocks go forward at 01:00 GMT; 10:00 is BST.
    expect(londonToIso('2027-03-28', '10:00')).toBe('2027-03-28T09:00:00.000Z');
    // 31 October 2027: clocks go back at 02:00 BST; 10:00 is GMT.
    expect(londonToIso('2027-10-31', '10:00')).toBe('2027-10-31T10:00:00.000Z');
  });
  it('round-trips', () => {
    expect(isoToLondon(londonToIso('2027-07-10', '18:30'))).toEqual({ date: '2027-07-10', time: '18:30' });
  });
  it('writes the date line', () => {
    expect(formatWhen('2027-01-09T11:00:00Z', '2027-01-09T15:00:00Z')).toBe('Saturday 9 January 2027, 11:00 – 15:00');
    expect(formatWhen('2027-01-09T11:00:00Z', '2027-01-10T13:00:00Z')).toBe('Saturday 9 January 2027, 11:00 – Sunday 10 January 2027, 13:00');
  });
});

describe('sectionStatus', () => {
  const plan = { size: 'large', complexity: 'high', has_planning_committee: false, budget_status: 'pending' } as unknown as EventPlan;
  it('flags a High complexity event without a committee', () => {
    expect(sectionStatus(3, plan)).toEqual({ label: 'Committee needed', tone: 'danger' });
  });
  it('shows the budget waiting for Finance', () => {
    expect(sectionStatus(5, plan).label).toBe('Awaiting Finance');
  });
  it('a complete section with open action points is not shown as complete', () => {
    expect(sectionStatus(1, plan, 2)).toEqual({ label: '2 actions open', tone: 'warn' });
  });
});

// Security review 15 (U09).
describe('isPastProject', () => {
  it('uses the London date of the end, not the UTC date', () => {
    // 00:30 BST on 11 July 2027 is 23:30 UTC on 10 July: the project ends on 11 July in London.
    expect(isPastProject({ status: 'approved', ends_at: '2027-07-10T23:30:00Z' }, '2027-07-11')).toBe(false);
    expect(isPastProject({ status: 'approved', ends_at: '2027-07-10T22:30:00Z' }, '2027-07-11')).toBe(true);
  });
  it('treats done and cancelled projects as past', () => {
    expect(isPastProject({ status: 'cancelled', ends_at: '2099-01-01T00:00:00Z' }, '2027-01-01')).toBe(true);
  });
});

describe('safeHttpsUrl', () => {
  it('keeps https links', () => {
    expect(safeHttpsUrl('https://example.org/budget.xlsx')).toBe('https://example.org/budget.xlsx');
  });
  it('refuses anything else', () => {
    for (const bad of ['javascript:alert(1)', 'http://example.org', 'data:text/html,x', 'https://exa mple.org', ' https://x.org', '', null, undefined])
      expect(safeHttpsUrl(bad)).toBeNull();
  });
});

describe('budgetButtons', () => {
  it('does not offer the owner "No budget needed" once there is an estimate (F11)', () => {
    expect(budgetButtons({ budget_status: 'pending', budget_estimate_gbp: 250 }, { decider: false, canManage: true })).toEqual([]);
    expect(budgetButtons({ budget_status: 'pending', budget_estimate_gbp: null }, { decider: false, canManage: true })).toEqual(['not_needed']);
  });
  it('offers Finance the decision', () => {
    expect(budgetButtons({ budget_status: 'pending', budget_estimate_gbp: 250 }, { decider: true, canManage: false })).toEqual([
      'approve',
      'reject',
      'not_needed',
    ]);
  });
});

describe('londonToIso on a missing hour', () => {
  it('moves 01:30 on the spring-forward day to the next valid time (02:30 BST)', () => {
    expect(londonToIso('2027-03-28', '01:30')).toBe('2027-03-28T01:30:00.000Z');
  });
});
