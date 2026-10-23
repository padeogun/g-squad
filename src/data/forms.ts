// -------------------------------------------------------------------------------------
// The reference forms, described as data. One generic screen (pages/admin/ReferenceForm.tsx)
// draws the list, the add/edit form and the switch-off/remove actions for every entry here,
// so adding a field is one line, not a new screen.
//
// `editRoles` only decides whether the edit buttons are SHOWN. The database's row-level
// security (migration 7) decides who may really change each table, and the two are kept in
// step by the test in forms.test.ts.
// -------------------------------------------------------------------------------------
import type { AppRole } from '../auth/useMe';

// The lookup lists a select field can draw its options from (see useLookup in ReferenceForm).
export type LookupName = 'purposes' | 'units' | 'community_types';

export interface FieldDef {
  key: string;
  label: string;
  type: 'text' | 'textarea' | 'number' | 'boolean' | 'select';
  required?: boolean;
  hint?: string;
  // Text length limit, matching the database check (names are 1 to 100 or 200 characters).
  maxLength?: number;
  // Number range, matching the database check.
  min?: number;
  max?: number;
  // Select options: a fixed list, or another reference list.
  options?: { value: string; label: string }[];
  lookup?: LookupName;
  // Shown in the list as a column.
  inList?: boolean;
}

export interface FormDef {
  id: string; // used in the address: /admin/forms/<id>
  table: 'purposes' | 'units' | 'church_roles' | 'teci_stages' | 'leadership_stages' | 'community_types' | 'greatness_communities' | 'project_types';
  title: string; // plural, for the list
  singular: string; // for buttons: "Add a unit"
  description: string;
  owner: string; // who looks after this list, in words
  editRoles: AppRole[];
  orderBy: string;
  fields: FieldDef[];
  // Tables with is_active are switched off rather than deleted, so history keeps its labels.
  hasActive: boolean;
  // Fixed-size lists (the 5 TECi stages) are edited, never added to or removed.
  fixedRows?: boolean;
}

const NAME: FieldDef = { key: 'name', label: 'Name', type: 'text', required: true, maxLength: 100, inList: true };

export const FORMS: FormDef[] = [
  {
    id: 'purposes',
    table: 'purposes',
    title: 'Purposes',
    singular: 'purpose',
    description: 'The church purposes that units sit under, each led by a Purpose Head.',
    owner: 'Operations Lead or G-Squad Coordinator',
    editRoles: ['operations_lead', 'gsquad_coordinator'],
    orderBy: 'name',
    hasActive: false,
    fields: [{ ...NAME, maxLength: 200 }, { key: 'description', label: 'Description', type: 'textarea', maxLength: 2000 }],
  },
  {
    id: 'units',
    table: 'units',
    title: 'G-Squad units',
    singular: 'unit',
    description: 'Each serving team: its purpose, objectives, scope and how many people it needs.',
    owner: 'Operations Lead or G-Squad Coordinator',
    editRoles: ['operations_lead', 'gsquad_coordinator'],
    orderBy: 'name',
    hasActive: true,
    fields: [
      NAME,
      { key: 'purpose_id', label: 'Purpose', type: 'select', lookup: 'purposes', inList: true },
      { key: 'objectives', label: 'Objectives', type: 'textarea', maxLength: 4000 },
      { key: 'scope', label: 'Scope', type: 'textarea', maxLength: 4000 },
      { key: 'target_headcount', label: 'Target team size', type: 'number', min: 0, max: 500, inList: true },
      {
        key: 'regular_monthly_need',
        label: 'Regular slots needed a month',
        type: 'number',
        required: true,
        min: 0,
        max: 500,
        hint: 'Used for spare capacity',
        inList: true,
      },
    ],
  },
  {
    id: 'roles',
    table: 'church_roles',
    title: 'Team roles',
    singular: 'team role',
    description: 'The roles people hold in a unit (for example Camera operator), or church-wide roles with no unit.',
    owner: 'Operations Lead or G-Squad Coordinator',
    editRoles: ['operations_lead', 'gsquad_coordinator'],
    orderBy: 'name',
    hasActive: true,
    fields: [
      NAME,
      { key: 'unit_id', label: 'Unit', type: 'select', lookup: 'units', hint: 'Leave empty for a church-wide role', inList: true },
      { key: 'description', label: 'Description', type: 'textarea', maxLength: 2000 },
      { key: 'is_rota_role', label: 'Appears on Sunday rotas', type: 'boolean', inList: true },
    ],
  },
  {
    id: 'teci-stages',
    table: 'teci_stages',
    title: 'TECi stages',
    singular: 'TECi stage',
    description: "The five stages of TEC's training and leadership development programme.",
    owner: 'TECi Coordinator or G-Squad Coordinator',
    editRoles: ['teci_coordinator', 'gsquad_coordinator'],
    orderBy: 'stage_no',
    hasActive: false,
    fixedRows: true,
    fields: [
      { key: 'stage_no', label: 'Stage', type: 'number', required: true, min: 1, max: 5, inList: true },
      NAME,
      { key: 'description', label: 'Description', type: 'textarea', maxLength: 2000 },
      { key: 'completion_criteria', label: 'What completes this stage', type: 'textarea', maxLength: 2000 },
    ],
  },
  {
    id: 'leadership-stages',
    table: 'leadership_stages',
    title: 'Leadership stages',
    singular: 'leadership stage',
    description: 'The stages a member moves through towards leading a team.',
    owner: 'Operations Lead or G-Squad Coordinator',
    editRoles: ['operations_lead', 'gsquad_coordinator'],
    orderBy: 'sort_order',
    hasActive: false,
    fields: [
      { key: 'sort_order', label: 'Order', type: 'number', required: true, min: 1, max: 50, inList: true },
      NAME,
      { key: 'description', label: 'Description', type: 'textarea', maxLength: 2000 },
      { key: 'advance_criteria', label: 'What moves someone to the next stage', type: 'textarea', maxLength: 2000 },
    ],
  },
  {
    id: 'community-types',
    table: 'community_types',
    title: 'Greatness Community types',
    singular: 'community type',
    description: 'Interest-based or location-based kinds of Greatness Community.',
    owner: 'Operations Lead or G-Squad Coordinator',
    editRoles: ['operations_lead', 'gsquad_coordinator'],
    orderBy: 'name',
    hasActive: false,
    fields: [
      NAME,
      {
        key: 'category',
        label: 'Category',
        type: 'select',
        required: true,
        options: [
          { value: 'interest', label: 'Interest-based' },
          { value: 'location', label: 'Location-based' },
        ],
        inList: true,
      },
      { key: 'objective', label: 'Objective', type: 'textarea', maxLength: 2000 },
      { key: 'meeting_schedule', label: 'Meeting schedule', type: 'text', maxLength: 200, inList: true },
    ],
  },
  {
    id: 'communities',
    table: 'greatness_communities',
    title: 'Greatness Communities',
    singular: 'community',
    description: "The church's small groups. Support roles and members are added in a later slice.",
    owner: 'Operations Lead or G-Squad Coordinator',
    editRoles: ['operations_lead', 'gsquad_coordinator'],
    orderBy: 'name',
    hasActive: true,
    fields: [NAME, { key: 'type_id', label: 'Type', type: 'select', required: true, lookup: 'community_types', inList: true }],
  },
  {
    id: 'project-types',
    table: 'project_types',
    title: 'Project and event types',
    singular: 'project type',
    description: 'Kinds of project or event, the level that usually approves them, and their newsletter tag.',
    owner: 'Operations Lead or G-Squad Coordinator',
    editRoles: ['operations_lead', 'gsquad_coordinator'],
    orderBy: 'name',
    hasActive: true,
    fields: [
      NAME,
      {
        key: 'default_level',
        label: 'Usual level',
        type: 'select',
        required: true,
        options: [
          { value: 'unit', label: 'Unit (approved by the Purpose Head)' },
          { value: 'church', label: 'Church (approved by the Resident Pastor)' },
        ],
        inList: true,
      },
      { key: 'newsletter_tag', label: 'Newsletter tag', type: 'text', maxLength: 50, inList: true },
    ],
  },
];

export function formById(id: string | undefined): FormDef | undefined {
  return FORMS.find((f) => f.id === id);
}

// Turns what the form holds (all strings, plus booleans) into the row to save:
// empty optional fields become null, numbers become numbers, text is trimmed.
export function toRow(def: FormDef, values: Record<string, string | boolean>): Record<string, unknown> {
  const row: Record<string, unknown> = {};
  for (const f of def.fields) {
    const v = values[f.key];
    if (f.type === 'boolean') row[f.key] = v === true;
    else if (typeof v !== 'string' || v.trim() === '') row[f.key] = null;
    else if (f.type === 'number') row[f.key] = Number(v);
    else row[f.key] = v.trim();
  }
  return row;
}

// Checks the form before saving, with the same limits the database applies, so people see
// the problem next to the field. Returns field key -> message.
export function validate(def: FormDef, values: Record<string, string | boolean>): Record<string, string> {
  const errors: Record<string, string> = {};
  for (const f of def.fields) {
    const v = values[f.key];
    if (f.type === 'boolean') continue;
    const s = typeof v === 'string' ? v.trim() : '';
    if (f.required && !s) {
      errors[f.key] = `${f.label} is required`;
      continue;
    }
    if (!s) continue;
    if (f.maxLength && s.length > f.maxLength) errors[f.key] = `Keep ${f.label.toLowerCase()} to ${f.maxLength} characters`;
    if (f.type === 'number') {
      const n = Number(s);
      if (!Number.isInteger(n)) errors[f.key] = `${f.label} must be a whole number`;
      else if ((f.min !== undefined && n < f.min) || (f.max !== undefined && n > f.max))
        errors[f.key] = `${f.label} must be between ${f.min} and ${f.max}`;
    }
  }
  return errors;
}
