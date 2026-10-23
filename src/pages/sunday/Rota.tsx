// -------------------------------------------------------------------------------------
// Sunday Rota: one unit, one month. Rows are the roles each Sunday's grid needs from the unit
// (team demand); columns are the month's Sundays. A Unit Lead fills a slot from "who can
// serve": the unit's active members, fewest slots this month first, with people on holiday
// or at their limit shown but not offered.
// The database checks every slot (migration 8): membership, holidays (R10) and one monthly
// limit across all units (R1/R2), which only the Operations Lead may go over, with a reason.
// -------------------------------------------------------------------------------------
import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, useChurchRoles, useUnits } from '../../data/reference';
import { fullName, usePersonNames } from '../../data/people';
import { shortDate, todayIso } from '../../data/sundays';
import { buildRota, monthBounds, useCandidates, useMonthSundays, useUnitAssignments, useUnitDemand, type RotaSlot } from '../../data/rota';
import { hasRole, ledUnitIds, useMe } from '../../auth/useMe';

const { SectionHeading, Card, Button, TextField, SelectField, Notice, Chip } = TEC;

// "2026-11" -> "November 2026".
const monthLabel = (m: string) =>
  new Date(`${m}-01T12:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });

// The month before or after "2026-11".
function shiftMonth(m: string, by: number): string {
  const [y, mo] = m.split('-').map(Number);
  const d = new Date(Date.UTC(y, mo - 1 + by, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
}

export function Rota() {
  const me = useMe();
  const units = useUnits();
  const isAdmin = hasRole(me.data, 'operations_lead', 'gsquad_coordinator');
  const led = ledUnitIds(me.data);
  // Units this leader can rota: all for the Operations Lead and Coordinator, otherwise those they lead.
  const choices = (units.data ?? []).filter((u) => u.is_active && (isAdmin || led.includes(u.id)));
  const [chosen, setChosen] = useState('');
  const unitId = chosen || choices[0]?.id || '';
  const [month, setMonth] = useState(() => todayIso().slice(0, 7));

  if (me.isPending || units.isPending) return <p>Loading…</p>;
  return (
    <>
      <SectionHeading eyebrow="Sundays and events" title="Sunday Rota" rule>
        Roles come from each Sunday's service grid. People on holiday or at their monthly limit aren't offered.
      </SectionHeading>
      {choices.length === 0 ? (
        <Notice tone="info" title="For Unit Leads">
          The rota is filled by each unit's lead. You don't lead a unit.
        </Notice>
      ) : (
        <>
          <div className="tec-row" style={{ padding: 0, alignItems: 'flex-end' }}>
            <SelectField
              id="rota-unit"
              label="Unit"
              value={unitId}
              onChange={(e) => setChosen(e.target.value)}
              options={choices.map((u) => ({ value: u.id, label: u.name }))}
            />
            <Button variant="quiet" size="sm" onClick={() => setMonth(shiftMonth(month, -1))}>
              ‹ Previous month
            </Button>
            <strong className="type-title">{monthLabel(month)}</strong>
            <Button variant="quiet" size="sm" onClick={() => setMonth(shiftMonth(month, 1))}>
              Next month ›
            </Button>
          </div>
          {unitId && (
            <MonthRota
              key={`${unitId}-${month}`}
              unitId={unitId}
              month={month}
              isOps={hasRole(me.data, 'operations_lead')}
              // SECURITY REVIEW FIX Q13: the Coordinator can view every unit's rota but the
              // database lets only the unit's lead and the Operations Lead change slots, so the
              // Coordinator is not offered buttons that would always fail.
              canEdit={hasRole(me.data, 'operations_lead') || led.includes(unitId)}
            />
          )}
        </>
      )}
    </>
  );
}

function MonthRota({ unitId, month, isOps, canEdit }: { unitId: string; month: string; isOps: boolean; canEdit: boolean }) {
  const qc = useQueryClient();
  const { from, to } = monthBounds(`${month}-01`);
  const sundays = useMonthSundays(`${month}-01`);
  const projectIds = (sundays.data ?? []).map((s) => s.project_id);
  const demand = useUnitDemand(unitId, projectIds);
  const assignments = useUnitAssignments(unitId, from, to);
  const roles = useChurchRoles();
  // SECURITY REVIEW FIX Q10: names of the people on this rota only (not everyone's records).
  const people = usePersonNames((assignments.data ?? []).map((a) => a.person_id));
  const roleMap = byId(roles.data);
  const personMap = byId(people.data);
  // The slot whose picker is open.
  const [picking, setPicking] = useState<RotaSlot | null>(null);

  const rows = useMemo(
    () => buildRota(sundays.data ?? [], demand.data ?? [], assignments.data ?? []),
    [sundays.data, demand.data, assignments.data],
  );

  // Cancelling a slot keeps it in history (status cancelled) and frees the person's limit.
  const cancel = useMutation({
    mutationFn: async (assignmentId: string) => {
      const { error } = await supabase.from('assignments').update({ status: 'cancelled' }).eq('id', assignmentId).select('id').single();
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['assignments', unitId] }),
  });

  if (sundays.isPending) return <p>Loading…</p>;
  // SECURITY REVIEW FIX Q12: a failed load is shown as a failure. Before, it looked like
  // "no Sundays" or like open slots, inviting a leader to book people who were already booked.
  const loadError = sundays.error ?? demand.error ?? assignments.error;
  if (loadError) return <Notice tone="danger" title="The rota could not be loaded">{friendlyError(loadError)}</Notice>;
  if ((sundays.data ?? []).length === 0)
    return (
      <Notice tone="info" title="No Sundays set up this month">
        The Operations Lead sets up each Sunday under <Link to="/sundays">Sunday Operations</Link>.
      </Notice>
    );

  const open = rows.reduce((n, r) => n + [...r.cells.values()].filter((c) => !c.assignment).length, 0);

  return (
    <>
      <Card title={open ? `Rota · ${open} open slot${open === 1 ? '' : 's'}` : 'Rota · all slots filled'}>
        {rows.length === 0 ? (
          <p>The service grids don't ask this unit for anyone this month yet.</p>
        ) : (
          <div className="tec-table-wrap">
            <table className="tec-table app-rota">
              <thead>
                <tr>
                  <th scope="col">Role</th>
                  {(sundays.data ?? []).map((s) => (
                    <th scope="col" key={s.service_date}>
                      {shortDate(s.service_date)}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={`${r.roleId}-${r.slotNo}`}>
                    <th scope="row">
                      {r.roleId ? roleMap.get(r.roleId)?.name ?? 'Role' : 'Any role'}
                      {r.slotNo > 1 && <span className="type-caption"> ({r.slotNo})</span>}
                    </th>
                    {(sundays.data ?? []).map((s) => {
                      const cell = r.cells.get(s.service_date);
                      if (!cell) return <td key={s.service_date} className="app-rota-none" aria-label="Not needed" />;
                      const a = cell.assignment;
                      const p = a ? personMap.get(a.person_id) : null;
                      return (
                        <td key={s.service_date}>
                          {a ? (
                            <span className="app-rota-filled">
                              <span>{p ? fullName(p) : 'Member'}</span>
                              {a.status === 'served' && <Chip tone="ok">Served</Chip>}
                              {a.status === 'no_show' && <Chip tone="danger">No-show</Chip>}
                              {a.status === 'planned' && canEdit && (
                                <button
                                  type="button"
                                  className="app-link-button"
                                  aria-label={`Take ${p ? fullName(p) : 'this member'} off ${shortDate(s.service_date)}`}
                                  disabled={cancel.isPending}
                                  onClick={() => cancel.mutate(a.id)}
                                >
                                  Remove
                                </button>
                              )}
                            </span>
                          ) : canEdit ? (
                            // SECURITY REVIEW FIX Q11: each button says which slot it fills.
                            <button
                              type="button"
                              className="app-link-button"
                              aria-label={`Assign ${r.roleId ? roleMap.get(r.roleId)?.name ?? 'role' : 'any role'}${r.slotNo > 1 ? ` (${r.slotNo})` : ''} on ${shortDate(s.service_date)}`}
                              onClick={() => setPicking(cell)}
                            >
                              + Assign
                            </button>
                          ) : (
                            <span className="type-caption">Open</span>
                          )}
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {cancel.isError && <Notice tone="danger">{friendlyError(cancel.error)}</Notice>}
      </Card>
      {picking && (
        <AssignPanel
          unitId={unitId}
          slot={picking}
          roleName={picking.roleId ? roleMap.get(picking.roleId)?.name ?? 'Role' : 'Any role'}
          isOps={isOps}
          onClose={() => setPicking(null)}
        />
      )}
    </>
  );
}

// ---------- Choose who serves in one slot ----------
function AssignPanel({
  unitId,
  slot,
  roleName,
  isOps,
  onClose,
}: {
  unitId: string;
  slot: RotaSlot;
  roleName: string;
  isOps: boolean;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const candidates = useCandidates(unitId, slot.date);
  const [reason, setReason] = useState('');
  const [overFor, setOverFor] = useState<string | null>(null); // person needing an override

  const assign = useMutation({
    mutationFn: async ({ personId, overrideReason }: { personId: string; overrideReason?: string }) => {
      const { error } = await supabase.from('assignments').insert({
        project_id: slot.projectId,
        person_id: personId,
        unit_id: unitId,
        church_role_id: slot.roleId,
        serve_date: slot.date,
        override_reason: overrideReason?.trim() || null,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['assignments', unitId] });
      qc.invalidateQueries({ queryKey: ['candidates', unitId] });
      onClose();
    },
  });

  const list = candidates.data ?? [];
  return (
    <Card title={`Assign ${roleName} · ${shortDate(slot.date)}`} tone="tint" action={<Button size="sm" variant="quiet" onClick={onClose}>Close</Button>}>
      <p className="type-caption" style={{ margin: 0 }}>
        Fewest slots this month first. One limit counts across all units.
      </p>
      {candidates.isPending && <p>Loading…</p>}
      {candidates.error && <Notice tone="danger">{friendlyError(candidates.error)}</Notice>}
      {candidates.data && list.length === 0 && <p>No active members in this unit.</p>}
      <ul className="app-candidates">
        {list.map((c) => {
          const atLimit = c.slots_used >= c.slot_limit;
          const blocked = c.on_holiday || c.serving_that_day;
          const status = c.on_holiday
            ? 'On holiday'
            : c.serving_that_day
              ? 'Already serving that day'
              : atLimit
                ? `At limit (${c.slot_limit})`
                : `${c.slot_limit - c.slots_used} left`;
          return (
            <li key={c.person_id}>
              <span>
                <strong>
                  {c.first_name} {c.surname}
                </strong>
                <span className="type-caption">
                  {' '}
                  {c.slots_used} of {c.slot_limit} this month
                </span>
              </span>
              <Chip tone={blocked ? 'neutral' : atLimit ? 'warn' : 'ok'}>{status}</Chip>
              {!blocked && !atLimit && (
                <Button size="sm" variant="primary" disabled={assign.isPending} onClick={() => assign.mutate({ personId: c.person_id })}>
                  Assign
                </Button>
              )}
              {!blocked && atLimit && isOps && (
                <Button size="sm" variant="secondary" onClick={() => setOverFor(c.person_id)}>
                  Override…
                </Button>
              )}
            </li>
          );
        })}
      </ul>
      {overFor && (
        <div className="app-form">
          <TextField
            id="override-reason"
            label="Reason for going over the limit"
            hint="(logged; at least a few words)"
            maxLength={500}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
          <div>
            <Button
              variant="primary"
              disabled={reason.trim().length < 5 || assign.isPending}
              onClick={() => assign.mutate({ personId: overFor, overrideReason: reason })}
            >
              Assign with override
            </Button>
          </div>
        </div>
      )}
      {assign.isError && (
        <Notice tone="danger" title="Not assigned">
          {friendlyError(assign.error)}
        </Notice>
      )}
    </Card>
  );
}
