// Unit tests for the pure helpers behind stage history, the pathway and the Maturity report.
import { describe, expect, it } from 'vitest';
import { currentPathway, describeChange, share } from './maturity';

const names: Record<string, string> = { a: 'Spotted', b: 'Developing' };
const nameOf = (id: string | null) => (id ? (names[id] ?? '?') : '');

describe('describeChange', () => {
  it('names the first entry as a starting point, not a move', () => {
    expect(describeChange({ from_stage_id: null, to_stage_id: 'a' }, nameOf)).toBe('Started at Spotted');
  });
  it('shows a move from one stage to the next', () => {
    expect(describeChange({ from_stage_id: 'a', to_stage_id: 'b' }, nameOf)).toBe('Spotted → Developing');
  });
  it('shows a stage being cleared', () => {
    expect(describeChange({ from_stage_id: 'b', to_stage_id: null }, nameOf)).toBe('Stage cleared (was Developing)');
  });
});

describe('currentPathway', () => {
  it('is nothing when nothing is recorded', () => {
    expect(currentPathway([])).toBeNull();
  });
  it('is the latest stage reached', () => {
    const e = [
      { id: 1, reached_on: '2026-01-05', recorded_at: '2026-01-05T10:00:00Z' },
      { id: 2, reached_on: '2026-06-01', recorded_at: '2026-06-01T10:00:00Z' },
      { id: 3, reached_on: '2026-03-01', recorded_at: '2026-11-01T10:00:00Z' },
    ];
    expect(currentPathway(e)?.id).toBe(2);
  });
  it('breaks a same-day tie by when it was recorded', () => {
    const e = [
      { id: 1, reached_on: '2026-06-01', recorded_at: '2026-06-02T10:00:00Z' },
      { id: 2, reached_on: '2026-06-01', recorded_at: '2026-06-01T10:00:00Z' },
    ];
    expect(currentPathway(e)?.id).toBe(1);
  });
});

describe('share', () => {
  it('rounds to a whole percent', () => {
    expect(share(1, 3)).toBe(33);
  });
  it('is 0 with nothing to share', () => {
    expect(share(0, 0)).toBe(0);
  });
});
