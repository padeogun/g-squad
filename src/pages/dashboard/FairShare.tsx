// -------------------------------------------------------------------------------------
// Fair share, rest and leaders' load on the Church Dashboard (steps 3 to 5 of the executive
// summary; migration 30). The vision for G-Squad is that no member is burned out and the
// weight of service is shared fairly, so the leadership group sees, in counts only:
//   * how many members served 0, up to 3, 3 to 6, 6 to 9 and over 9 hours this month;
//   * what share of all hours the busiest fifth gave (lower is fairer);
//   * how many active members have not been asked to serve in three months;
//   * how many leaders hold more leadership at once than the church allows.
// Those who look after leaders also see their names. The serving rules (limit, hours per
// slot, Sundays off, leadership roles) are shown to all and changed by the Operations Lead or
// G-Squad Coordinator; the database decides who may change what (church_settings_guard).
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { bandWidth, HOUR_BANDS, LEADER_CARE_ROLES, useFairShare, useLeadersCarryingTooMuch } from '../../data/dashboards';
import { useSettings } from '../../data/newsletter';
import { hasRole, useMe } from '../../auth/useMe';

const { Card, Notice, StatTile, Button, TextField } = TEC;

export function FairShareCard({ month }: { month: string }) {
  const me = useMe();
  const fair = useFairShare(month, true);
  const careForLeaders = hasRole(me.data, ...LEADER_CARE_ROLES);
  const leaders = useLeadersCarryingTooMuch(careForLeaders);
  const f = fair.data;

  return (
    <Card title="Fair share this month">
      <p className="type-caption" style={{ margin: 0 }}>
        Counts only. All serving counts: Sundays, events, outreach and team activities.
      </p>
      {fair.isPending && <p>Loading…</p>}
      {fair.error && <Notice tone="danger">{friendlyError(fair.error)}</Notice>}
      {f && (
        <>
          <ul className="app-bands" aria-label="Members by hours served this month">
            {HOUR_BANDS.map((b) => (
              <li key={b.key}>
                <span className="app-band-label">{b.label}</span>
                <span className="app-band-track" aria-hidden="true">
                  <span className={`app-band-bar${b.key === 'over_9' ? ' is-over' : ''}`} style={{ width: `${bandWidth(f.bands[b.key], f.bands)}%` }} />
                </span>
                <strong className="app-band-count">{f.bands[b.key]}</strong>
              </li>
            ))}
          </ul>
          <div className="tec-stats" style={{ padding: 0 }}>
            <StatTile
              label="Busiest fifth carry"
              value={f.busiest_fifth_share === null ? '–' : `${f.busiest_fifth_share}%`}
              note="of all hours served; 20% would be perfectly even"
              tone={f.busiest_fifth_share !== null && f.busiest_fifth_share >= 60 ? 'danger' : 'default'}
            />
            <StatTile label="Not asked in 3 months" value={f.not_asked_3_months} note={`of ${f.members} active members`} />
            <StatTile
              label="Leaders carrying a lot"
              value={f.leaders_over}
              note="more leadership roles and live projects than the church allows"
              tone={f.leaders_over ? 'danger' : 'default'}
            />
          </div>
        </>
      )}
      {careForLeaders && leaders.data && leaders.data.length > 0 && (
        <div>
          <h3 className="app-issue-h">Leaders to check on</h3>
          <ul className="app-candidates">
            {leaders.data.map((l) => (
              <li key={l.user_id}>
                <strong>{l.display_name}</strong>
                <span className="type-caption">
                  {l.team_roles} team lead or deputy role{l.team_roles === 1 ? '' : 's'}, {l.live_projects} live project{l.live_projects === 1 ? '' : 's'}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
      {leaders.error && <Notice tone="danger">{friendlyError(leaders.error)}</Notice>}
    </Card>
  );
}

// The serving rules everyone plans against.
export function ServingRulesCard() {
  const me = useMe();
  const qc = useQueryClient();
  const settings = useSettings();
  const canEdit = hasRole(me.data, 'operations_lead', 'gsquad_coordinator');
  const s = settings.data;
  const [v, setV] = useState<Record<string, string> | null>(null);
  const val = (k: string, fallback: number | undefined) => v?.[k] ?? String(fallback ?? '');

  const save = useMutation({
    mutationFn: async () => {
      const patch = {
        serving_limit_per_month: Number(val('limit', s?.serving_limit_per_month)),
        hours_per_slot: Number(val('hours', s?.hours_per_slot)),
        sundays_off_per_month: Number(val('off', s?.sundays_off_per_month)),
        leader_roles_max: Number(val('leaders', s?.leader_roles_max)),
      };
      const { error } = await supabase.from('church_settings').update(patch).eq('church_id', s!.church_id).select('church_id').single();
      if (error) throw error;
    },
    onSuccess: () => {
      setV(null);
      qc.invalidateQueries({ queryKey: ['church_settings'] });
      qc.invalidateQueries({ queryKey: ['dashboard'] });
    },
  });

  if (!s) return null;
  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement>) => setV({ ...(v ?? {}), [k]: e.target.value });
  return (
    <Card title="Serving rules">
      <p className="type-caption" style={{ margin: 0 }}>
        Each member may serve up to {Number(s.serving_limit_per_month) * Number(s.hours_per_slot)} hours a month across all teams,
        with at least {s.sundays_off_per_month} Sunday{s.sundays_off_per_month === 1 ? '' : 's'} off. Change the hours at the start
        of a month: places already booked keep their hours.
      </p>
      <div className="tec-fields" style={{ padding: 0 }}>
        <TextField id="sr-limit" label="Usual slots a month" type="number" min={1} max={31} disabled={!canEdit} value={val('limit', s.serving_limit_per_month)} onChange={set('limit')} />
        <TextField id="sr-hours" label="Hours in a usual slot" type="number" min={0.5} max={16} step={0.5} disabled={!canEdit} value={val('hours', s.hours_per_slot)} onChange={set('hours')} />
        <TextField id="sr-off" label="Sundays off a month" type="number" min={0} max={3} disabled={!canEdit} value={val('off', s.sundays_off_per_month)} onChange={set('off')} />
        <TextField id="sr-leaders" label="Leadership roles at once" type="number" min={1} max={10} disabled={!canEdit} value={val('leaders', s.leader_roles_max)} onChange={set('leaders')} />
      </div>
      {save.isError && <Notice tone="danger">{friendlyError(save.error)}</Notice>}
      {canEdit && (
        <div>
          <Button variant="secondary" disabled={!v || save.isPending} onClick={() => save.mutate()}>
            Save serving rules
          </Button>
        </div>
      )}
    </Card>
  );
}
