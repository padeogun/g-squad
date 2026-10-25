// Tests for the fair-share panel helpers (migration 30).
import { describe, expect, it } from 'vitest';
import { bandWidth, HOUR_BANDS, servingRulesPatch } from './dashboards';

describe('fair share bands', () => {
  const bands = { none: 10, up_to_3: 40, three_to_6: 30, six_to_9: 12, over_9: 4 };
  it('sizes each bar against the largest band', () => {
    expect(bandWidth(40, bands)).toBe(100);
    expect(bandWidth(10, bands)).toBe(25);
    expect(bandWidth(0, { none: 0, up_to_3: 0, three_to_6: 0, six_to_9: 0, over_9: 0 })).toBe(0);
  });
  it('lists every band once, from not serving to over the default limit', () => {
    expect(HOUR_BANDS.map((b) => b.key)).toEqual(['none', 'up_to_3', 'three_to_6', 'six_to_9', 'over_9']);
  });
});

// SECURITY REVIEW 20 (F03): a cleared or out-of-range box is refused, not saved as 0, and only
// changed rules are sent.
describe('servingRulesPatch', () => {
  const current = { serving_limit_per_month: 3, hours_per_slot: 3, sundays_off_per_month: 1, leader_roles_max: 2 };
  it('refuses a cleared box instead of saving 0 Sundays off', () => {
    expect(servingRulesPatch({ sundays_off_per_month: '' }, current).error).toMatch(/Sundays off/);
    expect(servingRulesPatch({ sundays_off_per_month: '4' }, current).error).toBeTruthy();
    expect(servingRulesPatch({ hours_per_slot: '2.7' }, current).error).toMatch(/half-hours/);
    expect(servingRulesPatch({ serving_limit_per_month: '2.5' }, current).error).toMatch(/whole number/);
  });
  it('sends only what changed', () => {
    expect(servingRulesPatch({ hours_per_slot: '2.5', sundays_off_per_month: '1' }, current)).toEqual({ patch: { hours_per_slot: 2.5 } });
    expect(servingRulesPatch({ sundays_off_per_month: '0' }, current)).toEqual({ patch: { sundays_off_per_month: 0 } });
  });
});
