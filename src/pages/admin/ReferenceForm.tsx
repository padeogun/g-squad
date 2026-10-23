// -------------------------------------------------------------------------------------
// One generic screen for every reference form in data/forms.ts: a table of the rows, and an
// add/edit panel built from the form's field list. Saving goes straight to the table through
// the Supabase client, so row-level security decides whether it is allowed; the screen only
// hides buttons from people who can't use them and shows the database's reason if it says no.
// -------------------------------------------------------------------------------------
import { useState, type FormEvent, type ReactNode } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { formById, toRow, validate, type FieldDef, type FormDef, type LookupName } from '../../data/forms';
import { hasRole, useMe } from '../../auth/useMe';
import { NotFound } from '../NotFound';

const { SectionHeading, Card, Button, TextField, SelectField, Checkbox, Notice, Chip, DataTable } = TEC;

type Row = Record<string, unknown> & { id: string };
type Values = Record<string, string | boolean>;

// The generated types can't follow a table name chosen at run time, so the dynamic table is
// reached through this one loosely typed handle. Columns come only from data/forms.ts.
// oxlint-disable-next-line typescript/no-explicit-any
const db = supabase as any;

export function ReferenceForm() {
  const { formId } = useParams();
  const def = formById(formId);
  // Unknown form in the address: show the usual not-found page.
  if (!def) return <NotFound />;
  // key: a fresh screen (and fresh state) for each form.
  return <FormScreen key={def.id} def={def} />;
}

function FormScreen({ def }: { def: FormDef }) {
  const me = useMe();
  const qc = useQueryClient();
  const canEdit = hasRole(me.data, ...def.editRoles);
  // null = panel closed; '' = adding a new row; an id = editing that row.
  const [editing, setEditing] = useState<string | null>(null);

  const rows = useQuery({
    queryKey: ['ref', def.table, 'all'],
    queryFn: async (): Promise<Row[]> => {
      const { data, error } = await db.from(def.table).select('*').order(def.orderBy);
      if (error) throw error;
      return data as Row[];
    },
  });

  // Lookup lists for select fields (purposes, units, community types), loaded only if needed.
  const lookups = useLookups(def);

  // After any change: refresh this list and every other screen's copy of reference data.
  const refresh = () => qc.invalidateQueries({ queryKey: ['ref'] });

  const toggleActive = useMutation({
    mutationFn: async (row: Row) => {
      const { error } = await db.from(def.table).update({ is_active: !row.is_active }).eq('id', row.id).select('id').single();
      if (error) throw error;
    },
    onSuccess: refresh,
  });

  const remove = useMutation({
    mutationFn: async (row: Row) => {
      const { error } = await db.from(def.table).delete().eq('id', row.id).select('id').single();
      if (error) throw error;
    },
    onSuccess: refresh,
  });

  const listFields = def.fields.filter((f) => f.inList);
  const actionError = toggleActive.error ?? remove.error;

  return (
    <>
      <SectionHeading eyebrow="Reference forms" title={def.title} rule>
        {def.description}
      </SectionHeading>
      <p style={{ margin: 0 }}>
        <Link to="/admin">All reference forms</Link>
      </p>

      {!canEdit && (
        <Notice tone="info" title="View only">
          This list is kept by the {def.owner}.
        </Notice>
      )}
      {actionError && (
        <Notice tone="danger" title="That change wasn't made">
          {friendlyError(actionError)}
        </Notice>
      )}

      {/* SECURITY REVIEW FIX L08: open the panel only for "add" or a row that is still in the
          list. A row removed meanwhile used to open an empty panel that INSERTED a new row. */}
      {canEdit && editing !== null && (editing === '' || rows.data?.some((r) => r.id === editing)) && (
        <EditPanel
          def={def}
          row={editing ? rows.data?.find((r) => r.id === editing) : undefined}
          lookups={lookups}
          onDone={() => setEditing(null)}
        />
      )}

      <Card
        title={`${def.title} (${rows.data?.length ?? 0})`}
        action={
          canEdit && !def.fixedRows && editing === null ? (
            <Button size="sm" variant="primary" icon="plus" onClick={() => setEditing('')}>
              Add a {def.singular}
            </Button>
          ) : undefined
        }
      >
        {rows.isPending && <p>Loading…</p>}
        {rows.error && <Notice tone="danger">{friendlyError(rows.error)}</Notice>}
        {rows.data && rows.data.length === 0 && <p>Nothing here yet.</p>}
        {rows.data && rows.data.length > 0 && (
          <DataTable
            columns={[
              ...listFields.map((f) => ({ key: f.key, label: f.label, align: f.type === 'number' ? ('right' as const) : undefined })),
              ...(def.hasActive ? [{ key: '_status', label: 'Status' }] : []),
              ...(canEdit ? [{ key: '_actions', label: 'Actions' }] : []),
            ]}
            rows={rows.data.map((r) => {
              const cells: Record<string, ReactNode> = { id: r.id };
              for (const f of listFields) cells[f.key] = display(f, r[f.key], lookups);
              // App-owned rows (default team roles) are marked, and can't be switched off or removed.
              const isProtected = !!def.protectedRows && r[def.protectedRows.flag] != null;
              if (def.hasActive)
                cells._status = (
                  <>
                    {r.is_active ? <Chip tone="ok">In use</Chip> : <Chip tone="neutral">Switched off</Chip>}
                    {isProtected && <Chip tone="info">{def.protectedRows!.label}</Chip>}
                  </>
                );
              if (canEdit)
                cells._actions = (
                  <div className="tec-row" style={{ padding: 0 }}>
                    <Button size="sm" variant="secondary" onClick={() => setEditing(r.id)}>
                      Edit
                    </Button>
                    {isProtected ? null : def.hasActive ? (
                      <Button size="sm" variant="quiet" disabled={toggleActive.isPending} onClick={() => toggleActive.mutate(r)}>
                        {r.is_active ? 'Switch off' : 'Switch on'}
                      </Button>
                    ) : (
                      !def.fixedRows && (
                        <Button
                          size="sm"
                          variant="quiet"
                          disabled={remove.isPending}
                          onClick={() => {
                            if (window.confirm(`Remove ${String(r.name ?? 'this item')}? This can't be undone.`)) remove.mutate(r);
                          }}
                        >
                          Remove
                        </Button>
                      )
                    )}
                  </div>
                );
              return cells as Record<string, ReactNode> & { id: string };
            })}
          />
        )}
      </Card>
    </>
  );
}

// ---------- Add or edit one row ----------
function EditPanel({
  def,
  row,
  lookups,
  onDone,
}: {
  def: FormDef;
  row: Row | undefined;
  lookups: Lookups;
  onDone: () => void;
}) {
  const qc = useQueryClient();
  // Start from the row being edited, or empty (booleans false) for a new one.
  const [values, setValues] = useState<Values>(() => {
    const v: Values = {};
    for (const f of def.fields) {
      const cur = row?.[f.key];
      v[f.key] = f.type === 'boolean' ? cur === true : cur == null ? (row ? '' : f.defaultValue ?? '') : String(cur);
    }
    return v;
  });
  // On an app-owned row only some fields can change; the rest are shown but locked.
  const locked = (key: string) =>
    !!row && !!def.protectedRows && row[def.protectedRows.flag] != null && !def.protectedRows.editable.includes(key);
  const [errors, setErrors] = useState<Record<string, string>>({});

  const save = useMutation({
    mutationFn: async () => {
      const payload = toRow(def, values);
      const q = row
        ? db.from(def.table).update(payload).eq('id', row.id)
        : db.from(def.table).insert(payload);
      // .select().single(): a change refused by row-level security returns no row; this turns
      // that silent "0 rows" into an error the screen can show.
      const { error } = await q.select('id').single();
      if (error) throw error;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['ref'] });
      onDone();
    },
  });

  function onSubmit(e: FormEvent) {
    e.preventDefault();
    const found = validate(def, values);
    setErrors(found);
    if (Object.keys(found).length === 0) save.mutate();
  }

  const set = (key: string, v: string | boolean) => setValues((cur) => ({ ...cur, [key]: v }));

  return (
    <Card title={row ? `Edit ${def.singular}` : `Add a ${def.singular}`} tone="tint">
      <form className="app-form" onSubmit={onSubmit} noValidate>
        <div className="tec-fields">
          {def.fields.map((f) => (
            <Field
              key={f.key}
              def={def}
              field={f}
              value={values[f.key]}
              error={errors[f.key]}
              lookups={lookups}
              onChange={set}
              disabled={locked(f.key)}
            />
          ))}
        </div>
        {save.isError && (
          <Notice tone="danger" title="Not saved">
            {friendlyError(save.error)}
          </Notice>
        )}
        <div className="tec-row" style={{ padding: 0 }}>
          <Button type="submit" variant="primary" disabled={save.isPending}>
            {save.isPending ? 'Saving…' : 'Save'}
          </Button>
          <Button type="button" variant="quiet" onClick={onDone}>
            Cancel
          </Button>
        </div>
      </form>
    </Card>
  );
}

// ---------- One field, by type ----------
function Field({
  def,
  field: f,
  value,
  error,
  lookups,
  onChange,
  disabled,
}: {
  def: FormDef;
  field: FieldDef;
  value: string | boolean;
  error?: string;
  lookups: Lookups;
  onChange: (key: string, v: string | boolean) => void;
  disabled?: boolean;
}) {
  const id = `${def.id}-${f.key}`;
  // The error is shown in the hint slot, beside the label, and announced to screen readers.
  const hint = error ? `– ${error}` : f.required ? undefined : f.hint ?? '(optional)';
  const invalid = error ? { 'aria-invalid': true as const } : {};

  if (f.type === 'boolean')
    return (
      <Checkbox id={id} label={f.label} disabled={disabled} checked={value === true} onChange={(e) => onChange(f.key, e.target.checked)} />
    );

  if (f.type === 'select') {
    const opts = f.options ?? (f.lookup ? lookups[f.lookup] : []);
    return (
      <SelectField
        id={id}
        label={f.label}
        hint={hint}
        value={String(value)}
        disabled={disabled}
        onChange={(e) => onChange(f.key, e.target.value)}
        options={[{ value: '', label: f.required ? 'Choose…' : 'None' }, ...opts]}
        {...invalid}
      />
    );
  }

  if (f.type === 'textarea')
    return (
      <label className="tec-field app-field-wide" htmlFor={id}>
        <span>
          {f.label} {hint && <span className="tec-hint">{hint}</span>}
        </span>
        <textarea
          id={id}
          className="tec-input app-textarea"
          rows={3}
          maxLength={f.maxLength}
          value={String(value)}
          disabled={disabled}
          onChange={(e) => onChange(f.key, e.target.value)}
          {...invalid}
        />
      </label>
    );

  return (
    <TextField
      id={id}
      label={f.label}
      hint={hint}
      type={f.type === 'number' ? 'number' : 'text'}
      inputMode={f.type === 'number' ? 'numeric' : undefined}
      min={f.min}
      max={f.max}
      maxLength={f.maxLength}
      required={f.required}
      disabled={disabled}
      value={String(value)}
      onChange={(e) => onChange(f.key, e.target.value)}
      {...invalid}
    />
  );
}

// ---------- Lookups for select fields ----------
type Lookups = Record<LookupName, { value: string; label: string }[]>;

// One lookup list (id + name), fetched only when the form has a field that uses it.
function useLookupList(name: LookupName, enabled: boolean) {
  return (
    useQuery({
      queryKey: ['ref', name, 'options'],
      enabled,
      queryFn: async () => {
        const { data, error } = await db.from(name).select('id, name').order('name');
        if (error) throw error;
        return (data as { id: string; name: string }[]).map((r) => ({ value: r.id, label: r.name }));
      },
    }).data ?? []
  );
}

function useLookups(def: FormDef): Lookups {
  const need = new Set(def.fields.map((f) => f.lookup));
  return {
    purposes: useLookupList('purposes', need.has('purposes')),
    units: useLookupList('units', need.has('units')),
    community_types: useLookupList('community_types', need.has('community_types')),
  };
}

// How a value appears in the list.
function display(f: FieldDef, v: unknown, lookups: Lookups): ReactNode {
  if (v == null || v === '') return <span className="type-caption">–</span>;
  if (f.type === 'boolean') return v ? 'Yes' : 'No';
  if (f.lookup) return lookups[f.lookup].find((o) => o.value === v)?.label ?? '…';
  if (f.options) return f.options.find((o) => o.value === v)?.label ?? String(v);
  return String(v);
}
