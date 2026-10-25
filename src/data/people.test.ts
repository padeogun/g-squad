/// <reference types="node" />
// Tests for the member helpers and source guards added in security review 7.
//   L06  an edit sends only the columns that changed.
//   L01  new members are added only through create_member (one transaction); a direct
//        insert into people would leave a person with no unit if the membership failed.
//        Faith fields are never read or written from the table directly (project rule).
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { changedColumns, cleanFaith, repeatedAt } from './people';

describe('changedColumns (L06)', () => {
  it('returns only the fields that differ', () => {
    const before = { first_name: 'Ada', email: 'ada@example.org', area: null as string | null };
    expect(changedColumns(before, { ...before })).toEqual({});
    expect(changedColumns(before, { ...before, area: 'M6' })).toEqual({ area: 'M6' });
    expect(changedColumns(before, { ...before, email: null as unknown as string })).toEqual({ email: null });
  });
  // V07 (review 16): lists are compared by their entries, not as objects.
  it('treats two copies of the same list as unchanged', () => {
    const before = { phones: ['07700 900123'], other_emails: [] as string[] };
    expect(changedColumns(before, { phones: ['07700 900123'], other_emails: [] })).toEqual({});
    expect(changedColumns(before, { phones: ['07700 900123', '0161 496 0000'], other_emails: [] })).toEqual({
      phones: ['07700 900123', '0161 496 0000'],
    });
    expect(changedColumns(before, { phones: [], other_emails: [] })).toEqual({ phones: [] });
  });
});

describe('repeatedAt (V05, review 16)', () => {
  it('finds entries that repeat an earlier one', () => {
    expect(repeatedAt(['a@example.org', 'B@example.org ', 'b@example.org'], true)).toEqual([2]);
    expect(repeatedAt(['a@example.org', 'A@example.org'])).toEqual([]);
    expect(repeatedAt(['07700 900123', '', '07700 900123'])).toEqual([2]);
    expect(repeatedAt(['', ''])).toEqual([]);
  });
});

describe('cleanFaith', () => {
  it('drops a date whose tick is not set', () => {
    const f = cleanFaith({
      salvation_date: '2020-01-01',
      water_baptism: false,
      water_baptism_date: '2021-01-01',
      holy_spirit_baptism: true,
      holy_spirit_baptism_date: '2022-01-01',
      speaks_in_tongues: false,
      speaks_in_tongues_date: null,
    });
    expect(f.water_baptism_date).toBeNull();
    expect(f.holy_spirit_baptism_date).toBe('2022-01-01');
    expect(f.salvation_date).toBe('2020-01-01');
  });
});

// Every .ts/.tsx file under src/, except tests and generated types.
function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) return sources(p);
    return /\.(ts|tsx)$/.test(name) && !/\.test\./.test(name) && !name.endsWith('database.types.ts') ? [p] : [];
  });
}

describe('source guards (L01)', () => {
  const files = sources(join(process.cwd(), 'src')).map((p) => ({ p, text: readFileSync(p, 'utf8') }));

  it('no screen inserts into people directly (use the create_member function)', () => {
    const bad = files.filter((f) => /from\(\s*['"]people['"]\s*\)\s*\.insert/.test(f.text)).map((f) => f.p);
    expect(bad).toEqual([]);
  });

  it('nothing reads or writes person_faith directly (use the logged functions)', () => {
    const bad = files.filter((f) => /from\(\s*['"]person_faith['"]/.test(f.text)).map((f) => f.p);
    expect(bad).toEqual([]);
  });
});
