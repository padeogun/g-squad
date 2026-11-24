// -------------------------------------------------------------------------------------
// The team's quarterly conversation on the four focus areas (migration 33, decision of
// 24 Nov 2026). The Team Lead writes one short note per area: what went well, and what the
// team will do next. This quarter, or catching up on the last one; earlier quarters are history.
// Read by those who see the team (its lead and deputy, its Purpose Head, the Coordinator, the
// Operations Lead and the Resident Pastor). The database decides who writes and when.
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { todayIso } from '../../data/sundays';
import {
  FOCUS_AREAS,
  previousQuarter,
  quarterName,
  quarterOf,
  useSaveReflection,
  useUnitReflections,
  type FocusAreaInfo,
  type UnitReflection,
} from '../../data/focus';

const { Card, Button, Notice, Segmented } = TEC;

export function TeamConversation({ unitId, canEdit }: { unitId: string; canEdit: boolean }) {
  const [thisQ] = useState(() => quarterOf(todayIso()));
  const lastQ = previousQuarter(thisQ);
  const [q, setQ] = useState(thisQ);
  const notes = useUnitReflections(unitId, [thisQ, lastQ]);
  const labels = [`This quarter (${quarterName(thisQ)})`, `Last quarter (${quarterName(lastQ)})`];
  const forQ = (notes.data ?? []).filter((n) => n.quarter_start === q);

  return (
    <Card title="Team conversation: the four focus areas">
      <p className="type-caption" style={{ margin: 0 }}>
        Talk these through with the team once a quarter. {canEdit ? 'Write a line or two for each: what went well, and what you will do next.' : 'Written by the Team Lead.'}
      </p>
      {/* SECURITY REVIEW 25 (S05): the notes are read beyond the team (its Purpose Head, the
          Coordinator, the Operations Lead and the Resident Pastor); keep members' own matters out. */}
      {canEdit && (
        <p className="type-caption" style={{ margin: 0 }}>
          About the team, not any one member: the Purpose Head, Coordinator, Operations Lead and Resident Pastor read these. For a member who
          needs care, raise a check-in instead.
        </p>
      )}
      <Segmented label="Quarter" options={labels} value={q === thisQ ? labels[0] : labels[1]} onChange={(x) => setQ(x === labels[0] ? thisQ : lastQ)} />
      {notes.error && <Notice tone="danger">{friendlyError(notes.error)}</Notice>}
      {notes.isPending && <p style={{ margin: 0 }}>Loading…</p>}
      {notes.data && !canEdit && forQ.length === 0 && <p style={{ margin: 0 }}>Nothing written for this quarter yet.</p>}
      {notes.data && (
        <ul className="app-focus-list">
          {FOCUS_AREAS.map((a) => {
            const note = forQ.find((n) => n.area === a.key);
            if (!canEdit && !note) return null;
            return canEdit ? (
              <NoteEditor key={`${q}-${a.key}`} unitId={unitId} quarter={q} info={a} note={note} />
            ) : (
              <NoteRead key={a.key} info={a} note={note!} />
            );
          })}
        </ul>
      )}
    </Card>
  );
}

function NoteRead({ info, note }: { info: FocusAreaInfo; note: UnitReflection }) {
  return (
    <li>
      <strong>{info.name}</strong>
      {note.went_well && (
        <span>
          <span className="type-caption">Went well: </span>
          {note.went_well}
        </span>
      )}
      {note.next_step && (
        <span>
          <span className="type-caption">Next: </span>
          {note.next_step}
        </span>
      )}
    </li>
  );
}

function NoteEditor({ unitId, quarter, info, note }: { unitId: string; quarter: string; info: FocusAreaInfo; note: UnitReflection | undefined }) {
  const save = useSaveReflection(unitId);
  const [went, setWent] = useState(note?.went_well ?? '');
  const [next, setNext] = useState(note?.next_step ?? '');
  const id = `team-${quarter}-${info.key}`;
  const changed = (note?.went_well ?? '') !== went.trim() || (note?.next_step ?? '') !== next.trim();
  return (
    <li>
      <strong>{info.name}</strong>
      <span className="type-caption">{info.short}</span>
      <div className="app-focus-edit">
        <label className="tec-field app-field-wide" htmlFor={`${id}-went`}>
          <span>What went well</span>
          <textarea id={`${id}-went`} className="tec-input app-textarea" rows={2} maxLength={600} value={went} onChange={(e) => setWent(e.target.value)} />
        </label>
        <label className="tec-field app-field-wide" htmlFor={`${id}-next`}>
          <span>What we will do next</span>
          <textarea id={`${id}-next`} className="tec-input app-textarea" rows={2} maxLength={600} value={next} onChange={(e) => setNext(e.target.value)} />
        </label>
        <span>
          <Button size="sm" variant="secondary" disabled={save.isPending || !changed} onClick={() => save.mutate({ quarter_start: quarter, area: info.key, went_well: went, next_step: next })}>
            {save.isPending ? 'Saving…' : 'Save'}
          </Button>
        </span>
      </div>
      {save.error && <Notice tone="danger">{friendlyError(save.error)}</Notice>}
    </li>
  );
}
