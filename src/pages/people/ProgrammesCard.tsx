// -------------------------------------------------------------------------------------
// The team's programmes (migration 37, decision of 27 Nov 2026): its core routine functions,
// e.g. the choir's rehearsals, singing in services, prayer and Bible study, team building.
// A programme that coordinates a core deliverable for the church reports monthly in one area
// (Maturity: discipleship classes; Evangelism: outreach; Assimilation: welcoming and
// onboarding visitors); one geared to presentation does not report. The Team Lead, the
// Coordinator or the Operations Lead keeps the list (the database checks:
// app.can_keep_programmes); a Deputy sees it. Events and routine activities are linked to a
// programme from the project form, so their counts reach the monthly report.
// -------------------------------------------------------------------------------------
import { useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { AREAS, AREA_KEYS, useProgrammes, type ProgrammeArea } from '../../data/programmes';

const { Card, Button, TextField, SelectField, Notice, Chip } = TEC;

export function ProgrammesCard({ unitId, canEdit }: { unitId: string; canEdit: boolean }) {
  const qc = useQueryClient();
  const programmes = useProgrammes();
  const [v, setV] = useState({ name: '', description: '', report_area: '' });
  const [err, setErr] = useState('');
  const list = (programmes.data ?? []).filter((x) => x.unit_id === unitId);
  const done = () => qc.invalidateQueries({ queryKey: ['programmes'] });

  const add = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('unit_programmes').insert({
        unit_id: unitId,
        name: v.name.trim(),
        description: v.description.trim() || null,
        report_area: (v.report_area || null) as ProgrammeArea | null,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setV({ name: '', description: '', report_area: '' });
      done();
    },
  });
  // A programme with linked projects is stopped rather than deleted, so its history stays.
  const setActive = useMutation({
    mutationFn: async ({ id, active }: { id: string; active: boolean }) => {
      const { error } = await supabase.from('unit_programmes').update({ is_active: active }).eq('id', id).select('id').single();
      if (error) throw error;
    },
    onSuccess: done,
  });

  function onAdd(e: FormEvent) {
    e.preventDefault();
    if (!v.name.trim()) return setErr('Name the programme');
    setErr('');
    add.mutate();
  }

  const reports = list.some((x) => x.is_active && x.report_area);
  return (
    <Card title="Team programmes">
      <p className="type-caption" style={{ margin: 0 }}>
        The team&rsquo;s core routine functions. Those that coordinate a core deliverable for the church report monthly; those geared to
        presentation do not.
        {reports && (
          <>
            {' '}
            <Link to="/programme-reports">Monthly programme report</Link>
          </>
        )}
      </p>
      {programmes.error && <Notice tone="danger">{friendlyError(programmes.error)}</Notice>}
      {list.length === 0 && !programmes.isPending && <p style={{ margin: 0 }}>No programmes listed yet.</p>}
      {list.length > 0 && (
        <ul className="app-checks">
          {list.map((x) => (
            <li key={x.id}>
              <Chip tone={x.report_area ? 'info' : 'neutral'}>{x.report_area ? `Reports: ${AREAS[x.report_area].label}` : 'Presentation'}</Chip>
              <span>
                {x.name}
                {x.description ? ` – ${x.description}` : ''}
                {!x.is_active && ' (stopped)'}
              </span>
              {canEdit && (
                <Button variant="quiet" disabled={setActive.isPending} onClick={() => setActive.mutate({ id: x.id, active: !x.is_active })}>
                  {x.is_active ? 'Stop' : 'Restart'}
                </Button>
              )}
            </li>
          ))}
        </ul>
      )}
      {setActive.isError && <Notice tone="danger">{friendlyError(setActive.error)}</Notice>}
      {canEdit && (
        <form onSubmit={onAdd} noValidate className="app-form">
          <div className="tec-fields">
            <TextField id="pg-name" label="Programme" hint={err ? `– ${err}` : 'e.g. Rehearsals, Discipleship classes'} maxLength={120} value={v.name} onChange={(e) => setV({ ...v, name: e.target.value })} />
            <SelectField
              id="pg-area"
              label="Monthly report"
              value={v.report_area}
              onChange={(e) => setV({ ...v, report_area: e.target.value })}
              options={[{ value: '', label: 'None (geared to presentation)' }, ...AREA_KEYS.map((k) => ({ value: k, label: `Reports on ${AREAS[k].label}` }))]}
            />
            <TextField id="pg-desc" label="Description" hint="(optional)" maxLength={1000} value={v.description} onChange={(e) => setV({ ...v, description: e.target.value })} />
          </div>
          {add.isError && <Notice tone="danger">{friendlyError(add.error)}</Notice>}
          <div>
            <Button type="submit" variant="secondary" disabled={add.isPending}>
              {add.isPending ? 'Adding…' : 'Add programme'}
            </Button>
          </div>
        </form>
      )}
    </Card>
  );
}
