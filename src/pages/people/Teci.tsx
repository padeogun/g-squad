// -------------------------------------------------------------------------------------
// TECi: the TECi Coordinator's list of G-Squad members who are in or have been through TECi,
// with each member's stage and whether it has been verified. The TECi Coordinator verifies
// stages and adds new members who have completed a TECi level but are not in a team yet
// (decision of 23 Oct 2026). Others who can open the page (G-Squad Coordinator, Resident
// Pastor, Operations Lead) see it read-only; the Operations Lead may also add a graduate.
// The database decides every change (migration 22); this screen only offers what it allows.
// -------------------------------------------------------------------------------------
import { useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { byId, useTeciStages } from '../../data/reference';
import { teciOrder, useAddGraduate, useTeciPeople, useVerifyTeci, type TeciPerson } from '../../data/teci';
import { shortDate } from '../../data/sundays';
import { hasRole, useMe } from '../../auth/useMe';

const { SectionHeading, Card, Notice, DataTable, StatTile, Chip, SelectField, TextField, Button } = TEC;

// A timestamp's calendar day in London (YYYY-MM-DD), so a verification made just after
// midnight in summer time is not shown as the day before.
const londonDay = (ts: string) => new Date(ts).toLocaleDateString('en-CA', { timeZone: 'Europe/London' });

const SHOW = [
  { value: 'teci', label: 'In or through TECi' },
  { value: 'unverified', label: 'Awaiting verification' },
  { value: 'none', label: 'Not started' },
  { value: 'all', label: 'Everyone' },
];

export function Teci() {
  const me = useMe();
  const people = useTeciPeople();
  const stages = useTeciStages();
  const verify = useVerifyTeci();
  const [show, setShow] = useState('teci');
  // Stage picked per person before pressing Verify (defaults to their current stage).
  const [picked, setPicked] = useState<Record<string, string>>({});

  const isTeci = hasRole(me.data, 'teci_coordinator');
  const mayAdd = hasRole(me.data, 'teci_coordinator', 'operations_lead');
  const allowed = hasRole(me.data, 'teci_coordinator', 'gsquad_coordinator', 'resident_pastor', 'operations_lead');
  const stageMap = byId(stages.data);
  const stageLabel = (id: string | null) => {
    const s = id ? stageMap.get(id) : undefined;
    return s ? `${s.stage_no}. ${s.name}` : '–';
  };

  const all = people.data ?? [];
  const inTeci = all.filter((p) => p.teci_stage_id);
  const unverified = inTeci.filter((p) => !p.teci_verified_at);
  const shown = all
    .filter((p) =>
      show === 'teci' ? !!p.teci_stage_id : show === 'unverified' ? !!p.teci_stage_id && !p.teci_verified_at : show === 'none' ? !p.teci_stage_id : true,
    )
    .sort(teciOrder);

  if (me.isPending) return <p>Loading…</p>;
  if (!allowed)
    return (
      <>
        <SectionHeading eyebrow="People and Teams" title="TECi" rule />
        <Notice tone="info">The TECi list is kept by the TECi Coordinator.</Notice>
      </>
    );

  return (
    <>
      <SectionHeading eyebrow="People and Teams" title="TECi" rule>
        G-Squad members in or through TEC's training programme, and whether each stage has been verified.
      </SectionHeading>

      <div className="tec-stats">
        <StatTile label="In or through TECi" value={inTeci.length} tone="brand" />
        <StatTile label="Verified" value={inTeci.length - unverified.length} />
        <StatTile label="Awaiting verification" value={unverified.length} tone={unverified.length ? 'danger' : 'default'} />
        <StatTile label="Not started" value={all.length - inTeci.length} />
      </div>

      {mayAdd && <AddGraduate stages={stages.data ?? []} />}

      {verify.isError && (
        <Notice tone="danger" title="Not verified">
          {friendlyError(verify.error)}
        </Notice>
      )}
      <Card
        title="Members"
        action={
          <SelectField id="teci-show" label="Show" className="app-inline-select" value={show} onChange={(e) => setShow(e.target.value)} options={SHOW} />
        }
      >
        {people.isPending && <p>Loading…</p>}
        {people.error && <Notice tone="danger">{friendlyError(people.error)}</Notice>}
        {people.data && shown.length === 0 && <p>No one to show.</p>}
        {shown.length > 0 && (
          <DataTable
            columns={[
              { key: 'name', label: 'Name' },
              { key: 'stage', label: 'TECi stage' },
              { key: 'verified', label: 'Verified' },
              ...(isTeci ? [{ key: 'action', label: 'Verify' }] : []),
            ]}
            rows={shown.map((p: TeciPerson) => {
              const name = `${p.first_name} ${p.surname}`;
              const choice = picked[p.id] ?? p.teci_stage_id ?? '';
              return {
                id: p.id,
                name: <Link to={`/members/${p.id}`}>{name}</Link>,
                stage: stageLabel(p.teci_stage_id),
                verified: !p.teci_stage_id ? (
                  <span className="type-caption">–</span>
                ) : p.teci_verified_at ? (
                  <Chip tone="ok">{`Verified ${shortDate(londonDay(p.teci_verified_at))}`}</Chip>
                ) : (
                  <Chip tone="warn">Not verified</Chip>
                ),
                action: (
                  <div className="app-inline-row">
                    <SelectField
                      id={`teci-stage-${p.id}`}
                      label={`TECi stage for ${name}`}
                      className="app-cell-field"
                      value={choice}
                      onChange={(e) => setPicked((cur) => ({ ...cur, [p.id]: e.target.value }))}
                      options={[{ value: '', label: 'Choose a stage' }, ...(stages.data ?? []).map((s) => ({ value: s.id, label: `${s.stage_no}. ${s.name}` }))]}
                    />
                    <Button
                      size="sm"
                      variant="secondary"
                      aria-label={`Verify ${name}'s TECi stage`}
                      // Nothing to do when this exact stage is already verified.
                      disabled={!choice || verify.isPending || (choice === p.teci_stage_id && !!p.teci_verified_at)}
                      onClick={() => verify.mutate({ personId: p.id, stageId: choice })}
                    >
                      Verify
                    </Button>
                  </div>
                ),
              };
            })}
          />
        )}
      </Card>
    </>
  );
}

// ---------- Add a TECi graduate who is not in a team yet ----------
function AddGraduate({ stages }: { stages: { id: string; stage_no: number; name: string }[] }) {
  const add = useAddGraduate();
  const blank = { first_name: '', surname: '', email: '', teci_stage_id: '' };
  const [v, setV] = useState(blank);
  const [open, setOpen] = useState(false);
  const ready = v.first_name.trim() && v.surname.trim() && v.teci_stage_id && (!v.email.trim() || v.email.includes('@'));

  function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (ready) add.mutate(v, { onSuccess: () => setV(blank) });
  }

  if (!open)
    return (
      <div>
        <Button variant="primary" icon="plus" onClick={() => setOpen(true)}>
          Add a TECi graduate
        </Button>
      </div>
    );
  return (
    <Card title="Add a TECi graduate" tone="tint">
      <form className="app-form" onSubmit={onSubmit} noValidate>
        <p className="type-caption" style={{ margin: 0 }}>
          For someone joining G-Squad after completing a TECi level who is not in a team yet. Their Team Lead adds the rest of
          their details when they join a team.
        </p>
        <div className="tec-fields">
          <TextField id="g-first" label="First name" required maxLength={100} value={v.first_name} onChange={(e) => setV({ ...v, first_name: e.target.value })} />
          <TextField id="g-surname" label="Surname" required maxLength={100} value={v.surname} onChange={(e) => setV({ ...v, surname: e.target.value })} />
          <TextField id="g-email" label="Email address" hint="(optional)" type="email" maxLength={254} value={v.email} onChange={(e) => setV({ ...v, email: e.target.value })} />
          <SelectField
            id="g-stage"
            label="TECi stage completed"
            required
            value={v.teci_stage_id}
            onChange={(e) => setV({ ...v, teci_stage_id: e.target.value })}
            options={[{ value: '', label: 'Choose a stage' }, ...stages.map((s) => ({ value: s.id, label: `${s.stage_no}. ${s.name}` }))]}
          />
        </div>
        {add.isError && (
          <Notice tone="danger" title="Not added">
            {friendlyError(add.error)}
          </Notice>
        )}
        {add.isSuccess && <Notice tone="ok" title="Added">They now appear in the list below.</Notice>}
        <div className="tec-row" style={{ padding: 0 }}>
          <Button type="submit" variant="primary" disabled={!ready || add.isPending}>
            {add.isPending ? 'Adding…' : 'Add'}
          </Button>
          <Button type="button" variant="quiet" onClick={() => setOpen(false)}>
            Close
          </Button>
        </div>
      </form>
    </Card>
  );
}
