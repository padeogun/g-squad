// -------------------------------------------------------------------------------------
// Two cards on an event's page (migration 36, decisions of 27 Nov 2026):
//   Who attended   check-in for each day of the event that has come, like Sunday check-in.
//                  The event's owner (or the Operations Lead) ticks anyone they can see; a
//                  Team Lead or the Coordinator ticks the members they look after. Members who
//                  RSVP'd through the Brief are listed first. Attending a prayer, Bible study or
//                  discipleship event counts as a maturity habit: a fact, never a score.
//   Planning committee   the G-Squad members on the event's committee. Seats on live events
//                  count in leaders' load with their own limit (flag, never block).
// The database decides who may do what; these cards only offer it.
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import type { Project as ProjectRow } from '../../data/projects';
import { usePeopleNames } from '../../data/people';
import { todayIso, shortDate } from '../../data/sundays';
import {
  attendanceDays,
  defaultAttendanceDay,
  useAddCommitteeMember,
  useCandidates,
  useCommittee,
  useMarkAttendance,
  useRemoveCommitteeMember,
} from '../../data/attendance';

const { Card, Button, Chip, Checkbox, Notice, SelectField, TextField } = TEC;

export function AttendanceCard({ p, maturity }: { p: ProjectRow; maturity: boolean }) {
  const [today] = useState(todayIso);
  const days = attendanceDays(p.starts_at, p.ends_at, today);
  const [day, setDay] = useState(() => defaultAttendanceDay(days, today));
  const list = useCandidates(p.id, day, days.length > 0);
  const mark = useMarkAttendance(p.id, day);
  const [filter, setFilter] = useState('');
  // Only approved events that have started take attendance (the database checks too).
  if (!['approved', 'in_progress', 'done'].includes(p.status) || days.length === 0) return null;
  const rows = (list.data ?? []).filter((c) => c.display_name.toLowerCase().includes(filter.trim().toLowerCase()));
  const marked = (list.data ?? []).filter((c) => c.attended).length;
  return (
    <Card title="Who attended" action={<Chip tone="app">{marked} marked</Chip>}>
      <p className="type-caption" style={{ margin: 0 }}>
        Tick the G-Squad members who came.{' '}
        {maturity ? 'This is a prayer, Bible study or discipleship event, so attending counts as a maturity habit. ' : ''}
        You can tick members you look after; the event's owner can tick anyone they can see. Those who replied to the Brief come first.
      </p>
      <div className="tec-fields">
        {days.length > 1 && (
          <SelectField
            id="attendance-day"
            label="Day"
            value={day}
            onChange={(e) => setDay(e.target.value)}
            options={days.map((d) => ({ value: d, label: shortDate(d) }))}
          />
        )}
        <TextField id="attendance-filter" label="Find a member" value={filter} onChange={(e) => setFilter(e.target.value)} />
      </div>
      {list.error && <Notice tone="danger">{friendlyError(list.error)}</Notice>}
      {list.isPending && <p style={{ margin: 0 }}>Loading…</p>}
      {list.data && list.data.length === 0 && (
        <p style={{ margin: 0 }}>There is nobody here you can record. Team Leads record the members they look after.</p>
      )}
      {rows.length > 0 && (
        <ul className="app-attendance">
          {rows.map((c) => (
            <li key={c.person_id}>
              <Checkbox
                label={c.display_name}
                checked={c.attended}
                disabled={mark.isPending}
                onChange={(e) =>
                  mark.mutate({
                    personId: c.person_id,
                    attended: e.target.checked,
                  })
                }
              />
              {c.rsvp && <span className="type-caption">Replied yes</span>}
            </li>
          ))}
        </ul>
      )}
      {mark.error && <Notice tone="danger">{friendlyError(mark.error)}</Notice>}
    </Card>
  );
}

export function CommitteeCard({ p, canManage }: { p: ProjectRow; canManage: boolean }) {
  const seats = useCommittee(p.id);
  const people = usePeopleNames();
  const add = useAddCommitteeMember(p.id);
  const remove = useRemoveCommitteeMember(p.id);
  const [who, setWho] = useState('');
  const [role, setRole] = useState('');
  const open = !['done', 'cancelled'].includes(p.status);
  const nameOf = (id: string) => {
    const x = people.data?.find((n) => n.id === id);
    return x ? `${x.first_name} ${x.surname}` : 'A G-Squad member';
  };
  const taken = new Set((seats.data ?? []).map((s) => s.person_id));
  if (!canManage && (seats.data ?? []).length === 0) return null;
  return (
    <Card title="Planning committee">
      <p className="type-caption" style={{ margin: 0 }}>
        G-Squad members on this event's planning committee. Seats on live events count towards each leader's load, so nobody carries too much.
      </p>
      {seats.error && <Notice tone="danger">{friendlyError(seats.error)}</Notice>}
      {(seats.data ?? []).length > 0 && (
        <ul className="app-journey">
          {seats.data!.map((s) => (
            <li key={s.id}>
              <span>
                {nameOf(s.person_id)}
                {s.role ? <span className="type-caption"> · {s.role}</span> : null}
              </span>
              {canManage && open && (
                <Button
                  size="sm"
                  variant="quiet"
                  disabled={remove.isPending}
                  aria-label={`Remove ${nameOf(s.person_id)} from the committee`}
                  onClick={() => remove.mutate(s.id)}
                >
                  Remove
                </Button>
              )}
            </li>
          ))}
        </ul>
      )}
      {canManage && open && (
        <div className="app-form">
          <div className="tec-fields">
            <SelectField
              id="committee-person"
              label="Add a member"
              value={who}
              onChange={(e) => setWho(e.target.value)}
              options={[
                { value: '', label: 'Choose a member' },
                ...(people.data ?? [])
                  .filter((n) => !taken.has(n.id))
                  .map((n) => ({
                    value: n.id,
                    label: `${n.first_name} ${n.surname}`,
                  })),
              ]}
            />
            <TextField id="committee-role" label="Role (optional)" maxLength={80} value={role} onChange={(e) => setRole(e.target.value)} />
          </div>
          <span>
            <Button
              size="sm"
              variant="secondary"
              disabled={!who || add.isPending}
              onClick={() =>
                add.mutate(
                  { personId: who, role },
                  {
                    onSuccess: () => {
                      setWho('');
                      setRole('');
                    },
                  },
                )
              }
            >
              {add.isPending ? 'Adding…' : 'Add to committee'}
            </Button>
          </span>
        </div>
      )}
      {(add.error || remove.error) && <Notice tone="danger">{friendlyError(add.error ?? remove.error)}</Notice>}
    </Card>
  );
}
