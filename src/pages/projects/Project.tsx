// -------------------------------------------------------------------------------------
// Project and event page (mockup "Project and event page"): the project's status flow and
// the actions open to this leader, the High-level Event Planning form (12 sections), and the
// side cards: Before approval, Volunteers needed, Inputs.
// Who may do what comes from public.project_readiness (can_manage, can_approve) and roles;
// the database decides every change (project_guard and friends, migrations 8 and 24) and its
// message is shown when it says no.
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useMutation } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, useLeaders, useUnits } from '../../data/reference';
import {
  formatWhen,
  isoToLondon,
  londonToIso,
  SHORTFALL_ACTIONS,
  useEventPlan,
  useProject,
  useProjectTypes,
  useReadiness,
  useRefreshProject,
  type Project as ProjectRow,
  type Readiness,
} from '../../data/projects';
import { hasRole, useMe } from '../../auth/useMe';
import { NotFound } from '../NotFound';
import { EventPlanCard } from './EventPlanCard';
import { DemandCard, InputsCard, ReadinessCard } from './ProjectSide';

const { SectionHeading, Card, Notice, Button, TextField, SelectField } = TEC;

type Patch = Partial<ProjectRow>;

export function Project() {
  const { id } = useParams();
  const project = useProject(id);
  if (project.isPending) return <p>Loading…</p>;
  if (project.error) return <Notice tone="danger">{friendlyError(project.error)}</Notice>;
  // Unknown, another church's, or a Sunday service (those live under Sunday Operations).
  if (!project.data || project.data.is_sunday_service) return <NotFound />;
  return <ProjectPage key={project.data.id} p={project.data} />;
}

function ProjectPage({ p }: { p: ProjectRow }) {
  const me = useMe();
  const units = useUnits();
  const types = useProjectTypes();
  const leaders = useLeaders();
  const plan = useEventPlan(p.id);
  const ready = useReadiness(p.id);
  const refresh = useRefreshProject(p.id);

  const unit = p.unit_id ? byId(units.data).get(p.unit_id) : undefined;
  const typeName = p.type_id ? byId(types.data).get(p.type_id)?.name : undefined;
  const owner = byId(leaders.data).get(p.owner_user_id)?.display_name ?? 'Unknown';
  // Without the readiness answer (still loading, or a role outside planning) nothing is offered.
  const r: Readiness | undefined = ready.data;
  const canManage = !!r?.can_manage;
  const canApprove = !!r?.can_approve;
  const isEvent = !!plan.data;

  return (
    <>
      <SectionHeading
        eyebrow={`${p.level === 'church' ? 'Church project' : `${unit?.name ?? 'Unit'} project`}${typeName ? ` · ${typeName}` : ''}`}
        title={p.name}
        rule
      >
        {formatWhen(p.starts_at, p.ends_at)} · Owner: {owner}
        {plan.data ? ` · ${cap(plan.data.size)} · ${cap(plan.data.complexity)} complexity` : ''}
      </SectionHeading>
      <p style={{ margin: 0 }}>
        <Link to="/projects">All projects</Link>
      </p>

      <StatusFlow p={p} />
      {/* Self-approval is allowed (decision of 25 Oct 2026) and always shown. SECURITY REVIEW 16
          (V01): from the flag the database records at approval, not from today's owner, which
          changes when a project is handed on. */}
      {p.approved_by && p.self_approved && <Notice tone="info">Self-approved: its owner at the time approved it.</Notice>}
      {/* The database keeps a note on a draft only when the approver sent it back (U05). */}
      {p.decision_note && (
        <Notice tone={p.status === 'draft' ? 'warn' : 'info'} title={p.status === 'draft' ? 'Sent back for changes' : 'Note from the approver'}>
          <span style={{ whiteSpace: 'pre-wrap' }}>{p.decision_note}</span>
        </Notice>
      )}
      {/* U09: a failed readiness call is not the same as "nothing for you to do". Roles outside
          planning are refused (42501) and simply see no actions; anything else is said. */}
      {ready.error && (ready.error as { code?: string }).code !== '42501' && (
        <Notice tone="danger" title="The approval checks could not be loaded">
          {friendlyError(ready.error)} Actions for this project are hidden until they load.
        </Notice>
      )}
      {p.description && <p style={{ margin: 0, whiteSpace: 'pre-wrap' }}>{p.description}</p>}

      <StatusActions p={p} r={r} canManage={canManage} canApprove={canApprove} isEvent={isEvent} onChange={refresh} />
      {canManage && <EditDetails p={p} onSaved={refresh} />}

      <div className="app-project-grid">
        <div className="app-project-main">
          {plan.isPending && <p>Loading the event plan…</p>}
          {plan.error && <Notice tone="danger">{friendlyError(plan.error)}</Notice>}
          {plan.data && <EventPlanCard plan={plan.data} projectId={p.id} canManage={canManage} canApprove={canApprove} status={p.status} />}
          {plan.data === null && <StartPlan projectId={p.id} status={p.status} canManage={canManage} onDone={refresh} />}
        </div>
        <aside className="app-project-side" aria-label="Approval, volunteers and inputs">
          {r && <ReadinessCard r={r} />}
          <DemandCard p={p} canManage={canManage} shortfall={r?.shortfall ?? null} />
          <InputsCard projectId={p.id} canManage={canManage} myId={me.data?.id} />
        </aside>
      </div>
    </>
  );
}

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

// ---------- Status: the steps and where this project is ----------
function StatusFlow({ p }: { p: ProjectRow }) {
  if (p.status === 'cancelled')
    return (
      <Notice tone="info" title="Cancelled">
        This project was cancelled.
      </Notice>
    );
  const steps: { key: ProjectRow['status']; label: string }[] = [
    { key: 'draft', label: 'Draft' },
    { key: 'submitted', label: 'Submitted' },
    { key: 'approved', label: p.level === 'church' ? 'Approved by the Operations Lead' : 'Approved by the Purpose Head' },
    { key: 'in_progress', label: 'In progress' },
    { key: 'done', label: 'Done' },
  ];
  const at = steps.findIndex((s) => s.key === p.status);
  return (
    <ol className="app-steps" aria-label="Status">
      {steps.map((s, i) => (
        <li key={s.key} className={i < at ? 'is-done' : i === at ? 'is-current' : ''} aria-current={i === at ? 'step' : undefined}>
          <span className="app-step-dot" aria-hidden="true" />
          {s.label}
          {i < at && <span className="app-visually-hidden"> (done)</span>}
        </li>
      ))}
    </ol>
  );
}

// ---------- The actions open to this leader now ----------
function StatusActions({
  p,
  r,
  canManage,
  canApprove,
  isEvent,
  onChange,
}: {
  p: ProjectRow;
  r: Readiness | undefined;
  canManage: boolean;
  canApprove: boolean;
  isEvent: boolean;
  onChange: () => void;
}) {
  const me = useMe();
  const navigate = useNavigate();
  const [panel, setPanel] = useState<'approve' | 'sendback' | null>(null);
  const [note, setNote] = useState('');
  const [action, setAction] = useState(p.shortfall_action ?? '');
  const [actionNote, setActionNote] = useState(p.shortfall_action_note ?? '');

  const update = useMutation({
    mutationFn: async (patch: Patch) => {
      const { error } = await supabase.from('projects').update(patch).eq('id', p.id).select('id').single();
      if (error) throw error;
    },
    onSuccess: () => {
      setPanel(null);
      onChange();
    },
  });
  const remove = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('projects').delete().eq('id', p.id).select('id').single();
      if (error) throw error;
    },
    onSuccess: () => navigate('/projects'),
  });

  const open = p.status !== 'done' && p.status !== 'cancelled';
  const canCancel = open && (canManage || hasRole(me.data, 'resident_pastor'));
  // R6: approving with a shortfall needs the action taken.
  const needsAction = !!r?.shortfall && !p.shortfall_action;
  const busy = update.isPending || remove.isPending;

  const buttons = [
    canManage && p.status === 'draft' && (
      <Button key="submit" variant="primary" disabled={busy} onClick={() => update.mutate({ status: 'submitted' })}>
        Submit for approval
      </Button>
    ),
    canApprove && p.status === 'submitted' && (
      <Button key="approve" variant="primary" disabled={busy} onClick={() => setPanel(panel === 'approve' ? null : 'approve')}>
        Approve
      </Button>
    ),
    canApprove && p.status === 'submitted' && (
      <Button key="back" variant="secondary" disabled={busy} onClick={() => setPanel(panel === 'sendback' ? null : 'sendback')}>
        Send back for changes
      </Button>
    ),
    canManage && !canApprove && p.status === 'submitted' && (
      <Button key="withdraw" variant="secondary" disabled={busy} onClick={() => update.mutate({ status: 'draft' })}>
        Withdraw to draft
      </Button>
    ),
    canManage && p.status === 'approved' && (
      <Button key="start" variant="primary" disabled={busy} onClick={() => update.mutate({ status: 'in_progress' })}>
        Mark in progress
      </Button>
    ),
    canManage && (p.status === 'approved' || p.status === 'in_progress') && (
      <Button key="done" variant={p.status === 'in_progress' ? 'primary' : 'secondary'} disabled={busy} onClick={() => update.mutate({ status: 'done' })}>
        Mark done
      </Button>
    ),
    canCancel && (
      <Button
        key="cancel"
        variant="quiet"
        disabled={busy}
        onClick={() => {
          if (window.confirm(`Cancel "${p.name}"? It stays in the history as cancelled.`)) update.mutate({ status: 'cancelled' });
        }}
      >
        Cancel project
      </Button>
    ),
    canManage && p.status === 'draft' && (
      <Button
        key="delete"
        variant="quiet"
        disabled={busy}
        onClick={() => {
          if (window.confirm(`Delete the draft "${p.name}"? This can't be undone.`)) remove.mutate();
        }}
      >
        Delete draft
      </Button>
    ),
  ].filter(Boolean);

  if (buttons.length === 0 && !update.isError) return null;
  const err = update.error ?? remove.error;

  return (
    <Card title="What happens next">
      {p.status === 'draft' && canManage && (
        <p style={{ margin: 0 }}>
          When the plan is ready, submit it. {p.level === 'church' ? 'The Operations Lead, for the leadership team,' : 'The Purpose Head'} approves it
          {isEvent ? ' once the checks under Before approval pass' : ''}.
        </p>
      )}
      {p.status === 'done' && isEvent && <p style={{ margin: 0 }}>Finished. The event review is part of the record.</p>}
      <div className="tec-row" style={{ padding: 0 }}>
        {buttons}
      </div>
      {err && (
        <Notice tone="danger" title="That wasn't done">
          {friendlyError(err)}
        </Notice>
      )}

      {panel === 'approve' && (
        <div className="app-form">
          {/* Self-approval is allowed for the Operations Lead (decision of 25 Oct 2026) and flagged. */}
          {p.owner_user_id === me.data?.id && (
            <Notice tone="info" title="This is your own project">
              You are approving a project you own. It will be shown as self-approved.
            </Notice>
          )}
          {needsAction && (
            <>
              <Notice tone="warn" title="Volunteer shortfall">
                {r?.shortfall} is short of volunteers. Record what will be done before approving.
              </Notice>
              <div className="tec-fields">
                <SelectField
                  id="pa-action"
                  label="Action taken"
                  value={action}
                  onChange={(e) => setAction(e.target.value)}
                  options={[{ value: '', label: 'Choose an action' }, ...SHORTFALL_ACTIONS]}
                />
                <TextField id="pa-action-note" label="Details" hint="(optional)" maxLength={1000} value={actionNote} onChange={(e) => setActionNote(e.target.value)} />
              </div>
            </>
          )}
          <TextField id="pa-note" label="Note to the owner" hint="(optional)" maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} />
          <div>
            <Button
              variant="primary"
              disabled={busy || (needsAction && !action)}
              onClick={() =>
                update.mutate({
                  status: 'approved',
                  decision_note: note.trim() || null,
                  ...(needsAction ? { shortfall_action: action as ProjectRow['shortfall_action'], shortfall_action_note: actionNote.trim() || null } : {}),
                })
              }
            >
              Confirm approval
            </Button>
          </div>
        </div>
      )}
      {panel === 'sendback' && (
        <div className="app-form">
          <TextField id="sb-note" label="What needs changing?" required maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} />
          <div>
            <Button variant="primary" disabled={busy || !note.trim()} onClick={() => update.mutate({ status: 'draft', decision_note: note.trim() })}>
              Send back
            </Button>
          </div>
        </div>
      )}
    </Card>
  );
}

// ---------- Edit name, dates, description (owner or Operations Lead) ----------
function EditDetails({ p, onSaved }: { p: ProjectRow; onSaved: () => void }) {
  const [open, setOpen] = useState(false);
  const s = isoToLondon(p.starts_at);
  const e = isoToLondon(p.ends_at);
  const [v, setV] = useState({ name: p.name, sd: s.date, st: s.time, ed: e.date, et: e.time, description: p.description ?? '' });
  const save = useMutation({
    mutationFn: async () => {
      const starts = londonToIso(v.sd, v.st);
      const ends = londonToIso(v.ed, v.et);
      if (ends < starts) throw new Error('The project ends before it starts.');
      const { error } = await supabase
        .from('projects')
        .update({ name: v.name.trim(), starts_at: starts, ends_at: ends, description: v.description.trim() || null })
        .eq('id', p.id)
        .select('id')
        .single();
      if (error) throw error;
    },
    onSuccess: () => {
      setOpen(false);
      onSaved();
    },
  });
  if (p.status === 'done' || p.status === 'cancelled') return null;
  if (!open)
    return (
      <div>
        <Button variant="quiet" size="sm" onClick={() => setOpen(true)}>
          Edit name, dates or description
        </Button>
      </div>
    );
  return (
    <Card title="Edit details" tone="tint">
      {(p.status === 'approved' || p.status === 'in_progress') && (
        <Notice tone="warn">Changing the dates of an approved project sends it back for approval.</Notice>
      )}
      <div className="tec-fields">
        <TextField id="ed-name" label="Name" maxLength={200} value={v.name} onChange={(ev) => setV({ ...v, name: ev.target.value })} />
        <TextField id="ed-sd" label="Starts on" type="date" value={v.sd} onChange={(ev) => setV({ ...v, sd: ev.target.value })} />
        <TextField id="ed-st" label="Start time" type="time" value={v.st} onChange={(ev) => setV({ ...v, st: ev.target.value })} />
        <TextField id="ed-ed" label="Ends on" type="date" value={v.ed} onChange={(ev) => setV({ ...v, ed: ev.target.value })} />
        <TextField id="ed-et" label="End time" type="time" value={v.et} onChange={(ev) => setV({ ...v, et: ev.target.value })} />
        <label className="tec-field app-field-wide" htmlFor="ed-desc">
          <span>
            Description <span className="tec-hint">(optional)</span>
          </span>
          <textarea id="ed-desc" className="tec-input app-textarea" rows={3} maxLength={4000} value={v.description} onChange={(ev) => setV({ ...v, description: ev.target.value })} />
        </label>
      </div>
      {save.isError && (
        <Notice tone="danger" title="Not saved">
          {friendlyError(save.error)}
        </Notice>
      )}
      <div className="tec-row" style={{ padding: 0 }}>
        <Button variant="primary" disabled={save.isPending || !v.name.trim() || !v.sd || !v.ed} onClick={() => save.mutate()}>
          Save
        </Button>
        <Button variant="quiet" onClick={() => setOpen(false)}>
          Cancel
        </Button>
      </div>
    </Card>
  );
}

// ---------- A project without the event form can start it ----------
function StartPlan({
  projectId,
  status,
  canManage,
  onDone,
}: {
  projectId: string;
  status: ProjectRow['status'];
  canManage: boolean;
  onDone: () => void;
}) {
  const start = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('event_plans').insert({ project_id: projectId, size: 'small', complexity: 'low' });
      if (error) throw error;
    },
    onSuccess: onDone,
  });
  return (
    <Card title="Event planning">
      <p style={{ margin: 0 }}>This project doesn't use the High-level Event Planning form.</p>
      {canManage && status !== 'done' && status !== 'cancelled' && (
        <>
          {(status === 'approved' || status === 'in_progress') && (
            <p className="type-caption" style={{ margin: 0 }}>
              Starting the form sends this project back for approval (the event checks apply).
            </p>
          )}
          <div>
            <Button variant="secondary" disabled={start.isPending} onClick={() => start.mutate()}>
              Use the event planning form
            </Button>
          </div>
        </>
      )}
      {start.isError && <Notice tone="danger">{friendlyError(start.error)}</Notice>}
    </Card>
  );
}
