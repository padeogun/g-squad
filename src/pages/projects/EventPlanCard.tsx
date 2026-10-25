// -------------------------------------------------------------------------------------
// High-level Event Planning (12 sections, TEC's workbook). Each section opens to show its
// fields and action points; the project's owner or the Operations Lead edit them. The budget
// is decided by Finance or the Resident Pastor with Approve / Reject (R16); the database
// records who decided and when, and a changed estimate needs a fresh decision.
// Section chips are a guide to progress; what blocks approval is in "Before approval".
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { useMutation } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, useLeaders } from '../../data/reference';
import { usePeopleNames } from '../../data/people';
import { shortDate, todayIso } from '../../data/sundays';
import {
  budgetButtons,
  PLAN_SECTIONS,
  sectionStatus,
  useActions,
  useRefreshProject,
  type EventPlan,
  type PlanAction,
  type PlanSection,
  type ProjectStatus,
} from '../../data/projects';
import { hasRole, useMe } from '../../auth/useMe';

const { Card, Notice, Button, Chip, TextField, SelectField, Checkbox } = TEC;

export function EventPlanCard({
  plan,
  projectId,
  canManage,
  canApprove,
  status,
}: {
  plan: EventPlan;
  projectId: string;
  canManage: boolean;
  canApprove: boolean;
  status: ProjectStatus;
}) {
  const actions = useActions(projectId);
  const [openNo, setOpenNo] = useState<number | null>(null);
  const openCount = (no: number) => (actions.data ?? []).filter((a) => a.section_no === no && a.status === 'open').length;
  const complete = PLAN_SECTIONS.filter((s) => sectionStatus(s.no, plan, openCount(s.no)).tone === 'ok').length;

  return (
    <Card title="High-level Event Planning" action={<span className="type-caption">{complete} of 12 sections complete</span>}>
      {/* U02: the database sends an approved event back for approval when these change. */}
      {(status === 'approved' || status === 'in_progress') && (
        <p className="type-caption" style={{ margin: 0 }}>
          Changing the size, the complexity, the planning committee or the budget sends the project back for approval.
        </p>
      )}
      <ol className="app-plan">
        {PLAN_SECTIONS.map((s) => {
          const st = sectionStatus(s.no, plan, openCount(s.no));
          const open = openNo === s.no;
          return (
            <li key={s.no} className={open ? 'is-open' : ''}>
              <button
                type="button"
                className="app-plan-head"
                aria-expanded={open}
                aria-controls={`plan-sec-${s.no}`}
                onClick={() => setOpenNo(open ? null : s.no)}
              >
                <span className={`app-plan-num${st.tone === 'ok' ? ' is-done' : ''}`} aria-hidden="true">
                  {s.no}
                </span>
                <span className="app-plan-title">{s.title}</span>
                <Chip tone={st.tone}>{st.label}</Chip>
              </button>
              {open && (
                <div id={`plan-sec-${s.no}`} className="app-plan-body">
                  <SectionForm key={plan.updated_at} section={s} plan={plan} projectId={projectId} canManage={canManage} />
                  {s.no === 5 && <BudgetDecision plan={plan} projectId={projectId} canManage={canManage} />}
                  {s.no === 8 && <SafeguardingPanel projectId={projectId} canManage={canManage} canApprove={canApprove} />}
                  <ActionPoints section={s.no} projectId={projectId} canManage={canManage} items={(actions.data ?? []).filter((a) => a.section_no === s.no)} />
                </div>
              )}
            </li>
          );
        })}
      </ol>
    </Card>
  );
}

// ---------- One section's fields ----------
type Val = string | boolean;

function SectionForm({ section, plan, projectId, canManage }: { section: PlanSection; plan: EventPlan; projectId: string; canManage: boolean }) {
  const refresh = useRefreshProject(projectId);
  const [v, setV] = useState<Record<string, Val>>(() => {
    const o: Record<string, Val> = {};
    for (const f of section.fields) {
      const cur = plan[f.key];
      o[f.key] = f.type === 'boolean' ? cur === true : cur == null ? '' : String(cur);
    }
    return o;
  });
  const save = useMutation({
    mutationFn: async () => {
      const patch: Record<string, unknown> = {};
      for (const f of section.fields) {
        const x = v[f.key];
        patch[f.key] = f.type === 'boolean' ? x === true : f.type === 'number' ? (x === '' ? null : Number(x)) : String(x).trim() || null;
      }
      const { error } = await supabase
        .from('event_plans')
        .update(patch as never)
        .eq('project_id', projectId)
        .select('project_id')
        .single();
      if (error) throw error;
    },
    onSuccess: refresh,
  });
  // Section 12: marking the review complete (the database records when).
  const review = useMutation({
    mutationFn: async (done: boolean) => {
      const { error } = await supabase
        .from('event_plans')
        .update({ review_completed_at: done ? new Date().toISOString() : null })
        .eq('project_id', projectId)
        .select('project_id')
        .single();
      if (error) throw error;
    },
    onSuccess: refresh,
  });

  const set = (k: string, x: Val) => setV((cur) => ({ ...cur, [k]: x }));
  const ro = !canManage;

  return (
    <div className="app-form">
      <fieldset className="app-fieldset" disabled={ro}>
        <legend className="app-visually-hidden">{section.title}</legend>
        <div className="tec-fields">
          {section.fields.map((f) => {
            const id = `plan-${projectId}-${String(f.key)}`;
            if (f.type === 'boolean')
              return <Checkbox key={f.key} id={id} label={f.label} checked={v[f.key] === true} onChange={(e) => set(f.key, e.target.checked)} />;
            if (f.type === 'select')
              return <SelectField key={f.key} id={id} label={f.label} hint={f.hint} value={String(v[f.key])} onChange={(e) => set(f.key, e.target.value)} options={[{ value: '', label: 'Not set' }, ...(f.options ?? [])]} />;
            if (f.type === 'person')
              return <PersonField key={f.key} id={id} label={f.label} value={String(v[f.key])} onChange={(x) => set(f.key, x)} />;
            if (f.type === 'textarea')
              return (
                <label key={f.key} className="tec-field app-field-wide" htmlFor={id}>
                  <span>
                    {f.label} {f.hint && <span className="tec-hint">{f.hint}</span>}
                  </span>
                  <textarea id={id} className="tec-input app-textarea" rows={3} maxLength={f.max} value={String(v[f.key])} onChange={(e) => set(f.key, e.target.value)} />
                </label>
              );
            return (
              <TextField
                key={f.key}
                id={id}
                label={f.label}
                hint={f.hint}
                type={f.type === 'number' ? 'number' : 'text'}
                inputMode={f.type === 'number' ? 'decimal' : undefined}
                min={f.type === 'number' ? 0 : undefined}
                maxLength={f.max}
                value={String(v[f.key])}
                onChange={(e) => set(f.key, e.target.value)}
              />
            );
          })}
        </div>
      </fieldset>
      {save.isError && (
        <Notice tone="danger" title="Not saved">
          {friendlyError(save.error)}
        </Notice>
      )}
      {canManage && (
        <div className="tec-row" style={{ padding: 0 }}>
          <Button variant="primary" size="sm" disabled={save.isPending} onClick={() => save.mutate()}>
            {save.isPending ? 'Saving…' : `Save ${section.title.split(':')[0].toLowerCase()}`}
          </Button>
          {save.isSuccess && <span className="type-caption" role="status">Saved.</span>}
          {section.no === 12 && (
            <Button variant="secondary" size="sm" disabled={review.isPending} onClick={() => review.mutate(!plan.review_completed_at)}>
              {plan.review_completed_at ? 'Reopen the review' : 'Mark the review complete'}
            </Button>
          )}
        </div>
      )}
      {section.no === 12 && plan.review_completed_at && (
        <p className="type-caption" style={{ margin: 0 }}>
          Review completed {shortDate(plan.review_completed_at.slice(0, 10))}.
        </p>
      )}
      {review.isError && <Notice tone="danger">{friendlyError(review.error)}</Notice>}
    </div>
  );
}

// ---------- Safeguarding notes: restricted and logged (migration 25) ----------
// Read through get_event_safeguarding (the project's owner, the Operations Lead, its approver,
// the Resident Pastor and the Pastoral Lead; every view is logged) only when asked, like the
// faith fields; written through set_event_safeguarding by the owner or the Operations Lead.
function SafeguardingPanel({ projectId, canManage, canApprove }: { projectId: string; canManage: boolean; canApprove: boolean }) {
  const me = useMe();
  const [shown, setShown] = useState<string | null>(null);
  const [draft, setDraft] = useState('');
  const mayRead = canManage || canApprove || hasRole(me.data, 'resident_pastor', 'pastoral_lead');
  const read = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('get_event_safeguarding', { p_project: projectId });
      if (error) throw error;
      return (data as string | null) ?? '';
    },
    onSuccess: (text) => {
      setShown(text);
      setDraft(text);
    },
  });
  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc('set_event_safeguarding', { p_project: projectId, p_notes: draft });
      if (error) throw error;
    },
    onSuccess: () => setShown(draft.trim()),
  });
  if (!mayRead) return null;
  return (
    <div className="app-form">
      <h4 className="app-subhead">Safeguarding notes</h4>
      <p className="type-caption" style={{ margin: 0 }}>
        Seen only by the event owner, the Operations Lead, the approver, the Resident Pastor and the Pastoral Lead. Every view is
        recorded.
      </p>
      {shown === null ? (
        <div>
          <Button size="sm" variant="secondary" icon="lock" disabled={read.isPending} onClick={() => read.mutate()}>
            {read.isPending ? 'Opening…' : 'Show safeguarding notes'}
          </Button>
        </div>
      ) : canManage ? (
        <>
          <label className="tec-field" htmlFor={`sg-${projectId}`}>
            <span>
              Notes <span className="tec-hint">Arrangements and who is responsible; empty removes them</span>
            </span>
            <textarea id={`sg-${projectId}`} className="tec-input app-textarea" rows={3} maxLength={2000} value={draft} onChange={(e) => setDraft(e.target.value)} />
          </label>
          <div className="tec-row" style={{ padding: 0 }}>
            <Button size="sm" variant="primary" disabled={save.isPending || draft.trim() === shown} onClick={() => save.mutate()}>
              Save safeguarding notes
            </Button>
            {save.isSuccess && draft.trim() === shown && (
              <span className="type-caption" role="status">
                Saved.
              </span>
            )}
          </div>
        </>
      ) : (
        <p style={{ margin: 0, whiteSpace: 'pre-wrap' }}>{shown || 'None recorded.'}</p>
      )}
      {(read.error || save.error) && <Notice tone="danger">{friendlyError(read.error ?? save.error)}</Notice>}
    </div>
  );
}

// ---------- A person picker (names only; someone outside this leader's view keeps their place) ----------
function PersonField({ id, label, value, onChange }: { id: string; label: string; value: string; onChange: (v: string) => void }) {
  const names = usePeopleNames();
  const opts = (names.data ?? []).map((p) => ({ value: p.id, label: `${p.first_name} ${p.surname}` }));
  if (value && !opts.some((o) => o.value === value)) opts.unshift({ value, label: 'Someone outside your view' });
  return <SelectField id={id} label={label} value={value} onChange={(e) => onChange(e.target.value)} options={[{ value: '', label: 'Not chosen' }, ...opts]} />;
}

// ---------- Budget: the owner sets "needed or not"; Finance or the Resident Pastor decide ----------
function BudgetDecision({ plan, projectId, canManage }: { plan: EventPlan; projectId: string; canManage: boolean }) {
  const me = useMe();
  const refresh = useRefreshProject(projectId);
  const decider = hasRole(me.data, 'finance', 'resident_pastor');
  const decide = useMutation({
    mutationFn: async (status: EventPlan['budget_status']) => {
      const { error } = await supabase.from('event_plans').update({ budget_status: status }).eq('project_id', projectId).select('project_id').single();
      if (error) throw error;
    },
    onSuccess: refresh,
  });
  const shown = budgetButtons(plan, { decider, canManage });
  const label = { pending: 'Waiting for a decision', approved: 'Approved', rejected: 'Rejected', not_needed: 'No budget needed' }[plan.budget_status];
  return (
    <div className="app-form">
      <p style={{ margin: 0 }}>
        <strong>Budget decision:</strong> {label}
        {plan.budget_decided_at ? ` (${shortDate(plan.budget_decided_at.slice(0, 10))})` : ''}. Only Finance or the Resident
        Pastor approve or reject a budget; a changed estimate needs a fresh decision.
      </p>
      <div className="tec-row" style={{ padding: 0 }}>
        {shown.includes('approve') && (
          <Button size="sm" variant="primary" disabled={decide.isPending} onClick={() => decide.mutate('approved')}>
            Approve budget
          </Button>
        )}
        {shown.includes('reject') && (
          <Button size="sm" variant="secondary" disabled={decide.isPending} onClick={() => decide.mutate('rejected')}>
            Reject budget
          </Button>
        )}
        {/* "No budget needed" with no estimate is the owner's call; with an estimate it is Finance's (F11, U09). */}
        {shown.includes('not_needed') && (
          <Button size="sm" variant="quiet" disabled={decide.isPending} onClick={() => decide.mutate('not_needed')}>
            No budget needed
          </Button>
        )}
        {shown.includes('needed') && (
          <Button size="sm" variant="quiet" disabled={decide.isPending} onClick={() => decide.mutate('pending')}>
            A budget is needed
          </Button>
        )}
      </div>
      {decide.isError && <Notice tone="danger">{friendlyError(decide.error)}</Notice>}
    </div>
  );
}

// ---------- Action points for one section ----------
function ActionPoints({ section, projectId, canManage, items }: { section: number; projectId: string; canManage: boolean; items: PlanAction[] }) {
  const me = useMe();
  const leaders = useLeaders();
  const refresh = useRefreshProject(projectId);
  const [today] = useState(todayIso);
  const [v, setV] = useState({ description: '', owner: '', due: '' });
  const add = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('event_plan_actions').insert({
        project_id: projectId,
        section_no: section,
        description: v.description.trim(),
        owner_user_id: v.owner || null,
        due_on: v.due || null,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setV({ description: '', owner: '', due: '' });
      refresh();
    },
  });
  const change = useMutation({
    mutationFn: async ({ id, done, remove }: { id: string; done?: boolean; remove?: boolean }) => {
      const q = remove
        ? supabase.from('event_plan_actions').delete().eq('id', id)
        : supabase.from('event_plan_actions').update({ status: done ? 'done' : 'open' }).eq('id', id);
      const { error } = await q.select('id').single();
      if (error) throw error;
    },
    onSuccess: refresh,
  });
  const leaderName = (id: string | null) => (id ? byId(leaders.data).get(id)?.display_name ?? 'A leader' : 'No one yet');

  if (!canManage && items.length === 0) return null;
  return (
    <div className="app-form">
      <h4 className="app-subhead">Action points</h4>
      {items.length === 0 && <p className="type-caption" style={{ margin: 0 }}>None yet.</p>}
      {items.length > 0 && (
        <ul className="app-candidates">
          {items.map((a) => {
            const mayTick = canManage || a.owner_user_id === me.data?.id;
            const late = a.status === 'open' && a.due_on && a.due_on < today;
            return (
              <li key={a.id}>
                <span>
                  {a.status === 'done' ? <s>{a.description}</s> : a.description}
                  <span className="type-caption">
                    {' '}
                    · {leaderName(a.owner_user_id)}
                    {a.due_on ? `, due ${shortDate(a.due_on)}` : ''}
                  </span>
                  {late && <Chip tone="danger">Overdue</Chip>}
                </span>
                <span className="app-inline-row">
                  {mayTick && (
                    <Checkbox
                      id={`act-${a.id}`}
                      label="Done"
                      aria-label={`${a.description}: done`}
                      checked={a.status === 'done'}
                      disabled={change.isPending}
                      onChange={(e) => change.mutate({ id: a.id, done: e.target.checked })}
                    />
                  )}
                  {canManage && (
                    <button
                      type="button"
                      className="app-link-button"
                      aria-label={`Remove action point: ${a.description}`}
                      disabled={change.isPending}
                      onClick={() => change.mutate({ id: a.id, remove: true })}
                    >
                      Remove
                    </button>
                  )}
                </span>
              </li>
            );
          })}
        </ul>
      )}
      {change.isError && <Notice tone="danger">{friendlyError(change.error)}</Notice>}
      {canManage && (
        <div className="tec-fields">
          <TextField id={`act-new-${section}`} label="New action point" maxLength={1000} value={v.description} onChange={(e) => setV({ ...v, description: e.target.value })} />
          <SelectField
            id={`act-owner-${section}`}
            label="Who"
            value={v.owner}
            onChange={(e) => setV({ ...v, owner: e.target.value })}
            options={[{ value: '', label: 'No one yet' }, ...(leaders.data ?? []).filter((l) => l.is_active).map((l) => ({ value: l.id, label: l.display_name }))]}
          />
          <TextField id={`act-due-${section}`} label="Due" type="date" value={v.due} onChange={(e) => setV({ ...v, due: e.target.value })} />
          <div>
            <Button size="sm" variant="secondary" disabled={!v.description.trim() || add.isPending} onClick={() => add.mutate()}>
              Add action point
            </Button>
          </div>
        </div>
      )}
      {add.isError && <Notice tone="danger">{friendlyError(add.error)}</Notice>}
    </div>
  );
}
