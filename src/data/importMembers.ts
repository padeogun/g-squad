// -------------------------------------------------------------------------------------
// Bulk upload of G-Squad members: turns a spreadsheet (already read into rows of cells) into
// the rows public.import_members expects, and lists every problem by spreadsheet row first,
// so a leader fixes the file before anything is sent.
//
// This file only reads and checks. The database still decides every row (row-level security,
// guards, the logged faith function) and saves all or nothing (migration 23); the checks here
// are for clear messages, not for security.
// Dates are UK style (day first) unless written as YYYY-MM-DD.
// -------------------------------------------------------------------------------------

export type Cell = string | number | boolean | Date | null | undefined;

// The template's columns, in order. Aliases let a slightly different heading still match.
export const COLUMNS = [
  { key: 'first_name', header: 'First name', required: true },
  { key: 'other_names', header: 'Other names' },
  { key: 'surname', header: 'Surname', required: true },
  { key: 'email', header: 'Email', aliases: ['email address'] },
  { key: 'area', header: 'Area', aliases: ['postcode district', 'town'] },
  { key: 'birthday', header: 'Birthday', aliases: ['birthday (day and month)', 'date of birth'] },
  { key: 'date_joined', header: 'Date joined', aliases: ['joined'] },
  { key: 'marital_status', header: 'Marital status' },
  { key: 'anniversary', header: 'Wedding anniversary', aliases: ['anniversary'] },
  { key: 'unit', header: 'Unit', aliases: ['team'] },
  { key: 'team_role', header: 'Team role', aliases: ['role'] },
  { key: 'leadership_stage', header: 'Leadership stage' },
  { key: 'teci_stage', header: 'TECi stage', aliases: ['teci'] },
  { key: 'salvation_date', header: 'Date of salvation', aliases: ['salvation date'] },
  { key: 'water_baptism', header: 'Water baptism' },
  { key: 'water_baptism_date', header: 'Water baptism date' },
  { key: 'holy_spirit_baptism', header: 'Holy Spirit baptism' },
  { key: 'holy_spirit_baptism_date', header: 'Holy Spirit baptism date' },
  { key: 'speaks_in_tongues', header: 'Speaks in tongues' },
  { key: 'speaks_in_tongues_date', header: 'Speaks in tongues date' },
  { key: 'newsletter', header: 'Receives newsletter', aliases: ['newsletter'] },
  { key: 'celebration', header: 'Birthday greetings in newsletter', aliases: ['celebration greetings', 'greetings'] },
] as const;

export type ColumnKey = (typeof COLUMNS)[number]['key'];
const FAITH_KEYS: ColumnKey[] = [
  'salvation_date',
  'water_baptism',
  'water_baptism_date',
  'holy_spirit_baptism',
  'holy_spirit_baptism_date',
  'speaks_in_tongues',
  'speaks_in_tongues_date',
];
export const MAX_ROWS = 500;

// A CSV of just the headings (no example people, so nothing fictional is uploaded by mistake).
export function templateCsv(): string {
  return COLUMNS.map((c) => c.header).join(',') + '\r\n';
}

const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

// Reads the heading row: which column holds which field, and headings it did not recognise.
export function mapHeadings(headings: Cell[]): { index: Partial<Record<ColumnKey, number>>; unknown: string[]; missing: string[] } {
  const index: Partial<Record<ColumnKey, number>> = {};
  const unknown: string[] = [];
  headings.forEach((h, i) => {
    const text = norm(String(h ?? ''));
    if (!text) return;
    const col = COLUMNS.find((c) => norm(c.header) === text || ('aliases' in c && c.aliases.some((a) => norm(a) === text)));
    if (col && index[col.key] === undefined) index[col.key] = i;
    else unknown.push(String(h));
  });
  const missing = COLUMNS.filter((c) => 'required' in c && c.required && index[c.key] === undefined).map((c) => c.header);
  return { index, unknown, missing };
}

// ---------- Cell readers ----------
const text = (v: Cell) => (v instanceof Date ? isoDate(v) : v == null ? '' : String(v).trim());

function isoDate(d: Date): string {
  // Spreadsheet dates arrive as midnight UTC; read the UTC parts so the day never shifts.
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
}

const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
function monthNo(s: string): number | null {
  if (/^\d{1,2}$/.test(s)) return Number(s);
  const i = MONTHS.indexOf(s.slice(0, 3).toLowerCase());
  return i >= 0 ? i + 1 : null;
}
const daysIn = (m: number, y = 2000) => new Date(Date.UTC(y, m, 0)).getUTCDate();

// A full date: a spreadsheet date, YYYY-MM-DD, DD/MM/YYYY (or - .), or "14 March 2026".
export function parseDate(v: Cell): string | null | 'invalid' {
  if (v == null || v === '') return null;
  if (v instanceof Date) return Number.isNaN(v.getTime()) ? 'invalid' : isoDate(v);
  const s = String(v).trim();
  if (!s) return null;
  let y: number, m: number | null, d: number;
  let r = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/);
  if (r) [y, m, d] = [Number(r[1]), Number(r[2]), Number(r[3])];
  else if ((r = s.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2}|\d{4})$/))) [d, m, y] = [Number(r[1]), Number(r[2]), Number(r[3])];
  else if ((r = s.match(/^(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]+)\s+(\d{4})$/i))) [d, m, y] = [Number(r[1]), monthNo(r[2]), Number(r[3])];
  else return 'invalid';
  if (y < 100) y += 2000;
  if (!m || m < 1 || m > 12 || d < 1 || d > daysIn(m, y) || y < 1900 || y > 2100) return 'invalid';
  return `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

// A day and month only (birthdays, anniversaries): "14/03", "14 March", or a full date (year dropped).
export function parseDayMonth(v: Cell): { day: number; month: number } | null | 'invalid' {
  if (v == null || v === '') return null;
  if (v instanceof Date) return Number.isNaN(v.getTime()) ? 'invalid' : { day: v.getUTCDate(), month: v.getUTCMonth() + 1 };
  const s = String(v).trim();
  if (!s) return null;
  let r = s.match(/^(\d{1,2})[/.-](\d{1,2})$/);
  let d: number, m: number | null;
  if (r) [d, m] = [Number(r[1]), Number(r[2])];
  else if ((r = s.match(/^(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]+)$/i))) [d, m] = [Number(r[1]), monthNo(r[2])];
  else {
    const full = parseDate(s);
    if (full === null || full === 'invalid') return 'invalid';
    [m, d] = [Number(full.slice(5, 7)), Number(full.slice(8, 10))];
  }
  // 29 February is a real birthday, so check against a leap year.
  if (!m || m < 1 || m > 12 || d < 1 || d > daysIn(m, 2000)) return 'invalid';
  return { day: d, month: m };
}

// Yes / no: yes, y, true, 1, x, ✓ count as yes; empty is "not given".
export function parseYesNo(v: Cell): boolean | null | 'invalid' {
  if (v == null || v === '') return null;
  if (typeof v === 'boolean') return v;
  const s = String(v).trim().toLowerCase();
  if (!s) return null;
  if (['yes', 'y', 'true', '1', 'x', '✓', '✔'].includes(s)) return true;
  if (['no', 'n', 'false', '0'].includes(s)) return false;
  return 'invalid';
}

// ---------- Rows ----------
export interface Refs {
  units: { id: string; name: string; is_active: boolean }[];
  roles: { id: string; name: string; unit_id: string | null; is_active: boolean; permanence: string }[];
  stages: { id: string; name: string }[];
  teciStages: { id: string; stage_no: number; name: string }[];
}
export interface Context {
  // Units this leader may upload into; null = any (Coordinator, Operations Lead).
  allowedUnitIds: string[] | null;
  // Whether this leader may record faith fields for someone joining this unit.
  canRecordFaith: (unitId: string) => boolean;
  // Whether this leader may give a TECi stage when adding someone.
  canSetTeci: boolean;
}
export interface ImportRow {
  row: number;
  person: Record<string, unknown>;
  unit_id: string;
  church_role_id: string | null;
  leadership_stage_id: string | null;
  faith: Record<string, unknown> | null;
  // For the preview only.
  display: { name: string; unit: string; role: string; email: string };
}
export interface Problem {
  row: number;
  messages: string[];
}

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const byName = <T extends { name: string }>(list: T[], name: string) => list.find((x) => norm(x.name) === norm(name));

// rows[0] is the heading row; spreadsheet row numbers start at 1 (so data starts at row 2).
export function buildImport(rows: Cell[][], refs: Refs, ctx: Context) {
  const problems: Problem[] = [];
  const out: ImportRow[] = [];
  if (rows.length === 0) return { rows: out, problems, headingProblem: 'The file is empty.', unknown: [] as string[] };
  const { index, unknown, missing } = mapHeadings(rows[0]);
  if (missing.length)
    return { rows: out, problems, headingProblem: `Missing column${missing.length > 1 ? 's' : ''}: ${missing.join(', ')}.`, unknown };

  const allowed = refs.units.filter((u) => u.is_active && (!ctx.allowedUnitIds || ctx.allowedUnitIds.includes(u.id)));
  const seenEmails = new Map<string, number>();
  const dataRows = rows.slice(1).map((cells, i) => ({ cells, row: i + 2 })).filter(({ cells }) => cells.some((c) => text(c) !== ''));
  if (dataRows.length > MAX_ROWS)
    return { rows: out, problems, headingProblem: `The file has ${dataRows.length} members; upload at most ${MAX_ROWS} at a time.`, unknown };

  for (const { cells, row } of dataRows) {
    const get = (k: ColumnKey): Cell => (index[k] === undefined ? null : cells[index[k]!]);
    const msgs: string[] = [];
    const person: Record<string, unknown> = {};

    // Names.
    for (const k of ['first_name', 'surname'] as const) {
      const v = text(get(k));
      if (!v) msgs.push(`${k === 'first_name' ? 'First name' : 'Surname'} is missing`);
      else if (v.length > 100) msgs.push(`${k === 'first_name' ? 'First name' : 'Surname'} is longer than 100 characters`);
      person[k] = v;
    }
    const other = text(get('other_names'));
    if (other.length > 200) msgs.push('Other names are longer than 200 characters');
    if (other) person.other_names = other;

    // Contact and area.
    const email = text(get('email')).toLowerCase();
    if (email) {
      if (email.length > 254 || !EMAIL.test(email)) msgs.push(`"${email}" is not an email address`);
      else if (seenEmails.has(email)) msgs.push(`Same email as row ${seenEmails.get(email)}`);
      else seenEmails.set(email, row);
      person.email = email;
    }
    const area = text(get('area'));
    if (area.length > 100) msgs.push('Area is longer than 100 characters (town or postcode district only)');
    if (area) person.area = area;

    // Birthday and anniversary: day and month only (no year is kept).
    const bday = parseDayMonth(get('birthday'));
    if (bday === 'invalid') msgs.push('Birthday is not a day and month (e.g. 14/03)');
    else if (bday) Object.assign(person, { birth_day: bday.day, birth_month: bday.month });
    const ms = text(get('marital_status')).toLowerCase();
    if (ms && ms !== 'single' && ms !== 'married') msgs.push('Marital status must be Single or Married (or left empty)');
    if (ms === 'single' || ms === 'married') person.marital_status = ms;
    const ann = parseDayMonth(get('anniversary'));
    if (ann === 'invalid') msgs.push('Wedding anniversary is not a day and month');
    else if (ann && ms !== 'married') msgs.push('A wedding anniversary is kept only for married members');
    else if (ann) Object.assign(person, { anniversary_day: ann.day, anniversary_month: ann.month });

    const joined = parseDate(get('date_joined'));
    if (joined === 'invalid') msgs.push('Date joined is not a date (e.g. 14/03/2025)');
    else if (joined) person.date_joined = joined;

    for (const [k, field] of [['newsletter', 'newsletter_subscribed'], ['celebration', 'celebration_opt_in']] as const) {
      const yn = parseYesNo(get(k));
      if (yn === 'invalid') msgs.push(`${COLUMNS.find((c) => c.key === k)!.header} must be Yes or No`);
      else if (yn !== null) person[field] = yn;
    }

    // Unit: the leader's only unit may be left blank.
    const unitName = text(get('unit'));
    const unit = unitName ? byName(allowed, unitName) : allowed.length === 1 ? allowed[0] : undefined;
    if (!unit)
      msgs.push(
        unitName
          ? refs.units.some((u) => norm(u.name) === norm(unitName))
            ? `You can't add members to ${unitName}`
            : `No active unit called "${unitName}"`
          : 'Unit is missing',
      );

    // Team role: operational, and church-wide or this unit's own.
    let roleId: string | null = null;
    const roleName = text(get('team_role'));
    if (roleName && unit) {
      const role = refs.roles.find(
        (r) => r.is_active && norm(r.name) === norm(roleName) && (!r.unit_id || r.unit_id === unit.id),
      );
      if (!role) msgs.push(`No team role "${roleName}" in ${unit.name}`);
      else if (role.permanence !== 'operational') msgs.push(`"${roleName}" is a project role, not a team role`);
      else roleId = role.id;
    }
    let stageId: string | null = null;
    const stageName = text(get('leadership_stage'));
    if (stageName) {
      const st = byName(refs.stages, stageName);
      if (!st) msgs.push(`No leadership stage "${stageName}"`);
      else stageId = st.id;
    }

    // TECi stage: a number (1 to 5) or its name; only some roles may give one.
    const teci = text(get('teci_stage'));
    if (teci) {
      const st = /^\d$/.test(teci) ? refs.teciStages.find((t) => t.stage_no === Number(teci)) : byName(refs.teciStages, teci);
      if (!ctx.canSetTeci) msgs.push('Only the TECi Coordinator, G-Squad Coordinator or Operations Lead can give a TECi stage');
      else if (!st) msgs.push(`No TECi stage "${teci}"`);
      else person.teci_stage_id = st.id;
    }

    // Faith fields (special category data): only for leaders who may record them.
    let faith: Record<string, unknown> | null = null;
    if (FAITH_KEYS.some((k) => text(get(k)) !== '')) {
      if (unit && !ctx.canRecordFaith(unit.id))
        msgs.push("Faith fields are recorded only by the G-Squad Coordinator or the team's Team Lead; leave those columns empty");
      else {
        faith = {};
        const sal = parseDate(get('salvation_date'));
        if (sal === 'invalid') msgs.push('Date of salvation is not a date');
        else if (sal) faith.salvation_date = sal;
        for (const [tick, date, label] of [
          ['water_baptism', 'water_baptism_date', 'Water baptism'],
          ['holy_spirit_baptism', 'holy_spirit_baptism_date', 'Holy Spirit baptism'],
          ['speaks_in_tongues', 'speaks_in_tongues_date', 'Speaks in tongues'],
        ] as const) {
          const yn = parseYesNo(get(tick));
          const dt = parseDate(get(date));
          if (yn === 'invalid') msgs.push(`${label} must be Yes or No`);
          if (dt === 'invalid') msgs.push(`${label} date is not a date`);
          // A date means yes (the database keeps a date only with the tick).
          const on = yn === true || (yn === null && typeof dt === 'string');
          if (yn === false && typeof dt === 'string') msgs.push(`${label} has a date but says No`);
          faith[tick] = on;
          if (on && typeof dt === 'string') faith[date] = dt;
        }
      }
    }

    if (msgs.length) problems.push({ row, messages: msgs });
    else
      out.push({
        row,
        person,
        unit_id: unit!.id,
        church_role_id: roleId,
        leadership_stage_id: stageId,
        faith,
        display: {
          name: `${person.first_name} ${person.surname}`,
          unit: unit!.name,
          role: roleName || '–',
          email: email || '–',
        },
      });
  }
  return { rows: out, problems, headingProblem: null as string | null, unknown };
}

// The database's row list (raised as JSON in the error's details) as problems.
export function serverProblems(details: string | null | undefined): Problem[] {
  try {
    const list = JSON.parse(details ?? '') as { row: number; message: string }[];
    if (!Array.isArray(list)) return [];
    return list.map((p) => ({
      row: Number(p.row),
      messages: [/row-level security/i.test(p.message) ? "You don't have permission to add this member here" : String(p.message)],
    }));
  } catch {
    return [];
  }
}
