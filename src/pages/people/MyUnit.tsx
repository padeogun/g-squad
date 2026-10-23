// -------------------------------------------------------------------------------------
// My Unit: a Unit Lead's view of their team. Lists the unit's live members with their team
// role, leader flag and leadership stage, and lets the lead change those three in place.
// A lead of several units picks one at the top. Other roles see a short explanation.
// (Unit dashboard figures, availability and holidays come in later slices.)
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, useChurchRoles, useLeadershipStages, useUnits } from '../../data/reference';
import { fullName, useMemberships, usePeople, type Membership } from '../../data/people';
import { ledUnitIds, useMe } from '../../auth/useMe';

const { SectionHeading, Card, SelectField, Checkbox, Notice, DataTable, StatTile, Chip } = TEC;

export function MyUnit() {
  const me = useMe();
  const units = useUnits();
  const myUnits = ledUnitIds(me.data);
  const [chosen, setChosen] = useState<string>('');
  // Default to the first unit they lead.
  const unitId = chosen || myUnits[0] || '';
  const unit = byId(units.data).get(unitId);

  if (me.isPending) return <p>Loading…</p>;
  if (myUnits.length === 0)
    return (
      <>
        <SectionHeading eyebrow="Overview" title="My Unit" rule />
        <Notice tone="info" title="For Unit Leads">
          My Unit shows a Unit Lead their team. You don't lead a unit; see <Link to="/members">G-Squad members</Link> instead.
        </Notice>
      </>
    );

  return (
    <>
      <SectionHeading eyebrow="Overview" title={unit ? `My Unit: ${unit.name}` : 'My Unit'} rule>
        {unit?.objectives ?? undefined}
      </SectionHeading>
      {myUnits.length > 1 && (
        <SelectField
          id="my-unit-pick"
          label="Unit"
          value={unitId}
          onChange={(e) => setChosen(e.target.value)}
          options={myUnits.map((id) => ({ value: id, label: byId(units.data).get(id)?.name ?? 'Unit' }))}
        />
      )}
      {unitId && <Team key={unitId} unitId={unitId} target={unit?.target_headcount ?? null} />}
    </>
  );
}

function Team({ unitId, target }: { unitId: string; target: number | null }) {
  const qc = useQueryClient();
  const people = usePeople();
  const memberships = useMemberships();
  const roles = useChurchRoles();
  const stages = useLeadershipStages();
  const personMap = byId(people.data);

  const team = (memberships.data ?? [])
    .filter((m) => m.unit_id === unitId)
    .sort((a, b) => (personMap.get(a.person_id)?.surname ?? '').localeCompare(personMap.get(b.person_id)?.surname ?? ''));
  const active = team.filter((m) => m.status === 'active' && personMap.get(m.person_id)?.status === 'active').length;

  // Change one membership's role, leader flag or stage. The database checks it is this unit's lead.
  const update = useMutation({
    mutationFn: async ({ id, patch }: { id: string; patch: Partial<Membership> }) => {
      const { error } = await supabase.from('unit_memberships').update(patch).eq('id', id).select('id').single();
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['memberships'] }),
  });

  const roleOptions = [
    { value: '', label: 'None' },
    ...(roles.data ?? []).filter((r) => r.is_active && (!r.unit_id || r.unit_id === unitId)).map((r) => ({ value: r.id, label: r.name })),
  ];
  const stageOptions = [{ value: '', label: 'None' }, ...(stages.data ?? []).map((s) => ({ value: s.id, label: s.name }))];

  return (
    <>
      <div className="tec-stats">
        <StatTile label="Team members" value={team.length} />
        <StatTile label="Active" value={active} tone="brand" note={target ? `Target ${target}` : undefined} />
      </div>
      {update.isError && (
        <Notice tone="danger" title="That change wasn't made">
          {friendlyError(update.error)}
        </Notice>
      )}
      <Card
        title="Team"
        action={
          <Link to="/members/new" className="tec-btn tec-btn-primary tec-btn-sm">
            Add a member
          </Link>
        }
      >
        {(people.isPending || memberships.isPending) && <p>Loading…</p>}
        {(people.error || memberships.error) && <Notice tone="danger">{friendlyError(people.error ?? memberships.error)}</Notice>}
        {memberships.data && team.length === 0 && <p>No one in this unit yet.</p>}
        {team.length > 0 && (
          <DataTable
            columns={[
              { key: 'name', label: 'Name' },
              { key: 'role', label: 'Team role' },
              { key: 'stage', label: 'Leadership stage' },
              { key: 'lead', label: 'Team leader' },
            ]}
            rows={team.map((m) => {
              const p = personMap.get(m.person_id);
              const name = p ? fullName(p) : 'Member';
              return {
                id: m.id,
                name: (
                  <span>
                    <Link to={`/members/${m.person_id}`}>{name}</Link>
                    {m.status === 'pending_approval' && <Chip tone="warn">Awaiting approval</Chip>}
                    {p?.status === 'paused' && <Chip tone="warn">Paused</Chip>}
                  </span>
                ),
                role: (
                  <SelectField
                    id={`role-${m.id}`}
                    label={`Team role for ${name}`}
                    className="app-cell-field"
                    value={m.church_role_id ?? ''}
                    disabled={update.isPending}
                    options={roleOptions}
                    onChange={(e) => update.mutate({ id: m.id, patch: { church_role_id: e.target.value || null } })}
                  />
                ),
                stage: (
                  <SelectField
                    id={`stage-${m.id}`}
                    label={`Leadership stage for ${name}`}
                    className="app-cell-field"
                    value={m.leadership_stage_id ?? ''}
                    disabled={update.isPending}
                    options={stageOptions}
                    onChange={(e) => update.mutate({ id: m.id, patch: { leadership_stage_id: e.target.value || null } })}
                  />
                ),
                lead: (
                  <Checkbox
                    id={`lead-${m.id}`}
                    label={`Team leader`}
                    aria-label={`${name} is a team leader`}
                    checked={m.is_team_leader}
                    disabled={update.isPending}
                    onChange={(e) => update.mutate({ id: m.id, patch: { is_team_leader: e.target.checked } })}
                  />
                ),
              };
            })}
          />
        )}
      </Card>
    </>
  );
}
