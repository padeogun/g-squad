// -------------------------------------------------------------------------------------
// Projects and events: every project and event in the church (Sunday services are under
// Sunday Operations), soonest first. At the top: inputs asked of this leader, and projects
// waiting for their decision (the Resident Pastor for church projects, a Purpose Head for
// units in their purpose). Anyone who may create projects sees "New project"; the database
// decides who may create which (projects_insert, migration 7).
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { byId, useLeaders, useUnits } from '../../data/reference';
import { formatWhen, PROJECT_CREATORS, STATUS_LABEL, STATUS_TONE, useMyInputs, useProjects, useProjectTypes, type Project } from '../../data/projects';
import { shortDate, todayIso } from '../../data/sundays';
import { hasRole, useMe } from '../../auth/useMe';

const { SectionHeading, Card, Notice, DataTable, Chip, SelectField } = TEC;

export function Projects() {
  const me = useMe();
  const projects = useProjects();
  const units = useUnits();
  const types = useProjectTypes();
  const leaders = useLeaders();
  const mine = useMyInputs(me.data?.id);
  const [show, setShow] = useState('coming');
  const [today] = useState(todayIso);

  const unitMap = byId(units.data);
  const typeMap = byId(types.data);
  const leaderMap = byId(leaders.data);
  const projectMap = byId(projects.data);

  // Waiting for my decision: submitted church projects for the Resident Pastor; submitted unit
  // projects in a purpose I head. (A courtesy list; the database checks the approval itself.)
  const myPurposes = (me.data?.roles ?? []).filter((r) => r.role === 'purpose_head').map((r) => r.purpose_id);
  const isRp = hasRole(me.data, 'resident_pastor');
  const awaiting = (projects.data ?? []).filter(
    (p) =>
      p.status === 'submitted' &&
      ((p.level === 'church' && isRp) || (p.level === 'unit' && myPurposes.includes(unitMap.get(p.unit_id ?? '')?.purpose_id ?? null))),
  );

  const isPast = (p: Project) => p.status === 'done' || p.status === 'cancelled' || p.ends_at.slice(0, 10) < today;
  const list = (projects.data ?? []).filter((p) =>
    show === 'coming' ? !isPast(p)
    : show === 'mine' ? p.owner_user_id === me.data?.id
    : show === 'past' ? isPast(p)
    : true,
  );
  const ordered = show === 'past' ? [...list].reverse() : list;

  const table = (rows: Project[]) => (
    <DataTable
      columns={[
        { key: 'name', label: 'Project' },
        { key: 'when', label: 'When' },
        { key: 'level', label: 'For' },
        { key: 'owner', label: 'Owner' },
        { key: 'status', label: 'Status' },
      ]}
      rows={rows.map((p) => ({
        id: p.id,
        name: (
          <span>
            <Link to={`/projects/${p.id}`}>{p.name}</Link>
            {p.type_id && <span className="type-caption"> · {typeMap.get(p.type_id)?.name}</span>}
          </span>
        ),
        when: formatWhen(p.starts_at, p.ends_at),
        level: p.level === 'church' ? 'Whole church' : unitMap.get(p.unit_id ?? '')?.name ?? 'A unit',
        owner: leaderMap.get(p.owner_user_id)?.display_name ?? '–',
        status: <Chip tone={STATUS_TONE[p.status]}>{STATUS_LABEL[p.status]}</Chip>,
      }))}
    />
  );

  return (
    <>
      <SectionHeading eyebrow="Sundays and events" title="Projects and events" rule>
        Events and projects that need volunteers, from draft to approved and done. Sunday services are under Sunday
        Operations.
      </SectionHeading>

      {mine.data && mine.data.length > 0 && (
        <Card title="Requested from you">
          <ul className="app-candidates">
            {mine.data.map((i) => (
              <li key={i.id!}>
                <span>
                  <Link to={`/projects/${i.project_id}#inputs`}>{i.title}</Link>
                  <span className="type-caption"> · {projectMap.get(i.project_id!)?.name ?? 'a project'}, due {shortDate(i.due_on!)}</span>
                </span>
                {i.display_status === 'overdue' ? <Chip tone="danger">Overdue</Chip> : <Chip tone="neutral">Requested</Chip>}
              </li>
            ))}
          </ul>
        </Card>
      )}

      {awaiting.length > 0 && <Card title="Waiting for your decision">{table(awaiting)}</Card>}

      <Card
        title="Projects"
        action={
          <span className="app-inline-row">
            <SelectField
              id="projects-show"
              label="Show"
              className="app-inline-select"
              value={show}
              onChange={(e) => setShow(e.target.value)}
              options={[
                { value: 'coming', label: 'Coming up' },
                { value: 'mine', label: 'Mine' },
                { value: 'past', label: 'Past, done or cancelled' },
                { value: 'all', label: 'All' },
              ]}
            />
            {hasRole(me.data, ...PROJECT_CREATORS) && (
              <Link to="/projects/new" className="tec-btn tec-btn-primary tec-btn-sm">
                New project
              </Link>
            )}
          </span>
        }
      >
        {projects.isPending && <p>Loading…</p>}
        {projects.error && <Notice tone="danger">{friendlyError(projects.error)}</Notice>}
        {projects.data && ordered.length === 0 && <p>Nothing to show.</p>}
        {ordered.length > 0 && table(ordered)}
      </Card>
    </>
  );
}
