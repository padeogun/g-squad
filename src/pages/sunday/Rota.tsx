// -------------------------------------------------------------------------------------
// Rota: one unit, one month. Rows are the roles each Sunday's grid needs from the unit
// (team demand); columns are the month's Sundays. Below (migration 28): the places the unit
// is asked to fill at events, outreach and team activities that month. A Team Lead fills a
// place from "who can serve": the unit's active members, fewest hours this month first, with
// people on holiday or without enough hours left shown but not offered. Every place counts
// its hours towards one monthly limit across all serving (decision of 25 Oct 2026).
// The database checks every slot (migration 8): membership, holidays (R10) and one monthly
// limit across all units (R1/R2), which only the Operations Lead may go over, with a reason.
// -------------------------------------------------------------------------------------
import { useEffect, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, useChurchRoles, useUnits } from '../../data/reference';
import { fullName, usePersonNames } from '../../data/people';
import { shortDate, todayIso } from '../../data/sundays';
import { buildEvents, buildRota, fitsLimit, monthBounds, placeHours, useCandidates, useMonthSundays, useUnitAssignments, useUnitDemand, useUnitEventDemand, type RotaSlot } from '../../data/rota';
import { useSettings } from '../../data/newsletter';
import { hasRole, ledUnitIds, viewedUnitIds, useMe } from '../../auth/useMe';

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
  // Units this leader can see the rota of: all for the Operations Lead and Coordinator, otherwise
  // those they lead or deputise for. Only the Team Lead (or Ops Lead) changes it (canEdit below).
  const seen = viewedUnitIds(me.data);
  const choices = (units.data ?? []).filter((u) => u.is_active && (isAdmin || seen.includes(u.id)));
  const [chosen, setChosen] = useState('');
  const unitId = chosen || choices[0]?.id || '';
  const [month, setMonth] = useState(() => todayIso().slice(0, 7));

  if (me.isPending || units.isPending) return <p>Loading…</p>;
  return (
    <>
      <SectionHeading eyebrow="Sundays and events" title="Rota" rule>
        Sundays, events, outreach and team activities. Every place counts its hours towards one monthly limit across all
        teams, so nobody is asked to carry too much.
      </SectionHeading>
      {choices.length === 0 ? (
        <Notice tone="info" title="For Team Leads">
          The rota is filled by each team's lead. You don't lead a team.
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
  // SECURITY REVIEW 19 (Z06): bookings outside this month's Sunday services, shown under events
  // even when their place has gone (they still count towards the limit).
  const eventBookings = (assignments.data ?? []).filter((a) => !projectIds.includes(a.project_id));
  const events = useUnitEventDemand(unitId, from, to, [...new Set(eventBookings.map((a) => a.project_id))]);
  const settings = useSettings();
  const roleMap = byId(roles.data);
  const personMap = byId(people.data);
  // The slot whose picker is open.
  const [picking, setPicking] = useState<(RotaSlot & { hours?: number | null }) | null>(null);

  const rows = useMemo(
    // Only Sunday places here: an event on a Sunday has its own list below.
    () => buildRota(sundays.data ?? [], demand.data ?? [], (assignments.data ?? []).filter((a) => projectIds.includes(a.project_id))),
    // eslint-disable-next-line react-hooks/exhaustive-deps -- projectIds is derived from sundays.data
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
  const loadError = sundays.error ?? demand.error ?? assignments.error ?? events.error;
  if (loadError) return <Notice tone="danger" title="The rota could not be loaded">{friendlyError(loadError)}</Notice>;
  const noSundays = (sundays.data ?? []).length === 0;
  const open = rows.reduce((n, r) => n + [...r.cells.values()].filter((c) => !c.assignment).length, 0);
  const defaultHours = Number(settings.data?.hours_per_slot ?? 3);

  return (
    <>
      <Card title={noSundays ? 'Sundays' : open ? `Sundays · ${open} open slot${open === 1 ? '' : 's'}` : 'Sundays · all slots filled'}>
        {noSundays ? (
          <Notice tone="info" title="No Sundays set up this month">
            The Operations Lead sets up each Sunday under <Link to="/sundays">Sunday Operations</Link>.
          </Notice>
        ) : rows.length === 0 ? (
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
                              onClick={() =>
                                setPicking({
                                  ...cell,
                                  // SECURITY REVIEW 19 (Z07): counted as the database counts it.
                                  hours: placeHours(demand.data ?? [], cell.projectId, cell.roleId, cell.date, defaultHours),
                                })
                              }
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
      <EventsCard
        groups={buildEvents(events.data?.demand ?? [], events.data?.projects ?? [], eventBookings, defaultHours)}
        loading={events.isPending}
        roleName={(id) => (id ? roleMap.get(id)?.name ?? 'Role' : 'Any role')}
        personName={(id) => {
          const p = personMap.get(id);
          return p ? fullName(p) : 'Member';
        }}
        canEdit={canEdit}
        onPick={(slot, hours) => setPicking({ ...slot, hours })}
        onCancel={(id) => cancel.mutate(id)}
        cancelling={cancel.isPending}
      />
      {picking && (
        <AssignPanel
          unitId={unitId}
          slot={picking}
          hours={picking.hours ?? defaultHours}
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
  hours,
  roleName,
  isOps,
  onClose,
}: {
  unitId: string;
  slot: RotaSlot;
  hours: number;
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
  // The panel opens below the lists: bring it into view so the leader sees who can serve.
  // SECURITY REVIEW 19 (Z07): and move focus to it, so keyboard and screen reader users land on
  // the list rather than staying on the "+ Assign" button far above.
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    box.current?.focus?.({ preventScroll: true });
    box.current?.scrollIntoView?.({ behavior: 'smooth', block: 'nearest' });
  }, [slot]);
  return (
    <div ref={box} tabIndex={-1} className="app-assign-panel" role="region" aria-label={`Assign ${roleName} on ${shortDate(slot.date)}`}>
    <Card title={`Assign ${roleName} · ${shortDate(slot.date)} · ${hours} h`} tone="tint" action={<Button size="sm" variant="quiet" onClick={onClose}>Close</Button>}>
      <p className="type-caption" style={{ margin: 0 }}>
        Fewest hours this month first. One limit counts across all teams, Sundays, events and team activities.
      </p>
      {candidates.isPending && <p>Loading…</p>}
      {candidates.error && <Notice tone="danger">{friendlyError(candidates.error)}</Notice>}
      {candidates.data && list.length === 0 && <p>No active members in this unit.</p>}
      <ul className="app-candidates">
        {list.map((c) => {
          const atLimit = !fitsLimit(c, hours);
          const left = Math.max(0, Number(c.hours_limit) - Number(c.hours_used));
          const blocked = c.on_holiday || c.serving_that_day;
          const status = c.on_holiday
            ? 'On holiday'
            : c.serving_that_day
              ? 'Already serving that day'
              : atLimit
                ? left > 0 ? `Only ${left} h left` : 'No hours left'
                : `${left} h left`;
          return (
            <li key={c.person_id}>
              <span>
                <strong>
                  {c.first_name} {c.surname}
                </strong>
                <span className="type-caption">
                  {' '}
                  {Number(c.hours_used)} of {Number(c.hours_limit)} hours this month
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
    </div>
  );
}

// ---------- Events, outreach and team activities (migration 28) ----------
// SECURITY REVIEW 19 (Z06/Z07): hours are shown per place when a day's places differ, and
// bookings whose place has gone (or whose project is no longer approved) are listed, marked,
// with Remove but no new places.
function EventsCard({
  groups,
  loading,
  roleName,
  personName,
  canEdit,
  onPick,
  onCancel,
  cancelling,
}: {
  groups: ReturnType<typeof buildEvents>;
  loading: boolean;
  roleName: (id: string | null) => string;
  personName: (id: string) => string;
  canEdit: boolean;
  onPick: (slot: RotaSlot, hours: number) => void;
  onCancel: (assignmentId: string) => void;
  cancelling: boolean;
}) {
  const open = groups.reduce((n, g) => n + g.slots.filter((s) => !s.assignment).length, 0);
  return (
    <Card title={groups.length === 0 ? 'Events and team activities' : open ? `Events and team activities · ${open} open` : 'Events and team activities · all filled'}>
      {loading && <p>Loading…</p>}
      {!loading && groups.length === 0 && (
        <p style={{ margin: 0 }}>
          No approved events or team activities ask this team for people this month. Places are requested under Volunteers needed
          on each <Link to="/projects">project</Link>.
        </p>
      )}
      {groups.map((g) => (
        <section key={`${g.projectId}-${g.date}`} className="app-event-group" aria-label={`${g.name}, ${shortDate(g.date)}`}>
          <div className="app-event-head">
            <Link to={`/projects/${g.projectId}`}>
              <strong>{g.name}</strong>
            </Link>
            <span className="type-caption">
              {shortDate(g.date)}
              {g.hours !== null ? ` · ${g.hours} h each` : ''}
            </span>
            {!g.open && <Chip tone="warn">No longer asking for people</Chip>}
          </div>
          <ul className="app-candidates">
            {g.slots.map((s, i) => {
              const a = s.assignment;
              return (
                <li key={a?.id ?? `${s.roleId}-${i}`}>
                  <span>
                    {roleName(s.roleId)}
                    {g.hours === null && <span className="type-caption">{` · ${s.hours} h`}</span>}
                    {a && <strong> · {personName(a.person_id)}</strong>}
                  </span>
                  {a?.status === 'served' && <Chip tone="ok">Served</Chip>}
                  {a?.status === 'no_show' && <Chip tone="danger">No-show</Chip>}
                  {!a && !canEdit && <span className="type-caption">Open</span>}
                  {!a && canEdit && (
                    <button
                      type="button"
                      className="app-link-button"
                      aria-label={`Assign ${roleName(s.roleId)} for ${g.name} on ${shortDate(g.date)}, ${s.hours} hours`}
                      onClick={() => onPick(s, s.hours)}
                    >
                      + Assign
                    </button>
                  )}
                  {a?.status === 'planned' && canEdit && (
                    <button
                      type="button"
                      className="app-link-button"
                      aria-label={`Take ${personName(a.person_id)} off ${g.name} on ${shortDate(g.date)}`}
                      disabled={cancelling}
                      onClick={() => onCancel(a.id)}
                    >
                      Remove
                    </button>
                  )}
                </li>
              );
            })}
          </ul>
        </section>
      ))}
    </Card>
  );
}
