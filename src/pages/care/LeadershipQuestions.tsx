// -------------------------------------------------------------------------------------
// Leadership questions for one-to-ones (decision of 25 Oct 2026): the G-Squad Coordinator (or
// the Resident Pastor) adds a question for a period; every one-to-one held in that period
// shows it, and the Team Lead records the answer. A question that has been answered is
// switched off rather than deleted, so its answers keep their question.
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { shortDate, todayIso } from '../../data/sundays';
import { quarterEnd, quarterStart, usePrompts } from '../../data/oneToOnes';
import { hasRole, useMe } from '../../auth/useMe';

const { SectionHeading, Card, Notice, Button, TextField, DataTable, Chip } = TEC;

export function LeadershipQuestions() {
  const me = useMe();
  const qc = useQueryClient();
  const prompts = usePrompts();
  const [today] = useState(todayIso);
  const [v, setV] = useState({ question: '', from: quarterStart(today), to: quarterEnd(quarterStart(today)) });
  const allowed = hasRole(me.data, 'gsquad_coordinator', 'resident_pastor');

  const refresh = () => qc.invalidateQueries({ queryKey: ['ref', 'one_to_one_prompts'] });
  const add = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('one_to_one_prompts').insert({ question: v.question.trim(), starts_on: v.from, ends_on: v.to });
      if (error) throw error;
    },
    onSuccess: () => {
      setV({ ...v, question: '' });
      refresh();
    },
  });
  const toggle = useMutation({
    mutationFn: async ({ id, on }: { id: string; on: boolean }) => {
      const { error } = await supabase.from('one_to_one_prompts').update({ is_active: on }).eq('id', id).select('id').single();
      if (error) throw error;
    },
    onSuccess: refresh,
  });

  if (me.isPending) return <p>Loading…</p>;
  return (
    <>
      <SectionHeading eyebrow="Care and growth" title="Leadership questions" rule>
        Questions the leadership wants asked in every one-to-one for a period, for example after a change to Sunday times.
      </SectionHeading>
      <p style={{ margin: 0 }}>
        <Link to="/one-to-ones">One-to-ones</Link>
      </p>
      {!allowed && <Notice tone="info">Leadership questions are set by the G-Squad Coordinator or the Resident Pastor.</Notice>}
      {allowed && (
        <Card title="Add a question" tone="tint">
          {/* SECURITY REVIEW 17 (W07): answers are read by everyone who reads the one-to-one,
              including the team's Purpose Head, so they are not the place for faith or pastoral matters. */}
          <p className="type-caption" style={{ margin: 0 }}>
            Answers are read by everyone who reads the one-to-one, including the team&apos;s Purpose Head. Do not ask about a
            member&apos;s walk with God, health or other pastoral matters here. Once a question has answers its wording cannot change.
          </p>
          <div className="tec-fields">
            <TextField id="lq-q" label="Question" maxLength={300} value={v.question} onChange={(e) => setV({ ...v, question: e.target.value })} />
            <TextField id="lq-from" label="Asked from" type="date" value={v.from} onChange={(e) => setV({ ...v, from: e.target.value })} />
            <TextField id="lq-to" label="Until" type="date" min={v.from} value={v.to} onChange={(e) => setV({ ...v, to: e.target.value })} />
          </div>
          {add.isError && <Notice tone="danger">{friendlyError(add.error)}</Notice>}
          <div>
            <Button variant="primary" disabled={!v.question.trim() || !v.from || !v.to || v.to < v.from || add.isPending} onClick={() => add.mutate()}>
              Add question
            </Button>
          </div>
        </Card>
      )}
      <Card title="Questions">
        {prompts.isPending && <p>Loading…</p>}
        {prompts.error && <Notice tone="danger">{friendlyError(prompts.error)}</Notice>}
        {prompts.data && prompts.data.length === 0 && <p>No questions yet.</p>}
        {toggle.isError && <Notice tone="danger">{friendlyError(toggle.error)}</Notice>}
        {prompts.data && prompts.data.length > 0 && (
          <DataTable
            columns={[
              { key: 'q', label: 'Question' },
              { key: 'when', label: 'Asked' },
              { key: 'status', label: 'Status' },
              ...(allowed ? [{ key: 'act', label: '' }] : []),
            ]}
            rows={prompts.data.map((p) => ({
              id: p.id,
              q: p.question,
              when: `${shortDate(p.starts_on)} – ${shortDate(p.ends_on)}`,
              status: !p.is_active ? <Chip tone="neutral">Switched off</Chip> : p.ends_on < today ? <Chip tone="neutral">Finished</Chip> : p.starts_on > today ? <Chip tone="info">Coming</Chip> : <Chip tone="ok">Being asked</Chip>,
              act: (
                <button type="button" className="app-link-button" disabled={toggle.isPending} onClick={() => toggle.mutate({ id: p.id, on: !p.is_active })} aria-label={`${p.is_active ? 'Switch off' : 'Switch on'}: ${p.question}`}>
                  {p.is_active ? 'Switch off' : 'Switch on'}
                </button>
              ),
            }))}
          />
        )}
      </Card>
    </>
  );
}
