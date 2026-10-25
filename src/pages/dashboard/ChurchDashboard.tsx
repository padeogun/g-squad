// -------------------------------------------------------------------------------------
// Church Dashboard: the leadership group's view of G-Squad as a whole. Totals only: no
// names or personal details beyond each leader's own scope (spec). Figures come from
// public.church_dashboard() (counts), the capacity calendar (shortfalls) and the outstanding
// project inputs list. Leaders without a dashboard role see the welcome page instead.
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { CAPACITY_ROLES, DASHBOARD_ROLES, shortfalls, useCapacity, useChurchDashboard, useOutstandingInputs } from '../../data/dashboards';
import { longDate, shortDate } from '../../data/sundays';
import { hasRole, useMe } from '../../auth/useMe';
import { GridStatus } from '../sunday/GridStatus';
import { EngagementBar } from './EngagementBar';
import { ShortfallsCard } from './Shortfalls';
import { FairShareCard, ServingRulesCard } from './FairShare';

const { SectionHeading, Card, Notice, StatTile, DataTable, Chip } = TEC;

export function ChurchDashboard() {
  const me = useMe();
  const allowed = hasRole(me.data, ...DASHBOARD_ROLES);
  // The capacity calendar has a narrower audience than the dashboard (R04).
  const seesCapacity = hasRole(me.data, ...CAPACITY_ROLES);
  const dash = useChurchDashboard(allowed);
  // Read once per visit (render must not read the clock directly).
  const [year] = useState(() => new Date().getFullYear());
  const capacity = useCapacity(year + 1, seesCapacity);
  const inputs = useOutstandingInputs(allowed);

  if (!allowed) return null; // the Home page shows the welcome instead
  if (dash.isPending) return <p>Loading…</p>;
  if (dash.error) return <Notice tone="danger">{friendlyError(dash.error)}</Notice>;
  const d = dash.data;
  const gaps = shortfalls(capacity.data ?? []);

  return (
    <>
      <SectionHeading eyebrow={longDate(d.as_of)} title="Church Dashboard" rule>
        Leadership group view: totals only, with no personal details beyond your own scope.
      </SectionHeading>

      <div className="tec-stats">
        <StatTile label="Volunteers" value={d.volunteers} note={`across ${d.units} units`} tone="brand" />
        <StatTile label="Team places" value={d.team_places} note={`${d.multi_unit} serve in 2+ units`} />
        <StatTile label="Units" value={d.units} note={`across ${d.purposes} purposes`} />
        <StatTile label="Active members" value={d.engagement.active} note="served 2+ times in 8 weeks" />
        <StatTile label="Over limit" value={d.over_limit} note="more hours than their monthly limit, across all serving" tone={d.over_limit ? 'danger' : 'default'} />
        <StatTile label="Check-ins open" value={d.checkins_open} note="flags only, no reasons" />
        <StatTile
          label="Inputs overdue"
          value={d.inputs_overdue}
          note={`of ${d.inputs_outstanding} outstanding`}
          tone={d.inputs_overdue ? 'danger' : 'default'}
        />
      </div>

      <Card title="Engagement mix">
        <EngagementBar mix={d.engagement} />
      </Card>

      {/* Steps 3 to 5 (migration 30): fair share, rest and leaders' load. */}
      <FairShareCard month={d.as_of.slice(0, 7) + '-01'} />

      {/* Decision of 25 Oct 2026: volunteer shortfalls are always shown on the dashboard. */}
      <ShortfallsCard />

      {d.next_sunday && (
        <Card title={`Next Sunday · ${shortDate(d.next_sunday.service_date)}`}>
          <div className="tec-row" style={{ padding: 0 }}>
            <GridStatus grid={d.next_sunday} />
            <span>
              {d.next_sunday.units_needed} unit{d.next_sunday.units_needed === 1 ? '' : 's'} on the rota;{' '}
              {d.next_sunday.open_slots ? `${d.next_sunday.open_slots} slot${d.next_sunday.open_slots === 1 ? '' : 's'} still open.` : 'every slot filled.'}
            </span>
            <Link to={`/sundays/${d.next_sunday.grid_id}`}>Open the grid</Link>
          </div>
        </Card>
      )}

      <Card title="Units">
        {d.units_table.length === 0 ? (
          <p>
            No units yet. Add them under <Link to="/admin/forms/units">Reference forms</Link>.
          </p>
        ) : (
          <DataTable
            columns={[
              { key: 'unit', label: 'Unit' },
              { key: 'purpose', label: 'Purpose' },
              { key: 'head', label: 'Headcount', align: 'right' },
              { key: 'active', label: 'Active', align: 'right' },
              { key: 'open', label: 'Next 8 weeks' },
              { key: 'oto', label: 'One-to-ones this quarter', align: 'right' },
            ]}
            rows={d.units_table.map((u) => ({
              id: u.unit_id,
              unit: u.name,
              purpose: u.purpose ?? '–',
              head: u.target ? `${u.headcount} / ${u.target}` : String(u.headcount),
              active: String(u.active),
              open: u.open_8_weeks ? <Chip tone="warn">{u.open_8_weeks} unfilled</Chip> : <Chip tone="ok">Covered</Chip>,
              // Null = not this leader's to see (R01); say so rather than show a 0.
              oto:
                u.one_to_ones_quarter === null ? (
                  <span className="type-caption">Not shown to your role</span>
                ) : (
                  `${u.one_to_ones_quarter} of ${u.headcount}`
                ),
            }))}
          />
        )}
      </Card>

      <div className="app-card-grid">
        <Card title="Outstanding project inputs">
          {inputs.isPending && <p>Loading…</p>}
          {inputs.error && <Notice tone="danger">{friendlyError(inputs.error)}</Notice>}
          {inputs.data && inputs.data.length === 0 && <p>Nothing outstanding.</p>}
          {inputs.data && inputs.data.length > 0 && (
            <ul className="app-candidates">
              {inputs.data.map((i) => (
                <li key={i.id!}>
                  <span>
                    <strong>{i.project}</strong> · {i.title}
                    <span className="type-caption"> owed by {i.owedBy}, due {shortDate(i.due_on!)}</span>
                  </span>
                  {i.display_status === 'overdue' ? <Chip tone="danger">Overdue</Chip> : <Chip tone="neutral">Requested</Chip>}
                </li>
              ))}
            </ul>
          )}
        </Card>
        {seesCapacity && (
          <Card title={`${year + 1} shortfalls`} action={<Link to="/capacity">Capacity calendar</Link>}>
            {capacity.isPending && <p>Loading…</p>}
            {capacity.error && <Notice tone="danger">{friendlyError(capacity.error)}</Notice>}
            {capacity.data && gaps.size === 0 && <p>No unit is short in any month of {year + 1} on current plans.</p>}
            {gaps.size > 0 && (
              <ul className="app-candidates">
                {[...gaps].map(([unit, months]) => (
                  <li key={unit}>
                    <strong>{unit}</strong>
                    <span>{months.join(', ')}</span>
                  </li>
                ))}
              </ul>
            )}
          </Card>
        )}
      </div>
      <ServingRulesCard />
    </>
  );
}
