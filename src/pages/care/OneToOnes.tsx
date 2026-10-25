// -------------------------------------------------------------------------------------
// One-to-ones: for a team and a quarter, who has had their one-to-one and who hasn't. The
// Team Lead records them (one per member per quarter); the team's Purpose Head, the G-Squad
// Coordinator and the Resident Pastor read them. The Deputy Team Lead does not see one-to-ones.
// Below: Values in Action for the team this quarter, counted by value (never per person, R20).
// The G-Squad Coordinator and Resident Pastor also manage the leadership's questions.
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { byId, useUnits } from '../../data/reference';
import { useMemberships, usePersonNames } from '../../data/people';
import { shortDate, todayIso } from '../../data/sundays';
import { FEELINGS, quarterEnd, quarterLabel, recentQuarters, SUPPORT, useOneToOnes, useValueCounts } from '../../data/oneToOnes';
import { hasRole, ledUnitIds, useMe } from '../../auth/useMe';

const { SectionHeading, Card, Notice, DataTable, Chip, SelectField, StatTile } = TEC;

export function OneToOnes() {
  const me = useMe();
  const units = useUnits();
  const [today] = useState(todayIso);
  const quarters = recentQuarters(today, 4);
  const [quarter, setQuarter] = useState(quarters[0]);
  const [chosen, setChosen] = useState('');

  const led = ledUnitIds(me.data);
  const wide = hasRole(me.data, 'gsquad_coordinator', 'resident_pastor');
  const myPurposes = (me.data?.roles ?? []).filter((r) => r.role === 'purpose_head').map((r) => r.purpose_id);
  // Teams this leader may see one-to-ones for: those they lead first, then their purposes' units, or all.
  const scope = (units.data ?? []).filter((u) => u.is_active && (wide || led.includes(u.id) || myPurposes.includes(u.purpose_id)));
  const ordered = [...scope.filter((u) => led.includes(u.id)), ...scope.filter((u) => !led.includes(u.id))];
  const unitId = chosen || ordered[0]?.id || '';
  const canWrite = led.includes(unitId);

  if (me.isPending || units.isPending) return <p>Loading…</p>;
  if (ordered.length === 0)
    return (
      <>
        <SectionHeading eyebrow="Care and growth" title="One-to-ones" rule />
        <Notice tone="info">
          One-to-ones are held by each Team Lead with their team, and read by the team's Purpose Head, the G-Squad Coordinator and
          the Resident Pastor.
        </Notice>
      </>
    );

  return (
    <>
      <SectionHeading eyebrow="Care and growth" title="One-to-ones" rule>
        Once a quarter, each member and their Team Lead talk about the ASHLIE values, belonging, their role and their walk with
        God. Values are recognised, never scored.
      </SectionHeading>
      {wide && (
        <p style={{ margin: 0 }}>
          <Link to="/one-to-ones/questions">Leadership questions</Link>
        </p>
      )}
      <div className="tec-row" style={{ padding: 0 }}>
        <SelectField
          id="oto-unit"
          label="Team"
          value={unitId}
          onChange={(e) => setChosen(e.target.value)}
          options={ordered.map((u) => ({ value: u.id, label: led.includes(u.id) ? u.name : `${u.name} (view only)` }))}
        />
        <SelectField id="oto-quarter" label="Quarter" value={quarter} onChange={(e) => setQuarter(e.target.value)} options={quarters.map((q) => ({ value: q, label: quarterLabel(q) }))} />
      </div>
      {unitId && <TeamQuarter key={`${unitId}-${quarter}`} unitId={unitId} unitName={byId(units.data).get(unitId)?.name ?? 'Team'} quarter={quarter} canWrite={canWrite} isCurrent={quarter === quarters[0]} />}
    </>
  );
}

function TeamQuarter({ unitId, unitName, quarter, canWrite, isCurrent }: { unitId: string; unitName: string; quarter: string; canWrite: boolean; isCurrent: boolean }) {
  const memberships = useMemberships();
  const otos = useOneToOnes(unitId, quarter);
  const counts = useValueCounts(unitId, quarter, quarterEnd(quarter));
  const team = (memberships.data ?? []).filter((m) => m.unit_id === unitId && m.status !== 'ended');
  const names = usePersonNames(team.map((m) => m.person_id));
  const nameMap = byId(names.data);
  const byPerson = new Map((otos.data ?? []).map((o) => [o.person_id, o]));
  const held = team.filter((m) => byPerson.has(m.person_id)).length;

  const sorted = [...team].sort((a, b) => (nameMap.get(a.person_id)?.surname ?? '').localeCompare(nameMap.get(b.person_id)?.surname ?? ''));

  return (
    <>
      <div className="tec-stats" style={{ padding: 0 }}>
        <StatTile label="Held this quarter" value={otos.data ? held : '–'} note={`of ${team.length} in ${unitName}`} tone="brand" />
        <StatTile label="Still to hold" value={otos.data ? team.length - held : '–'} tone={otos.data && team.length - held > 0 && isCurrent ? 'danger' : 'default'} />
      </div>
      <Card title={`${unitName} · ${quarterLabel(quarter)}`}>
        {(memberships.isPending || otos.isPending) && <p>Loading…</p>}
        {(memberships.error || otos.error) && <Notice tone="danger">{friendlyError(memberships.error ?? otos.error)}</Notice>}
        {memberships.data && team.length === 0 && <p>No one in this team yet.</p>}
        {otos.data && team.length > 0 && (
          <DataTable
            columns={[
              { key: 'name', label: 'Member' },
              { key: 'held', label: 'One-to-one' },
              { key: 'feeling', label: 'Serving' },
              { key: 'support', label: 'Support needed' },
              { key: 'open', label: '' },
            ]}
            rows={sorted.map((m) => {
              const o = byPerson.get(m.person_id);
              const n = nameMap.get(m.person_id);
              const name = n ? `${n.first_name} ${n.surname}` : 'Member';
              return {
                id: m.id,
                name,
                held: o ? `Held ${shortDate(o.held_on)}` : <Chip tone={isCurrent ? 'warn' : 'neutral'}>Not yet</Chip>,
                feeling: o ? <Chip tone={o.feeling === 'overstretched' || o.feeling === 'finding_it_hard' ? 'warn' : 'ok'}>{FEELINGS.find((f) => f.value === o.feeling)?.label ?? o.feeling}</Chip> : '–',
                support: o ? SUPPORT.find((s) => s.value === o.support_needed)?.label : '–',
                open: o ? (
                  <Link to={`/one-to-ones/${o.id}`} aria-label={`Open ${name}'s one-to-one`}>
                    Open
                  </Link>
                ) : canWrite && isCurrent ? (
                  <Link to={`/one-to-ones/new?unit=${unitId}&person=${m.person_id}`} className="tec-btn tec-btn-secondary tec-btn-sm" aria-label={`Record ${name}'s one-to-one`}>
                    Record
                  </Link>
                ) : (
                  ''
                ),
              };
            })}
          />
        )}
        {!canWrite && <p className="type-caption" style={{ margin: 0 }}>View only: one-to-ones are recorded by the team's Team Lead.</p>}
      </Card>
      <Card title="Values in Action this quarter">
        <p className="type-caption" style={{ margin: 0 }}>
          Recognitions for {unitName}, counted by value. Values are recognised, never scored or compared between people.
        </p>
        {counts.error && <Notice tone="danger">{friendlyError(counts.error)}</Notice>}
        {counts.data && (
          <ul className="app-values-count">
            {counts.data.map((c) => (
              <li key={c.letter}>
                <span className="app-value-letter" aria-hidden="true">
                  {c.letter}
                </span>
                <span>{c.value_name}</span>
                <strong>{c.recognitions}</strong>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </>
  );
}
