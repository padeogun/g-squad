// -------------------------------------------------------------------------------------
// Side cards on the project page:
//   * Before approval: the approval rules as Pass / Block / Action (from project_readiness).
//   * Volunteers needed: team demand by unit, role and day; the owner adds and removes rows.
//   * Inputs: what the project needs from named leaders, due dates and Overdue (R9). The owner
//     requests and removes them; the person asked writes their input and marks it received.
//     A project can't close while a required input is outstanding.
// -------------------------------------------------------------------------------------
import { useState, type ReactNode } from 'react';
import { useMutation } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, useChurchRoles, useLeaders, useUnits } from '../../data/reference';
import { useDemand, shortDate, todayIso } from '../../data/sundays';
import { isoToLondon, safeHttpsUrl, SHORTFALL_ACTIONS, useInputs, useRefreshProject, type Input, type Project, type Readiness } from '../../data/projects';

const { Card, Notice, Button, Chip, TextField, SelectField, Checkbox } = TEC;

// ---------- Before approval ----------
type Check = { tone: 'ok' | 'danger' | 'warn' | 'neutral'; tag: string; text: string };

export function ReadinessCard({ r }: { r: Readiness }) {
  const checks: Check[] = [];
  const size = r.lead_time?.size;
  if (r.lead_time)
    checks.push(
      r.lead_time.ok
        ? { tone: 'ok', tag: 'Pass', text: `Lead time: ${Math.max(0, Math.floor(r.lead_time.weeks_to_go))} weeks to go; a ${size} event needs ${r.lead_time.weeks_needed}.` }
        : { tone: 'danger', tag: 'Block', text: `Lead time: a ${size} event needs ${r.lead_time.weeks_needed} weeks' notice. Scale it down or move the date.` },
    );
  if (r.committee)
    checks.push(
      r.committee.ok
        ? { tone: 'ok', tag: 'Pass', text: r.committee.needed ? 'Event owner and planning committee in place.' : 'Event owner in place.' }
        : { tone: 'danger', tag: 'Block', text: 'A High complexity event needs a planning committee (section 3).' },
    );
  if (r.budget)
    checks.push(
      r.budget.ok
        ? { tone: 'ok', tag: 'Pass', text: r.budget.status === 'approved' ? 'Budget approved.' : 'No budget needed.' }
        : { tone: 'danger', tag: 'Block', text: r.budget.status === 'rejected' ? 'Budget rejected: revise the estimate (section 5).' : 'Budget not yet approved by Finance.' },
    );
  if (r.shortfall)
    checks.push(
      r.shortfall_action
        ? { tone: 'ok', tag: 'Pass', text: `${r.shortfall} is short; action recorded: ${SHORTFALL_ACTIONS.find((a) => a.value === r.shortfall_action)?.label.toLowerCase()}.` }
        : { tone: 'warn', tag: 'Action', text: `${r.shortfall} is short of volunteers. Record: move, scale down, borrow or recruit (when approving).` },
    );
  else checks.push({ tone: 'ok', tag: 'Pass', text: 'No unit is short of volunteers for the days needed.' });
  if (r.status === 'approved' || r.status === 'in_progress') {
    if (r.inputs_outstanding > 0)
      checks.push({ tone: 'warn', tag: 'To close', text: `${r.inputs_outstanding} required input${r.inputs_outstanding > 1 ? 's' : ''} still to come.` });
    if (r.review_done === false) checks.push({ tone: 'warn', tag: 'To close', text: 'Complete the event review (section 12).' });
  }
  const title = r.status === 'draft' || r.status === 'submitted' ? 'Before approval' : 'Checks';
  return (
    <Card title={title}>
      <ul className="app-checks">
        {checks.map((c, i) => (
          <li key={i}>
            <Chip tone={c.tone}>{c.tag}</Chip>
            <span>{c.text}</span>
          </li>
        ))}
      </ul>
    </Card>
  );
}

// ---------- Volunteers needed ----------
export function DemandCard({ p, canManage, shortfall }: { p: Project; canManage: boolean; shortfall: string | null }) {
  const demand = useDemand(p.id);
  const units = useUnits();
  const roles = useChurchRoles();
  const refresh = useRefreshProject(p.id);
  const first = isoToLondon(p.starts_at).date;
  const last = isoToLondon(p.ends_at).date;
  const [v, setV] = useState({ unit: '', role: '', date: first, slots: '1' });
  const unitMap = byId(units.data);
  const roleMap = byId(roles.data);

  const add = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('team_demand').insert({
        project_id: p.id,
        unit_id: v.unit,
        church_role_id: v.role || null,
        on_date: v.date,
        slots_needed: Number(v.slots),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setV({ unit: '', role: '', date: first, slots: '1' });
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
  const total = rows.reduce((n, d) => n + d.slots_needed, 0);
  const slots = Number(v.slots);
  const valid = !!v.unit && !!v.date && Number.isInteger(slots) && slots >= 1 && slots <= 500;

  return (
    <Card title="Volunteers needed" action={total ? <span className="type-caption">{total} slots</span> : undefined}>
      {demand.isPending && <p>Loading…</p>}
      {demand.error && <Notice tone="danger">{friendlyError(demand.error)}</Notice>}
      {demand.data && rows.length === 0 && <p style={{ margin: 0 }}>No volunteers requested yet.</p>}
      {rows.length > 0 && (
        <ul className="app-candidates">
          {rows.map((d) => (
            <li key={d.id}>
              <span>
                <strong>{unitMap.get(d.unit_id)?.name ?? 'Unit'}</strong>
                {d.church_role_id ? ` · ${roleMap.get(d.church_role_id)?.name ?? 'role'}` : ''}
                <span className="type-caption">{first !== last ? ` · ${shortDate(d.on_date)}` : ''}</span>
              </span>
              <span className="app-inline-row">
                <span>{d.slots_needed} slot{d.slots_needed > 1 ? 's' : ''}</span>
                {canManage && (
                  <button
                    type="button"
                    className="app-link-button"
                    aria-label={`Remove ${unitMap.get(d.unit_id)?.name ?? 'unit'} ${d.slots_needed} slots on ${shortDate(d.on_date)}`}
                    disabled={remove.isPending}
                    onClick={() => remove.mutate(d.id)}
                  >
                    Remove
                  </button>
                )}
              </span>
            </li>
          ))}
        </ul>
      )}
      {shortfall && <Notice tone="warn">{shortfall} is short of volunteers on current plans.</Notice>}
      {(add.error || remove.error) && <Notice tone="danger">{friendlyError(add.error ?? remove.error)}</Notice>}
      {canManage && p.status !== 'done' && p.status !== 'cancelled' && (
        <div className="tec-fields app-fields-narrow">
          <SelectField
            id="dm-unit"
            label="Unit"
            value={v.unit}
            onChange={(e) => setV({ ...v, unit: e.target.value, role: '' })}
            options={[{ value: '', label: 'Choose a unit' }, ...(units.data ?? []).filter((u) => u.is_active).map((u) => ({ value: u.id, label: u.name }))]}
          />
          <SelectField
            id="dm-role"
            label="Role"
            hint="(optional)"
            value={v.role}
            onChange={(e) => setV({ ...v, role: e.target.value })}
            options={[
              { value: '', label: 'Any role' },
              ...(roles.data ?? []).filter((r) => r.is_active && (!r.unit_id || r.unit_id === v.unit)).map((r) => ({ value: r.id, label: r.name })),
            ]}
          />
          {first !== last && (
            <TextField id="dm-date" label="Day" type="date" min={first} max={last} value={v.date} onChange={(e) => setV({ ...v, date: e.target.value })} />
          )}
          <TextField id="dm-slots" label="Slots" type="number" inputMode="numeric" min={1} max={500} value={v.slots} onChange={(e) => setV({ ...v, slots: e.target.value })} />
          <div>
            <Button size="sm" variant="secondary" disabled={!valid || add.isPending} onClick={() => add.mutate()}>
              Add
            </Button>
          </div>
        </div>
      )}
    </Card>
  );
}

// ---------- Inputs ----------
export function InputsCard({ projectId, canManage, myId }: { projectId: string; canManage: boolean; myId: string | undefined }) {
  const inputs = useInputs(projectId);
  const leaders = useLeaders();
  const units = useUnits();
  const refresh = useRefreshProject(projectId);
  const [today] = useState(todayIso);
  const [v, setV] = useState({ title: '', from: '', due: '', required: true, unit: '' });
  const leaderMap = byId(leaders.data);

  const request = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('project_inputs').insert({
        project_id: projectId,
        title: v.title.trim(),
        requested_from_user_id: v.from,
        due_on: v.due,
        is_required: v.required,
        unit_id: v.unit || null,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setV({ title: '', from: '', due: '', required: true, unit: '' });
      refresh();
    },
  });
  const change = useMutation({
    mutationFn: async ({ id, patch, remove }: { id: string; patch?: Record<string, unknown>; remove?: boolean }) => {
      const q = remove ? supabase.from('project_inputs').delete().eq('id', id) : supabase.from('project_inputs').update(patch as never).eq('id', id);
      const { error } = await q.select('id').single();
      if (error) throw error;
    },
    onSuccess: refresh,
  });

  const list = inputs.data ?? [];
  const chip = (i: Input) =>
    i.display_status === 'received' ? <Chip tone="ok">Received</Chip>
    : i.display_status === 'overdue' ? <Chip tone="danger">Overdue</Chip>
    : <Chip tone="info">{`Due ${shortDate(i.due_on!)}`}</Chip>;

  return (
    <Card title="Inputs">
      <span id="inputs" />
      {inputs.isPending && <p>Loading…</p>}
      {inputs.error && <Notice tone="danger">{friendlyError(inputs.error)}</Notice>}
      {inputs.data && list.length === 0 && <p style={{ margin: 0 }}>No inputs requested.</p>}
      {list.length > 0 && (
        <ul className="app-inputs">
          {list.map((i) => (
            <InputRow
              key={i.id!}
              i={i}
              chip={chip(i)}
              from={leaderMap.get(i.requested_from_user_id!)?.display_name ?? 'A leader'}
              mine={i.requested_from_user_id === myId}
              canManage={canManage}
              busy={change.isPending}
              onChange={(patch) => change.mutate({ id: i.id!, patch })}
              onRemove={() => change.mutate({ id: i.id!, remove: true })}
            />
          ))}
        </ul>
      )}
      {change.isError && <Notice tone="danger">{friendlyError(change.error)}</Notice>}
      <span className="type-caption">The project can't close while a required input is outstanding.</span>
      {canManage && (
        <details className="app-details">
          <summary>Request an input</summary>
          <div className="tec-fields app-fields-narrow">
            <TextField id="in-title" label="What is needed" maxLength={200} value={v.title} onChange={(e) => setV({ ...v, title: e.target.value })} />
            <SelectField
              id="in-from"
              label="From"
              value={v.from}
              onChange={(e) => setV({ ...v, from: e.target.value })}
              options={[{ value: '', label: 'Choose a leader' }, ...(leaders.data ?? []).filter((l) => l.is_active).map((l) => ({ value: l.id, label: l.display_name }))]}
            />
            <TextField id="in-due" label="Due" type="date" min={today} value={v.due} onChange={(e) => setV({ ...v, due: e.target.value })} />
            <SelectField
              id="in-unit"
              label="For a unit"
              hint="(optional)"
              value={v.unit}
              onChange={(e) => setV({ ...v, unit: e.target.value })}
              options={[{ value: '', label: 'Not a unit' }, ...(units.data ?? []).filter((u) => u.is_active).map((u) => ({ value: u.id, label: u.name }))]}
            />
            <Checkbox id="in-req" label="Required before the project closes" checked={v.required} onChange={(e) => setV({ ...v, required: e.target.checked })} />
          </div>
          {request.isError && <Notice tone="danger">{friendlyError(request.error)}</Notice>}
          <div>
            <Button size="sm" variant="primary" disabled={!v.title.trim() || !v.from || !v.due || request.isPending} onClick={() => request.mutate()}>
              Request
            </Button>
          </div>
        </details>
      )}
    </Card>
  );
}

// One input: who it's from, its status, and (for the person asked) a place to give it.
function InputRow({
  i,
  chip,
  from,
  mine,
  canManage,
  busy,
  onChange,
  onRemove,
}: {
  i: Input;
  chip: ReactNode;
  from: string;
  mine: boolean;
  canManage: boolean;
  busy: boolean;
  onChange: (patch: Record<string, unknown>) => void;
  onRemove: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [body, setBody] = useState(i.body ?? '');
  const [link, setLink] = useState(i.link_url ?? '');
  const linkOk = !link.trim() || /^https:\/\/\S+$/.test(link.trim());
  const received = i.status === 'received';
  // U09: only an https address becomes a link (the database checks this too).
  const href = safeHttpsUrl(i.link_url);
  const formId = `input-form-${i.id}`;
  return (
    <li>
      <div className="app-input-head">
        <span>
          <strong>{i.title}</strong>
          <span className="type-caption">
            {' '}
            · {from}
            {i.is_required ? '' : ' · optional'}
          </span>
        </span>
        {chip}
      </div>
      {(i.body || i.link_url) && !open && (
        <p className="app-input-body">
          {i.body}
          {href && (
            <>
              {i.body ? ' ' : ''}
              <a href={href} target="_blank" rel="noopener noreferrer">
                Open the link<span className="app-visually-hidden"> (opens in a new tab)</span>
              </a>
            </>
          )}
        </p>
      )}
      <div className="app-inline-row">
        {mine && !received && (
          <Button size="sm" variant="secondary" onClick={() => setOpen(!open)} aria-expanded={open} aria-controls={formId}>
            {open ? 'Close' : 'Give your input'}
          </Button>
        )}
        {canManage && !received && (
          <button type="button" className="app-link-button" disabled={busy} onClick={() => onChange({ status: 'received' })} aria-label={`Mark ${i.title} received`}>
            Mark received
          </button>
        )}
        {(canManage || mine) && received && (
          <button type="button" className="app-link-button" disabled={busy} onClick={() => onChange({ status: 'requested' })} aria-label={`Reopen ${i.title}`}>
            Reopen
          </button>
        )}
        {canManage && (
          <button
            type="button"
            className="app-link-button"
            disabled={busy}
            aria-label={`Remove input ${i.title}`}
            onClick={() => {
              if (window.confirm(`Remove the input "${i.title}"?`)) onRemove();
            }}
          >
            Remove
          </button>
        )}
      </div>
      {open && (
        <div className="app-form" id={formId}>
          <label className="tec-field" htmlFor={`ib-${i.id}`}>
            <span>Your input</span>
            <textarea id={`ib-${i.id}`} className="tec-input app-textarea" rows={3} maxLength={4000} value={body} onChange={(e) => setBody(e.target.value)} />
          </label>
          <TextField
            id={`il-${i.id}`}
            label="Link"
            hint={linkOk ? '(optional, https://…)' : '– must start with https://'}
            type="url"
            maxLength={2000}
            value={link}
            onChange={(e) => setLink(e.target.value)}
            aria-invalid={!linkOk || undefined}
          />
          <div className="tec-row" style={{ padding: 0 }}>
            <Button
              size="sm"
              variant="primary"
              disabled={busy || !linkOk || (!body.trim() && !link.trim())}
              onClick={() => {
                onChange({ body: body.trim() || null, link_url: link.trim() || null, status: 'received' });
                setOpen(false);
              }}
            >
              Send and mark received
            </Button>
            <Button
              size="sm"
              variant="quiet"
              disabled={busy || !linkOk}
              onClick={() => {
                onChange({ body: body.trim() || null, link_url: link.trim() || null });
                setOpen(false);
              }}
            >
              Save draft
            </Button>
          </div>
        </div>
      )}
    </li>
  );
}
