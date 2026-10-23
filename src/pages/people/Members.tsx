// -------------------------------------------------------------------------------------
// G-Squad Members: everyone this leader may see (row-level security decides: a Unit Lead
// sees their own unit's members), with their units and team roles, and a search box.
// -------------------------------------------------------------------------------------
import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { byId, useChurchRoles, useUnits } from '../../data/reference';
import { fullName, useMemberships, usePeople } from '../../data/people';
import { hasRole, useMe } from '../../auth/useMe';

const { SectionHeading, Card, TextField, Chip, Notice, DataTable, StatTile } = TEC;

const STATUS_CHIP = {
  active: <Chip tone="ok">Active</Chip>,
  paused: <Chip tone="warn">Paused</Chip>,
  left: <Chip tone="neutral">Left</Chip>,
} as const;

export function Members() {
  const me = useMe();
  const people = usePeople();
  const memberships = useMemberships();
  const unitMap = byId(useUnits().data);
  const roleMap = byId(useChurchRoles().data);
  const [query, setQuery] = useState('');
  // Team Leads, the Operations Lead and the G-Squad Coordinator add members, one at a time or
  // by uploading a spreadsheet (people_insert policy, migration 23).
  const canAdd = hasRole(me.data, 'unit_lead', 'operations_lead', 'gsquad_coordinator');

  // Each person's live memberships, as "Production · Camera (lead)" labels.
  const unitsByPerson = useMemo(() => {
    const m = new Map<string, string[]>();
    for (const ms of memberships.data ?? []) {
      const label =
        (unitMap.get(ms.unit_id)?.name ?? 'Unit') +
        (ms.church_role_id ? ` · ${roleMap.get(ms.church_role_id)?.name ?? ''}` : '') +
        (ms.is_team_leader ? ' (lead)' : '') +
        (ms.status === 'pending_approval' ? ' – awaiting approval' : '');
      m.set(ms.person_id, [...(m.get(ms.person_id) ?? []), label]);
    }
    return m;
  }, [memberships.data, unitMap, roleMap]);

  // Search by name, email, area or unit, ignoring case.
  const q = query.trim().toLowerCase();
  const shown = (people.data ?? []).filter((p) =>
    !q
      ? true
      : [fullName(p), p.other_names, p.email, p.area, ...(unitsByPerson.get(p.id) ?? [])]
          .filter(Boolean)
          .some((s) => s!.toLowerCase().includes(q)),
  );
  const active = (people.data ?? []).filter((p) => p.status === 'active').length;

  return (
    <>
      <SectionHeading eyebrow="People and Teams" title="G-Squad members" rule />
      <div className="tec-stats">
        <StatTile label="Members you can see" value={people.data?.length ?? '–'} />
        <StatTile label="Active" value={people.data ? active : '–'} tone="brand" />
      </div>

      <Card
        title="Members"
        action={
          canAdd ? (
            <span className="app-inline-row">
              <Link to="/members/import" className="tec-btn tec-btn-secondary tec-btn-sm">
                Upload members
              </Link>
              <Link to="/members/new" className="tec-btn tec-btn-primary tec-btn-sm">
                Add a member
              </Link>
            </span>
          ) : undefined
        }
      >
        <TextField
          id="member-search"
          label="Search"
          hint="name, email, area or unit"
          type="search"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        {people.isPending && <p>Loading…</p>}
        {people.error && <Notice tone="danger">{friendlyError(people.error)}</Notice>}
        {people.data && shown.length === 0 && <p>{q ? 'No one matches that search.' : 'No members yet.'}</p>}
        {shown.length > 0 && (
          <DataTable
            columns={[
              { key: 'name', label: 'Name' },
              { key: 'units', label: 'Units and roles' },
              { key: 'area', label: 'Area' },
              { key: 'status', label: 'Status' },
              { key: 'open', label: '' },
            ]}
            rows={shown.map((p) => ({
              id: p.id,
              name: fullName(p),
              units: (unitsByPerson.get(p.id) ?? []).join(', ') || <span className="type-caption">No unit</span>,
              area: p.area ?? '',
              status: STATUS_CHIP[p.status],
              open: <Link to={`/members/${p.id}`}>Open</Link>,
            }))}
          />
        )}
      </Card>
    </>
  );
}
