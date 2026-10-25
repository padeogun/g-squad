// -------------------------------------------------------------------------------------
// Team Lead One-to-One (one per member per team per quarter). Sections follow the focus
// areas agreed on 23 and 25 Oct 2026:
//   1. Serving: how they are finding it and any support needed.
//   2. Sense of family as a team member.
//   3. Competence in their role or unit.
//   4. Personal walk with God: restricted (the writing Team Lead, the G-Squad Coordinator and
//      the Resident Pastor; every view logged), saved through set_one_to_one_walk.
//   5. ASHLIE values: one lived out and one to grow in, with a note. Never scored (R20).
//   6. Leadership questions being asked when it was held.
//   7. A development goal and serving notes.
// Recording also offers a Values in Action recognition (shared only with their agreement,
// R19) and a pastoral check-in flag (pastoral matters are not written in the one-to-one).
// Only the Team Lead who wrote it edits it; others who may read it see it read-only.
// -------------------------------------------------------------------------------------
import { useRef, useState, type FormEvent } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, useUnits } from '../../data/reference';
import { usePersonNames } from '../../data/people';
import { shortDate, todayIso } from '../../data/sundays';
import {
  FEELINGS,
  heldOnMax,
  heldOnProblem,
  promptsFor,
  quarterLabel,
  quarterStart,
  saveErrorMessage,
  SUPPORT,
  useAnswers,
  useCoreValues,
  useOneToOne,
  usePrompts,
  walkAccess,
  type OneToOne,
} from '../../data/oneToOnes';
import { hasRole, ledUnitIds, useMe } from '../../auth/useMe';
import { NotFound } from '../NotFound';

const { SectionHeading, Card, Notice, Button, TextField, SelectField, Checkbox } = TEC;

export function OneToOneForm() {
  const { id } = useParams();
  const [params] = useSearchParams();
  const existing = useOneToOne(id);
  if (id && existing.isPending) return <p>Loading…</p>;
  if (id && existing.error) return <Notice tone="danger">{friendlyError(existing.error)}</Notice>;
  if (id && !existing.data) return <NotFound />;
  const unitId = existing.data?.unit_id ?? params.get('unit') ?? '';
  const personId = existing.data?.person_id ?? params.get('person') ?? '';
  if (!unitId || !personId) return <NotFound />;
  return <Form key={existing.data?.id ?? 'new'} oto={existing.data ?? null} unitId={unitId} personId={personId} />;
}

type Vals = {
  held_on: string;
  feeling: string;
  support_needed: string;
  sense_of_family: string;
  competence: string;
  value_lived_id: string;
  value_lived_note: string;
  value_to_grow_id: string;
  value_to_grow_note: string;
  development_goal: string;
  notes: string;
};

function Form({ oto, unitId, personId }: { oto: OneToOne | null; unitId: string; personId: string }) {
  const me = useMe();
  const qc = useQueryClient();
  const navigate = useNavigate();
  const [today] = useState(todayIso);
  const units = useUnits();
  const names = usePersonNames([personId]);
  const values = useCoreValues();
  const prompts = usePrompts();
  const answers = useAnswers(oto?.id);
  const person = names.data?.[0];
  const name = person ? `${person.first_name} ${person.surname}` : 'Member';
  const unitName = byId(units.data).get(unitId)?.name ?? 'Team';
  // Only the Team Lead who wrote it (or, for a new one, the team's Team Lead) edits.
  const canWrite = oto ? oto.lead_user_id === me.data?.id && ledUnitIds(me.data).includes(unitId) : ledUnitIds(me.data).includes(unitId);
  const ro = !canWrite;

  const s = (x: string | null | undefined) => x ?? '';
  const [v, setV] = useState<Vals>({
    held_on: oto?.held_on ?? today,
    feeling: oto?.feeling ?? '',
    support_needed: oto?.support_needed ?? 'none',
    sense_of_family: s(oto?.sense_of_family),
    competence: s(oto?.competence),
    value_lived_id: s(oto?.value_lived_id),
    value_lived_note: s(oto?.value_lived_note),
    value_to_grow_id: s(oto?.value_to_grow_id),
    value_to_grow_note: s(oto?.value_to_grow_note),
    development_goal: s(oto?.development_goal),
    notes: s(oto?.notes),
  });
  const set = (k: keyof Vals, x: string) => setV((cur) => ({ ...cur, [k]: x }));
  const q = quarterStart(v.held_on || today);
  const asked = promptsFor(prompts.data ?? [], v.held_on || today);
  // Answers typed this visit, by question; saved answers fill in until changed.
  const [typed, setTyped] = useState<Record<string, string>>({});
  const answerFor = (pid: string) => typed[pid] ?? answers.data?.find((a) => a.prompt_id === pid)?.answer ?? '';
  const [walk, setWalk] = useState('');
  const [walkTouched, setWalkTouched] = useState(false);
  const [flag, setFlag] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // SECURITY REVIEW 17 (W04): the one-to-one is saved first, then the walk, answers and
  // check-in. If a later step fails, the new one-to-one already exists: remember its id so
  // that saving again updates it (rather than failing as a second one for the quarter), and
  // say that it was saved.
  const savedId = useRef<string | undefined>(oto?.id);
  const [savedFirst, setSavedFirst] = useState(false);

  const save = useMutation({
    mutationFn: async () => {
      const t = (x: string) => (x.trim() === '' ? null : x.trim());
      const row = {
        held_on: v.held_on,
        quarter_start: q,
        feeling: v.feeling as OneToOne['feeling'],
        support_needed: v.support_needed as OneToOne['support_needed'],
        sense_of_family: t(v.sense_of_family),
        competence: t(v.competence),
        value_lived_id: t(v.value_lived_id),
        value_lived_note: v.value_lived_id ? t(v.value_lived_note) : null,
        value_to_grow_id: t(v.value_to_grow_id),
        value_to_grow_note: v.value_to_grow_id ? t(v.value_to_grow_note) : null,
        development_goal: t(v.development_goal),
        notes: t(v.notes),
      };
      setSavedFirst(false);
      let otoId = savedId.current;
      if (otoId) {
        const { error: e } = await supabase.from('one_to_ones').update(row).eq('id', otoId).select('id').single();
        if (e) throw e;
      } else {
        const { data, error: e } = await supabase
          .from('one_to_ones')
          .insert({ ...row, person_id: personId, unit_id: unitId })
          .select('id')
          .single();
        if (e) throw e;
        otoId = data.id;
        savedId.current = otoId;
      }
      setSavedFirst(true);
      // The walk with God only when written or changed this visit (it is read only on request).
      if (walkTouched) {
        const { error: e } = await supabase.rpc('set_one_to_one_walk', { p_one_to_one: otoId!, p_notes: walk });
        if (e) throw e;
      }
      // Leadership questions: save what was typed; an emptied answer is removed.
      for (const p of asked) {
        if (!(p.id in typed)) continue;
        const text = typed[p.id].trim();
        const prev = answers.data?.find((a) => a.prompt_id === p.id);
        const r = text
          ? prev
            ? await supabase.from('one_to_one_answers').update({ answer: text }).eq('id', prev.id).select('id').single()
            : await supabase.from('one_to_one_answers').insert({ one_to_one_id: otoId!, prompt_id: p.id, answer: text }).select('id').single()
          : prev
            ? await supabase.from('one_to_one_answers').delete().eq('id', prev.id).select('id').single()
            : { error: null };
        if (r.error) throw r.error;
      }
      // A pastoral check-in: a flag only (no reasons); an open one already counts.
      if (flag) {
        const { error: e } = await supabase.from('checkin_flags').insert({ person_id: personId, source: 'manual', status: 'open', raised_by: me.data!.id });
        if (e && e.code !== '23505') throw e;
      }
      return otoId!;
    },
    onSuccess: (otoId) => {
      setFlag(false);   // W04: a check-in is asked for once, not again on the next save
      setWalkTouched(false);
      setTyped({});
      for (const k of [['one_to_ones'], ['one_to_one_answers'], ['unit_dashboard']]) qc.invalidateQueries({ queryKey: k });
      navigate(`/one-to-ones/${otoId}`, { replace: true });
    },
  });

  function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (!v.feeling) return setError('Choose how they are finding serving.');
    const dateProblem = heldOnProblem(v.held_on, today, oto?.quarter_start ?? null);
    if (dateProblem) return setError(dateProblem);
    // W06: without the saved answers, a typed answer would be added a second time.
    if (oto && !answers.data) return setError('The saved answers to the leadership questions have not loaded yet. Try again in a moment.');
    setError(null);
    save.mutate();
  }

  const valueOpts = [{ value: '', label: 'Choose a value' }, ...(values.data ?? []).map((x) => ({ value: x.id, label: `${x.letter} · ${x.name}` }))];
  const area = (id: string, label: string, key: keyof Vals, hint?: string, max = 1000) => (
    <label className="tec-field app-field-wide" htmlFor={id}>
      <span>
        {label} {hint && <span className="tec-hint">{hint}</span>}
      </span>
      <textarea id={id} className="tec-input app-textarea" rows={3} maxLength={max} value={v[key]} onChange={(e) => set(key, e.target.value)} />
    </label>
  );

  return (
    <>
      <SectionHeading eyebrow={`${unitName} · ${quarterLabel(oto?.quarter_start ?? q)}`} title={`One-to-one with ${name}`} rule>
        {oto ? `Held ${shortDate(oto.held_on)}.` : 'Short notes for each area. Values are recognised, never scored.'}
      </SectionHeading>
      <p style={{ margin: 0 }}>
        <Link to="/one-to-ones">All one-to-ones</Link>
      </p>
      {ro && <Notice tone="info">View only: one-to-ones are written by the Team Lead who held them.</Notice>}
      {/* W06: a list that failed to load must not look like an empty one. */}
      {(values.error || prompts.error || answers.error) && (
        <Notice tone="danger" title="Part of this one-to-one did not load">
          {friendlyError(values.error ?? prompts.error ?? answers.error)}
        </Notice>
      )}

      <form className="app-form" onSubmit={onSubmit} noValidate>
        <Card title="Serving">
          <fieldset className="app-fieldset tec-fields" disabled={ro}>
            <TextField id="o-held" label="Held on" type="date" min={oto ? oto.quarter_start : quarterStart(today)} max={heldOnMax(oto ? oto.quarter_start : quarterStart(today), today)} value={v.held_on} onChange={(e) => set('held_on', e.target.value)} />
            <SelectField id="o-feeling" label="How are they finding serving?" value={v.feeling} onChange={(e) => set('feeling', e.target.value)} options={[{ value: '', label: 'Choose' }, ...FEELINGS]} />
            <SelectField id="o-support" label="Support needed" value={v.support_needed} onChange={(e) => set('support_needed', e.target.value)} options={SUPPORT} />
          </fieldset>
        </Card>

        <Card title="Belonging and role">
          <fieldset className="app-fieldset tec-fields" disabled={ro}>
            {area('o-family', 'Sense of family as a team member', 'sense_of_family', 'Do they feel they belong?')}
            {area('o-competence', 'Competence in their role or unit', 'competence', 'Confidence, skills, training wanted')}
          </fieldset>
        </Card>

        <WalkPanel oto={oto} canWrite={canWrite} value={walk} onChange={(x) => { setWalk(x); setWalkTouched(true); }} onLoaded={setWalk} />

        <Card title="ASHLIE values">
          <p className="type-caption" style={{ margin: 0 }}>A value they have lived out, and one to grow in. Names and notes only: values are never scored or rated.</p>
          <fieldset className="app-fieldset tec-fields" disabled={ro}>
            <SelectField id="o-lived" label="A value lived out" value={v.value_lived_id} onChange={(e) => set('value_lived_id', e.target.value)} options={valueOpts} />
            <TextField id="o-lived-note" label="How they live it out" hint={v.value_lived_id ? undefined : 'Choose a value first'} maxLength={280} disabled={!v.value_lived_id} value={v.value_lived_note} onChange={(e) => set('value_lived_note', e.target.value)} />
            <SelectField id="o-grow" label="A value to grow in" value={v.value_to_grow_id} onChange={(e) => set('value_to_grow_id', e.target.value)} options={valueOpts} />
            <TextField id="o-grow-note" label="How they could grow in it" hint={v.value_to_grow_id ? undefined : 'Choose a value first'} maxLength={280} disabled={!v.value_to_grow_id} value={v.value_to_grow_note} onChange={(e) => set('value_to_grow_note', e.target.value)} />
          </fieldset>
        </Card>

        {asked.length > 0 && (
          <Card title="Questions from the leadership">
            <fieldset className="app-fieldset tec-fields" disabled={ro}>
              {asked.map((p) => (
                <label key={p.id} className="tec-field app-field-wide" htmlFor={`o-q-${p.id}`}>
                  <span>{p.question}</span>
                  <textarea id={`o-q-${p.id}`} className="tec-input app-textarea" rows={2} maxLength={1000} value={answerFor(p.id)} onChange={(e) => setTyped((cur) => ({ ...cur, [p.id]: e.target.value }))} />
                </label>
              ))}
            </fieldset>
          </Card>
        )}

        <Card title="Growth">
          <fieldset className="app-fieldset tec-fields" disabled={ro}>
            {area('o-goal', 'Development goal', 'development_goal')}
            {area('o-notes', 'Notes about serving', 'notes', 'Serving only; pastoral matters go to a check-in', 2000)}
          </fieldset>
          {canWrite && (
            <Checkbox id="o-flag" label="Ask for a pastoral check-in (a flag only: no reasons are recorded)" checked={flag} onChange={(e) => setFlag(e.target.checked)} />
          )}
          {/* SECURITY REVIEW 17 (W08): "Support needed: a pastoral check-in" is a note on the
              one-to-one only; the pastoral team is told only by the flag. */}
          {canWrite && v.support_needed === 'pastoral_check_in' && !flag && (
            <p className="type-caption" role="status" style={{ margin: 0 }}>
              You chose a pastoral check-in as the support needed. Tick the box above so the pastoral team is told; the one-to-one
              itself is not shared with them.
            </p>
          )}
        </Card>

        {(error || save.error) && (
          <Notice tone="danger" title={error || !savedFirst ? 'Not saved' : 'Partly saved'}>
            {error ?? saveErrorMessage(save.error, savedFirst)}
          </Notice>
        )}
        {canWrite && (
          <div className="tec-row" style={{ padding: 0 }}>
            <Button type="submit" variant="primary" disabled={save.isPending}>
              {save.isPending ? 'Saving…' : oto ? 'Save changes' : 'Save one-to-one'}
            </Button>
            <Link to="/one-to-ones">Cancel</Link>
          </div>
        )}
      </form>

      {oto && canWrite && <Recognise personId={personId} unitId={unitId} name={name} />}
    </>
  );
}

// ---------- Personal walk with God: restricted and logged ----------
// SECURITY REVIEW 17 (W05): who is offered the panel follows walkAccess (the writer even if
// they no longer lead the team, so a refusal from the database is shown, not hidden); the
// button names the section and says the view is recorded, and the loaded notes are announced.
function WalkPanel({ oto, canWrite, value, onChange, onLoaded }: { oto: OneToOne | null; canWrite: boolean; value: string; onChange: (v: string) => void; onLoaded: (v: string) => void }) {
  const me = useMe();
  const access = walkAccess({
    isNew: !oto,
    canWrite,
    isWriter: !!oto && oto.lead_user_id === me.data?.id,
    isWide: hasRole(me.data, 'gsquad_coordinator', 'resident_pastor'),
  });
  const [shown, setShown] = useState<boolean>(access === 'edit');
  const read = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('get_one_to_one_walk', { p_one_to_one: oto!.id });
      if (error) throw error;
      return (data as string | null) ?? '';
    },
    onSuccess: (text) => {
      onLoaded(text);
      setShown(true);
    },
  });
  return (
    <Card title="Personal walk with God">
      <p id="o-walk-who" className="type-caption" style={{ margin: 0 }}>
        Seen only by the Team Lead who held the one-to-one, the G-Squad Coordinator and the Resident Pastor. Every view is recorded.
      </p>
      {access === 'none' ? (
        <p style={{ margin: 0 }}>Not shown to your role.</p>
      ) : !shown ? (
        <div>
          <Button size="sm" variant="secondary" icon="lock" disabled={read.isPending} onClick={() => read.mutate()} aria-label="Show the personal walk with God notes (your view is recorded)" aria-describedby="o-walk-who">
            {read.isPending ? 'Opening…' : 'Show this section'}
          </Button>
        </div>
      ) : canWrite ? (
        <label className="tec-field" htmlFor="o-walk">
          <span>
            Notes on their walk with God <span className="tec-hint">(optional)</span>
          </span>
          <textarea id="o-walk" className="tec-input app-textarea" rows={3} maxLength={1000} value={value} aria-describedby="o-walk-who" onChange={(e) => onChange(e.target.value)} />
        </label>
      ) : (
        <p role="status" style={{ margin: 0, whiteSpace: 'pre-wrap' }}>{value || 'Nothing recorded.'}</p>
      )}
      {read.error && <Notice tone="danger">{friendlyError(read.error)}</Notice>}
    </Card>
  );
}

// ---------- Values in Action: recognise an act of service (shared only with agreement) ----------
function Recognise({ personId, unitId, name }: { personId: string; unitId: string; name: string }) {
  const values = useCoreValues();
  const qc = useQueryClient();
  const [v, setV] = useState({ value: '', description: '', newsletter: false, meeting: false, agreed: false });
  const add = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('recognitions').insert({
        person_id: personId,
        unit_id: unitId,
        value_id: v.value,
        description: v.description.trim(),
        offered_to_newsletter: v.agreed && v.newsletter,
        offered_to_meeting: v.agreed && v.meeting,
        person_agreed: v.agreed,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setV({ value: '', description: '', newsletter: false, meeting: false, agreed: false });
      qc.invalidateQueries({ queryKey: ['values_in_action'] });
    },
  });
  return (
    <Card title="Values in Action">
      <p className="type-caption" style={{ margin: 0 }}>
        Recognise {name} for an act of service that showed one of the values. It is shared in The Greatness Brief or a G-Squad
        meeting only if they agree.
      </p>
      <div className="tec-fields">
        <SelectField id="r-value" label="Value shown" value={v.value} onChange={(e) => setV({ ...v, value: e.target.value })} options={[{ value: '', label: 'Choose a value' }, ...(values.data ?? []).map((x) => ({ value: x.id, label: `${x.letter} · ${x.name}` }))]} />
        <TextField id="r-desc" label="What they did" maxLength={280} value={v.description} onChange={(e) => setV({ ...v, description: e.target.value })} />
        <Checkbox id="r-agreed" label={`${name} agrees to it being shared`} checked={v.agreed} onChange={(e) => setV({ ...v, agreed: e.target.checked, newsletter: e.target.checked && v.newsletter, meeting: e.target.checked && v.meeting })} />
        <Checkbox id="r-news" label="Offer it to the newsletter" disabled={!v.agreed} checked={v.newsletter} onChange={(e) => setV({ ...v, newsletter: e.target.checked })} />
        <Checkbox id="r-meet" label="Offer it to a G-Squad meeting" disabled={!v.agreed} checked={v.meeting} onChange={(e) => setV({ ...v, meeting: e.target.checked })} />
      </div>
      {add.isError && <Notice tone="danger">{friendlyError(add.error)}</Notice>}
      {add.isSuccess && <Notice tone="ok">Recognised. Thank you for noticing.</Notice>}
      <div>
        <Button variant="secondary" disabled={!v.value || !v.description.trim() || add.isPending} onClick={() => add.mutate()}>
          Add recognition
        </Button>
      </div>
    </Card>
  );
}
