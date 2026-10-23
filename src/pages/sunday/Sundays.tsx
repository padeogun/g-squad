// -------------------------------------------------------------------------------------
// Sunday Operations: every Sunday's service grid, coming and past, with its status, and (for
// the Operations Lead) "Set up a Sunday", which creates the Sunday's project and grid in one
// step (public.create_sunday_service, migration 19).
// -------------------------------------------------------------------------------------
import { useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { finaliseDeadline, longDate, nextSunday, shortDate, todayIso, useSundays, type Grid } from '../../data/sundays';
import { hasRole, useMe } from '../../auth/useMe';
import { GridStatus } from './GridStatus';

const { SectionHeading, Card, Button, TextField, Notice, DataTable } = TEC;

export function Sundays() {
  const me = useMe();
  const sundays = useSundays();
  const canBuild = hasRole(me.data, 'operations_lead');
  // Read once per screen visit (React render functions must not read the clock directly).
  const [today] = useState(todayIso);
  const coming = (sundays.data ?? []).filter((g) => g.service_date >= today).reverse(); // soonest first
  const past = (sundays.data ?? []).filter((g) => g.service_date < today);

  const table = (list: Grid[]) => (
    <DataTable
      columns={[
        { key: 'date', label: 'Sunday' },
        { key: 'theme', label: 'Theme' },
        { key: 'status', label: 'Status' },
        { key: 'deadline', label: 'Finalise by' },
        { key: 'open', label: '' },
      ]}
      rows={list.map((g) => ({
        id: g.id,
        date: longDate(g.service_date),
        theme: g.theme ?? '',
        status: <GridStatus grid={g} />,
        deadline: shortDate(finaliseDeadline(g.service_date)),
        open: <Link to={`/sundays/${g.id}`}>Open</Link>,
      }))}
    />
  );

  return (
    <>
      <SectionHeading eyebrow="Sundays and events" title="Sunday Operations" rule>
        One service each Sunday. The Operations Lead builds the grid, finalises it by the Thursday before, and the
        Resident Pastor approves it.
      </SectionHeading>
      {canBuild && <SetUpSunday existing={(sundays.data ?? []).map((g) => g.service_date)} />}
      <Card title={`Coming Sundays (${coming.length})`}>
        {sundays.isPending && <p>Loading…</p>}
        {sundays.error && <Notice tone="danger">{friendlyError(sundays.error)}</Notice>}
        {sundays.data && coming.length === 0 && <p>No Sundays set up yet.</p>}
        {coming.length > 0 && table(coming)}
      </Card>
      {past.length > 0 && <Card title={`Past Sundays (${past.length})`}>{table(past)}</Card>}
    </>
  );
}

// ---------- Set up a Sunday (Operations Lead) ----------
function SetUpSunday({ existing }: { existing: string[] }) {
  const qc = useQueryClient();
  const navigate = useNavigate();
  // Default to the first Sunday from today that has no grid yet.
  const [date, setDate] = useState(() => {
    let d = nextSunday();
    while (existing.includes(d)) d = nextSunday(new Date(new Date(`${d}T12:00:00Z`).getTime() + 86_400_000));
    return d;
  });
  const [starts, setStarts] = useState('10:00');
  const [ends, setEnds] = useState('12:40');
  const [theme, setTheme] = useState('');
  const [error, setError] = useState('');

  const create = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('create_sunday_service', {
        p_date: date,
        p_starts: starts,
        p_ends: ends,
        p_theme: theme.trim() || (null as unknown as string),
      });
      if (error) throw error;
      return data as string;
    },
    onSuccess: (gridId) => {
      qc.invalidateQueries({ queryKey: ['grids'] });
      navigate(`/sundays/${gridId}`);
    },
  });

  function onSubmit(e: FormEvent) {
    e.preventDefault();
    // Same checks as the database, shown by the field first.
    if (new Date(`${date}T12:00:00Z`).getUTCDay() !== 0) return setError('Choose a Sunday.');
    if (existing.includes(date)) return setError('That Sunday already has a grid.');
    if (ends <= starts) return setError('The service must end after it starts.');
    setError('');
    create.mutate();
  }

  return (
    <Card title="Set up a Sunday" tone="tint">
      <form className="app-form" onSubmit={onSubmit} noValidate>
        <div className="tec-fields">
          <TextField id="sun-date" label="Sunday" type="date" required value={date} onChange={(e) => setDate(e.target.value)} />
          <TextField id="sun-start" label="Starts" type="time" required value={starts} onChange={(e) => setStarts(e.target.value)} />
          <TextField id="sun-end" label="Ends" type="time" required value={ends} onChange={(e) => setEnds(e.target.value)} />
          <TextField id="sun-theme" label="Theme" hint="(optional)" maxLength={200} value={theme} onChange={(e) => setTheme(e.target.value)} />
        </div>
        {(error || create.isError) && (
          <Notice tone="danger" title="Not set up">
            {error || friendlyError(create.error)}
          </Notice>
        )}
        <div>
          <Button type="submit" variant="primary" icon="calendar" disabled={create.isPending}>
            {create.isPending ? 'Setting up…' : 'Set up this Sunday'}
          </Button>
        </div>
      </form>
    </Card>
  );
}
