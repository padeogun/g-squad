// -------------------------------------------------------------------------------------
// Sunday check-in, made for a phone: a Unit Lead marks who served and who didn't, for their
// unit, on the day. Served and no-show records feed engagement (active / inactive) and the
// monthly report. Defaults to today if it is a Sunday, otherwise the most recent Sunday.
// The database lets a Unit Lead change only their own unit's slots (assignments_update).
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, useChurchRoles, useUnits } from '../../data/reference';
import { fullName, usePeople } from '../../data/people';
import { longDate, todayIso } from '../../data/sundays';
import { useUnitAssignments, type Assignment } from '../../data/rota';
import { hasRole, ledUnitIds, useMe } from '../../auth/useMe';

const { SectionHeading, Card, Button, SelectField, Notice, TextField } = TEC;

// Today if it is a Sunday, otherwise the Sunday just gone (check-in is often done late).
function latestSunday(): string {
  const t = todayIso();
  const d = new Date(`${t}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() - d.getUTCDay());
  return d.toISOString().slice(0, 10);
}

export function CheckIn() {
  const me = useMe();
  const units = useUnits();
  const isOps = hasRole(me.data, 'operations_lead');
  const led = ledUnitIds(me.data);
  const choices = (units.data ?? []).filter((u) => u.is_active && (isOps || led.includes(u.id)));
  const [chosen, setChosen] = useState('');
  const unitId = chosen || choices[0]?.id || '';
  const [date, setDate] = useState(latestSunday);

  if (me.isPending || units.isPending) return <p>Loading…</p>;
  return (
    <div className="app-phone">
      <SectionHeading eyebrow="Sunday check-in" title={longDate(date)} rule />
      {choices.length === 0 ? (
        <Notice tone="info" title="For Unit Leads">
          Check-in is done by each unit's lead.
        </Notice>
      ) : (
        <>
          {choices.length > 1 && (
            <SelectField
              id="ci-unit"
              label="Unit"
              value={unitId}
              onChange={(e) => setChosen(e.target.value)}
              options={choices.map((u) => ({ value: u.id, label: u.name }))}
            />
          )}
          <TextField id="ci-date" label="Sunday" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          {unitId && <Team key={`${unitId}-${date}`} unitId={unitId} date={date} />}
        </>
      )}
    </div>
  );
}

function Team({ unitId, date }: { unitId: string; date: string }) {
  const qc = useQueryClient();
  const slots = useUnitAssignments(unitId, date, date);
  const people = usePeople();
  const roles = useChurchRoles();
  const personMap = byId(people.data);
  const roleMap = byId(roles.data);

  const mark = useMutation({
    mutationFn: async ({ id, status }: { id: string; status: Assignment['status'] }) => {
      const { error } = await supabase.from('assignments').update({ status }).eq('id', id).select('id').single();
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['assignments', unitId] }),
  });

  const list = slots.data ?? [];
  const served = list.filter((a) => a.status === 'served').length;

  return (
    <Card title={list.length ? `Who served (${served} of ${list.length})` : 'Who served'}>
      {slots.isPending && <p>Loading…</p>}
      {slots.error && <Notice tone="danger">{friendlyError(slots.error)}</Notice>}
      {slots.data && list.length === 0 && (
        <p>
          No one was on this unit's rota for that Sunday. <Link to="/rota">Open the rota</Link>
        </p>
      )}
      <ul className="app-checkin">
        {list.map((a) => {
          const p = personMap.get(a.person_id);
          const name = p ? fullName(p) : 'Member';
          return (
            <li key={a.id}>
              <span>
                <strong>{name}</strong>
                <span className="type-caption"> {a.church_role_id ? roleMap.get(a.church_role_id)?.name : 'Any role'}</span>
              </span>
              <span className="app-checkin-buttons" role="group" aria-label={`Check-in for ${name}`}>
                <Button
                  size="sm"
                  variant={a.status === 'served' ? 'primary' : 'secondary'}
                  aria-pressed={a.status === 'served'}
                  disabled={mark.isPending}
                  onClick={() => mark.mutate({ id: a.id, status: a.status === 'served' ? 'planned' : 'served' })}
                >
                  Served
                </Button>
                <Button
                  size="sm"
                  variant={a.status === 'no_show' ? 'primary' : 'secondary'}
                  aria-pressed={a.status === 'no_show'}
                  disabled={mark.isPending}
                  onClick={() => mark.mutate({ id: a.id, status: a.status === 'no_show' ? 'planned' : 'no_show' })}
                >
                  No-show
                </Button>
              </span>
            </li>
          );
        })}
      </ul>
      {mark.isError && <Notice tone="danger">{friendlyError(mark.error)}</Notice>}
    </Card>
  );
}
