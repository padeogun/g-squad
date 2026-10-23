// -------------------------------------------------------------------------------------
// Capacity calendar: spare serving slots per unit per month for a year (slots members offer,
// split across their units and reduced by holidays, minus the unit's regular monthly need and
// project demand). Negative means a shortfall to plan for (R6 asks for an action before a
// project with a shortfall is approved). Figures only; no names.
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { useCapacity } from '../../data/dashboards';
import { hasRole, useMe } from '../../auth/useMe';

const { SectionHeading, Card, Notice, Button } = TEC;

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// Mirrors public.capacity_calendar's audience.
const CAPACITY_ROLES = ['resident_pastor', 'purpose_head', 'gsquad_coordinator', 'unit_lead', 'operations_lead'] as const;

export function Capacity() {
  const me = useMe();
  const allowed = hasRole(me.data, ...CAPACITY_ROLES);
  const [year, setYear] = useState(() => new Date().getFullYear() + 1);
  const cap = useCapacity(year, allowed);

  // unit -> 12 monthly figures
  const byUnit = new Map<string, (number | null)[]>();
  for (const r of cap.data ?? []) {
    const row = byUnit.get(r.unit_name) ?? Array<number | null>(12).fill(null);
    row[Number(r.month.slice(5, 7)) - 1] = Math.round(Number(r.spare) * 10) / 10;
    byUnit.set(r.unit_name, row);
  }

  return (
    <>
      <SectionHeading eyebrow="Planning" title="Capacity calendar" rule>
        Spare serving slots per unit each month. A minus figure is a shortfall to plan for.
      </SectionHeading>
      {!allowed ? (
        <Notice tone="info">The capacity calendar is for the leadership group and the Operations Lead.</Notice>
      ) : (
        <Card
          title={String(year)}
          action={
            <span className="tec-row" style={{ padding: 0 }}>
              <Button size="sm" variant="quiet" onClick={() => setYear(year - 1)}>
                ‹ {year - 1}
              </Button>
              <Button size="sm" variant="quiet" onClick={() => setYear(year + 1)}>
                {year + 1} ›
              </Button>
            </span>
          }
        >
          {cap.isPending && <p>Loading…</p>}
          {cap.error && <Notice tone="danger">{friendlyError(cap.error)}</Notice>}
          {cap.data && byUnit.size === 0 && <p>No active units yet.</p>}
          {byUnit.size > 0 && (
            <div className="tec-table-wrap">
              <table className="tec-table app-capacity">
                <caption className="type-caption">Spare slots by month, {year}</caption>
                <thead>
                  <tr>
                    <th scope="col">Unit</th>
                    {MONTHS.map((m) => (
                      <th scope="col" key={m}>
                        {m}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {[...byUnit].map(([unit, row]) => (
                    <tr key={unit}>
                      <th scope="row">{unit}</th>
                      {row.map((v, i) => (
                        <td key={i} className={v === null ? '' : v < 0 ? 'app-cap-short' : v < 2 ? 'app-cap-tight' : 'app-cap-ok'}>
                          {v === null ? '–' : v}
                        </td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <p className="type-caption" style={{ margin: 0 }}>
            Red: short. Amber: under 2 spare. Figures update as rotas, holidays and project demand change.
          </p>
        </Card>
      )}
    </>
  );
}
