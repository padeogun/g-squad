// -------------------------------------------------------------------------------------
// "Taking part this quarter" on My Unit (migration 36, decision of 27 Nov 2026): how many of
// the team's members attended events (prayer, Bible study and discipleship among them),
// served at events (not Sundays), or sat on a planning committee. Counts only, never names;
// the database checks who may see the team (team_engagement).
// -------------------------------------------------------------------------------------
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { useTeamEngagement } from '../../data/attendance';

const { Card, Notice } = TEC;

export function TeamEngagementCard({ unitId }: { unitId: string }) {
  const e = useTeamEngagement(unitId);
  if (e.error) return <Notice tone="danger">{friendlyError(e.error)}</Notice>;
  if (!e.data) return null;
  const t = e.data;
  const of = (n: number) => `${n} of ${t.members}`;
  return (
    <Card title="Taking part this quarter">
      <dl className="app-focus-counts">
        <div>
          <dt>Attended an event</dt>
          <dd>{of(t.attended)}</dd>
        </div>
        <div>
          <dt>Attended prayer, Bible study or discipleship</dt>
          <dd>{of(t.attended_maturity)}</dd>
        </div>
        <div>
          <dt>Served at an event (not Sundays)</dt>
          <dd>{of(t.served)}</dd>
        </div>
        <div>
          <dt>On a planning committee</dt>
          <dd>{of(t.on_committees)}</dd>
        </div>
      </dl>
      <p className="type-caption" style={{ margin: 0 }}>
        From event check-ins, the rota and planning committees. Counts only, never names or scores.
      </p>
    </Card>
  );
}
