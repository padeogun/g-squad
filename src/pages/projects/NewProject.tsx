// -------------------------------------------------------------------------------------
// New project: name, type, whole church or one unit, where and when, and (for an event) its
// size and complexity, which start the High-level Event Planning form. The creator becomes
// the owner. Every project starts as a draft (project_guard). Who may create which:
//   * church projects: Operations Lead, G-Squad Coordinator, Resident Pastor, Purpose Heads;
//   * unit projects: the unit's Team Lead or Purpose Head, the Coordinator or Ops Lead.
// Times are London wall-clock times (see londonToIso).
// -------------------------------------------------------------------------------------
import { useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { useUnits } from '../../data/reference';
import { londonToIso, PROJECT_CREATORS, useProjectTypes, useSites } from '../../data/projects';
import { hasRole, ledUnitIds, useMe } from '../../auth/useMe';
import { todayIso } from '../../data/sundays';

const { SectionHeading, Card, Notice, Button, TextField, SelectField, Checkbox } = TEC;

export function NewProject() {
  const me = useMe();
  const qc = useQueryClient();
  const navigate = useNavigate();
  const units = useUnits();
  const types = useProjectTypes();
  const sites = useSites();
  const [today] = useState(todayIso);

  const wide = hasRole(me.data, 'operations_lead', 'gsquad_coordinator');
  const canChurch = wide || hasRole(me.data, 'resident_pastor', 'purpose_head');
  const myPurposes = (me.data?.roles ?? []).filter((r) => r.role === 'purpose_head').map((r) => r.purpose_id);
  const led = ledUnitIds(me.data);
  // Units this leader may start a project for.
  const unitChoices = (units.data ?? []).filter((u) => u.is_active && (wide || led.includes(u.id) || myPurposes.includes(u.purpose_id)));

  const [v, setV] = useState({
    name: '',
    type_id: '',
    level: canChurch ? 'church' : 'unit',
    unit_id: unitChoices.length === 1 ? unitChoices[0].id : '',
    site_id: '',
    start_date: '',
    start_time: '10:00',
    end_date: '',
    end_time: '13:00',
    description: '',
    is_event: true,
    size: 'small',
    complexity: 'low',
  });
  const set = (k: keyof typeof v, val: string | boolean) => setV((cur) => ({ ...cur, [k]: val }));
  const [errors, setErrors] = useState<Record<string, string>>({});

  const save = useMutation({
    mutationFn: async () => {
      const starts = londonToIso(v.start_date, v.start_time);
      const ends = londonToIso(v.end_date || v.start_date, v.end_time);
      const { data, error } = await supabase
        .from('projects')
        .insert({
          name: v.name.trim(),
          type_id: v.type_id || null,
          level: v.level as 'church' | 'unit',
          unit_id: v.level === 'unit' ? v.unit_id : null,
          site_id: v.site_id || null,
          starts_at: starts,
          ends_at: ends,
          description: v.description.trim() || null,
        })
        .select('id')
        .single();
      if (error) throw error;
      // An event starts its planning form now; if that step fails, the project still exists
      // and the form can be started from the project page.
      if (v.is_event) {
        const { error: planError } = await supabase
          .from('event_plans')
          .insert({ project_id: data.id, size: v.size as 'small', complexity: v.complexity as 'low' });
        if (planError) return { id: data.id, planError };
      }
      return { id: data.id, planError: null };
    },
    onSuccess: ({ id }) => {
      qc.invalidateQueries({ queryKey: ['projects'] });
      navigate(`/projects/${id}`);
    },
  });

  function onSubmit(e: FormEvent) {
    e.preventDefault();
    const found: Record<string, string> = {};
    if (!v.name.trim()) found.name = 'Give it a name';
    if (v.level === 'unit' && !v.unit_id) found.unit_id = 'Choose the unit';
    if (!v.start_date) found.start_date = 'Choose the start date';
    else if (v.start_date < today) found.start_date = 'The start date has passed';
    if (v.end_date && v.end_date < v.start_date) found.end_date = 'Ends before it starts';
    if ((v.end_date || v.start_date) === v.start_date && v.end_time < v.start_time) found.end_time = 'Ends before it starts';
    setErrors(found);
    if (Object.keys(found).length === 0) save.mutate();
  }

  const hint = (k: string, fallback?: string) => (errors[k] ? `– ${errors[k]}` : fallback);

  if (me.isPending) return <p>Loading…</p>;
  if (!hasRole(me.data, ...PROJECT_CREATORS))
    return (
      <>
        <SectionHeading eyebrow="Projects and events" title="New project" rule />
        <Notice tone="info">Projects are started by Team Leads, Purpose Heads, the G-Squad Coordinator, the Operations Lead and the Resident Pastor.</Notice>
      </>
    );

  return (
    <>
      <SectionHeading eyebrow="Projects and events" title="New project" rule>
        It starts as a draft. Fill in the plan, then submit it for approval.
      </SectionHeading>
      <p style={{ margin: 0 }}>
        <Link to="/projects">All projects</Link>
      </p>
      <form onSubmit={onSubmit} noValidate className="app-form">
        <Card title="About it">
          <div className="tec-fields">
            <TextField id="np-name" label="Name" hint={hint('name')} required maxLength={200} value={v.name} onChange={(e) => set('name', e.target.value)} aria-invalid={!!errors.name || undefined} />
            <SelectField
              id="np-type"
              label="Type"
              hint="(optional)"
              value={v.type_id}
              onChange={(e) => {
                const t = types.data?.find((x) => x.id === e.target.value);
                set('type_id', e.target.value);
                // The type suggests the level (e.g. "Unit-level"), if this leader may use it.
                if (t && (t.default_level === 'unit' || canChurch)) set('level', t.default_level);
              }}
              options={[
                { value: '', label: 'Choose a type' },
                ...(types.data ?? []).filter((t) => t.is_active && t.name !== 'Sunday Service').map((t) => ({ value: t.id, label: t.name })),
              ]}
            />
            <SelectField
              id="np-level"
              label="For"
              value={v.level}
              onChange={(e) => set('level', e.target.value)}
              options={[...(canChurch ? [{ value: 'church', label: 'The whole church' }] : []), { value: 'unit', label: 'One unit' }]}
            />
            {v.level === 'unit' && (
              <SelectField
                id="np-unit"
                label="Unit"
                hint={hint('unit_id')}
                value={v.unit_id}
                onChange={(e) => set('unit_id', e.target.value)}
                options={[{ value: '', label: 'Choose a unit' }, ...unitChoices.map((u) => ({ value: u.id, label: u.name }))]}
                aria-invalid={!!errors.unit_id || undefined}
              />
            )}
            <SelectField
              id="np-site"
              label="Site"
              hint="(optional)"
              value={v.site_id}
              onChange={(e) => set('site_id', e.target.value)}
              options={[{ value: '', label: 'Not set' }, ...(sites.data ?? []).map((s) => ({ value: s.id, label: s.name }))]}
            />
            <label className="tec-field app-field-wide" htmlFor="np-desc">
              <span>
                Description <span className="tec-hint">(optional)</span>
              </span>
              <textarea id="np-desc" className="tec-input app-textarea" rows={3} maxLength={4000} value={v.description} onChange={(e) => set('description', e.target.value)} />
            </label>
          </div>
        </Card>

        <Card title="When">
          <div className="tec-fields">
            <TextField id="np-sd" label="Starts on" type="date" min={today} hint={hint('start_date')} value={v.start_date} onChange={(e) => set('start_date', e.target.value)} aria-invalid={!!errors.start_date || undefined} />
            <TextField id="np-st" label="Start time" type="time" value={v.start_time} onChange={(e) => set('start_time', e.target.value)} />
            <TextField id="np-ed" label="Ends on" type="date" min={v.start_date || today} hint={hint('end_date', '(if a different day)')} value={v.end_date} onChange={(e) => set('end_date', e.target.value)} aria-invalid={!!errors.end_date || undefined} />
            <TextField id="np-et" label="End time" type="time" hint={hint('end_time')} value={v.end_time} onChange={(e) => set('end_time', e.target.value)} aria-invalid={!!errors.end_time || undefined} />
          </div>
          <p className="type-caption" style={{ margin: 0 }}>
            UK time.
          </p>
        </Card>

        <Card title="Event planning">
          <Checkbox id="np-event" label="This is an event: use the High-level Event Planning form" checked={v.is_event} onChange={(e) => set('is_event', e.target.checked)} />
          {v.is_event && (
            <div className="tec-fields">
              <SelectField
                id="np-size"
                label="Size"
                hint="Sets the lead time it needs"
                value={v.size}
                onChange={(e) => set('size', e.target.value)}
                options={[
                  { value: 'small', label: 'Small (under 100)' },
                  { value: 'medium', label: 'Medium (100 to 200)' },
                  { value: 'large', label: 'Large (over 200)' },
                ]}
              />
              <SelectField
                id="np-complexity"
                label="Complexity"
                hint="High needs a planning committee"
                value={v.complexity}
                onChange={(e) => set('complexity', e.target.value)}
                options={[
                  { value: 'low', label: 'Low' },
                  { value: 'moderate', label: 'Moderate' },
                  { value: 'high', label: 'High' },
                ]}
              />
            </div>
          )}
        </Card>

        {save.isError && (
          <Notice tone="danger" title="Not created">
            {friendlyError(save.error)}
          </Notice>
        )}
        <div className="tec-row" style={{ padding: 0 }}>
          <Button type="submit" variant="primary" disabled={save.isPending}>
            {save.isPending ? 'Creating…' : 'Create draft'}
          </Button>
          <Link to="/projects">Cancel</Link>
        </div>
      </form>
    </>
  );
}
