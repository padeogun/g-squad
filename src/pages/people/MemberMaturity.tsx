// -------------------------------------------------------------------------------------
// On a member's record (migration 35, decisions of 25 Nov 2026):
//   Leadership stage history  each time their leadership stage in a team was set or changed,
//                             written by the database. Read by those who can read the member.
//   Discipleship pathway      the stages they have reached (Encounter to Sending), treated like
//                             the faith fields: offered only to faith readers, loaded only when
//                             asked for (every view is logged), recorded by their Team Lead or
//                             the G-Squad Coordinator.
// The database checks every read and change; this page only decides what to offer.
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import type { Person } from '../../data/people';
import { useLeadershipStages, useUnits } from '../../data/reference';
import { shortDate, todayIso } from '../../data/sundays';
import { currentPathway, describeChange, usePathway, usePathwayStages, useRemovePathway, useSetPathway, useStageHistory } from '../../data/maturity';

const { Card, Button, Chip, Notice, SelectField, TextField } = TEC;

export function MemberMaturity({ person, canSeePathway, canEditPathway }: { person: Person; canSeePathway: boolean; canEditPathway: boolean }) {
  return (
    <>
      <StageHistory person={person} />
      {canSeePathway && <Pathway person={person} canEdit={canEditPathway} />}
    </>
  );
}

function StageHistory({ person }: { person: Person }) {
  const history = useStageHistory(person.id);
  const stages = useLeadershipStages();
  const units = useUnits();
  const stageName = (id: string | null) => stages.data?.find((s) => s.id === id)?.name ?? 'a stage no longer listed';
  const unitName = (id: string) => units.data?.find((u) => u.id === id)?.name ?? 'Team';
  // Nothing to show until a leadership stage has been set in one of their teams.
  if (history.isPending || (history.data ?? []).length === 0)
    return history.error ? <Notice tone="danger">{friendlyError(history.error)}</Notice> : null;
  return (
    <Card title="Leadership stage history">
      <p className="type-caption" style={{ margin: 0 }}>
        Written down by the app whenever a leadership stage is set or changed under In G-Squad. Newest first.
      </p>
      <ul className="app-journey">
        {history.data!.map((c) => (
          <li key={c.id}>
            <span>
              <span className="type-caption">{unitName(c.unit_id)}: </span>
              {describeChange(c, stageName)}
            </span>
            <span className="type-caption">{shortDate(c.changed_on)}</span>
          </li>
        ))}
      </ul>
    </Card>
  );
}

function Pathway({ person, canEdit }: { person: Person; canEdit: boolean }) {
  const [today] = useState(todayIso);
  // SECURITY: like "Show faith journey", the pathway is fetched only when asked for, because
  // the database logs every view.
  const [show, setShow] = useState(false);
  const entries = usePathway(person.id, show);
  const stages = usePathwayStages();
  const record = useSetPathway(person.id);
  const remove = useRemovePathway(person.id);
  const [stage, setStage] = useState('');
  const [on, setOn] = useState(today);
  const current = currentPathway(entries.data ?? []);
  const inUse = (stages.data ?? []).filter((s) => s.is_active);

  return (
    <Card title="Discipleship pathway" action={current ? <Chip tone="app">{current.stage_name}</Chip> : undefined}>
      <p className="type-caption" style={{ margin: 0 }}>
        Where this member is on the Maturity pathway (Encounter, Foundation, Community, Depth, Sending). Like faith details, shown only to those who
        may see them, and every view is recorded.
      </p>
      {!show ? (
        <span>
          <Button size="sm" variant="secondary" onClick={() => setShow(true)}>
            Show pathway
          </Button>
        </span>
      ) : (
        <>
          {entries.error && <Notice tone="danger">{friendlyError(entries.error)}</Notice>}
          {entries.isPending && <p style={{ margin: 0 }}>Loading…</p>}
          {entries.data && entries.data.length === 0 && <p style={{ margin: 0 }}>No stage recorded yet.</p>}
          {entries.data && entries.data.length > 0 && (
            <ul className="app-journey">
              {[...entries.data].reverse().map((e) => (
                <li key={e.id}>
                  <span>
                    <span className="type-caption">Stage {e.stage_no}: </span>
                    {e.stage_name}
                  </span>
                  <span className="app-journey-state">
                    <span className="type-caption">reached {shortDate(e.reached_on)}</span>
                    {canEdit && (
                      <Button
                        size="sm"
                        variant="quiet"
                        disabled={remove.isPending}
                        aria-label={`Remove ${e.stage_name}`}
                        onClick={() => remove.mutate(e.id)}
                      >
                        Remove
                      </Button>
                    )}
                  </span>
                </li>
              ))}
            </ul>
          )}
          {canEdit && inUse.length > 0 && (
            <div className="app-form">
              <div className="tec-fields">
                <SelectField
                  id="pathway-stage"
                  label="Record a stage reached"
                  value={stage}
                  onChange={(e) => setStage(e.target.value)}
                  options={[
                    { value: '', label: 'Choose a stage' },
                    ...inUse.map((s) => ({
                      value: s.id,
                      label: `${s.stage_no}. ${s.name}`,
                    })),
                  ]}
                />
                <TextField id="pathway-on" label="Reached on" type="date" max={today} value={on} onChange={(e) => setOn(e.target.value)} />
              </div>
              {stage && (
                <p className="type-caption" style={{ margin: 0 }}>
                  {inUse.find((s) => s.id === stage)?.marker ?? inUse.find((s) => s.id === stage)?.description}
                </p>
              )}
              <span>
                <Button
                  size="sm"
                  variant="secondary"
                  disabled={!stage || !on || on > today || record.isPending}
                  onClick={() => record.mutate({ stageId: stage, reachedOn: on }, { onSuccess: () => setStage('') })}
                >
                  {record.isPending ? 'Saving…' : 'Record stage'}
                </Button>
              </span>
            </div>
          )}
          {(record.error || remove.error) && <Notice tone="danger">{friendlyError(record.error ?? remove.error)}</Notice>}
        </>
      )}
    </Card>
  );
}
