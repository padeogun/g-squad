// -------------------------------------------------------------------------------------
// On a member's record: settling in, courses completed, and mentoring (migration 34).
// Their Team Lead and the G-Squad Coordinator change these; the TECi Coordinator may also
// record courses; others who can read the record see them read-only. Courses are shown only
// to those who may see the member's faith (all courses the same, 25 Nov 2026), and the
// G-Squad Coordinator may remove a pairing at any time. The database checks
// every change (app.growth_record_guard); this page shows its message when it says no.
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { fullName, usePeopleNames, type Person } from '../../data/people';
import { shortDate, todayIso } from '../../data/sundays';
import {
  isSettling,
  journeyFor,
  doneCount,
  MENTOR_KINDS,
  mentorKind,
  useCourses,
  useCourseTypes,
  useEndPairing,
  usePairings,
  useRecordCourse,
  useRemoveCourse,
  useRemovePairing,
  useStartPairing,
  useSteps,
  useSupporting,
  useToggleStep,
  type AssimilationStep,
  type JourneyItem,
  type MentorKind,
} from '../../data/growth';

const { Card, Button, Chip, Notice, SelectField, TextField, Checkbox } = TEC;

export function MemberGrowth({
  person,
  canEdit,
  canSeeCourses,
  canRecordCourses,
  canRemovePairings,
}: {
  person: Person;
  canEdit: boolean;
  canSeeCourses: boolean;
  canRecordCourses: boolean;
  canRemovePairings: boolean;
}) {
  const names = usePeopleNames();
  const nameOf = (id: string) => {
    const p = names.data?.find((x) => x.id === id);
    return p ? fullName(p) : 'Another G-Squad member';
  };
  return (
    <>
      <SettlingIn person={person} canEdit={canEdit} nameOf={nameOf} />
      {canSeeCourses && <Courses person={person} canEdit={canRecordCourses} />}
      <Mentoring person={person} canEdit={canEdit} canRemove={canRemovePairings} nameOf={nameOf} options={(names.data ?? []).filter((n) => n.id !== person.id)} />
    </>
  );
}

const STATE_TONE = { done: 'ok', due: 'info', late: 'warn', later: 'neutral' } as const;
function stateText(i: JourneyItem) {
  if (i.state === 'done') return i.doneOn ? `Done ${shortDate(i.doneOn)}` : 'Done';
  if (i.state === 'late') return `Was due ${shortDate(i.dueOn)}`;
  if (i.state === 'due') return `Due by ${shortDate(i.dueOn)}`;
  return `By ${shortDate(i.dueOn)}`;
}

function SettlingIn({ person, canEdit, nameOf }: { person: Person; canEdit: boolean; nameOf: (id: string) => string }) {
  const [today] = useState(todayIso);
  const steps = useSteps([person.id]);
  const pairings = usePairings([person.id]);
  const toggle = useToggleStep(person.id);
  const buddy = pairings.data?.find((p) => p.kind === 'buddy' && !p.ended_on);
  const items = journeyFor(person.date_joined, today, steps.data ?? [], !!buddy, !!person.greatness_community_id);
  // Shown while they are settling in, or once any step has been recorded.
  if (steps.isPending || !isSettling(person.date_joined, today, items, (steps.data ?? []).length)) return null;
  return (
    <Card title="Settling in" action={<Chip tone={doneCount(items) === items.length ? 'ok' : 'app'}>{`${doneCount(items)} of ${items.length}`}</Chip>}>
      <p className="type-caption" style={{ margin: 0 }}>
        Joined {shortDate(person.date_joined)}. The steps that help a new member feel part of the family: connected, active in a community, living
        ASHLIE and at home beyond their own team.
      </p>
      {steps.error && <Notice tone="danger">{friendlyError(steps.error)}</Notice>}
      <ul className="app-journey">
        {items.map((i) => (
          <li key={i.key}>
            {i.auto || !canEdit ? (
              <span>{i.label}</span>
            ) : (
              <Checkbox
                id={`step-${i.key}`}
                label={i.label}
                checked={i.state === 'done'}
                disabled={toggle.isPending}
                onChange={(e) => toggle.mutate({ step: i.key as AssimilationStep, done: e.target.checked })}
              />
            )}
            <span className="app-journey-state">
              <Chip tone={STATE_TONE[i.state]}>{stateText(i)}</Chip>
              {i.key === 'buddy' && buddy && <span className="type-caption">{nameOf(buddy.mentor_person_id)}</span>}
              {i.key === 'buddy' && !buddy && canEdit && <span className="type-caption">Name one under Mentoring</span>}
              {i.key === 'community' && i.state !== 'done' && canEdit && <span className="type-caption">Set it under In G-Squad</span>}
            </span>
          </li>
        ))}
      </ul>
      {toggle.error && <Notice tone="danger">{friendlyError(toggle.error)}</Notice>}
    </Card>
  );
}

function Courses({ person, canEdit }: { person: Person; canEdit: boolean }) {
  const [today] = useState(todayIso);
  const types = useCourseTypes();
  const done = useCourses(person.id);
  const record = useRecordCourse(person.id);
  const remove = useRemoveCourse(person.id);
  const [course, setCourse] = useState('');
  const [on, setOn] = useState(today);
  const byId = new Map((types.data ?? []).map((t) => [t.id, t]));
  const doneIds = new Set((done.data ?? []).map((c) => c.course_type_id));
  const open = (types.data ?? []).filter((t) => t.is_active && !doneIds.has(t.id));
  return (
    <Card title="Courses completed">
      {/* SECURITY REVIEW 26 (T01), all courses the same (25 Nov 2026): the database shows courses
          only to those who may see this member's faith details, so the card is offered only to them. */}
      <p className="type-caption" style={{ margin: 0 }}>
        Discipleship and leadership courses this member has completed. Completion only. Like faith details, shown only to those who may see them.
      </p>
      {done.error && <Notice tone="danger">{friendlyError(done.error)}</Notice>}
      {done.data && done.data.length === 0 && <p style={{ margin: 0 }}>None recorded yet.</p>}
      {done.data && done.data.length > 0 && (
        <ul className="app-journey">
          {done.data.map((c) => {
            const t = byId.get(c.course_type_id);
            return (
              <li key={c.id}>
                <span>
                  {t?.name ?? 'Course'}
                  {t?.kind === 'leadership' && <span className="type-caption"> · leadership</span>}
                </span>
                <span className="app-journey-state">
                  <span className="type-caption">{shortDate(c.completed_on)}</span>
                  {canEdit && (
                    <Button size="sm" variant="quiet" disabled={remove.isPending} aria-label={`Remove ${t?.name ?? 'course'}`} onClick={() => remove.mutate(c.id)}>
                      Remove
                    </Button>
                  )}
                </span>
              </li>
            );
          })}
        </ul>
      )}
      {canEdit && open.length > 0 && (
        <div className="app-form">
          <div className="tec-fields">
            <SelectField id="course-add" label="Record a completed course" value={course} onChange={(e) => setCourse(e.target.value)} options={[{ value: '', label: 'Choose a course' }, ...open.map((t) => ({ value: t.id, label: t.name }))]} />
            <TextField id="course-on" label="Completed on" type="date" max={today} value={on} onChange={(e) => setOn(e.target.value)} />
          </div>
          <span>
            <Button size="sm" variant="secondary" disabled={!course || !on || record.isPending} onClick={() => record.mutate({ courseId: course, completedOn: on }, { onSuccess: () => setCourse('') })}>
              {record.isPending ? 'Saving…' : 'Record course'}
            </Button>
          </span>
        </div>
      )}
      {(record.error || remove.error) && <Notice tone="danger">{friendlyError(record.error ?? remove.error)}</Notice>}
    </Card>
  );
}

function Mentoring({
  person,
  canEdit,
  canRemove,
  nameOf,
  options,
}: {
  person: Person;
  canEdit: boolean;
  canRemove: boolean;
  nameOf: (id: string) => string;
  options: Array<{ id: string; first_name: string; surname: string }>;
}) {
  const [today] = useState(todayIso);
  const pairings = usePairings([person.id]);
  const supporting = useSupporting(person.id);
  const start = useStartPairing(person.id);
  const end = useEndPairing(person.id);
  const removePairing = useRemovePairing(person.id);
  const [kind, setKind] = useState<MentorKind | ''>('');
  const [mentor, setMentor] = useState('');
  const live = (pairings.data ?? []).filter((p) => !p.ended_on);
  const past = (pairings.data ?? []).filter((p) => p.ended_on);
  const freeKinds = MENTOR_KINDS.filter((k) => !live.some((p) => p.kind === k.value));
  return (
    <Card title="Mentoring">
      <p className="type-caption" style={{ margin: 0 }}>
        Someone beside this member: a buddy while they settle in, a leader growing them towards leading, or one member discipling another.
      </p>
      {pairings.error && <Notice tone="danger">{friendlyError(pairings.error)}</Notice>}
      {pairings.data && live.length === 0 && <p style={{ margin: 0 }}>No one named yet.</p>}
      {live.length > 0 && (
        <ul className="app-journey">
          {live.map((p) => (
            <li key={p.id}>
              <span>
                <span className="type-caption">{mentorKind(p.kind).mentorLabel}: </span>
                <strong>{nameOf(p.mentor_person_id)}</strong>
              </span>
              <span className="app-journey-state">
                <span className="type-caption">since {shortDate(p.started_on)}</span>
                {canEdit && (
                  <Button size="sm" variant="quiet" disabled={end.isPending} onClick={() => end.mutate({ id: p.id, endedOn: today })}>
                    End
                  </Button>
                )}
                {canRemove && (
                  <Button size="sm" variant="quiet" disabled={removePairing.isPending} aria-label={`Remove pairing with ${nameOf(p.mentor_person_id)}`} onClick={() => removePairing.mutate(p.id)}>
                    Remove
                  </Button>
                )}
              </span>
            </li>
          ))}
        </ul>
      )}
      {canEdit && freeKinds.length > 0 && (
        <div className="app-form">
          <div className="tec-fields">
            <SelectField id="mentor-kind" label="Name someone as" value={kind} onChange={(e) => setKind(e.target.value as MentorKind)} options={[{ value: '', label: 'Choose' }, ...freeKinds.map((k) => ({ value: k.value, label: k.label }))]} />
            <SelectField id="mentor-person" label="Who" value={mentor} onChange={(e) => setMentor(e.target.value)} options={[{ value: '', label: 'Choose a member' }, ...options.map((o) => ({ value: o.id, label: fullName(o) }))]} />
          </div>
          {kind && <p className="type-caption" style={{ margin: 0 }}>{mentorKind(kind).hint}</p>}
          <span>
            <Button size="sm" variant="secondary" disabled={!kind || !mentor || start.isPending} onClick={() => start.mutate({ mentorId: mentor, kind: kind as MentorKind }, { onSuccess: () => { setKind(''); setMentor(''); } })}>
              {start.isPending ? 'Saving…' : 'Name them'}
            </Button>
          </span>
        </div>
      )}
      {(start.error || end.error || removePairing.error) && <Notice tone="danger">{friendlyError(start.error ?? end.error ?? removePairing.error)}</Notice>}
      {(supporting.data ?? []).length > 0 && (
        <>
          <h4 className="app-subhead">Supporting</h4>
          <ul className="app-journey">
            {supporting.data!.map((p) => (
              <li key={p.id}>
                <span>
                  {nameOf(p.person_id)} <span className="type-caption">({mentorKind(p.kind).label.toLowerCase()})</span>
                </span>
                <span className="type-caption">since {shortDate(p.started_on)}</span>
              </li>
            ))}
          </ul>
        </>
      )}
      {past.length > 0 && (
        <details>
          <summary className="type-caption">Earlier ({past.length})</summary>
          <ul className="app-journey">
            {past.map((p) => (
              <li key={p.id}>
                <span>
                  {mentorKind(p.kind).label}: {nameOf(p.mentor_person_id)}
                </span>
                <span className="app-journey-state">
                  <span className="type-caption">
                    {shortDate(p.started_on)} to {shortDate(p.ended_on!)}
                  </span>
                  {canRemove && (
                    <Button size="sm" variant="quiet" disabled={removePairing.isPending} aria-label={`Remove earlier pairing with ${nameOf(p.mentor_person_id)}`} onClick={() => removePairing.mutate(p.id)}>
                      Remove
                    </Button>
                  )}
                </span>
              </li>
            ))}
          </ul>
        </details>
      )}
    </Card>
  );
}
