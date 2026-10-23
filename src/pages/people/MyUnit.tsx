// -------------------------------------------------------------------------------------
// My Unit: a Unit Lead's view of their team. Lists the unit's live members with their team
// role, leader flag and leadership stage, and lets the lead change those three in place.
// A lead of several units picks one at the top. Other roles see a short explanation.
// Slice 3 adds the unit dashboard (public.unit_dashboard): headline tiles, the engagement mix,
// the leadership pipeline and, per member, slots this month, engagement, holiday and last
// one-to-one. Those figures are checked in the database to be this unit's lead (or seniors).
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
import { useUnitDashboard } from '../../data/dashboards';
import { shortDate } from '../../data/sundays';
import { EngagementBar } from '../dashboard/EngagementBar';

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
  const dash = useUnitDashboard(unitId);
  // person_id -> that member's unit figures (absent while loading or if the call failed).
  const figures = new Map((dash.data?.members ?? []).map((m) => [m.person_id, m]));

  const team = (memberships.data ?? [])
    .filter((m) => m.unit_id === unitId)
    .sort((a, b) => (personMap.get(a.person_id)?.surname ?? '').localeCompare(personMap.get(b.person_id)?.surname ?? ''));

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
      {dash.isPending && <p>Loading unit figures…</p>}
      {dash.error && (
        <Notice tone="danger" title="Unit figures could not be loaded">
          {friendlyError(dash.error)}
        </Notice>
      )}
      {dash.data && (
        <>
          <div className="tec-stats">
            <StatTile
              label="Headcount"
              value={target ? `${dash.data.headcount} / ${target}` : dash.data.headcount}
              note={target ? 'of the target headcount' : 'no target set'}
              tone="brand"
            />
            <StatTile label="Active" value={dash.data.engagement.active} note="served 2+ times in 8 weeks" />
            <StatTile
              label="Next 8 weeks"
              value={dash.data.open_8_weeks}
              note="slots still unfilled"
              tone={dash.data.open_8_weeks ? 'danger' : 'default'}
            />
            {/* Only one-to-ones this leader may read (the ones they wrote; R01). */}
            {dash.data.one_to_ones_visible && (
              <StatTile label="One-to-ones" value={dash.data.one_to_ones_quarter ?? 0} note={`yours this quarter, of ${dash.data.headcount}`} />
            )}
            <StatTile label="Check-ins raised" value={dash.data.checkins_open} note="open, needing a conversation" />
          </div>
          <div className="app-card-grid">
            <Card title="Engagement mix">
              <EngagementBar mix={dash.data.engagement} />
            </Card>
            <Card title="Leadership pipeline">
              {dash.data.pipeline.length === 0 ? (
                <p>No leadership stages recorded yet.</p>
              ) : (
                <ul className="app-candidates">
                  {dash.data.pipeline.map((s) => (
                    <li key={s.stage}>
                      <span>{s.stage}</span>
                      <strong>{s.count}</strong>
                    </li>
                  ))}
                </ul>
              )}
            </Card>
          </div>
        </>
      )}
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
              { key: 'slots', label: 'Slots this month', align: 'right' },
              { key: 'engagement', label: 'Engagement' },
              { key: 'holiday', label: 'Holiday' },
              { key: 'oto', label: 'Your last one-to-one' },
            ]}
            rows={team.map((m) => {
              const p = personMap.get(m.person_id);
              const name = p ? fullName(p) : 'Member';
              const f = figures.get(m.person_id);
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
                // Over the member's own limit shows as a warning: R-limits protect volunteers.
                slots: f ? (
                  f.slots_this_month > f.slot_limit ? (
                    <Chip tone="danger">{`${f.slots_this_month} / ${f.slot_limit}`}</Chip>
                  ) : (
                    `${f.slots_this_month} / ${f.slot_limit}`
                  )
                ) : (
                  '–'
                ),
                engagement: f ? ENGAGEMENT_LABELS[f.engagement] : '–',
                holiday: f?.holiday_from ? `${shortDate(f.holiday_from)} – ${shortDate(f.holiday_to ?? f.holiday_from)}` : '–',
                // '–' while the figures are missing (loading or refused), so an error never reads
                // as "no one-to-one held"; 'None yet' only when the database says so (R05).
                oto: !f ? '–' : f.last_one_to_one ? shortDate(f.last_one_to_one) : 'None yet',
              };
            })}
          />
        )}
      </Card>
    </>
  );
}

// Plain-English engagement labels (the database returns the v_engagement codes).
const ENGAGEMENT_LABELS: Record<string, string> = {
  active: 'Active',
  occasional: 'Occasional',
  new: 'New',
  inactive: 'Inactive',
  paused: 'Paused',
  left: 'Left',
};
