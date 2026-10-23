/// <reference types="node" />
// Tests for the reference form definitions.
// 1. The roles the screen offers editing to must match the roles the database lets write
//    (the latest "<table>_write" policy in the migrations). If someone changes one without the
//    other, this fails, so the screen never shows an Edit button that can't work, or hides one
//    that should be there.
// 2. Saving and checking a form behave like the database (empty optional -> null, limits).
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { FORMS, formById, toRow, validate } from './forms';

// All migrations in order, joined, so a later policy for a table overrides an earlier one.
const dir = join(process.cwd(), 'supabase', 'migrations');
const sql = readdirSync(dir)
  .filter((f) => f.endsWith('.sql'))
  .sort()
  .map((f) => readFileSync(join(dir, f), 'utf8'))
  .join('\n');

// Roles named in the LAST "create policy ... on public.<table> for all" statement.
function writeRoles(table: string): string[] {
  const re = new RegExp(`create policy \\w+ on public\\.${table} for all[\\s\\S]*?;`, 'g');
  const matches = sql.match(re);
  if (!matches) throw new Error(`no write policy for ${table}`);
  const last = matches.at(-1)!;
  const roles = new Set<string>();
  for (const m of last.matchAll(/'(\w+)'/g)) roles.add(m[1]);
  return [...roles].sort();
}

describe('reference forms', () => {
  it.each(FORMS.map((f) => [f.table, f]))('%s: editRoles match the database write policy', (_t, f) => {
    expect([...f.editRoles].sort()).toEqual(writeRoles(f.table));
  });

  it('every form has a unique address', () => {
    expect(new Set(FORMS.map((f) => f.id)).size).toBe(FORMS.length);
    expect(formById('units')?.table).toBe('units');
    expect(formById('nope')).toBeUndefined();
  });
});

describe('toRow and validate', () => {
  const units = formById('units')!;

  it('turns empty optional fields into null and numbers into numbers', () => {
    const row = toRow(units, {
      name: '  Production ',
      purpose_id: '',
      objectives: '',
      scope: 'Sunday',
      target_headcount: '12',
      regular_monthly_need: '8',
    });
    expect(row).toEqual({
      name: 'Production',
      purpose_id: null,
      objectives: null,
      scope: 'Sunday',
      target_headcount: 12,
      regular_monthly_need: 8,
    });
  });

  it('reports missing, too long and out-of-range values', () => {
    const errors = validate(units, { name: '', regular_monthly_need: '-1', target_headcount: '2.5', objectives: 'x'.repeat(4001) });
    expect(errors.name).toMatch(/required/);
    expect(errors.regular_monthly_need).toMatch(/between 0 and 500/);
    expect(errors.target_headcount).toMatch(/whole number/);
    expect(errors.objectives).toMatch(/4000 characters/);
  });

  it('accepts a valid unit', () => {
    expect(validate(units, { name: 'Hospitality', regular_monthly_need: '4' })).toEqual({});
  });

  it('booleans are saved as true or false, never null', () => {
    const roles = formById('roles')!;
    expect(toRow(roles, { name: 'Usher', is_rota_role: true }).is_rota_role).toBe(true);
    expect(toRow(roles, { name: 'Usher' }).is_rota_role).toBe(false);
  });
});
