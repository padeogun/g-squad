// -------------------------------------------------------------------------------------
// One Sunday's service grid: the order of service with times worked out from each start and
// duration, gaps and overlaps flagged, the units and roles the Sunday needs (which set its
// rota), attached text blocks, and the PDF for officiating leaders.
// Who does what is decided in the database (migration 8, R11):
//   * the Operations Lead builds and finalises; any change to a finalised or approved grid
//     makes a new version that needs approving again;
//   * the Resident Pastor approves a finalised grid.
// The screen only offers the buttons each role can use.
// -------------------------------------------------------------------------------------
import { useState, type FormEvent } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, useChurchRoles, useUnits } from '../../data/reference';
import {
  endOf,
  finaliseDeadline,
  formatDuration,
  gaps,
  longDate,
  parsePoints,
  serviceSpan,
  shortDate,
  toMinutes,
  toTime,
  todayIso,
  useBlocks,
  useDemand,
  useGrid,
  useGridBlocks,
  useSegments,
  useSundays,
  type Grid,
  type Segment,
} from '../../data/sundays';
import { hasRole, useMe } from '../../auth/useMe';
import { NotFound } from '../NotFound';
import { GridStatus } from './GridStatus';

const { SectionHeading, Card, Button, TextField, SelectField, Checkbox, Notice, DataTable, Chip } = TEC;

export function ServiceGrid() {
  const { gridId } = useParams();
  const grid = useGrid(gridId);
  if (grid.isPending) return <p>Loading…</p>;
  if (!grid.data) return <NotFound />;
  return <GridScreen key={grid.data.id} grid={grid.data} />;
}

function GridScreen({ grid }: { grid: Grid }) {
  const me = useMe();
  const qc = useQueryClient();
  const segments = useSegments(grid.id);
  const units = useUnits();
  const unitMap = byId(units.data);
  const canBuild = hasRole(me.data, 'operations_lead');
  const canApprove = hasRole(me.data, 'resident_pastor');
  // null = no form open; 'new' = adding; otherwise the id of the segment being edited.
  const [editing, setEditing] = useState<string | null>(null);

  const list = segments.data ?? [];
  const span = serviceSpan(list);
  const gapMap = gaps(list);
  const deadline = finaliseDeadline(grid.service_date);
  const [today] = useState(todayIso); // read once per visit (render must not read the clock)
  const lateToFinalise = grid.status === 'draft' && today > deadline;

  // Everything that changes the grid refreshes the grid (its version may have gone up) and its parts.
  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['grids'] });
    qc.invalidateQueries({ queryKey: ['segments', grid.id] });
    qc.invalidateQueries({ queryKey: ['grid_blocks', grid.id] });
  };

  // Status changes: finalise, back to draft, approve. The database checks who may.
  const setStatus = useMutation({
    mutationFn: async (status: Grid['status']) => {
      const { error } = await supabase.from('service_grids').update({ status }).eq('id', grid.id).select('id').single();
      if (error) throw error;
    },
    onSuccess: refresh,
  });

  // Move a segment up or down: the whole new order is sent in one call (reorder_segments).
  const move = useMutation({
    mutationFn: async ({ index, by }: { index: number; by: -1 | 1 }) => {
      const ids = list.map((s) => s.id);
      const j = index + by;
      [ids[index], ids[j]] = [ids[j], ids[index]];
      const { error } = await supabase.rpc('reorder_segments', { p_grid: grid.id, p_segments: ids });
      if (error) throw error;
    },
    onSuccess: refresh,
  });

  const remove = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('service_segments').delete().eq('id', id).select('id').single();
      if (error) throw error;
    },
    onSuccess: refresh,
  });

  const ledBy = (s: Segment) =>
    [s.led_by_unit_id ? unitMap.get(s.led_by_unit_id)?.name : null, s.led_by_text].filter(Boolean).join(' · ') || '–';

  const actionError = setStatus.error ?? move.error ?? remove.error;

  return (
    <>
      <SectionHeading eyebrow="Sunday Operations" title={longDate(grid.service_date)} rule>
        {grid.theme ? `Theme: ${grid.theme}` : undefined}
      </SectionHeading>
      <p style={{ margin: 0 }}>
        <Link to="/sundays">All Sundays</Link>
      </p>

      <Card
        title="Status"
        action={<PdfButton grid={grid} segments={list} ledBy={ledBy} />}
      >
        <div className="tec-row" style={{ padding: 0 }}>
          <GridStatus grid={grid} />
          <span className="type-caption">Finalise by {shortDate(deadline)}</span>
          {span && (
            <span className="type-caption">
              Service {span.start} – {span.end} · {formatDuration(span.minutes)}
            </span>
          )}
        </div>
        {lateToFinalise && (
          <Notice tone="warn" title="Past the finalise deadline">
            Grids are finalised by the Thursday before the service.
          </Notice>
        )}
        {grid.status !== 'draft' && canBuild && (
          <p className="type-caption" style={{ margin: 0 }}>
            Any change now makes a new version that the Resident Pastor approves again.
          </p>
        )}
        <div className="tec-row" style={{ padding: 0 }}>
          {canBuild && grid.status === 'draft' && (
            <Button variant="primary" disabled={setStatus.isPending || list.length === 0} onClick={() => setStatus.mutate('finalised')}>
              Finalise grid
            </Button>
          )}
          {canApprove && grid.status === 'finalised' && (
            <Button variant="lime" icon="check" disabled={setStatus.isPending} onClick={() => setStatus.mutate('approved')}>
              Approve grid
            </Button>
          )}
          {canBuild && grid.status !== 'draft' && (
            <Button variant="quiet" disabled={setStatus.isPending} onClick={() => setStatus.mutate('draft')}>
              Back to draft
            </Button>
          )}
        </div>
        {actionError && (
          <Notice tone="danger" title="That change wasn't made">
            {friendlyError(actionError)}
          </Notice>
        )}
      </Card>

      <Card
        title={`Order of service (${list.length})`}
        action={
          canBuild && editing === null ? (
            <Button size="sm" variant="primary" icon="plus" onClick={() => setEditing('new')}>
              Add segment
            </Button>
          ) : undefined
        }
      >
        {segments.isPending && <p>Loading…</p>}
        {segments.error && <Notice tone="danger">{friendlyError(segments.error)}</Notice>}
        {segments.data && list.length === 0 && (
          <>
            <p>No segments yet.</p>
            {canBuild && <CopyFromSunday grid={grid} onDone={refresh} />}
          </>
        )}
        {editing === 'new' && (
          <SegmentForm
            grid={grid}
            position={list.length + 1}
            // A new segment starts where the last one ends.
            defaultStart={list.length ? endOf(list[list.length - 1]) : '10:00'}
            onDone={() => {
              setEditing(null);
              refresh();
            }}
          />
        )}
        {list.length > 0 && (
          <DataTable
            columns={[
              { key: 'time', label: 'Time' },
              { key: 'activity', label: 'Activity' },
              { key: 'led', label: 'Led by' },
              { key: 'dur', label: 'Duration', align: 'right' },
              ...(canBuild ? [{ key: 'actions', label: 'Actions' }] : []),
            ]}
            rows={list.map((s, i) => {
              const gap = gapMap.get(i);
              return {
                id: s.id,
                time: `${toTime(toMinutes(s.starts_at))} – ${endOf(s)}`,
                activity:
                  editing === s.id ? (
                    <SegmentForm
                      grid={grid}
                      segment={s}
                      position={s.position}
                      defaultStart={s.starts_at.slice(0, 5)}
                      onDone={() => {
                        setEditing(null);
                        refresh();
                      }}
                    />
                  ) : (
                    <div>
                      <strong>{s.title}</strong>
                      {s.sub_points.length > 0 && (
                        <ul className="app-points">
                          {s.sub_points.map((p, k) => (
                            <li key={k}>{p}</li>
                          ))}
                        </ul>
                      )}
                      {gap !== undefined && (
                        <Chip tone="warn">{gap > 0 ? `${gap}-minute gap before this` : `Overlaps the one before by ${-gap} min`}</Chip>
                      )}
                    </div>
                  ),
                led: ledBy(s),
                dur: `${s.duration_minutes} min`,
                ...(canBuild
                  ? {
                      actions: (
                        <div className="tec-row" style={{ padding: 0 }}>
                          {/* SECURITY REVIEW FIX Q11: Edit and Remove name their segment, as Up and Down
                              already did, so a screen reader user removes the segment they mean. */}
                          <button
                            type="button"
                            className="app-link-button"
                            aria-label={`Edit ${s.title}`}
                            disabled={editing !== null}
                            onClick={() => setEditing(s.id)}
                          >
                            Edit
                          </button>
                          <button
                            type="button"
                            className="app-link-button"
                            aria-label={`Move ${s.title} up`}
                            disabled={i === 0 || move.isPending}
                            onClick={() => move.mutate({ index: i, by: -1 })}
                          >
                            Up
                          </button>
                          <button
                            type="button"
                            className="app-link-button"
                            aria-label={`Move ${s.title} down`}
                            disabled={i === list.length - 1 || move.isPending}
                            onClick={() => move.mutate({ index: i, by: 1 })}
                          >
                            Down
                          </button>
                          <button
                            type="button"
                            className="app-link-button"
                            aria-label={`Remove ${s.title}`}
                            disabled={remove.isPending}
                            onClick={() => {
                              if (window.confirm(`Remove "${s.title}" from the grid?`)) remove.mutate(s.id);
                            }}
                          >
                            Remove
                          </button>
                        </div>
                      ),
                    }
                  : {}),
              };
            })}
          />
        )}
      </Card>

      <UnitsNeeded grid={grid} canEdit={canBuild} />
      <AttachedBlocks grid={grid} canEdit={canBuild} onChange={refresh} />
    </>
  );
}

// ---------- Add or edit a segment ----------
function SegmentForm({
  grid,
  segment,
  position,
  defaultStart,
  onDone,
}: {
  grid: Grid;
  segment?: Segment;
  position: number;
  defaultStart: string;
  onDone: () => void;
}) {
  const units = useUnits();
  const [title, setTitle] = useState(segment?.title ?? '');
  const [points, setPoints] = useState((segment?.sub_points ?? []).join('\n'));
  const [start, setStart] = useState(defaultStart);
  const [duration, setDuration] = useState(String(segment?.duration_minutes ?? 5));
  const [unitId, setUnitId] = useState(segment?.led_by_unit_id ?? '');
  const [ledText, setLedText] = useState(segment?.led_by_text ?? '');
  const [error, setError] = useState('');

  const save = useMutation({
    mutationFn: async () => {
      const row = {
        title: title.trim(),
        sub_points: parsePoints(points),
        starts_at: start,
        duration_minutes: Number(duration),
        led_by_unit_id: unitId || null,
        led_by_text: ledText.trim() || null,
      };
      const q = segment
        ? supabase.from('service_segments').update(row).eq('id', segment.id)
        : supabase.from('service_segments').insert({ ...row, grid_id: grid.id, position });
      const { error } = await q.select('id').single();
      if (error) throw error;
    },
    onSuccess: onDone,
  });

  function onSubmit(e: FormEvent) {
    e.preventDefault();
    // The same limits as the database, shown here first.
    const mins = Number(duration);
    if (!title.trim()) return setError('Give the segment a title.');
    if (!Number.isInteger(mins) || mins < 1 || mins > 600) return setError('Duration is 1 to 600 minutes.');
    if (!unitId && !ledText.trim()) return setError('Say who leads it: a unit, a name, or both.');
    setError('');
    save.mutate();
  }

  return (
    <form className="app-form app-segment-form" onSubmit={onSubmit} noValidate>
      <div className="tec-fields" style={{ padding: 0 }}>
        <TextField id="seg-title" label="Activity" required maxLength={200} value={title} onChange={(e) => setTitle(e.target.value)} />
        <TextField id="seg-start" label="Starts" type="time" required value={start} onChange={(e) => setStart(e.target.value)} />
        <TextField
          id="seg-dur"
          label="Minutes"
          type="number"
          inputMode="numeric"
          min={1}
          max={600}
          required
          value={duration}
          onChange={(e) => setDuration(e.target.value)}
        />
        <SelectField
          id="seg-unit"
          label="Led by unit"
          hint="(optional)"
          value={unitId}
          onChange={(e) => setUnitId(e.target.value)}
          options={[{ value: '', label: 'None' }, ...(units.data ?? []).filter((u) => u.is_active).map((u) => ({ value: u.id, label: u.name }))]}
        />
        <TextField id="seg-led" label="Led by (name)" hint="(optional), e.g. Pastor Tosin" maxLength={200} value={ledText} onChange={(e) => setLedText(e.target.value)} />
        <label className="tec-field app-field-wide" htmlFor="seg-points">
          <span>
            Points <span className="tec-hint">(optional, one per line)</span>
          </span>
          <textarea id="seg-points" className="tec-input app-textarea" rows={3} value={points} onChange={(e) => setPoints(e.target.value)} />
        </label>
      </div>
      {(error || save.isError) && (
        <Notice tone="danger" title="Not saved">
          {error || friendlyError(save.error)}
        </Notice>
      )}
      <div className="tec-row" style={{ padding: 0 }}>
        <Button type="submit" size="sm" variant="primary" disabled={save.isPending}>
          {save.isPending ? 'Saving…' : 'Save segment'}
        </Button>
        <Button type="button" size="sm" variant="quiet" onClick={onDone}>
          Cancel
        </Button>
      </div>
    </form>
  );
}

// ---------- Start from an earlier Sunday's order of service ----------
function CopyFromSunday({ grid, onDone }: { grid: Grid; onDone: () => void }) {
  const sundays = useSundays();
  const others = (sundays.data ?? []).filter((g) => g.id !== grid.id);
  const [from, setFrom] = useState('');
  const copy = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.from('service_segments').select('*').eq('grid_id', from).order('position');
      if (error) throw error;
      if (!data.length) throw new Error('That Sunday has no segments to copy.');
      // One insert, so either every segment is copied or none is.
      const { error: insErr } = await supabase.from('service_segments').insert(
        data.map((s) => ({
          grid_id: grid.id,
          position: s.position,
          title: s.title,
          sub_points: s.sub_points,
          starts_at: s.starts_at,
          duration_minutes: s.duration_minutes,
          led_by_unit_id: s.led_by_unit_id,
          led_by_person_id: s.led_by_person_id,
          led_by_text: s.led_by_text,
        })),
      );
      if (insErr) throw insErr;
    },
    onSuccess: onDone,
  });
  if (others.length === 0) return null;
  return (
    <div className="tec-row" style={{ padding: 0, alignItems: 'flex-end' }}>
      <SelectField
        id="copy-from"
        label="Start from another Sunday's order"
        value={from}
        onChange={(e) => setFrom(e.target.value)}
        options={[{ value: '', label: 'Choose a Sunday' }, ...others.map((g) => ({ value: g.id, label: longDate(g.service_date) }))]}
      />
      <Button variant="secondary" disabled={!from || copy.isPending} onClick={() => copy.mutate()}>
        Copy segments
      </Button>
      {copy.isError && <Notice tone="danger">{friendlyError(copy.error)}</Notice>}
    </div>
  );
}

// ---------- Units and roles this Sunday needs (team demand; sets the rota) ----------
function UnitsNeeded({ grid, canEdit }: { grid: Grid; canEdit: boolean }) {
  const qc = useQueryClient();
  const demand = useDemand(grid.project_id);
  const units = useUnits();
  const roles = useChurchRoles();
  const unitMap = byId(units.data);
  const roleMap = byId(roles.data);
  const [unitId, setUnitId] = useState('');
  const [roleId, setRoleId] = useState('');
  const [slots, setSlots] = useState('1');

  const refresh = () => qc.invalidateQueries({ queryKey: ['demand', grid.project_id] });
  const add = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('team_demand').insert({
        project_id: grid.project_id,
        unit_id: unitId,
        church_role_id: roleId || null,
        on_date: grid.service_date,
        slots_needed: Number(slots),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setUnitId('');
      setRoleId('');
      setSlots('1');
      refresh();
    },
  });
  const remove = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('team_demand').delete().eq('id', id).select('id').single();
      if (error) throw error;
    },
    onSuccess: refresh,
  });

  const rows = demand.data ?? [];
  const slotsOk = Number.isInteger(Number(slots)) && Number(slots) >= 1 && Number(slots) <= 500;

  return (
    <Card title="Units and roles this Sunday needs">
      <p className="type-caption" style={{ margin: 0 }}>
        These set each unit's rota for {shortDate(grid.service_date)}.
      </p>
      {rows.length === 0 ? (
        <p>None added yet.</p>
      ) : (
        <DataTable
          columns={[
            { key: 'unit', label: 'Unit' },
            { key: 'role', label: 'Role' },
            { key: 'slots', label: 'People', align: 'right' },
            ...(canEdit ? [{ key: 'x', label: '' }] : []),
          ]}
          rows={rows.map((d) => ({
            id: d.id,
            unit: unitMap.get(d.unit_id)?.name ?? 'Unit',
            role: d.church_role_id ? roleMap.get(d.church_role_id)?.name ?? '' : 'Any role',
            slots: String(d.slots_needed),
            ...(canEdit
              ? {
                  x: (
                    <button
                      type="button"
                      className="app-link-button"
                      // SECURITY REVIEW FIX Q11: says which unit and role it removes.
                      aria-label={`Remove ${unitMap.get(d.unit_id)?.name ?? 'unit'}, ${d.church_role_id ? roleMap.get(d.church_role_id)?.name ?? 'role' : 'any role'}`}
                      disabled={remove.isPending}
                      onClick={() => remove.mutate(d.id)}
                    >
                      Remove
                    </button>
                  ),
                }
              : {}),
          }))}
        />
      )}
      {canEdit && (
        <div className="tec-fields" style={{ padding: 0, alignItems: 'end' }}>
          <SelectField
            id="need-unit"
            label="Unit"
            value={unitId}
            onChange={(e) => {
              setUnitId(e.target.value);
              setRoleId('');
            }}
            options={[{ value: '', label: 'Choose a unit' }, ...(units.data ?? []).filter((u) => u.is_active).map((u) => ({ value: u.id, label: u.name }))]}
          />
          <SelectField
            id="need-role"
            label="Role"
            hint="(optional)"
            value={roleId}
            onChange={(e) => setRoleId(e.target.value)}
            options={[
              { value: '', label: 'Any role' },
              ...(roles.data ?? [])
                .filter((r) => r.is_active && r.is_rota_role && (!r.unit_id || r.unit_id === unitId))
                .map((r) => ({ value: r.id, label: r.name })),
            ]}
          />
          <TextField id="need-slots" label="People needed" type="number" min={1} max={500} value={slots} onChange={(e) => setSlots(e.target.value)} />
          <div>
            <Button variant="secondary" icon="plus" disabled={!unitId || !slotsOk || add.isPending} onClick={() => add.mutate()}>
              Add
            </Button>
          </div>
        </div>
      )}
      {(add.isError || remove.isError) && <Notice tone="danger">{friendlyError(add.error ?? remove.error)}</Notice>}
    </Card>
  );
}

// ---------- Reusable text blocks printed after the grid (e.g. Guest Welcome Script) ----------
function AttachedBlocks({ grid, canEdit, onChange }: { grid: Grid; canEdit: boolean; onChange: () => void }) {
  const blocks = useBlocks();
  const attached = useGridBlocks(grid.id);
  const on = new Set((attached.data ?? []).map((b) => b.block_id));
  const toggle = useMutation({
    mutationFn: async ({ blockId, attach }: { blockId: string; attach: boolean }) => {
      const { error } = attach
        ? await supabase
            .from('service_grid_blocks')
            .insert({ grid_id: grid.id, block_id: blockId, position: Math.min(50, (attached.data?.length ?? 0) + 1) })
        : await supabase.from('service_grid_blocks').delete().eq('grid_id', grid.id).eq('block_id', blockId);
      if (error) throw error;
    },
    onSuccess: onChange,
  });
  if (!blocks.data?.length) return null;
  return (
    <Card title="Printed with the grid">
      <div className="tec-fields" style={{ padding: 0 }}>
        {blocks.data.map((b) => (
          <Checkbox
            key={b.id}
            id={`blk-${b.id}`}
            label={b.name}
            checked={on.has(b.id)}
            disabled={!canEdit || toggle.isPending}
            onChange={(e) => toggle.mutate({ blockId: b.id, attach: e.target.checked })}
          />
        ))}
      </div>
      {toggle.isError && <Notice tone="danger">{friendlyError(toggle.error)}</Notice>}
    </Card>
  );
}

// ---------- PDF download ----------
function PdfButton({ grid, segments, ledBy }: { grid: Grid; segments: Segment[]; ledBy: (s: Segment) => string }) {
  const blocks = useBlocks();
  const attached = useGridBlocks(grid.id);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function download() {
    setBusy(true);
    setError('');
    try {
      // Loaded only now, so the PDF library doesn't slow the rest of the app.
      const { downloadGridPdf } = await import('../../lib/gridPdf');
      const blockMap = byId(blocks.data);
      // SECURITY REVIEW FIX Q12: never print a grid without a block it should carry (e.g. the
      // Guest Welcome Script). Before, pressing Download while the blocks were still loading,
      // or after they failed to load, silently left them out.
      const attachedBlocks = (attached.data ?? []).map((a) => blockMap.get(a.block_id));
      if (!blocks.data || !attached.data || attachedBlocks.some((b) => !b)) throw new Error('Blocks not loaded');
      await downloadGridPdf({
        serviceDate: grid.service_date,
        theme: grid.theme,
        version: grid.version,
        status: grid.status,
        segments: segments.map((s) => ({ ...s, ledBy: ledBy(s) })),
        blocks: attachedBlocks.map((b) => ({ name: b!.name, body: b!.body })),
      });
    } catch {
      setError('The PDF could not be made. Please try again.');
    } finally {
      setBusy(false);
    }
  }
  return (
    <span className="tec-row" style={{ padding: 0 }}>
      <Button size="sm" variant="secondary" icon="download" disabled={busy || segments.length === 0 || blocks.isPending || attached.isPending} onClick={() => void download()}>
        {busy ? 'Making PDF…' : 'Download PDF'}
      </Button>
      {error && <span className="type-caption">{error}</span>}
    </span>
  );
}
