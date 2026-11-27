// -------------------------------------------------------------------------------------
// Year plan (migration 37, decisions of 27 Nov 2026). Every project is put to the church
// leadership and approved alongside the year's other projects; extra projects can still be
// approved during the year. This page shows one year's plan in one place:
//   * goal-based projects (church, purpose or team level), decided by the Resident Pastor with
//     the leadership: waiting, approved, under way, done;
//   * events and routine activities, month by month, with their status (their approvers are
//     unchanged: the Purpose Head for team events, the Operations Lead for church events).
// Projects are read across the church (row-level security), so this page only arranges them.
// Approval itself happens on each project's page, where the database checks it.
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { byId, useLeaders, usePurposes, useUnits } from '../../data/reference';
import { isoToLondon, STATUS_LABEL, STATUS_TONE, useProjects, type Project } from '../../data/projects';

const { SectionHeading, Card, Notice, DataTable, Chip, StatTile } = TEC;

// Does a project run in this (London) year at all?
const inYear = (p: Pick<Project, 'starts_at' | 'ends_at'>, year: number) =>
  isoToLondon(p.starts_at).date.slice(0, 4) <= String(year) && isoToLondon(p.ends_at).date.slice(0, 4) >= String(year);

export function YearPlan() {
  const projects = useProjects();
  const units = useUnits();
  const purposes = usePurposes();
  const leaders = useLeaders();
  const [thisYear] = useState(() => Number(isoToLondon(new Date().toISOString()).date.slice(0, 4)));
  // From October the leadership is planning next year (the retreat is in December), so open on it.
  const [year, setYear] = useState(() => {
    const d = isoToLondon(new Date().toISOString()).date;
    return Number(d.slice(5, 7)) >= 10 ? Number(d.slice(0, 4)) + 1 : Number(d.slice(0, 4));
  });

  const unitMap = byId(units.data);
  const purposeMap = byId(purposes.data);
  const leaderMap = byId(leaders.data);
  const all = (projects.data ?? []).filter((p) => inYear(p, year) && p.status !== 'cancelled');
  const goals = all.filter((p) => p.is_goal);
  const others = all.filter((p) => !p.is_goal);
  const where = (p: Project) =>
    p.purpose_id ? (purposeMap.get(p.purpose_id)?.name ?? 'Purpose') : p.level === 'church' ? 'Church' : (unitMap.get(p.unit_id ?? '')?.name ?? 'Team');
  const status = (p: Project) => <Chip tone={STATUS_TONE[p.status]}>{STATUS_LABEL[p.status]}</Chip>;

  // Events and activities by the month they start in.
  const byMonth = new Map<string, Project[]>();
  for (const p of others) {
    const m = isoToLondon(p.starts_at).date.slice(0, 7);
    byMonth.set(m, [...(byMonth.get(m) ?? []), p]);
  }
  const monthLabel = (m: string) => new Date(`${m}-01T12:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });

  return (
    <>
      <SectionHeading eyebrow="Projects and events" title={`Year plan ${year}`} rule>
        Every project is put to the leadership and approved alongside the year&rsquo;s other projects. Goal-based projects are decided by the
        Resident Pastor with the leadership; events keep their approvers.
      </SectionHeading>
      <div className="tec-row" style={{ padding: 0 }}>
        <label className="tec-field" htmlFor="yp-year">
          <span>Year</span>
          <select id="yp-year" className="tec-input" value={year} onChange={(e) => setYear(Number(e.target.value))}>
            {[thisYear - 1, thisYear, thisYear + 1, thisYear + 2].map((y) => (
              <option key={y} value={y}>
                {y}
              </option>
            ))}
          </select>
        </label>
        <Link to="/projects/new">New project</Link>
      </div>
      {projects.isPending && <p>Loading…</p>}
      {projects.error && <Notice tone="danger">{friendlyError(projects.error)}</Notice>}
      {projects.data && (
        <>
          <div className="tec-stats">
            <StatTile label="Goal-based projects waiting" value={goals.filter((p) => p.status === 'submitted').length} />
            <StatTile label="Goal-based projects approved or under way" value={goals.filter((p) => ['approved', 'in_progress'].includes(p.status)).length} />
            <StatTile label="Events and activities" value={others.length} />
          </div>
          <Card title={`Goal-based projects (${goals.length})`}>
            {goals.length === 0 ? (
              <p style={{ margin: 0 }}>None for {year} yet.</p>
            ) : (
              <DataTable
                columns={[
                  { key: 'name', label: 'Project' },
                  { key: 'where', label: 'Level' },
                  { key: 'when', label: 'When' },
                  { key: 'owner', label: 'Owner' },
                  { key: 'status', label: 'Status' },
                ]}
                rows={goals.map((p) => ({
                  id: p.id,
                  name: <Link to={`/projects/${p.id}`}>{p.name}</Link>,
                  where: where(p),
                  // A goal-based project runs for months: its dates, not times.
                  when: `${isoToLondon(p.starts_at).date} to ${isoToLondon(p.ends_at).date}`,
                  owner: leaderMap.get(p.owner_user_id)?.display_name ?? '',
                  status: status(p),
                }))}
              />
            )}
          </Card>
          <Card title={`Events and activities (${others.length})`}>
            {others.length === 0 && <p style={{ margin: 0 }}>None for {year} yet.</p>}
            {[...byMonth.entries()].map(([m, list]) => (
              <details key={m}>
                <summary>
                  {monthLabel(m)} ({list.length})
                </summary>
                <ul>
                  {list.map((p) => (
                    <li key={p.id}>
                      <Link to={`/projects/${p.id}`}>{p.name}</Link> · {where(p)} · {p.is_event ? 'Event' : 'Routine activity'} · {STATUS_LABEL[p.status]}
                    </li>
                  ))}
                </ul>
              </details>
            ))}
          </Card>
        </>
      )}
    </>
  );
}
