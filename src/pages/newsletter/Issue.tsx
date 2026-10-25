// -------------------------------------------------------------------------------------
// One issue of The Greatness Brief (mockup "Newsletter content manager").
// Left: the editors' words (headline, standfirst, the Pastor's word, send date), the sections
// that come from the app (gatherings, celebrations, baptisms, team updates, Values in Action),
// each of which editors may leave out, and the typed Wins and Notices (R18: a named item needs
// the person's agreement). Right: the approval steps and this leader's next action, team
// updates received, and after sending, counts only.
// Preview shows the exact email, made by the same code the Edge Function uses, in a sandboxed
// frame (no scripts). The database decides every change (issue_guard, migration 27).
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useMutation } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, useUnits } from '../../data/reference';
import { isoToLondon, useInputs } from '../../data/projects';
import { shortDate } from '../../data/sundays';
import { monthLabel, renderHtml, visible, whenLabel, type IssueContent } from '../../../supabase/functions/_shared/newsletter.ts';
import {
  approvalSteps,
  callSender,
  isSending,
  issueActions,
  STATUS_LABEL,
  STATUS_TONE,
  toggleExcluded,
  useIssue,
  useIssueContent,
  useIssueStats,
  useRecipientCount,
  useRefreshIssue,
  useSettings,
  type Issue as IssueRow,
} from '../../data/newsletter';
import { useMe, type AppRole } from '../../auth/useMe';
import { NotFound } from '../NotFound';

const { SectionHeading, Card, Notice, Button, TextField, Chip, Stepper, Checkbox, SelectField } = TEC;

export function Issue() {
  const { id } = useParams();
  const me = useMe();
  const issue = useIssue(id);
  const content = useIssueContent(id);
  const settings = useSettings();
  const recipients = useRecipientCount();
  const refresh = useRefreshIssue();
  const [preview, setPreview] = useState(false);
  const [note, setNote] = useState<string | null>(null);

  const roles = (me.data?.roles ?? []).map((r) => r.role as AppRole);
  const i = issue.data;
  const sendingNow = i ? isSending(i.send_started_at) : false;
  const can = i ? issueActions(i, roles, sendingNow) : null;

  // Status moves (submit, approve, send back) and Send now.
  const move = useMutation({
    mutationFn: async (patch: Partial<IssueRow>) => {
      const { error } = await supabase.from('newsletter_issues').update(patch).eq('id', id!).select('id').single();
      if (error) throw error;
      if (patch.send_now_at) {
        // Ask the sender straight away; if that fails the 15-minute job sends it anyway.
        await callSender({ action: 'tick' }).catch(() => undefined);
      }
    },
    onSuccess: () => refresh(id),
    // The content may have changed under the approver (Y01): show them the current version.
    onError: () => refresh(id),
  });
  const test = useMutation({
    mutationFn: () => callSender({ action: 'test', issue_id: id! }),
    onSuccess: (r) => setNote(`Test sent to ${r.sent ?? 0} address${r.sent === 1 ? '' : 'es'} on the test list.`),
  });

  if (issue.isPending || me.isPending) return <p>Loading…</p>;
  if (issue.error) return <Notice tone="danger">{friendlyError(issue.error)}</Notice>;
  if (!i || !can) return <NotFound />;

  const live = settings.data?.newsletter_live ?? false;
  // SECURITY REVIEW 18 (Y02): once sending has started the issue keeps its own mode.
  const mode = i.send_live ?? live;
  const audience = mode
    ? `Goes to ${recipients.data ?? '…'} G-Squad members`
    : `Test list only (${settings.data?.newsletter_test_recipients.length ?? 0} addresses) until the DPIA is signed`;

  return (
    <>
      <p style={{ margin: 0 }}>
        <Link to="/newsletter">All issues</Link>
      </p>
      <SectionHeading eyebrow="The Greatness Brief · Editor" title={`${monthLabel(i.issue_month)} issue`} rule>
        <span className="app-issue-meta">
          <Chip tone={STATUS_TONE[i.status]}>
            {STATUS_LABEL[i.status]}
            {i.status === 'sent' && i.sent_as_test ? ' (test list)' : ''}
          </Chip>
          <span>
            {i.status === 'sent' && i.sent_at
              ? `Sent ${shortDate(i.sent_at.slice(0, 10))}`
              : `${audience} · send date ${i.send_on ? shortDate(i.send_on) : 'not set'}`}
          </span>
        </span>
      </SectionHeading>

      <div className="tec-row" style={{ padding: 0 }}>
        <Button variant="secondary" aria-expanded={preview} onClick={() => setPreview(!preview)}>
          {preview ? 'Close preview' : 'Preview email'}
        </Button>
        {can.test && (
          <Button variant="secondary" disabled={test.isPending} onClick={() => test.mutate()}>
            Send a test
          </Button>
        )}
        {can.submit && (
          <Button variant="primary" disabled={move.isPending} onClick={() => move.mutate({ status: 'awaiting_coordinator' })}>
            Send to G-Squad Coordinator
          </Button>
        )}
        {/* SECURITY REVIEW 18 (Y01): an approval names the version of the content on this page;
            the database refuses it if the content has changed since (the page then reloads it). */}
        {can.coordinatorApprove && (
          <Button
            variant="primary"
            disabled={move.isPending || !content.data?.version}
            onClick={() => move.mutate({ status: 'awaiting_pastor', approved_version: content.data!.version })}
          >
            Approve and send to the Resident Pastor
          </Button>
        )}
        {can.pastorApprove && (
          <Button
            variant="primary"
            disabled={move.isPending || !content.data?.version}
            onClick={() => move.mutate({ status: 'approved', approved_version: content.data!.version })}
          >
            Give final approval
          </Button>
        )}
        {(can.sendNow || can.retry) && (
          <Button
            variant="primary"
            disabled={move.isPending}
            onClick={() => {
              if (window.confirm(mode ? 'Send this issue to G-Squad members now?' : 'Send this issue to the test list now?'))
                move.mutate({ send_now_at: new Date().toISOString() });
            }}
          >
            {can.retry ? 'Try sending again' : 'Send now'}
          </Button>
        )}
      </div>
      {move.isError && <Notice tone="danger">{friendlyError(move.error)}</Notice>}
      {test.isError && <Notice tone="danger">{friendlyError(test.error)}</Notice>}
      {note && <Notice tone="ok">{note}</Notice>}
      {sendingNow && <Notice tone="info">This issue is being sent. It cannot be changed now.</Notice>}
      {i.status === 'approved' && i.send_error && !sendingNow && (
        <Notice tone="warn" title="Not finished sending">
          {i.send_error}.{' '}
          {i.send_attempts >= 5
            ? 'After 5 tries it has stopped. The G-Squad Coordinator or Resident Pastor can try sending again.'
            : i.send_live && !live
              ? 'Sending to members was switched off part-way; it carries on only if the Resident Pastor switches it on again.'
              : 'It will try again within 15 minutes.'}
        </Notice>
      )}

      {preview && content.data && <PreviewCard content={content.data} />}

      <div className="app-project-grid">
        <div className="app-project-main">
          <WordsCard key={i.updated_at} issue={i} canEdit={can.edit} onSaved={() => refresh(id)} />
          {content.error && <Notice tone="danger">{friendlyError(content.error)}</Notice>}
          {content.data && <FromTheApp issue={i} content={content.data} canEdit={can.edit} onSaved={() => refresh(id)} />}
          {content.data && <ItemsCard issueId={i.id} content={content.data} canEdit={can.edit} onSaved={() => refresh(id)} />}
        </div>
        <aside className="app-project-side" aria-label="Approval and team updates">
          <Card title="Approval">
            <Stepper label="Approval" steps={approvalSteps(i.status)} />
            {i.coordinator_approved_at && <p className="type-caption" style={{ margin: 0 }}>Coordinator approved {shortDate(i.coordinator_approved_at.slice(0, 10))}.</p>}
            {i.pastor_approved_at && <p className="type-caption" style={{ margin: 0 }}>Resident Pastor approved {shortDate(i.pastor_approved_at.slice(0, 10))}.</p>}
            {can.sendBack && (
              <div>
                <Button variant="quiet" size="sm" disabled={move.isPending} onClick={() => move.mutate({ status: 'draft' })}>
                  Return to the editors
                </Button>
              </div>
            )}
          </Card>
          <TeamUpdatesCard projectId={i.project_id} />
          {i.status === 'sent' && <StatsCard issueId={i.id} />}
        </aside>
      </div>
    </>
  );
}

// "1 birthday", "2 birthdays".
const n = (count: number, one: string, many: string) => `${count} ${count === 1 ? one : many}`;

// ---------- Preview: the exact email in a sandboxed frame ----------
function PreviewCard({ content }: { content: IssueContent }) {
  const html = renderHtml(content, { appUrl: window.location.origin, links: null, firstName: 'Ada' });
  return (
    <Card title="Email preview">
      <p className="type-caption" style={{ margin: 0 }}>
        As members will see it, with sample personal links. Celebrations and recognitions withdrawn before sending are left out.
      </p>
      {/* sandbox with no permissions: no scripts, no forms, links cannot open from the frame. */}
      <iframe className="app-email-frame" title="Email preview" sandbox="" srcDoc={html} />
    </Card>
  );
}

// ---------- The editors' words ----------
function WordsCard({ issue, canEdit, onSaved }: { issue: IssueRow; canEdit: boolean; onSaved: () => void }) {
  const [v, setV] = useState({
    headline: issue.headline ?? '',
    standfirst: issue.standfirst ?? '',
    pastor_word: issue.pastor_word ?? '',
    pastor_name: issue.pastor_name ?? '',
    send_on: issue.send_on ?? '',
  });
  const [today] = useState(() => isoToLondon(new Date().toISOString()).date);
  const dirty =
    v.headline !== (issue.headline ?? '') ||
    v.standfirst !== (issue.standfirst ?? '') ||
    v.pastor_word !== (issue.pastor_word ?? '') ||
    v.pastor_name !== (issue.pastor_name ?? '') ||
    v.send_on !== (issue.send_on ?? '');
  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase
        .from('newsletter_issues')
        .update({
          headline: v.headline.trim() || null,
          standfirst: v.standfirst.trim() || null,
          pastor_word: v.pastor_word.trim() || null,
          pastor_name: v.pastor_name.trim() || null,
          send_on: v.send_on || null,
        })
        .eq('id', issue.id)
        .select('id')
        .single();
      if (error) throw error;
    },
    onSuccess: onSaved,
  });
  const approved = issue.status === 'awaiting_pastor' || issue.status === 'approved';
  return (
    <Card title="This month at a glance">
      <div className="app-form">
        <TextField id="is-head" label="Headline" maxLength={200} disabled={!canEdit} value={v.headline} onChange={(e) => setV({ ...v, headline: e.target.value })} />
        <TextField id="is-stand" label="Standfirst" hint="One line under the headline" maxLength={500} disabled={!canEdit} value={v.standfirst} onChange={(e) => setV({ ...v, standfirst: e.target.value })} />
        <label className="tec-field" htmlFor="is-word">
          <span>A word from the Pastor</span>
          <textarea id="is-word" className="tec-input app-textarea" rows={4} maxLength={2000} disabled={!canEdit} value={v.pastor_word} onChange={(e) => setV({ ...v, pastor_word: e.target.value })} />
        </label>
        <div className="tec-fields" style={{ padding: 0 }}>
          <TextField id="is-pname" label="Pastor's name" maxLength={100} disabled={!canEdit} value={v.pastor_name} onChange={(e) => setV({ ...v, pastor_name: e.target.value })} />
          <TextField id="is-send" label="Send date" type="date" min={today} disabled={!canEdit} value={v.send_on} onChange={(e) => setV({ ...v, send_on: e.target.value })} />
        </div>
        {save.isError && <Notice tone="danger">{friendlyError(save.error)}</Notice>}
        {canEdit && (
          <div className="tec-row" style={{ padding: 0 }}>
            <Button variant="primary" disabled={!dirty || save.isPending} onClick={() => save.mutate()}>
              Save
            </Button>
            {approved && dirty && <span className="type-caption">Saving sends the issue back to the G-Squad Coordinator.</span>}
          </div>
        )}
      </div>
    </Card>
  );
}

// ---------- Sections from the app ----------
function FromTheApp({ issue, content, canEdit, onSaved }: { issue: IssueRow; content: IssueContent; canEdit: boolean; onSaved: () => void }) {
  const save = useMutation({
    mutationFn: async (excluded: string[]) => {
      const { error } = await supabase.from('newsletter_issues').update({ excluded }).eq('id', issue.id).select('id').single();
      if (error) throw error;
    },
    onSuccess: onSaved,
  });
  const shown = visible(content);
  const toggle = (rowId: string, label: string, isOut: boolean | undefined) =>
    canEdit ? (
      <button type="button" className="app-link-button" disabled={save.isPending} onClick={() => save.mutate(toggleExcluded(issue.excluded, rowId))} aria-label={`${isOut ? 'Include' : 'Leave out'}: ${label}`}>
        {isOut ? 'Include' : 'Leave out'}
      </button>
    ) : null;
  const count = (kind: string) => content.celebrations.filter((c) => c.kind === kind).length;

  return (
    <Card title="From the app">
      <p className="type-caption" style={{ margin: 0 }}>
        Filled in from the app. Only members who chose to share celebrations appear, by first name and initial, day and month.
      </p>
      {save.isError && <Notice tone="danger">{friendlyError(save.error)}</Notice>}

      <h3 className="app-issue-h">Upcoming gatherings</h3>
      {content.gatherings.length === 0 && <p className="app-issue-empty">No approved church events in {monthLabel(issue.issue_month)}.</p>}
      <ul className="app-issue-list">
        {content.gatherings.map((g) => (
          <li key={g.id} className={g.excluded ? 'is-out' : undefined}>
            <span>
              <strong>{g.name}</strong>
              <br />
              <span className="type-caption">{[whenLabel(g.starts_at), g.site].filter(Boolean).join(' · ')}</span>
            </span>
            {g.excluded && <Chip tone="neutral">Left out</Chip>}
            {toggle(g.id, g.name, g.excluded)}
          </li>
        ))}
      </ul>

      <h3 className="app-issue-h">Celebrations</h3>
      <p className="app-issue-empty">
        {n(count('birthday'), 'birthday', 'birthdays')}, {n(count('anniversary'), 'anniversary', 'anniversaries')},{' '}
        {n(count('new_member'), 'new member', 'new members')} (opted in).
      </p>

      <h3 className="app-issue-h">Baptisms last month</h3>
      <p className="app-issue-empty">
        {content.baptisms.water} in water, {content.baptisms.holy_spirit} of the Holy Spirit (counts only, never names).
      </p>

      <h3 className="app-issue-h">From the teams</h3>
      {content.team_updates.length === 0 && <p className="app-issue-empty">No team updates received yet.</p>}
      <ul className="app-issue-list">
        {content.team_updates.map((t) => (
          <li key={t.id} className={t.excluded ? 'is-out' : undefined}>
            <span>
              <strong>{t.unit ?? 'Team'}</strong>
              <br />
              <span className="app-issue-body">{t.body}</span>
            </span>
            {t.excluded && <Chip tone="neutral">Left out</Chip>}
            {toggle(t.id, t.unit ?? 'Team update', t.excluded)}
          </li>
        ))}
      </ul>

      <h3 className="app-issue-h">Values in Action</h3>
      {content.recognitions.length === 0 && <p className="app-issue-empty">No recognitions shared with the newsletter last month.</p>}
      <ul className="app-issue-list">
        {content.recognitions.map((r) => (
          <li key={r.id} className={r.excluded ? 'is-out' : undefined}>
            <span>
              <span className="app-value-letter" aria-hidden="true">
                {r.letter}
              </span>{' '}
              <strong>{r.name}</strong>: {r.description}
            </span>
            {r.excluded ? <Chip tone="neutral">Left out</Chip> : <Chip tone="ok">Agreed to share</Chip>}
            {toggle(r.id, `${r.name}'s recognition`, r.excluded)}
          </li>
        ))}
      </ul>
      <p className="type-caption" style={{ margin: 0 }}>
        In the email: {n(shown.gatherings.length, 'gathering', 'gatherings')}, {n(shown.team_updates.length, 'team update', 'team updates')},{' '}
        {n(shown.recognitions.length, 'recognition', 'recognitions')}.
      </p>
    </Card>
  );
}

// ---------- Wins, testimonies and notices (R18) ----------
function ItemsCard({ issueId, content, canEdit, onSaved }: { issueId: string; content: IssueContent; canEdit: boolean; onSaved: () => void }) {
  const blank = { kind: 'win' as 'win' | 'notice', title: '', body: '', names_a_person: false, agreement_ticked: false };
  const [v, setV] = useState(blank);
  const add = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('newsletter_items').insert({
        issue_id: issueId,
        kind: v.kind,
        title: v.title.trim() || null,
        body: v.body.trim(),
        names_a_person: v.names_a_person,
        agreement_ticked: v.names_a_person && v.agreement_ticked,
        position: content.items.length + 1,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setV(blank);
      onSaved();
    },
  });
  const change = useMutation({
    mutationFn: async ({ itemId, patch, remove }: { itemId: string; patch?: { agreement_ticked: boolean }; remove?: boolean }) => {
      const q = remove ? supabase.from('newsletter_items').delete().eq('id', itemId) : supabase.from('newsletter_items').update(patch!).eq('id', itemId);
      const { error } = await q.select('id').single();
      if (error) throw error;
    },
    onSuccess: onSaved,
  });

  return (
    <Card title="Wins, testimonies and notices">
      {content.items.length === 0 && <p style={{ margin: 0 }}>Nothing added yet.</p>}
      {content.items.map((it) => (
        <div key={it.id} className="app-issue-item">
          <span className="app-issue-item-kind">{it.kind === 'win' ? 'Win or testimony' : 'Notice'}</span>
          {it.title && <strong>{it.title}</strong>}
          <span className="app-issue-body">{it.body}</span>
          {it.names_a_person && (
            <div className="tec-row" style={{ padding: 0 }}>
              <Checkbox
                id={`ag-${it.id}`}
                label="The person named agreed to share this"
                checked={!!it.agreement_ticked}
                disabled={!canEdit || change.isPending}
                onChange={(e) => change.mutate({ itemId: it.id, patch: { agreement_ticked: e.target.checked } })}
              />
              {!it.agreement_ticked && <Chip tone="danger">Needed before approval</Chip>}
            </div>
          )}
          {canEdit && (
            <div>
              <button
                type="button"
                className="app-link-button"
                disabled={change.isPending}
                onClick={() => {
                  if (window.confirm('Remove this item?')) change.mutate({ itemId: it.id, remove: true });
                }}
              >
                Remove
              </button>
            </div>
          )}
        </div>
      ))}
      {change.isError && <Notice tone="danger">{friendlyError(change.error)}</Notice>}
      {canEdit && (
        <details className="app-details">
          <summary>Add a win, testimony or notice</summary>
          <div className="app-form">
            <div className="tec-fields" style={{ padding: 0 }}>
              <SelectField
                id="it-kind"
                label="Type"
                value={v.kind}
                onChange={(e) => setV({ ...v, kind: e.target.value as 'win' | 'notice' })}
                options={[
                  { value: 'win', label: 'Win or testimony' },
                  { value: 'notice', label: 'Notice' },
                ]}
              />
              <TextField id="it-title" label="Title (optional)" maxLength={200} value={v.title} onChange={(e) => setV({ ...v, title: e.target.value })} />
            </div>
            <label className="tec-field" htmlFor="it-body">
              <span>Text</span>
              <textarea id="it-body" className="tec-input app-textarea" rows={3} maxLength={2000} value={v.body} onChange={(e) => setV({ ...v, body: e.target.value })} />
            </label>
            <Checkbox id="it-named" label="It names or identifies a person" checked={v.names_a_person} onChange={(e) => setV({ ...v, names_a_person: e.target.checked })} />
            {v.names_a_person && (
              <Checkbox id="it-agreed" label="They agreed to share it" checked={v.agreement_ticked} onChange={(e) => setV({ ...v, agreement_ticked: e.target.checked })} />
            )}
            {add.isError && <Notice tone="danger">{friendlyError(add.error)}</Notice>}
            <div>
              <Button variant="secondary" disabled={!v.body.trim() || add.isPending} onClick={() => add.mutate()}>
                Add
              </Button>
            </div>
          </div>
        </details>
      )}
    </Card>
  );
}

// ---------- Team updates (asked of every Team Lead, due by the 25th) ----------
function TeamUpdatesCard({ projectId }: { projectId: string }) {
  const inputs = useInputs(projectId);
  const units = useUnits();
  const unitMap = byId(units.data);
  const list = inputs.data ?? [];
  const received = list.filter((x) => x.display_status === 'received').length;
  return (
    <Card title="Team updates">
      {inputs.isPending && <p>Loading…</p>}
      {inputs.data && list.length === 0 && <p style={{ margin: 0 }}>No team updates requested.</p>}
      {list.length > 0 && (
        <>
          <p className="type-caption" style={{ margin: 0 }}>
            {received} of {list.length} in · due {list[0].due_on ? shortDate(list[0].due_on) : ''}
          </p>
          <ul className="app-issue-list">
            {list.map((x) => (
              <li key={x.id!}>
                <span>{unitMap.get(x.unit_id ?? '')?.name ?? x.title}</span>
                <Chip tone={x.display_status === 'received' ? 'ok' : x.display_status === 'overdue' ? 'warn' : 'info'}>
                  {x.display_status === 'received' ? 'Received' : x.display_status === 'overdue' ? 'Overdue' : 'Requested'}
                </Chip>
              </li>
            ))}
          </ul>
        </>
      )}
      <Link to={`/projects/${projectId}#inputs`}>Request or remove updates</Link>
    </Card>
  );
}

// ---------- After sending: counts only ----------
function StatsCard({ issueId }: { issueId: string }) {
  const stats = useIssueStats(issueId, true);
  const total = (item: string) => (stats.data ?? []).filter((s) => s.item === item).reduce((n, s) => n + s.total, 0);
  return (
    <Card title="Response">
      {stats.error && <Notice tone="danger">{friendlyError(stats.error)}</Notice>}
      <div className="app-issue-stats">
        <span>
          <strong>{total('delivered')}</strong> received
        </span>
        <span>
          <strong>{total('rsvp')}</strong> RSVPs
        </span>
        <span>
          <strong>{total('reaction')}</strong> reactions
        </span>
      </div>
      <p className="type-caption" style={{ margin: 0 }}>
        Counts only. Editors never see who responded.
      </p>
    </Card>
  );
}
