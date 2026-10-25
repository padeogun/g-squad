// Tests for the fair-share panel helpers (migration 30).
import { describe, expect, it } from 'vitest';
import { bandWidth, HOUR_BANDS } from './dashboards';

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
