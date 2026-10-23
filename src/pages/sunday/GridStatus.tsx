// Status chip for a service grid: Draft, Finalised (awaiting the Resident Pastor) or Approved.
import { TEC } from '../../design-system';
import type { Grid } from '../../data/sundays';

const { Chip } = TEC;

export function GridStatus({ grid }: { grid: Pick<Grid, 'status' | 'version'> }) {
  if (grid.status === 'approved') return <Chip tone="ok">Approved · v{grid.version}</Chip>;
  if (grid.status === 'finalised') return <Chip tone="warn">Finalised · v{grid.version} · awaiting approval</Chip>;
  return <Chip tone="neutral">Draft</Chip>;
}
