// -------------------------------------------------------------------------------------
// Serving approvals (migration 32, decision of 12 Nov 2026). The G-Squad Coordinator approves
// or declines a member joining more teams than the church allows, or serving on another event
// at the same time as two others. The Operations Lead and the Resident Pastor see the same list
// read-only: the Resident Pastor is kept in the loop but does not attend to operational tasks.
// Decisions from the last 90 days are listed under what is waiting. The database checks every
// decision again (role, hours, Sundays off, holidays).
// -------------------------------------------------------------------------------------
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { APPROVAL_READERS, approvalSubject, useDecideServingApproval, useServingApprovals, type ServingApproval } from '../../data/dashboards';
import { shortDate } from '../../data/sundays';
import { hasRole, useMe } from '../../auth/useMe';

const { Card, Button, Chip, Notice } = TEC;

export function ServingApprovalsCard() {
  const me = useMe();
  const reader = hasRole(me.data, ...APPROVAL_READERS);
  const decider = hasRole(me.data, 'gsquad_coordinator');
  const list = useServingApprovals(reader);
  const decide = useDecideServingApproval();
  if (!reader) return null;

  const rows = list.data ?? [];
  const waiting = rows.filter((r) => r.state === 'waiting');
  const decided = rows.filter((r) => r.state !== 'waiting');

  return (
    <Card title="Serving approvals" action={waiting.length ? <Chip tone="warn">{waiting.length} waiting</Chip> : undefined}>
      <p className="type-caption" style={{ margin: 0 }}>
        {decider
          ? 'You approve a member joining more teams than the church allows, or serving on another event at the same time as two others.'
          : 'The G-Squad Coordinator approves these. Shown here so you are kept in the loop.'}
      </p>
      {list.isPending && <p style={{ margin: 0 }}>Loading…</p>}
      {list.error && <Notice tone="danger">{friendlyError(list.error)}</Notice>}
      {decide.error && <Notice tone="danger">{friendlyError(decide.error)}</Notice>}
      {list.data && waiting.length === 0 && <p style={{ margin: 0 }}>Nothing is waiting.</p>}
      {waiting.length > 0 && (
        <ul className="app-approvals">
          {waiting.map((r) => (
            <li key={r.request_id}>
              <Request r={r} />
              {decider && (
                <span className="tec-row" style={{ padding: 0 }}>
                  <Button
                    size="sm"
                    variant="lime"
                    icon="check"
                    disabled={decide.isPending}
                    aria-label={`Approve: ${r.person_name}, ${approvalSubject(r)}`}
                    onClick={() => decide.mutate({ kind: r.kind as 'team' | 'project', id: r.request_id, approve: true })}
                  >
                    Approve
                  </Button>
                  <Button
                    size="sm"
                    variant="quiet"
                    disabled={decide.isPending}
                    aria-label={`Decline: ${r.person_name}, ${approvalSubject(r)}`}
                    onClick={() => decide.mutate({ kind: r.kind as 'team' | 'project', id: r.request_id, approve: false })}
                  >
                    Decline
                  </Button>
                </span>
              )}
            </li>
          ))}
        </ul>
      )}
      {decided.length > 0 && (
        <details>
          <summary className="type-caption">Decided in the last 90 days ({decided.length})</summary>
          <ul className="app-approvals">
            {decided.map((r) => (
              <li key={`${r.request_id}-${r.decided_at}`}>
                <Request r={r} />
                <span className="type-caption">
                  {/* SECURITY REVIEW 23 (R04): a request withdrawn by the team's lead or the Operations Lead is shown as such. */}
                  <Chip tone={r.state === 'approved' ? 'ok' : 'neutral'}>
                    {r.state === 'approved' ? 'Approved' : r.state === 'withdrawn' ? 'Withdrawn' : 'Declined'}
                  </Chip>
                  {r.decided_at ? ` ${shortDate(r.decided_at.slice(0, 10))}` : ''}
                  {r.decided_by ? ` by ${r.decided_by}` : ''}
                </span>
              </li>
            ))}
          </ul>
        </details>
      )}
    </Card>
  );
}

function Request({ r }: { r: ServingApproval }) {
  return (
    <span style={{ display: 'grid', gap: 2, minWidth: 0 }}>
      <strong>{r.person_name}</strong>
      <span>
        {approvalSubject(r)}
        {r.starts_on ? ` · ${shortDate(r.starts_on)}` : ''}
      </span>
      {r.requested_at && <span className="type-caption">Asked {shortDate(r.requested_at.slice(0, 10))}</span>}
    </span>
  );
}
