// -------------------------------------------------------------------------------------
// New member entry form (/members/new) and a member's record (/members/:id).
// Follows the spec's member entry form and its data protection decisions:
//   * birthday and anniversary as day and month only, area only (never a full address);
//   * faith fields in their own panel, read and saved only through get_person_faith /
//     set_person_faith, which check access and log every view and change;
//   * the TECi stage is set by the TECi Coordinator (the database refuses others).
// Saving a new member: one call to create_member, which adds the person, their unit
// membership and any faith fields in a single transaction (all or nothing).
// -------------------------------------------------------------------------------------
import { useState, type FormEvent } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, useChurchRoles, useCommunities, useLeadershipStages, useTeciStages, useUnits } from '../../data/reference';
import {
  changedColumns,
  cleanFaith,
  fetchFaith,
  fullName,
  repeatedAt,
  saveFaith,
  useMemberships,
  usePerson,
  type FaithInput,
  type Person,
} from '../../data/people';
import { FAITH_READERS, hasRole, ledUnitIds, viewedUnitIds, useMe } from '../../auth/useMe';
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
  // Migration 25: up to 3 phone numbers and 2 more email addresses (3 in all).
  email2: string;
  email3: string;
  phone1: string;
  phone2: string;
  phone3: string;
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
  email2: '',
  email3: '',
  phone1: '',
  phone2: '',
  phone3: '',
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
    email2: s(p.other_emails?.[0]),
    email3: s(p.other_emails?.[1]),
    phone1: s(p.phones?.[0]),
    phone2: s(p.phones?.[1]),
    phone3: s(p.phones?.[2]),
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
    // Empty boxes are left out, so the lists hold only what was entered.
    other_emails: [v.email2, v.email3].map((x) => x.trim().toLowerCase()).filter(Boolean),
    phones: [v.phone1, v.phone2, v.phone3].map((x) => x.trim()).filter(Boolean),
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
  for (const k of ['email2', 'email3'] as const)
    if (v[k].trim() && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v[k].trim())) e[k] = 'Enter a valid email address';
  if ((v.email2.trim() || v.email3.trim()) && !v.email.trim()) e.email = 'Give the main email first';
  // SECURITY REVIEW 16 (V05): the database keeps each phone and email once.
  const emailKeys = ['email', 'email2', 'email3'] as const;
  for (const i of repeatedAt(emailKeys.map((k) => v[k]), true)) e[emailKeys[i]] ??= 'Already given above';
  const phoneKeys = ['phone1', 'phone2', 'phone3'] as const;
  for (const i of repeatedAt(phoneKeys.map((k) => v[k]))) e[phoneKeys[i]] ??= 'Already given above';
  // Same rule as the database: digits with optional +, spaces, brackets and dashes, 7 to 20 characters.
  for (const k of ['phone1', 'phone2', 'phone3'] as const)
    if (v[k].trim() && !/^\+?[0-9][0-9 ()-]{5,18}[0-9]$/.test(v[k].trim())) e[k] = 'Use digits, spaces and an optional +, e.g. 07700 900123';
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
  // SECURITY REVIEW FIX L02: an anonymised record is not opened as a form (the database now
  // refuses any change to it as well).
  if (!isNew && (!person.data || person.data.anonymised_at)) return <NotFound />;
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

  // Who may do what (display only: the database checks every save). Decision of 23 Oct 2026
  // (migration 16): a member record is edited only by their Team Lead (Unit Lead of a unit they
  // are in now) and the G-Squad Coordinator; others who can see it get a read-only view.
  const isOps = hasRole(me.data, 'operations_lead');
  const myUnits = ledUnitIds(me.data);
  const isCoordinator = hasRole(me.data, 'gsquad_coordinator');
  const liveUnits = (memberships.data ?? []).filter((m) => m.person_id === person?.id && m.status !== 'ended');
  const canEditRecord = !person || isCoordinator || liveUnits.some((m) => myUnits.includes(m.unit_id));
  // TECi stage: on an existing record the TECi Coordinator only; when adding, also the Ops Lead.
  const canSetTeci = person ? hasRole(me.data, 'teci_coordinator') : hasRole(me.data, 'teci_coordinator', 'operations_lead');
  const ro = !canEditRecord;

  // Unit for a NEW member: a Unit Lead picks one of their units; the Operations Lead any unit.
  // The Operations Lead and G-Squad Coordinator add to any unit (migration 23); a Team Lead to theirs.
  const unitChoices = (units.data ?? []).filter((u) => u.is_active && (isOps || isCoordinator || myUnits.includes(u.id)));
  const [unitId, setUnitId] = useState(() => (myUnits.length === 1 ? myUnits[0] : ''));
  // SECURITY REVIEW FIX L05: for a new member, the faith panel is offered only when the chosen
  // unit is one this leader leads (an Operations Lead who also leads another unit could not
  // record them, and the whole save would fail).
  // Offer the faith panel only to those app.can_see_faith lets in: the reading roles, or the
  // Unit Lead of a unit this person is actively in (or, for a new member, the chosen unit).
  // Faith fields are READ by the roles above but RECORDED only by the G-Squad Coordinator and
  // their Team Lead (an active membership of a unit they lead), as app.can_edit_faith checks.
  const canEditFaith =
    isCoordinator ||
    (person ? liveUnits.some((m) => m.status === 'active' && myUnits.includes(m.unit_id)) : myUnits.includes(unitId));
  // SECURITY REVIEW FIX M03: for a NEW member there is nothing to read, so the panel is offered
  // only to someone who may record the fields. Before, a reading role that also adds members
  // (for example an Operations Lead who is also the TECi Coordinator) saw an empty, locked panel.
  // Reading also includes their Deputy Team Lead (view-only; migration 22).
  const seenUnits = viewedUnitIds(me.data);
  const mayRecordFaith = person
    ? hasRole(me.data, ...FAITH_READERS) || liveUnits.some((m) => m.status === 'active' && seenUnits.includes(m.unit_id))
    : canEditFaith;
  // Nothing to save for someone who can neither edit the record, the TECi stage nor faith fields.
  const canSave = canEditRecord || canSetTeci || canEditFaith;
  const [roleId, setRoleId] = useState('');
  const [stageId, setStageId] = useState('');

  // SECURITY REVIEW FIX L04: faith fields (special category data) are loaded only when the
  // leader asks to see them, not every time a record is opened to change an email address.
  // Each load is a logged view, so the audit log then shows real looks, and the fields are not
  // on screen by default.
  const [showFaith, setShowFaith] = useState(false);
  // Faith fields: loaded through the logged function for an existing member.
  const faith = useQuery({
    queryKey: ['faith', person?.id],
    enabled: !!person && mayRecordFaith && showFaith,
    // A view is logged each time, so don't re-fetch in the background (staleTime) and drop the
    // copy as soon as the form closes (gcTime 0: nothing is kept in the cache to reappear).
    staleTime: Infinity,
    gcTime: 0,
    // SECURITY REVIEW FIX L04: no automatic retry. A retried call whose first answer was lost
    // would log a second view; the leader can retry by hand.
    retry: false,
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
  // SECURITY REVIEW FIX L03: if loading failed, the fields must not be shown as empty and
  // editable: one tick would then save over the real record with blanks.
  const faithReady = !person || faith.isSuccess;

  const save = useMutation({
    mutationFn: async () => {
      const sendFaith = canEditFaith && faithTouched && faithReady && !faithRestricted;
      if (!person) {
        // SECURITY REVIEW FIX L01: one transaction (public.create_member, migration 15). Before,
        // three calls: the first (insert ... select) was always refused by row-level security,
        // and any failure after it left a person with no unit that the leader could neither
        // see in a unit nor remove. The function runs as the leader, so every rule still applies.
        const { data, error } = await supabase.rpc('create_member', {
          p_person: toPersonRow(v, canSetTeci),
          p_unit: unitId,
          p_church_role: (roleId || null) as string,
          // Ignored by the database now: the Team Lead role label decides (migration 22).
          p_is_team_leader: false,
          p_leadership_stage: (stageId || null) as string,
          p_faith: sendFaith ? { ...cleanFaith(f) } : null,
        });
        if (error) throw error;
        return data;
      }
      // SECURITY REVIEW FIX L06: send only the columns that changed. Re-sending the whole row
      // overwrote fields other leaders had changed meanwhile, and made a faith-only change by
      // the Resident Pastor (who reads but does not edit member records) fail before the faith
      // fields were saved.
      const patch = changedColumns(toPersonRow(fromPerson(person), canSetTeci), toPersonRow(v, canSetTeci));
      if (Object.keys(patch).length > 0) {
        // .select().single(): an update refused by row-level security returns no row; this
        // turns that into an error instead of a silent "saved".
        const { error } = await supabase.from('people').update(patch).eq('id', person.id).select('id').single();
        if (error) throw error;
      }
      if (sendFaith) await saveFaith(person.id, f);
      return person.id;
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

      {person && ro && (
        <Notice tone="info" title="View only">
          Member records are changed by their Team Lead or the G-Squad Coordinator.
          {canSetTeci ? ' You can set the TECi stage.' : ''}
        </Notice>
      )}

      <form className="app-form" onSubmit={onSubmit} noValidate>
        <Card title="About them">
          {/* A disabled fieldset makes every field in it read-only in one place. */}
          <fieldset className="app-fieldset tec-fields" disabled={ro}>
            <TextField id="m-first" label="First name" hint={hint('first_name')} required maxLength={100} value={v.first_name} onChange={(e) => set('first_name', e.target.value)} />
            <TextField id="m-other" label="Other names" hint="(optional)" maxLength={200} value={v.other_names} onChange={(e) => set('other_names', e.target.value)} />
            <TextField id="m-surname" label="Surname" hint={hint('surname')} required maxLength={100} value={v.surname} onChange={(e) => set('surname', e.target.value)} />
            <TextField id="m-email" label="Main email" hint={hint('email', '(optional; used for the newsletter)')} type="email" maxLength={254} value={v.email} onChange={(e) => set('email', e.target.value)} />
            <TextField id="m-email2" label="Email 2" hint={hint('email2', '(optional)')} type="email" maxLength={254} value={v.email2} onChange={(e) => set('email2', e.target.value)} />
            <TextField id="m-email3" label="Email 3" hint={hint('email3', '(optional)')} type="email" maxLength={254} value={v.email3} onChange={(e) => set('email3', e.target.value)} />
            <TextField id="m-phone1" label="Phone 1" hint={hint('phone1', '(optional)')} type="tel" autoComplete="off" maxLength={20} value={v.phone1} onChange={(e) => set('phone1', e.target.value)} />
            <TextField id="m-phone2" label="Phone 2" hint={hint('phone2', '(optional)')} type="tel" autoComplete="off" maxLength={20} value={v.phone2} onChange={(e) => set('phone2', e.target.value)} />
            <TextField id="m-phone3" label="Phone 3" hint={hint('phone3', '(optional)')} type="tel" autoComplete="off" maxLength={20} value={v.phone3} onChange={(e) => set('phone3', e.target.value)} />
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
          </fieldset>
        </Card>

        <Card title="In G-Squad">
          <div className="tec-fields">
            <TextField id="m-joined" label="Date joined" hint={hint('date_joined')} type="date" required disabled={ro} value={v.date_joined} onChange={(e) => set('date_joined', e.target.value)} />
            <SelectField
              id="m-status"
              label="Status"
              options={[{ value: 'active', label: 'Active' }, { value: 'paused', label: 'Paused (taking a break)' }]}
              value={v.status}
              disabled={ro || !!v.date_left}
              onChange={(e) => set('status', e.target.value)}
            />
            <TextField id="m-left" label="Date left" hint={hint('date_left', '(only when leaving G-Squad)')} type="date" disabled={ro} value={v.date_left} onChange={(e) => set('date_left', e.target.value)} />
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
              disabled={ro}
              options={[{ value: '', label: 'None' }, ...(communities.data ?? []).filter((c) => c.is_active).map((c) => ({ value: c.id, label: c.name }))]}
              value={v.greatness_community_id}
              onChange={(e) => set('greatness_community_id', e.target.value)}
            />
          </div>
          <div className="tec-fields" style={{ paddingTop: 0 }}>
            <Checkbox id="m-news" label="Receives The Greatness Brief newsletter" disabled={ro} checked={v.newsletter_subscribed} onChange={(e) => set('newsletter_subscribed', e.target.checked)} />
            <Checkbox id="m-celebrate" label="Agrees to birthday and anniversary greetings in the newsletter" disabled={ro} checked={v.celebration_opt_in} onChange={(e) => set('celebration_opt_in', e.target.checked)} />
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
                  { key: 'status', label: 'Status' },
                ]}
                rows={theirMemberships.map((m) => ({
                  id: m.id,
                  unit: unitMap.get(m.unit_id)?.name ?? 'Unit',
                  role: m.church_role_id ? roleMap.get(m.church_role_id)?.name ?? '' : '',
                  // SECURITY REVIEW FIX M04: an ended membership was shown as "Awaiting approval",
                  // suggesting the person was still joining a unit they had left.
                  status:
                    m.status === 'active' ? <Chip tone="ok">Active</Chip>
                    : m.status === 'ended' ? <Chip tone="neutral">Ended</Chip>
                    : <Chip tone="warn">Awaiting approval</Chip>,
                }))}
              />
            )}
            <p className="type-caption" style={{ margin: 0 }}>Team roles are changed by the Team Lead on My Unit.</p>
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
                    // Operational roles only; a new member can't take the Team Lead label if the
                    // team already has one (no co-leads; the database checks too).
                    .filter((r) => r.is_active && r.permanence === 'operational' && (!r.unit_id || r.unit_id === unitId))
                    .filter(
                      (r) =>
                        r.default_key !== 'team_lead' ||
                        !(memberships.data ?? []).some((m) => m.unit_id === unitId && m.status !== 'ended' && m.is_team_leader),
                    )
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
            </div>
            {unitChoices.length === 0 && (
              <Notice tone="warn" title="No unit to add to">
                {isOps || isCoordinator ? 'Add units under Reference forms first.' : 'You are not the Team Lead of an active unit.'}
              </Notice>
            )}
          </Card>
        )}

        {mayRecordFaith && faithRestricted && (
          <Notice tone="info" title="Faith journey">
            Only the Resident Pastor, G-Squad Coordinator, TECi Coordinator and the person's own Team Lead and Deputy see these fields.
          </Notice>
        )}
        {mayRecordFaith && !faithRestricted && (
          <RestrictedPanel title="Faith journey" audience="Resident Pastor, G-Squad Coordinator, TECi Coordinator, their Team Lead and Deputy">
            {person && !showFaith ? (
              <Button type="button" variant="secondary" size="sm" onClick={() => setShowFaith(true)}>
                Show faith journey
              </Button>
            ) : person && faith.isError ? (
              <Notice tone="danger" title="Faith journey not loaded">
                {friendlyError(faith.error)}
              </Notice>
            ) : !faithReady ? (
              <p>Loading…</p>
            ) : (
              <fieldset className="app-fieldset tec-fields" disabled={!canEditFaith}>
                <TextField id="f-salv" label="Date of salvation" hint="(optional)" type="date" value={f.salvation_date ?? ''} onChange={(e) => setFaith('salvation_date', e.target.value || null)} />
                <FaithTick id="f-water" label="Water baptism" tick={f.water_baptism} date={f.water_baptism_date} onTick={(t) => setFaith('water_baptism', t)} onDate={(d) => setFaith('water_baptism_date', d)} />
                <FaithTick id="f-hs" label="Holy Spirit baptism" tick={f.holy_spirit_baptism} date={f.holy_spirit_baptism_date} onTick={(t) => setFaith('holy_spirit_baptism', t)} onDate={(d) => setFaith('holy_spirit_baptism_date', d)} />
                <FaithTick id="f-tongues" label="Speaks in tongues" tick={f.speaks_in_tongues} date={f.speaks_in_tongues_date} onTick={(t) => setFaith('speaks_in_tongues', t)} onDate={(d) => setFaith('speaks_in_tongues_date', d)} />
              </fieldset>
            )}
            <p className="type-caption" style={{ margin: 0 }}>
              Every view and change of these fields is recorded.
              {!canEditFaith && ' They are recorded by their Team Lead or the G-Squad Coordinator.'}
            </p>
          </RestrictedPanel>
        )}

        {save.isError && (
          <Notice tone="danger" title="Not saved">
            {/* SECURITY REVIEW FIX L06: on this form a duplicate (23505) can only be the email address. */}
            {(save.error as { code?: string }).code === '23505'
              ? 'A member with that email address is already recorded.'
              : friendlyError(save.error)}
          </Notice>
        )}
        <div className="tec-row" style={{ padding: 0 }}>
          {canSave && (
            <Button type="submit" variant="primary" disabled={save.isPending}>
              {save.isPending ? 'Saving…' : person ? 'Save changes' : 'Add member'}
            </Button>
          )}
          <Link to="/members">{canSave ? 'Cancel' : 'Back to members'}</Link>
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
