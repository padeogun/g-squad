// -------------------------------------------------------------------------------------
// Volunteer shortfalls (decision of 25 Oct 2026): every coming project whose volunteers needed
// from a unit in a month exceed that unit's spare capacity, always shown, not only when the
// project is approved. On the Church Dashboard for all units, on My Unit for one unit.
// Figures come from public.volunteer_shortfalls (migration 25); no names of people.
// -------------------------------------------------------------------------------------
import { Link } from 'react-router-dom';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { STATUS_LABEL, useShortfalls } from '../../data/projects';

const { Card, Notice, Chip } = TEC;

const monthName = (iso: string) =>
  new Date(`${iso.slice(0, 10)}T12:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });

export function ShortfallsCard({ unitId = null, enabled = true }: { unitId?: string | null; enabled?: boolean }) {
  const list = useShortfalls(unitId, enabled);
  return (
    <Card title="Volunteer shortfalls" action={<Link to="/capacity">Capacity calendar</Link>}>
      {list.isPending && <p>Loading…</p>}
      {list.error && <Notice tone="danger">{friendlyError(list.error)}</Notice>}
      {list.data && list.data.length === 0 && (
        <p style={{ margin: 0 }}>{unitId ? 'No coming project is short of volunteers from this team.' : 'No coming project is short of volunteers.'}</p>
      )}
      {list.data && list.data.length > 0 && (
        <ul className="app-candidates">
          {list.data.map((s) => {
            const short = Math.max(1, Math.ceil(s.slots_needed - Math.max(0, Number(s.spare))));
            const to = s.is_sunday_service ? (s.grid_id ? `/sundays/${s.grid_id}` : '/sundays') : `/projects/${s.project_id}`;
            return (
              <li key={`${s.project_id}-${s.unit_id}-${s.month}`}>
                <span>
                  <Link to={to}>{s.project_name}</Link>
                  <span className="type-caption">
                    {' '}
                    · {unitId ? '' : `${s.unit_name}, `}
                    {monthName(s.month)} · {STATUS_LABEL[s.project_status]}
                  </span>
                </span>
                <Chip tone="danger">{`Short by ${short}`}</Chip>
              </li>
            );
          })}
        </ul>
      )}
    </Card>
  );
}
