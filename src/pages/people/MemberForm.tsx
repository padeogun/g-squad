// -------------------------------------------------------------------------------------
// New member entry form (/members/new) and a member's record (/members/:id).
// Follows the spec's member entry form and its data protection decisions:
//   * birthday and anniversary as day and month only, area only (never a full address);
//   * faith fields in their own panel, read and saved only through get_person_faith /
//     set_person_faith, which check access and log every view and change;
//   * the TECi stage is set by the TECi Coordinator (the database refuses others).
// Saving a new member: the person, then their unit membership, then faith fields (a Unit
// Lead may record faith fields only once the person is in their unit).
// -------------------------------------------------------------------------------------
import { useState, type FormEvent } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, useChurchRoles, useCommunities, useLeadershipStages, useTeciStages, useUnits } from '../../data/reference';
import { fetchFaith, fullName, saveFaith, useMemberships, usePerson, type FaithInput, type Person } from '../../data/people';
import { FAITH_READERS, hasRole, ledUnitIds, useMe } from '../../auth/useMe';
import { NotFound } from '../NotFound';

const { SectionHeading, Card, Button, TextField, SelectField, Checkbox, Notice, RestrictedPanel, Chip, DataTable } = TEC;

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const monthOptions = [{ value: '', label: 'Month' }, ...MONTHS.map((m, i) => ({ value: String(i + 1), label: m }))];
const dayOptions = [{ value: '', label: 'Day' }, ...Array.from({ length: 31 }, (_, i) => ({ value: String(i + 1), label: String(i + 1) }))];
const today = () => new Date().toISOString().slice(0, 10);

// Everything the form holds, as strings and booleans (converted when saving).
interface Values {
  first_name: string;
  other_names: string;
  surname: string;
  email: string;
  area: string;
  birth_day: string;
  birth_month: string;
  marital_status: string;
  anniversary_day: string;
  anniversary_month: string;
  date_joined: string;
  status: string; // active | paused (left is set by a leaving date)
  date_left: string;
  teci_stage_id: string;
  greatness_community_id: string;
  newsletter_subscribed: boolean;
  celebration_opt_in: boolean;
}

const EMPTY: Values = {
  first_name: '',
  other_names: '',
  surname: '',
  email: '',
  area: '',
  birth_day: '',
  birth_month: '',
  marital_status: '',
  anniversary_day: '',
  anniversary_month: '',
  date_joined: today(),
  status: 'active',
  date_left: '',
  teci_stage_id: '',
  greatness_community_id: '',
  newsletter_subscribed: true,
  celebration_opt_in: false,
};

// Fills the form from a saved person.
function fromPerson(p: Person): Values {
  const s = (v: unknown) => (v == null ? '' : String(v));
  return {
    first_name: p.first_name,
    other_names: s(p.other_names),
    surname: p.surname,
    email: s(p.email),
    area: s(p.area),
    birth_day: s(p.birth_day),
    birth_month: s(p.birth_month),
    marital_status: s(p.marital_status),
    anniversary_day: s(p.anniversary_day),
    anniversary_month: s(p.anniversary_month),
    date_joined: p.date_joined,
    status: p.status === 'paused' ? 'paused' : 'active',
    date_left: s(p.date_left),
    teci_stage_id: s(p.teci_stage_id),
    greatness_community_id: s(p.greatness_community_id),
    newsletter_subscribed: p.newsletter_subscribed,
    celebration_opt_in: p.celebration_opt_in,
  };
}

// The row to save. Empty optional fields become null; a leaving date makes the status "left".
function toPersonRow(v: Values, includeTeci: boolean) {
  const t = (s: string) => (s.trim() === '' ? null : s.trim());
  const n = (s: string) => (s === '' ? null : Number(s));
  const married = v.marital_status === 'married';
  return {
    first_name: v.first_name.trim(),
    other_names: t(v.other_names),
    surname: v.surname.trim(),
    email: t(v.email)?.toLowerCase() ?? null,
    area: t(v.area),
    birth_day: n(v.birth_day),
    birth_month: n(v.birth_month),
    marital_status: (t(v.marital_status) as Person['marital_status']) ?? null,
    // An anniversary is kept only for married members.
    anniversary_day: married ? n(v.anniversary_day) : null,
    anniversary_month: married ? n(v.anniversary_month) : null,
    date_joined: v.date_joined,
    date_left: t(v.date_left),
    status: (v.date_left ? 'left' : v.status) as Person['status'],
    greatness_community_id: t(v.greatness_community_id),
    newsletter_subscribed: v.newsletter_subscribed,
    celebration_opt_in: v.celebration_opt_in,
    // Sent only by those allowed to set it, so others' saves never touch it.
    ...(includeTeci ? { teci_stage_id: t(v.teci_stage_id) } : {}),
  };
}

// Checks before saving, matching the database's rules, so the message sits by the field.
function checkPerson(v: Values): Record<string, string> {
  const e: Record<string, string> = {};
  if (!v.first_name.trim()) e.first_name = 'First name is required';
  if (!v.surname.trim()) e.surname = 'Surname is required';
  if (v.email.trim() && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v.email.trim())) e.email = 'Enter a valid email address';
  if (!!v.birth_day !== !!v.birth_month) e.birth_day = 'Give both day and month, or neither';
  else if (v.birth_day && !realDay(+v.birth_day, +v.birth_month)) e.birth_day = 'That day is not in that month';
  if (v.marital_status === 'married') {
    if (!!v.anniversary_day !== !!v.anniversary_month) e.anniversary_day = 'Give both day and month, or neither';
    else if (v.anniversary_day && !realDay(+v.anniversary_day, +v.anniversary_month))
      e.anniversary_day = 'That day is not in that month';
  }
  if (!v.date_joined) e.date_joined = 'Date joined is required';
  if (v.date_left && v.date_left < v.date_joined) e.date_left = 'Cannot be before the date joined';
  return e;
}

// Is day d a real day of month m? (29 February is allowed: no year is held.)
function realDay(d: number, m: number) {
  return d >= 1 && d <= new Date(2000, m, 0).getDate();
}

export function MemberForm() {
  const { id } = useParams();
  const isNew = !id;
  const person = usePerson(id);
  if (!isNew && person.isPending) return <p>Loading…</p>;
  if (!isNew && !person.data) return <NotFound />;
  return <MemberFormInner key={id ?? 'new'} person={person.data ?? undefined} />;
}

function MemberFormInner({ person }: { person?: Person }) {
  const me = useMe();
  const qc = useQueryClient();
  const navigate = useNavigate();
  const units = useUnits();
  const roles = useChurchRoles();
  const stages = useLeadershipStages();
  const teci = useTeciStages();
  const communities = useCommunities();
  const memberships = useMemberships();

  const [v, setV] = useState<Values>(() => (person ? fromPerson(person) : EMPTY));
  const [errors, setErrors] = useState<Record<string, string>>({});
  const set = <K extends keyof Values>(k: K, val: Values[K]) => setV((cur) => ({ ...cur, [k]: val }));

  // Who may do what (display only: the database checks every save).
  const canSetTeci = hasRole(me.data, 'teci_coordinator', 'operations_lead');
  const isOps = hasRole(me.data, 'operations_lead');
  const myUnits = ledUnitIds(me.data);
  const mayRecordFaith = hasRole(me.data, ...FAITH_READERS) || myUnits.length > 0;

  // Unit for a NEW member: a Unit Lead picks one of their units; the Operations Lead any unit.
  const unitChoices = (units.data ?? []).filter((u) => u.is_active && (isOps || myUnits.includes(u.id)));
  const [unitId, setUnitId] = useState(() => (myUnits.length === 1 ? myUnits[0] : ''));
  const [roleId, setRoleId] = useState('');
  const [isLeader, setIsLeader] = useState(false);
  const [stageId, setStageId] = useState('');

  // Faith fields: loaded through the logged function for an existing member.
  const faith = useQuery({
    queryKey: ['faith', person?.id],
    enabled: !!person && mayRecordFaith,
    // A view is logged each time, so don't re-fetch in the background.
    staleTime: Infinity,
    gcTime: 0,
    queryFn: () => fetchFaith(person!.id),
  });
  // The faith fields being edited: null until the leader changes something, so the form shows
  // the loaded record (or an empty one) without copying it into state.
  const [edited, setEdited] = useState<FaithInput | null>(null);
  const loaded = faith.data && faith.data !== 'restricted' ? faith.data : null;
  const f: FaithInput = edited ?? {
    salvation_date: loaded?.salvation_date ?? null,
    water_baptism: loaded?.water_baptism ?? false,
    water_baptism_date: loaded?.water_baptism_date ?? null,
    holy_spirit_baptism: loaded?.holy_spirit_baptism ?? false,
    holy_spirit_baptism_date: loaded?.holy_spirit_baptism_date ?? null,
    speaks_in_tongues: loaded?.speaks_in_tongues ?? false,
    speaks_in_tongues_date: loaded?.speaks_in_tongues_date ?? null,
  };
  const faithTouched = edited !== null;
  const setFaith = <K extends keyof FaithInput>(k: K, val: FaithInput[K]) => setEdited({ ...f, [k]: val });
  const faithRestricted = faith.data === 'restricted';

  const save = useMutation({
    mutationFn: async () => {
      let personId = person?.id;
      if (person) {
        // .select().single(): an update refused by row-level security returns no row; this
        // turns that into an error instead of a silent "saved".
        const { error } = await supabase.from('people').update(toPersonRow(v, canSetTeci)).eq('id', person.id).select('id').single();
        if (error) throw error;
      } else {
        const { data, error } = await supabase.from('people').insert(toPersonRow(v, canSetTeci)).select('id').single();
        if (error) throw error;
        personId = data.id;
        const { error: mErr } = await supabase.from('unit_memberships').insert({
          person_id: personId,
          unit_id: unitId,
          church_role_id: roleId || null,
          is_team_leader: isLeader,
          leadership_stage_id: stageId || null,
        });
        if (mErr) throw new Error(`Saved ${v.first_name}, but adding them to the unit failed: ${friendlyError(mErr)}`);
      }
      if (mayRecordFaith && faithTouched && !faithRestricted) await saveFaith(personId!, f);
      return personId!;
    },
    onSuccess: (pid) => {
      qc.invalidateQueries({ queryKey: ['people'] });
      qc.invalidateQueries({ queryKey: ['memberships'] });
      qc.removeQueries({ queryKey: ['faith', pid] });
      navigate(`/members/${pid}`, { replace: true, state: { saved: true } });
    },
  });

  function onSubmit(e: FormEvent) {
    e.preventDefault();
    const found = checkPerson(v);
    if (!person && !unitId) found.unit = 'Choose the unit they are joining';
    setErrors(found);
    if (Object.keys(found).length === 0) save.mutate();
  }

  const hint = (k: string, fallback?: string) => (errors[k] ? `– ${errors[k]}` : fallback);
  const unitMap = byId(units.data);
  const roleMap = byId(roles.data);
  const theirMemberships = (memberships.data ?? []).filter((m) => m.person_id === person?.id);

  return (
    <>
      <SectionHeading eyebrow="People and Teams" title={person ? fullName(person) : 'New member'} rule />
      <p style={{ margin: 0 }}>
        <Link to="/members">All members</Link>
      </p>

      <form className="app-form" onSubmit={onSubmit} noValidate>
        <Card title="About them">
          <div className="tec-fields">
            <TextField id="m-first" label="First name" hint={hint('first_name')} required maxLength={100} value={v.first_name} onChange={(e) => set('first_name', e.target.value)} />
            <TextField id="m-other" label="Other names" hint="(optional)" maxLength={200} value={v.other_names} onChange={(e) => set('other_names', e.target.value)} />
            <TextField id="m-surname" label="Surname" hint={hint('surname')} required maxLength={100} value={v.surname} onChange={(e) => set('surname', e.target.value)} />
            <TextField id="m-email" label="Email address" hint={hint('email', '(optional)')} type="email" maxLength={254} value={v.email} onChange={(e) => set('email', e.target.value)} />
            <TextField id="m-area" label="Area" hint="Town or postcode district only, e.g. M6" maxLength={100} value={v.area} onChange={(e) => set('area', e.target.value)} />
            <SelectField id="m-bday" label="Birthday: day" hint={hint('birth_day', '(no year)')} options={dayOptions} value={v.birth_day} onChange={(e) => set('birth_day', e.target.value)} />
            <SelectField id="m-bmonth" label="Birthday: month" options={monthOptions} value={v.birth_month} onChange={(e) => set('birth_month', e.target.value)} />
            <SelectField
              id="m-marital"
              label="Marital status"
              hint="(optional, with their agreement)"
              options={[{ value: '', label: 'Not given' }, { value: 'single', label: 'Single' }, { value: 'married', label: 'Married' }]}
              value={v.marital_status}
              onChange={(e) => set('marital_status', e.target.value)}
            />
            {v.marital_status === 'married' && (
              <>
                <SelectField id="m-aday" label="Anniversary: day" hint={hint('anniversary_day', '(optional)')} options={dayOptions} value={v.anniversary_day} onChange={(e) => set('anniversary_day', e.target.value)} />
                <SelectField id="m-amonth" label="Anniversary: month" options={monthOptions} value={v.anniversary_month} onChange={(e) => set('anniversary_month', e.target.value)} />
              </>
            )}
          </div>
        </Card>

        <Card title="In G-Squad">
          <div className="tec-fields">
            <TextField id="m-joined" label="Date joined" hint={hint('date_joined')} type="date" required value={v.date_joined} onChange={(e) => set('date_joined', e.target.value)} />
            <SelectField
              id="m-status"
              label="Status"
              options={[{ value: 'active', label: 'Active' }, { value: 'paused', label: 'Paused (taking a break)' }]}
              value={v.status}
              disabled={!!v.date_left}
              onChange={(e) => set('status', e.target.value)}
            />
            <TextField id="m-left" label="Date left" hint={hint('date_left', '(only when leaving G-Squad)')} type="date" value={v.date_left} onChange={(e) => set('date_left', e.target.value)} />
            <SelectField
              id="m-teci"
              label="TECi stage"
              hint={canSetTeci ? '(optional)' : 'Set by the TECi Coordinator'}
              disabled={!canSetTeci}
              options={[{ value: '', label: 'Not started' }, ...(teci.data ?? []).map((s) => ({ value: s.id, label: `${s.stage_no}. ${s.name}` }))]}
              value={v.teci_stage_id}
              onChange={(e) => set('teci_stage_id', e.target.value)}
            />
            <SelectField
              id="m-community"
              label="Greatness Community"
              hint="(optional)"
              options={[{ value: '', label: 'None' }, ...(communities.data ?? []).filter((c) => c.is_active).map((c) => ({ value: c.id, label: c.name }))]}
              value={v.greatness_community_id}
              onChange={(e) => set('greatness_community_id', e.target.value)}
            />
          </div>
          <div className="tec-fields" style={{ paddingTop: 0 }}>
            <Checkbox id="m-news" label="Receives The Greatness Brief newsletter" checked={v.newsletter_subscribed} onChange={(e) => set('newsletter_subscribed', e.target.checked)} />
            <Checkbox id="m-celebrate" label="Agrees to birthday and anniversary greetings in the newsletter" checked={v.celebration_opt_in} onChange={(e) => set('celebration_opt_in', e.target.checked)} />
          </div>
        </Card>

        {person ? (
          <Card title="Units">
            {theirMemberships.length === 0 ? (
              <p>Not in a unit you can see.</p>
            ) : (
              <DataTable
                columns={[
                  { key: 'unit', label: 'Unit' },
                  { key: 'role', label: 'Team role' },
                  { key: 'lead', label: 'Team leader' },
                  { key: 'status', label: 'Status' },
                ]}
                rows={theirMemberships.map((m) => ({
                  id: m.id,
                  unit: unitMap.get(m.unit_id)?.name ?? 'Unit',
                  role: m.church_role_id ? roleMap.get(m.church_role_id)?.name ?? '' : '',
                  lead: m.is_team_leader ? 'Yes' : 'No',
                  status: m.status === 'active' ? <Chip tone="ok">Active</Chip> : <Chip tone="warn">Awaiting approval</Chip>,
                }))}
              />
            )}
            <p className="type-caption" style={{ margin: 0 }}>Team roles and leaders are changed on My Unit.</p>
          </Card>
        ) : (
          <Card title="Joining a unit">
            <div className="tec-fields">
              <SelectField
                id="m-unit"
                label="Unit"
                hint={hint('unit')}
                required
                options={[{ value: '', label: 'Choose a unit' }, ...unitChoices.map((u) => ({ value: u.id, label: u.name }))]}
                value={unitId}
                onChange={(e) => {
                  setUnitId(e.target.value);
                  setRoleId('');
                }}
              />
              <SelectField
                id="m-role"
                label="Team role"
                hint="(optional)"
                options={[
                  { value: '', label: 'None yet' },
                  ...(roles.data ?? [])
                    .filter((r) => r.is_active && (!r.unit_id || r.unit_id === unitId))
                    .map((r) => ({ value: r.id, label: r.name })),
                ]}
                value={roleId}
                onChange={(e) => setRoleId(e.target.value)}
              />
              <SelectField
                id="m-stage"
                label="Leadership stage"
                hint="(optional)"
                options={[{ value: '', label: 'None' }, ...(stages.data ?? []).map((s) => ({ value: s.id, label: s.name }))]}
                value={stageId}
                onChange={(e) => setStageId(e.target.value)}
              />
              <Checkbox id="m-leader" label="Team leader in this unit" checked={isLeader} onChange={(e) => setIsLeader(e.target.checked)} />
            </div>
            {unitChoices.length === 0 && (
              <Notice tone="warn" title="No unit to add to">
                {isOps ? 'Add units under Reference forms first.' : 'You are not the Unit Lead of an active unit.'}
              </Notice>
            )}
          </Card>
        )}

        {mayRecordFaith && !faithRestricted && (
          <RestrictedPanel title="Faith journey" audience="Resident Pastor, G-Squad Coordinator, TECi Coordinator and their Unit Lead">
            {faith.isPending && person ? (
              <p>Loading…</p>
            ) : (
              <div className="tec-fields">
                <TextField id="f-salv" label="Date of salvation" hint="(optional)" type="date" value={f.salvation_date ?? ''} onChange={(e) => setFaith('salvation_date', e.target.value || null)} />
                <FaithTick id="f-water" label="Water baptism" tick={f.water_baptism} date={f.water_baptism_date} onTick={(t) => setFaith('water_baptism', t)} onDate={(d) => setFaith('water_baptism_date', d)} />
                <FaithTick id="f-hs" label="Holy Spirit baptism" tick={f.holy_spirit_baptism} date={f.holy_spirit_baptism_date} onTick={(t) => setFaith('holy_spirit_baptism', t)} onDate={(d) => setFaith('holy_spirit_baptism_date', d)} />
                <FaithTick id="f-tongues" label="Speaks in tongues" tick={f.speaks_in_tongues} date={f.speaks_in_tongues_date} onTick={(t) => setFaith('speaks_in_tongues', t)} onDate={(d) => setFaith('speaks_in_tongues_date', d)} />
              </div>
            )}
            <p className="type-caption" style={{ margin: 0 }}>Every view and change of these fields is recorded.</p>
          </RestrictedPanel>
        )}

        {save.isError && (
          <Notice tone="danger" title="Not saved">
            {friendlyError(save.error)}
          </Notice>
        )}
        <div className="tec-row" style={{ padding: 0 }}>
          <Button type="submit" variant="primary" disabled={save.isPending}>
            {save.isPending ? 'Saving…' : person ? 'Save changes' : 'Add member'}
          </Button>
          <Link to="/members">Cancel</Link>
        </div>
      </form>
    </>
  );
}

// A faith tick with its optional date, shown only once ticked.
function FaithTick(p: { id: string; label: string; tick: boolean; date: string | null; onTick: (t: boolean) => void; onDate: (d: string | null) => void }) {
  return (
    <div className="app-form" style={{ gap: 'var(--space-2)' }}>
      <Checkbox id={p.id} label={p.label} checked={p.tick} onChange={(e) => p.onTick(e.target.checked)} />
      {p.tick && <TextField id={`${p.id}-date`} label="Date" hint="(optional)" type="date" value={p.date ?? ''} onChange={(e) => p.onDate(e.target.value || null)} />}
    </div>
  );
}
