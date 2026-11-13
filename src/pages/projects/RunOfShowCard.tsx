// -------------------------------------------------------------------------------------
// The event's run of show on its project page (migration 32): every event has one, as a
// Sunday has its service grid. It shows the run of show's status and version and opens it; the
// owner (or the Operations Lead) starts it. It must be started before the event is approved;
// its own approval (by the event's approver) can follow nearer the day, as a Sunday's does.
// The database decides who may start it (grid policies and app.grid_kind_guard).
// -------------------------------------------------------------------------------------
import { Link, useNavigate } from 'react-router-dom';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import { longDate, useProjectRunOfShow, useStartRunOfShow } from '../../data/sundays';
import type { Project } from '../../data/projects';
import { GridStatus } from '../sunday/GridStatus';

const { Card, Button, Notice } = TEC;

export function RunOfShowCard({ p, canManage }: { p: Project; canManage: boolean }) {
  const grid = useProjectRunOfShow(p.id);
  const start = useStartRunOfShow(p.id);
  const navigate = useNavigate();
  const open = p.status !== 'done' && p.status !== 'cancelled';

  return (
    <Card title="Run of show">
      {grid.isPending && <p style={{ margin: 0 }}>Loading…</p>}
      {grid.error && <Notice tone="danger">{friendlyError(grid.error)}</Notice>}
      {grid.data && (
        <div className="tec-row" style={{ padding: 0 }}>
          <GridStatus grid={grid.data} />
          <span className="type-caption">
            {longDate(grid.data.service_date)} · version {grid.data.version}
          </span>
          <Link to={`/run-of-show/${grid.data.id}`}>Open the run of show</Link>
        </div>
      )}
      {grid.data === null && (
        <div style={{ display: 'grid', gap: 8 }}>
          <p style={{ margin: 0 }}>
            The timed order of the event, who leads each part, and what is printed with it. Start it before the event is approved;
            the event&rsquo;s approver approves it once it is finalised.
          </p>
          {canManage && open && (
            <span>
              <Button
                variant="primary"
                disabled={start.isPending}
                onClick={() => start.mutate(undefined, { onSuccess: (id) => navigate(`/run-of-show/${id}`) })}
              >
                Start the run of show
              </Button>
            </span>
          )}
          {start.error && <Notice tone="danger">{friendlyError(start.error)}</Notice>}
        </div>
      )}
    </Card>
  );
}
