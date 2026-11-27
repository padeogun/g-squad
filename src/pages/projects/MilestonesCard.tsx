// -------------------------------------------------------------------------------------
// Milestones and outputs of a goal-based project (migration 37, decision of 27 Nov 2026).
// A goal-based project has these instead of a run of show: it goes for approval with at least
// one, and closes when every one is met. The owner or the Operations Lead keeps them while the
// project is open; everyone in the church reads them. The database checks each change
// (app.milestone_guard): a milestone is met on a day that has come.
// -------------------------------------------------------------------------------------
import { useState, type FormEvent } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { openMilestones, useMilestones } from '../../data/programmes';
import { todayIso } from '../../data/sundays';
import type { Project } from '../../data/projects';

const { Card, Notice, Button, TextField } = TEC;

export function MilestonesCard({ p, canManage }: { p: Project; canManage: boolean }) {
  const qc = useQueryClient();
  const ms = useMilestones(p.id);
  const [today] = useState(todayIso);
  const [v, setV] = useState({ title: '', output: '', due_on: '' });
  const [err, setErr] = useState('');
  const open = !['done', 'cancelled'].includes(p.status);
  const editable = canManage && open;

  // Every change refreshes the list and the readiness (which counts open milestones).
  const done = () => {
    qc.invalidateQueries({ queryKey: ['milestones', p.id] });
    qc.invalidateQueries({ queryKey: ['readiness', p.id] });
  };
  const add = useMutation({
    mutationFn: async () => {
      const { error } = await supabase
        .from('project_milestones')
        .insert({ project_id: p.id, title: v.title.trim(), output: v.output.trim() || null, due_on: v.due_on });
      if (error) throw error;
    },
    onSuccess: () => {
      setV({ title: '', output: '', due_on: '' });
      done();
    },
  });
  const change = useMutation({
    mutationFn: async ({ id, patch }: { id: string; patch: { done_on?: string | null } }) => {
      const { error } = await supabase.from('project_milestones').update(patch).eq('id', id).select('id').single();
      if (error) throw error;
    },
    onSuccess: done,
  });
  const remove = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('project_milestones').delete().eq('id', id).select('id').single();
      if (error) throw error;
    },
    onSuccess: done,
  });

  function onAdd(e: FormEvent) {
    e.preventDefault();
    if (!v.title.trim()) return setErr('Name the milestone');
    if (!v.due_on) return setErr('Choose when it is due');
    setErr('');
    add.mutate();
  }

  const list = ms.data ?? [];
  const failed = add.error ?? change.error ?? remove.error;
  return (
    <Card title="Milestones and outputs">
      <p className="type-caption" style={{ margin: 0 }}>
        What this project will deliver, and by when. It goes for approval with at least one milestone and closes when every one is met
        {list.length > 0 ? ` (${openMilestones(list)} of ${list.length} still to meet)` : ''}.
      </p>
      {ms.isPending && <p>Loading…</p>}
      {ms.error && <Notice tone="danger">{friendlyError(ms.error)}</Notice>}
      {list.length > 0 && (
        <table className="app-table">
          <thead>
            <tr>
              <th scope="col">Milestone</th>
              <th scope="col">Output</th>
              <th scope="col">Due</th>
              <th scope="col">Met</th>
              {editable && <th scope="col"><span className="app-visually-hidden">Actions</span></th>}
            </tr>
          </thead>
          <tbody>
            {list.map((m) => (
              <tr key={m.id}>
                <td>{m.title}</td>
                <td style={{ whiteSpace: 'pre-wrap' }}>{m.output ?? '—'}</td>
                <td>{m.due_on}</td>
                <td>{m.done_on ?? (m.due_on < today ? 'Overdue' : 'Not yet')}</td>
                {editable && (
                  <td className="tec-row" style={{ padding: 0 }}>
                    {m.done_on ? (
                      <Button variant="quiet" disabled={change.isPending} onClick={() => change.mutate({ id: m.id, patch: { done_on: null } })}>
                        Not met
                      </Button>
                    ) : (
                      <Button variant="secondary" disabled={change.isPending} onClick={() => change.mutate({ id: m.id, patch: { done_on: today } })}>
                        Met today
                      </Button>
                    )}
                    <Button
                      variant="quiet"
                      disabled={remove.isPending}
                      onClick={() => {
                        if (window.confirm(`Remove "${m.title}"?`)) remove.mutate(m.id);
                      }}
                    >
                      Remove
                    </Button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {list.length === 0 && !ms.isPending && <p style={{ margin: 0 }}>No milestones yet.</p>}
      {failed && <Notice tone="danger">{friendlyError(failed)}</Notice>}
      {editable && (
        <form onSubmit={onAdd} noValidate className="app-form">
          <div className="tec-fields">
            <TextField id="ms-title" label="Milestone" hint={err ? `– ${err}` : undefined} maxLength={200} value={v.title} onChange={(e) => setV({ ...v, title: e.target.value })} />
            <TextField id="ms-due" label="Due on" type="date" value={v.due_on} onChange={(e) => setV({ ...v, due_on: e.target.value })} />
            <label className="tec-field app-field-wide" htmlFor="ms-output">
              <span>
                Output <span className="tec-hint">(optional) what is delivered</span>
              </span>
              <textarea id="ms-output" className="tec-input app-textarea" rows={2} maxLength={1000} value={v.output} onChange={(e) => setV({ ...v, output: e.target.value })} />
            </label>
          </div>
          <div>
            <Button type="submit" variant="secondary" disabled={add.isPending}>
              {add.isPending ? 'Adding…' : 'Add milestone'}
            </Button>
          </div>
        </form>
      )}
    </Card>
  );
}
