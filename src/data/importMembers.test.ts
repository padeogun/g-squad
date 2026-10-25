// Tests for reading and checking a members spreadsheet before upload.
import { describe, expect, it } from 'vitest';
import { buildImport, mapHeadings, parseDate, parseDayMonth, parseYesNo, serverProblems, templateCsv, type Context, type Refs } from './importMembers';

const refs: Refs = {
  units: [
    { id: 'u1', name: 'Production', is_active: true },
    { id: 'u2', name: 'Hospitality', is_active: true },
  ],
  roles: [
    { id: 'r-member', name: 'Member', unit_id: null, is_active: true, permanence: 'operational' },
    { id: 'r-cam', name: 'Camera operator', unit_id: 'u1', is_active: true, permanence: 'operational' },
    { id: 'r-proj', name: 'Harvest steward', unit_id: null, is_active: true, permanence: 'project' },
  ],
  stages: [{ id: 'l1', name: 'Spotted' }],
  teciStages: [{ id: 't1', stage_no: 1, name: 'Foundations' }],
};
const coordinator: Context = { allowedUnitIds: null, canRecordFaith: () => true, canSetTeci: true };
const head = ['First name', 'Surname', 'Email', 'Birthday', 'Unit', 'Team role', 'Water baptism', 'Water baptism date', 'TECi stage'];

describe('cell readers', () => {
  it('reads UK dates, ISO dates and spreadsheet dates', () => {
    expect(parseDate('14/03/2025')).toBe('2025-03-14');
    expect(parseDate('2025-03-14')).toBe('2025-03-14');
    expect(parseDate('14 March 2025')).toBe('2025-03-14');
    expect(parseDate(new Date(Date.UTC(2025, 2, 14)))).toBe('2025-03-14');
    expect(parseDate('31/02/2025')).toBe('invalid');
    expect(parseDate('')).toBeNull();
  });
  it('reads birthdays as day and month only, allowing 29 February', () => {
    expect(parseDayMonth('14/03')).toEqual({ day: 14, month: 3 });
    expect(parseDayMonth('29 Feb')).toEqual({ day: 29, month: 2 });
    expect(parseDayMonth('14/03/1990')).toEqual({ day: 14, month: 3 });
    expect(parseDayMonth('32/01')).toBe('invalid');
  });
  it('reads yes and no', () => {
    expect(parseYesNo('Yes')).toBe(true);
    expect(parseYesNo('n')).toBe(false);
    expect(parseYesNo(true)).toBe(true);
    expect(parseYesNo('maybe')).toBe('invalid');
    expect(parseYesNo('')).toBeNull();
  });
});

describe('headings', () => {
  it('matches headings and aliases, whatever the case', () => {
    const m = mapHeadings(['FIRST NAME', 'surname', 'Email address', 'Team', 'Shoe size']);
    expect(m.index).toMatchObject({ first_name: 0, surname: 1, email: 2, unit: 3 });
    expect(m.unknown).toEqual(['Shoe size']);
    expect(m.missing).toEqual([]);
  });
  it('the template has every column, required ones included', () => {
    expect(mapHeadings(templateCsv().trim().split(',')).missing).toEqual([]);
  });
  it('reports missing required columns', () => {
    expect(buildImport([['Email']], refs, coordinator).headingProblem).toMatch(/First name, Surname/);
  });
});

describe('buildImport', () => {
  it('turns good rows into import rows', () => {
    const res = buildImport(
      [head, ['Ada', 'Obi', 'ADA@example.org', '14/03', 'production', 'Camera operator', 'Yes', '01/06/2026', '1']],
      refs,
      coordinator,
    );
    expect(res.problems).toEqual([]);
    expect(res.rows[0]).toMatchObject({
      row: 2,
      unit_id: 'u1',
      church_role_id: 'r-cam',
      person: { first_name: 'Ada', surname: 'Obi', email: 'ada@example.org', birth_day: 14, birth_month: 3, teci_stage_id: 't1' },
      faith: { water_baptism: true, water_baptism_date: '2026-06-01' },
    });
  });

  it('lists every problem against its spreadsheet row, and skips blank rows', () => {
    const res = buildImport(
      [
        head,
        ['', 'Obi', 'not-an-email', '31/02', 'Kitchen', '', '', '', ''],
        [null, null, null, null, null, null, null, null, null],
        ['Bo', 'Bell', '', '', 'Hospitality', 'Camera operator', '', '', ''],
        ['Cy', 'Cole', '', '', 'Production', 'Harvest steward', '', '', ''],
      ],
      refs,
      coordinator,
    );
    expect(res.rows).toEqual([]);
    expect(res.problems.map((p) => p.row)).toEqual([2, 4, 5]);
    expect(res.problems[0].messages.join(' ')).toMatch(/First name is missing.*not an email.*Birthday.*No active unit called "Kitchen"/);
    expect(res.problems[1].messages[0]).toMatch(/No team role "Camera operator" in Hospitality/);
    expect(res.problems[2].messages[0]).toMatch(/project role/);
  });

  it('a Team Lead uploads into their own unit only, which may be left blank', () => {
    const lead: Context = { allowedUnitIds: ['u2'], canRecordFaith: (u) => u === 'u2', canSetTeci: false };
    const res = buildImport([head, ['Ada', 'Obi', '', '', '', '', '', '', ''], ['Bo', 'Bell', '', '', 'Production', '', '', '', '']], refs, lead);
    expect(res.rows[0].unit_id).toBe('u2');
    expect(res.problems[0].messages[0]).toMatch(/can't add members to Production/);
  });

  it('refuses faith fields and TECi stages from leaders who may not record them', () => {
    const ops: Context = { allowedUnitIds: null, canRecordFaith: () => false, canSetTeci: false };
    const res = buildImport([head, ['Ada', 'Obi', '', '', 'Production', '', 'Yes', '', '2']], refs, ops);
    expect(res.problems[0].messages.join(' ')).toMatch(/TECi stage.*Faith fields/);
  });

  it('spots the same email twice in one file', () => {
    const res = buildImport([head, ['A', 'One', 'a@example.org', '', 'Production'], ['B', 'Two', 'A@example.org', '', 'Production']], refs, coordinator);
    expect(res.problems[0]).toEqual({ row: 3, messages: ['Same email as row 2'] });
  });

  it('refuses more than 500 members', () => {
    const many = Array.from({ length: 501 }, (_, i) => ['A', `S${i}`, '', '', 'Production']);
    expect(buildImport([head, ...many], refs, coordinator).headingProblem).toMatch(/at most 500/);
  });
});

describe('phones and extra emails (migration 25)', () => {
  const h = ['First name', 'Surname', 'Email', 'Email 2', 'Mobile', 'Phone 2', 'Unit'];
  it('reads up to 3 phones and 2 more emails', () => {
    const res = buildImport([h, ['Ada', 'Obi', 'ada@example.org', 'ADA.work@example.org', '07700 900123', '+44 161 496 0000', 'Production']], refs, coordinator);
    expect(res.problems).toEqual([]);
    expect(res.rows[0].person).toMatchObject({ other_emails: ['ada.work@example.org'], phones: ['07700 900123', '+44 161 496 0000'] });
  });
  it('refuses a bad phone number, and an extra email without the main one', () => {
    const res = buildImport([h, ['Ada', 'Obi', '', 'ada@example.org', 'call me', '', 'Production']], refs, coordinator);
    expect(res.problems[0].messages.join(' ')).toMatch(/main email.*|"call me" is not a phone number/);
    expect(res.problems[0].messages).toHaveLength(2);
  });
});

describe('phone numbers stored as numbers by Excel', () => {
  it('asks for the column to be formatted as text', () => {
    const res = buildImport([['First name', 'Surname', 'Phone 1', 'Unit'], ['Ada', 'Obi', 7700900123, 'Production']], refs, coordinator);
    expect(res.problems[0].messages[0]).toMatch(/lost its leading 0/);
  });
});

describe('serverProblems', () => {
  it('reads the database row list and softens permission messages', () => {
    expect(serverProblems('[{"row":4,"message":"new row violates row-level security policy for table \\"people\\""}]')).toEqual([
      { row: 4, messages: ["You don't have permission to add this member here"] },
    ]);
    expect(serverProblems('not json')).toEqual([]);
  });
});
