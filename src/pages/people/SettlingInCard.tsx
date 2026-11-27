// -------------------------------------------------------------------------------------
// My Unit: the team's new members settling in (migration 34). Each shows how many of the
// eight steps are done, what is late or due next, and their buddy. The Team Lead ticks the
// steps on the member's record; the Deputy sees the same list. Read under the database's
// rules (the steps and pairings of members this leader can read).
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { fullName, useMemberships, usePeople, usePeopleNames } from '../../data/people';
import { shortDate, todayIso } from '../../data/sundays';
import { doneCount, isSettling, journeyFor, usePairings, useSteps } from '../../data/growth';

const { Card, Chip, Notice } = TEC;

export function SettlingInCard({ unitId }: { unitId: string }) {
  const [today] = useState(todayIso);
  const people = usePeople();
  const memberships = useMemberships();
  const names = usePeopleNames();
  const team = (people.data ?? []).filter(
    (p) => p.status === 'active' && (memberships.data ?? []).some((m) => m.person_id === p.id && m.unit_id === unitId && m.status !== 'ended'),
  );
  const ids = team.map((p) => p.id);
  const steps = useSteps(ids);
  const pairings = usePairings(ids);
  const nameOf = (id: string) => {
    const p = names.data?.find((x) => x.id === id);
    return p ? fullName(p) : 'another member';
  };

  const rows = team
    .map((p) => {
      const buddy = (pairings.data ?? []).find((x) => x.person_id === p.id && x.kind === 'buddy' && !x.ended_on);
      const mine = (steps.data ?? []).filter((s) => s.person_id === p.id);
      const items = journeyFor(p.date_joined, today, mine, !!buddy, !!p.greatness_community_id);
      return { p, buddy, items, recorded: mine.length };
    })
    .filter((r) => isSettling(r.p.date_joined, today, r.items, r.recorded))
    .sort((a, b) => b.p.date_joined.localeCompare(a.p.date_joined));

  if (people.isPending || memberships.isPending) return null;
  return (
    <Card title="New members settling in">
      {(steps.error || pairings.error) && <Notice tone="danger">{friendlyError(steps.error ?? pairings.error)}</Notice>}
      {rows.length === 0 && <p style={{ margin: 0 }}>No new members are settling in just now.</p>}
      {rows.length > 0 && (
        <ul className="app-journey">
          {rows.map(({ p, buddy, items }) => {
            const late = items.filter((i) => i.state === 'late');
            const next = items.find((i) => i.state === 'due');
            return (
              <li key={p.id}>
                <span style={{ display: 'grid', gap: 2, minWidth: 0 }}>
                  <Link to={`/members/${p.id}`}>{fullName(p)}</Link>
                  <span className="type-caption">
                    Joined {shortDate(p.date_joined)} · {buddy ? `buddy ${nameOf(buddy.mentor_person_id)}` : 'no buddy yet'}
                  </span>
                </span>
                <span className="app-journey-state">
                  <Chip tone={doneCount(items) === items.length ? 'ok' : 'app'}>{`${doneCount(items)} of ${items.length}`}</Chip>
                  {late.length > 0 && <Chip tone="warn">{`${late.length} late`}</Chip>}
                  {late.length === 0 && next && <span className="type-caption">Next: {next.label.toLowerCase()}</span>}
                </span>
              </li>
            );
          })}
        </ul>
      )}
    </Card>
  );
}
