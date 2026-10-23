// Tests for the TECi list order: people awaiting verification come first (the TECi
// Coordinator's to-do list), then verified members, then those who have not started TECi.
import { describe, expect, it } from 'vitest';
import { teciOrder, type TeciPerson } from './teci';

const p = (id: string, surname: string, stage: string | null, verified: string | null): TeciPerson => ({
  id,
  first_name: 'A',
  surname,
  status: 'active',
  teci_stage_id: stage,
  teci_verified_at: verified,
});

describe('teciOrder', () => {
  it('puts unverified stages first, then verified, then not started', () => {
    const list = [
      p('none', 'Adams', null, null),
      p('done', 'Bello', 's1', '2026-10-23T10:00:00Z'),
      p('todo', 'Cole', 's1', null),
    ].sort(teciOrder);
    expect(list.map((x) => x.id)).toEqual(['todo', 'done', 'none']);
  });

  it('sorts by surname within a group', () => {
    const list = [p('b', 'Okafor', 's2', null), p('a', 'Adeyemi', 's1', null)].sort(teciOrder);
    expect(list.map((x) => x.id)).toEqual(['a', 'b']);
  });
});
