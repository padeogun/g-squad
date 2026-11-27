// -------------------------------------------------------------------------------------
// Monthly programme reports (migration 37, decisions of 27 Nov 2026).
//   * Maturity: classes held, people completing them, G-Squad participation, decisions for Christ.
//   * Evangelism: outreach sessions, people and G-Squad participation, decisions for Christ.
//   * Assimilation: visitors welcomed and onboarded within 48 hours, people connected to the
//     Greatness Communities.
// A team whose programme reports on an area writes one report a month: its Team Lead types
// what the app cannot know, sees beside it what the app counts from linked events and routine
// activities, and submits it to the G-Squad Coordinator. The Coordinator may return it for
// changes. This page is also the Coordinator's monthly view: every team's report and the
// church totals, which go into the Coordinator's monthly report to the Resident Pastor.
// Readers: the monthly-report roles and each team's own Lead and Deputy (the database decides:
// app.can_read_programme_report). Counts only, no names.
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { byId, useUnits } from '../../data/reference';
import { hasRole, ledUnitIds, viewedUnitIds, useMe } from '../../auth/useMe';
import { todayIso } from '../../data/sundays';
import {
  AREAS,
  AREA_KEYS,
  monthStart,
  parseFigure,
  sumTyped,
  totalDecisions,
  useAppFigures,
  useProgrammeReports,
  useProgrammes,
  type ProgrammeArea,
  type ProgrammeReport,
} from '../../data/programmes';

const { SectionHeading, Card, Button, TextField, Notice, Chip, StatTile } = TEC;

const REPORT_ROLES = ['gsquad_coordinator', 'resident_pastor', 'purpose_head', 'operations_lead', 'pastoral_lead'] as const;

// The last twelve months, newest first, as YYYY-MM-01 (the database refuses a future month).
function recentMonths(today: string): string[] {
  const out: string[] = [];
  const d = new Date(`${monthStart(today)}T12:00:00Z`);
  for (let i = 0; i < 12; i++) {
    out.push(d.toISOString().slice(0, 10));
    d.setUTCMonth(d.getUTCMonth() - 1);
  }
  return out;
}
const monthLabel = (iso: string) => new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });

export function ProgrammeReports() {
  const me = useMe();
  const units = useUnits();
  const programmes = useProgrammes();
  const [today] = useState(todayIso);
  const months = recentMonths(today);
  const [month, setMonth] = useState(months[0]);
  const reports = useProgrammeReports(month);

  const readsAll = hasRole(me.data, ...REPORT_ROLES);
  const isCoordinator = hasRole(me.data, 'gsquad_coordinator');
  const led = ledUnitIds(me.data);
  const viewed = viewedUnitIds(me.data);
  // Each team's reporting areas, from its current programmes.
  const areasOf = (unitId: string) =>
    [...new Set((programmes.data ?? []).filter((x) => x.unit_id === unitId && x.is_active && x.report_area).map((x) => x.report_area!))];
  const reportingUnits = [...new Set((programmes.data ?? []).filter((x) => x.is_active && x.report_area).map((x) => x.unit_id))];
  // The teams whose report this leader writes (Team Lead) or sees as its own (Deputy).
  const myTeams = reportingUnits.filter((u) => viewed.includes(u));
  const unitName = (id: string) => byId(units.data).get(id)?.name ?? 'Team';

  if (me.isPending || programmes.isPending || reports.isPending) return <p>Loading…</p>;
  if (!readsAll && myTeams.length === 0)
    return (
      <>
        <SectionHeading eyebrow="Overview" title="Programme reports" rule />
        <Notice tone="info">Monthly programme reports are written by teams whose programmes report on Maturity, Evangelism or Assimilation, and read by the monthly-report roles.</Notice>
      </>
    );

  const list = reports.data ?? [];
  const find = (unitId: string, area: ProgrammeArea) => list.find((r) => r.unit_id === unitId && r.area === area);
  return (
    <>
      <SectionHeading eyebrow="Overview" title="Programme reports" rule>
        Each reporting programme&rsquo;s month: what the team typed and what the app counted from linked events and activities. Counts only.
      </SectionHeading>
      <div className="tec-row" style={{ padding: 0 }}>
        <label className="tec-field" htmlFor="pr-month">
          <span>Month</span>
          <select id="pr-month" className="tec-input" value={month} onChange={(e) => setMonth(e.target.value)}>
            {months.map((m) => (
              <option key={m} value={m}>
                {monthLabel(m)}
              </option>
            ))}
          </select>
        </label>
      </div>
      {reports.error && <Notice tone="danger">{friendlyError(reports.error)}</Notice>}

      {/* The leader's own teams: write (Team Lead) or read (Deputy). */}
      {myTeams.map((u) =>
        areasOf(u).map((area) => (
          <ReportForm
            key={`${u}-${area}-${month}-${find(u, area)?.updated_at ?? 'new'}`}
            unitId={u}
            unitName={unitName(u)}
            area={area}
            month={month}
            report={find(u, area)}
            canWrite={led.includes(u) || isCoordinator}
            isCoordinator={isCoordinator}
          />
        )),
      )}

      {/* The monthly view for the report roles: every team, and church totals. */}
      {readsAll &&
        AREA_KEYS.map((area) => {
          const teams = reportingUnits.filter((u) => areasOf(u).includes(area));
          if (teams.length === 0) return null;
          const submitted = list.filter((r) => r.area === area && r.status === 'submitted');
          return (
            <Card key={area} title={`${AREAS[area].label}: all teams`}>
              <div className="tec-stats">
                {AREAS[area].typed.map((f) => (
                  <StatTile key={f.key} label={f.label} value={sumTyped(submitted, f.key)} />
                ))}
              </div>
              <p className="type-caption" style={{ margin: 0 }}>
                Totals from submitted reports ({submitted.length} of {teams.length} team{teams.length > 1 ? 's' : ''}).
              </p>
              {teams
                .filter((u) => !myTeams.includes(u) || isCoordinator)
                .map((u) => (
                  <ReportForm
                    key={`all-${u}-${area}-${month}-${find(u, area)?.updated_at ?? 'new'}`}
                    unitId={u}
                    unitName={unitName(u)}
                    area={area}
                    month={month}
                    report={find(u, area)}
                    canWrite={isCoordinator && !myTeams.includes(u)}
                    isCoordinator={isCoordinator}
                    compact
                  />
                ))}
            </Card>
          );
        })}
    </>
  );
}

// One team's report for one area and month: typed figures (editable while a draft, for the Team
// Lead or the Coordinator) beside what the app counts.
function ReportForm({
  unitId,
  unitName,
  area,
  month,
  report,
  canWrite,
  isCoordinator,
  compact = false,
}: {
  unitId: string;
  unitName: string;
  area: ProgrammeArea;
  month: string;
  report: ProgrammeReport | undefined;
  canWrite: boolean;
  isCoordinator: boolean;
  compact?: boolean;
}) {
  const qc = useQueryClient();
  const app = useAppFigures(unitId, area, month);
  const typedNow = (report?.figures ?? {}) as Record<string, unknown>;
  const [raw, setRaw] = useState<Record<string, string>>(() =>
    Object.fromEntries(AREAS[area].typed.map((f) => [f.key, typeof typedNow[f.key] === 'number' ? String(typedNow[f.key]) : ''])),
  );
  const [commentary, setCommentary] = useState(report?.commentary ?? '');
  const [errors, setErrors] = useState<Record<string, string>>({});
  const submitted = report?.status === 'submitted';
  const editable = canWrite && !submitted;

  const save = useMutation({
    mutationFn: async (status: 'draft' | 'submitted') => {
      const figures: Record<string, number | null> = {};
      const found: Record<string, string> = {};
      for (const f of AREAS[area].typed) {
        const r = parseFigure(raw[f.key] ?? '');
        if (r.error) found[f.key] = r.error;
        figures[f.key] = r.value;
      }
      setErrors(found);
      if (Object.keys(found).length > 0) throw new Error('Check the figures marked');
      const row = { figures, commentary: commentary.trim() || null, status };
      const { error } = report
        ? await supabase.from('programme_reports').update(row).eq('id', report.id).select('id').single()
        : await supabase.from('programme_reports').insert({ ...row, unit_id: unitId, area, report_month: month }).select('id').single();
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['programme-reports', month] }),
  });
  // The Coordinator returns a submitted report to the team for changes.
  const reopen = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('programme_reports').update({ status: 'draft' }).eq('id', report!.id).select('id').single();
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['programme-reports', month] }),
  });

  const status = submitted ? (
    <Chip tone="ok">Submitted</Chip>
  ) : report ? (
    <Chip tone="warn">Draft</Chip>
  ) : (
    <Chip tone="neutral">Not started</Chip>
  );
  // SECURITY REVIEW 30 (G04): a submitted report shows the app's counts as they stood then.
  const appFig = (submitted && report?.computed_figures ? report.computed_figures : app.data) as unknown as Record<string, number> | undefined;
  const body = (
    <>
      <div className="tec-fields">
        {AREAS[area].typed.map((f) =>
          editable ? (
            <TextField
              key={f.key}
              id={`pr-${unitId}-${area}-${f.key}`}
              label={f.label}
              inputMode="numeric"
              hint={errors[f.key] ? `– ${errors[f.key]}` : undefined}
              value={raw[f.key] ?? ''}
              onChange={(e) => setRaw({ ...raw, [f.key]: e.target.value })}
              aria-invalid={!!errors[f.key] || undefined}
            />
          ) : (
            <p key={f.key} style={{ margin: 0 }}>
              <span className="type-caption">{f.label}: </span>
              {typeof typedNow[f.key] === 'number' ? String(typedNow[f.key]) : '—'}
            </p>
          ),
        )}
      </div>
      <p className="type-caption" style={{ margin: 0 }}>
        {submitted ? 'Counted by the app when submitted' : 'Counted by the app from linked events and activities'}:{' '}
        {appFig
          ? AREAS[area].app.map((f) => `${f.label} ${appFig[f.key] ?? 0}`).join(' · ')
          : app.error
            ? friendlyError(app.error)
            : '…'}
        {area !== 'assimilation' && appFig ? ` · Decisions for Christ in all: ${totalDecisions(appFig, typedNow)}` : ''}
      </p>
      {editable ? (
        <label className="tec-field app-field-wide" htmlFor={`pr-${unitId}-${area}-c`}>
          <span>
            Commentary <span className="tec-hint">(optional)</span>
          </span>
          <textarea
            id={`pr-${unitId}-${area}-c`}
            className="tec-input app-textarea"
            rows={2}
            maxLength={4000}
            value={commentary}
            onChange={(e) => setCommentary(e.target.value)}
          />
        </label>
      ) : (
        report?.commentary && <p style={{ margin: 0, whiteSpace: 'pre-wrap' }}>{report.commentary}</p>
      )}
      {(save.isError || reopen.isError) && <Notice tone="danger">{friendlyError(save.error ?? reopen.error)}</Notice>}
      <div className="tec-row" style={{ padding: 0 }}>
        {editable && (
          <>
            <Button variant="secondary" disabled={save.isPending} onClick={() => save.mutate('draft')}>
              Save draft
            </Button>
            <Button variant="primary" disabled={save.isPending} onClick={() => save.mutate('submitted')}>
              Submit to the Coordinator
            </Button>
          </>
        )}
        {submitted && isCoordinator && (
          <Button variant="quiet" disabled={reopen.isPending} onClick={() => reopen.mutate()}>
            Return for changes
          </Button>
        )}
      </div>
    </>
  );
  if (compact)
    return (
      <details>
        <summary>
          {unitName} {status}
        </summary>
        {body}
      </details>
    );
  return (
    <Card title={`${unitName}: ${AREAS[area].label} report, ${monthLabel(month)}`} action={status}>
      {body}
    </Card>
  );
}
