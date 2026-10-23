// -------------------------------------------------------------------------------------
// Admin > Leaders: invite leaders and manage their roles.
// Who sees and does what is decided by the database (migration 13):
//   * the Operations Lead, G-Squad Coordinator and Resident Pastor invite leaders;
//   * senior roles are given only by the Resident Pastor; the Operations Lead role only by the
//     Resident Pastor or an Operations Lead; nobody changes their own roles.
// Decisions of 23 Oct 2026 (migration 22): one Team Lead per team (no co-leads); a Deputy Team
// Lead per team is view-only; the G-Squad Coordinator and Operations Lead functions are given
// only to someone who already holds Purpose Head or Resident Pastor.
// This screen mirrors those rules in what it offers, and shows the database's message if a
// change is refused anyway.
// -------------------------------------------------------------------------------------
import { useMemo, useState, type FormEvent } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, usePurposes, useUnits, useLeaders } from '../../data/reference';
import {
  grantableRoles,
  hasRole,
  INVITERS,
  NEEDS_SENIOR_HOLDER,
  ROLE_LABELS,
  SENIOR_HOLDERS,
  useMe,
  type AppRole,
} from '../../auth/useMe';

const { SectionHeading, Card, Button, TextField, SelectField, Notice, Chip, DataTable } = TEC;

interface RoleRow {
  id: string;
  user_id: string;
  role: AppRole;
  unit_id: string | null;
  purpose_id: string | null;
}

export function Leaders() {
  const me = useMe();
  const qc = useQueryClient();
  const leaders = useLeaders();
  const units = useUnits();
  const purposes = usePurposes();
  const roles = useQuery({
    queryKey: ['role_assignments'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('role_assignments')
        .select('id, user_id, role, unit_id, purpose_id')
        .eq('is_active', true);
      if (error) throw error;
      return data as RoleRow[];
    },
  });

  const unitMap = byId(units.data);
  const purposeMap = byId(purposes.data);
  const canInvite = hasRole(me.data, ...INVITERS);
  const offer = grantableRoles(me.data);

  // Teams that already have a Team Lead (offered no second one).
  const ledTeams = new Set((roles.data ?? []).filter((r) => r.role === 'unit_lead' && r.unit_id).map((r) => r.unit_id!));

  // Labels a role with its scope, e.g. "Team Lead · Production".
  const roleLabel = (r: { role: AppRole; unit_id: string | null; purpose_id: string | null }) =>
    ROLE_LABELS[r.role] +
    (r.unit_id ? ` · ${unitMap.get(r.unit_id)?.name ?? 'unit'}` : '') +
    (r.purpose_id ? ` · ${purposeMap.get(r.purpose_id)?.name ?? 'purpose'}` : '');

  // Remove one role. The database refuses if this leader may not.
  const removeRole = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('role_assignments').delete().eq('id', id);
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['role_assignments'] }),
  });

  // Switch an account off or back on (switched-off leaders cannot sign in to any data).
  const setActive = useMutation({
    mutationFn: async ({ id, active }: { id: string; active: boolean }) => {
      const { error } = await supabase.from('app_users').update({ is_active: active }).eq('id', id).select('id').single();
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['leaders'] }),
  });

  const rolesByUser = useMemo(() => {
    const m = new Map<string, RoleRow[]>();
    for (const r of roles.data ?? []) m.set(r.user_id, [...(m.get(r.user_id) ?? []), r]);
    return m;
  }, [roles.data]);

  const actionError = removeRole.error ?? setActive.error;

  return (
    <>
      <SectionHeading eyebrow="Administration" title="Leaders" rule>
        People who sign in to the G-Squad Planner, and what each can do. Volunteers do not sign in.
      </SectionHeading>

      {canInvite ? (
        <InviteForm offer={offer} ledTeams={ledTeams} />
      ) : (
        <Notice tone="info" title="View only">
          The Operations Lead, the G-Squad Coordinator or the Resident Pastor invite leaders.
        </Notice>
      )}

      {actionError && (
        <Notice tone="danger" title="That change wasn't made">
          {friendlyError(actionError)}
        </Notice>
      )}

      <Card title={`Leaders (${leaders.data?.length ?? 0})`}>
        {(leaders.isPending || roles.isPending) && <p>Loading…</p>}
        {(leaders.error || roles.error) && <Notice tone="danger">{friendlyError(leaders.error ?? roles.error)}</Notice>}
        {leaders.data && (
          <DataTable
            columns={[
              { key: 'name', label: 'Name' },
              { key: 'roles', label: 'Roles' },
              { key: 'status', label: 'Account' },
              { key: 'actions', label: 'Actions' },
            ]}
            rows={leaders.data.map((l) => {
              const isMe = l.id === me.data?.id;
              const theirRoles = rolesByUser.get(l.id) ?? [];
              return {
                id: l.id,
                name: (
                  <span>
                    {l.display_name}
                    {isMe && <span className="type-caption"> (you)</span>}
                  </span>
                ),
                roles: (
                  <div className="tec-row" style={{ padding: 0 }}>
                    {theirRoles.length === 0 && <span className="type-caption">No roles</span>}
                    {theirRoles.map((r) => (
                      <span key={r.id} style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                        <Chip tone="info">{roleLabel(r)}</Chip>
                        {canInvite && !isMe && offer.includes(r.role) && (
                          <button
                            type="button"
                            className="app-link-button"
                            aria-label={`Remove ${roleLabel(r)} from ${l.display_name}`}
                            disabled={removeRole.isPending}
                            onClick={() => {
                              if (window.confirm(`Remove ${roleLabel(r)} from ${l.display_name}?`)) removeRole.mutate(r.id);
                            }}
                          >
                            Remove
                          </button>
                        )}
                      </span>
                    ))}
                  </div>
                ),
                status: l.is_active ? <Chip tone="ok">Active</Chip> : <Chip tone="neutral">Switched off</Chip>,
                actions:
                  canInvite && !isMe ? (
                    <div className="tec-row" style={{ padding: 0 }}>
                      <AddRole
                        userId={l.id}
                        // The two functions are offered only to a Purpose Head or the Resident Pastor.
                        offer={offer.filter(
                          (r) => !NEEDS_SENIOR_HOLDER.includes(r) || theirRoles.some((t) => SENIOR_HOLDERS.includes(t.role)),
                        )}
                        ledTeams={ledTeams}
                      />
                      <Button
                        size="sm"
                        variant="quiet"
                        disabled={setActive.isPending}
                        onClick={() => setActive.mutate({ id: l.id, active: !l.is_active })}
                      >
                        {l.is_active ? 'Switch off' : 'Switch on'}
                      </Button>
                    </div>
                  ) : null,
              };
            })}
          />
        )}
      </Card>
    </>
  );
}

// ---------- Role picker shared by the invite form and "Add role" ----------
function RoleFields({
  idPrefix,
  offer,
  value,
  onChange,
  ledTeams,
}: {
  idPrefix: string;
  offer: AppRole[];
  value: { role: AppRole; unit_id: string; purpose_id: string };
  onChange: (v: { role: AppRole; unit_id: string; purpose_id: string }) => void;
  ledTeams: Set<string>;
}) {
  const units = useUnits();
  const purposes = usePurposes();
  return (
    <>
      <SelectField
        id={`${idPrefix}-role`}
        label="Role"
        value={value.role}
        onChange={(e) => onChange({ role: e.target.value as AppRole, unit_id: '', purpose_id: '' })}
        options={offer.map((r) => ({ value: r, label: ROLE_LABELS[r] }))}
      />
      {(value.role === 'unit_lead' || value.role === 'deputy_unit_lead') && (
        <SelectField
          id={`${idPrefix}-unit`}
          label="Unit"
          required
          value={value.unit_id}
          onChange={(e) => onChange({ ...value, unit_id: e.target.value })}
          options={[
            { value: '', label: 'Choose a unit' },
            ...(units.data ?? [])
              // No co-leads: a team that has a Team Lead isn't offered for another.
              .filter((u) => u.is_active && (value.role !== 'unit_lead' || !ledTeams.has(u.id)))
              .map((u) => ({ value: u.id, label: u.name })),
          ]}
        />
      )}
      {value.role === 'purpose_head' && (
        <SelectField
          id={`${idPrefix}-purpose`}
          label="Purpose"
          required
          value={value.purpose_id}
          onChange={(e) => onChange({ ...value, purpose_id: e.target.value })}
          options={[{ value: '', label: 'Choose a purpose' }, ...(purposes.data ?? []).map((p) => ({ value: p.id, label: p.name }))]}
        />
      )}
    </>
  );
}

// Is the role choice complete (scoped roles need their unit or purpose)?
const roleReady = (v: { role: AppRole; unit_id: string; purpose_id: string }) =>
  ((v.role !== 'unit_lead' && v.role !== 'deputy_unit_lead') || !!v.unit_id) && (v.role !== 'purpose_head' || !!v.purpose_id);

// ---------- Invite a new leader (Edge Function invite-leader) ----------
function InviteForm({ offer: all, ledTeams }: { offer: AppRole[]; ledTeams: Set<string> }) {
  // The invitation carries one role. The two functions need Purpose Head first, so they are
  // given afterwards with "Add role".
  const offer = all.filter((r) => !NEEDS_SENIOR_HOLDER.includes(r));
  const qc = useQueryClient();
  const [email, setEmail] = useState('');
  const [name, setName] = useState('');
  const [role, setRole] = useState<{ role: AppRole; unit_id: string; purpose_id: string }>({
    role: 'unit_lead',
    unit_id: '',
    purpose_id: '',
  });

  const invite = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.functions.invoke('invite-leader', {
        body: {
          email: email.trim(),
          display_name: name.trim(),
          roles: [{ role: role.role, unit_id: role.unit_id || null, purpose_id: role.purpose_id || null }],
        },
      });
      if (error) {
        // The function returns { error: "..." } with a non-2xx status; show that sentence.
        const body = await (error as { context?: Response }).context?.json?.().catch(() => null);
        throw new Error(body?.error ?? 'The invitation could not be sent');
      }
      return data as { id: string };
    },
    onSuccess: () => {
      setEmail('');
      setName('');
      qc.invalidateQueries({ queryKey: ['leaders'] });
      qc.invalidateQueries({ queryKey: ['role_assignments'] });
    },
  });

  function onSubmit(e: FormEvent) {
    e.preventDefault();
    invite.mutate();
  }

  const ready = email.includes('@') && name.trim().length > 0 && roleReady(role);

  return (
    <Card title="Invite a leader">
      <form onSubmit={onSubmit} className="app-form">
        <p className="type-caption" style={{ margin: 0 }}>
          They get an email with a link. After opening it, they sign in with their email address each time.
        </p>
        <div className="tec-fields">
          <TextField id="inv-name" label="Name" required autoComplete="off" value={name} onChange={(e) => setName(e.target.value)} />
          <TextField
            id="inv-email"
            label="Email address"
            type="email"
            required
            autoComplete="off"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
          <RoleFields idPrefix="inv" offer={offer} value={role} onChange={setRole} ledTeams={ledTeams} />
        </div>
        <p className="type-caption" style={{ margin: 0 }}>
          G-Squad Coordinator and Operations Lead are functions of a Purpose Head or the Resident Pastor: invite them with
          that role, then use Add role.
        </p>
        {invite.isError && <Notice tone="danger" title="Not sent">{friendlyError(invite.error)}</Notice>}
        {invite.isSuccess && <Notice tone="ok" title="Invitation sent">They'll appear below as soon as they accept.</Notice>}
        <div>
          <Button type="submit" variant="primary" icon="mail" disabled={!ready || invite.isPending}>
            {invite.isPending ? 'Sending…' : 'Send invitation'}
          </Button>
        </div>
      </form>
    </Card>
  );
}

// ---------- Give an existing leader another role ----------
function AddRole({ userId, offer, ledTeams }: { userId: string; offer: AppRole[]; ledTeams: Set<string> }) {
  const qc = useQueryClient();
  const [open, setOpen] = useState(false);
  const [role, setRole] = useState<{ role: AppRole; unit_id: string; purpose_id: string }>({
    role: 'unit_lead',
    unit_id: '',
    purpose_id: '',
  });
  const add = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('role_assignments').insert({
        user_id: userId,
        role: role.role,
        unit_id: role.unit_id || null,
        purpose_id: role.purpose_id || null,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setOpen(false);
      qc.invalidateQueries({ queryKey: ['role_assignments'] });
    },
  });

  if (!open)
    return (
      <Button size="sm" variant="secondary" icon="plus" onClick={() => setOpen(true)}>
        Add role
      </Button>
    );
  return (
    <div className="app-inline-form">
      <RoleFields idPrefix={`add-${userId}`} offer={offer} value={role} onChange={setRole} ledTeams={ledTeams} />
      {add.isError && <Notice tone="danger">{friendlyError(add.error)}</Notice>}
      <div className="tec-row" style={{ padding: 0 }}>
        <Button size="sm" variant="primary" disabled={!roleReady(role) || add.isPending} onClick={() => add.mutate()}>
          Save role
        </Button>
        <Button size="sm" variant="quiet" onClick={() => setOpen(false)}>
          Cancel
        </Button>
      </div>
    </div>
  );
}
