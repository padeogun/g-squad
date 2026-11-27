// -------------------------------------------------------------------------------------
// Special Sunday (migration 37, decision of 27 Nov 2026). A Sunday with special guests or
// non-routine activities (a themed Sunday, say) is still a Sunday service, but it is planned
// like an event, with a planning committee. Whether a Sunday is special is the Resident
// Pastor's or the Operations Lead's call; only they see the switch. The database decides the
// same (app.project_kind_guard) and allows a committee only on a special Sunday
// (app.committee_guard). The grid stays its run of show.
// -------------------------------------------------------------------------------------
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { useProject } from '../../data/projects';
import { hasRole, useMe } from '../../auth/useMe';
import { CommitteeCard } from '../projects/AttendanceCards';

const { Card, Button, Notice, Chip } = TEC;

export function SpecialSunday({ projectId }: { projectId: string }) {
  const me = useMe();
  const qc = useQueryClient();
  const project = useProject(projectId);
  const p = project.data;
  const decides = hasRole(me.data, 'resident_pastor', 'operations_lead');

  const toggle = useMutation({
    mutationFn: async (special: boolean) => {
      const { error } = await supabase.from('projects').update({ is_special_sunday: special }).eq('id', projectId).select('id').single();
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['projects', projectId] }),
  });

  if (!p) return null;
  const open = !['done', 'cancelled'].includes(p.status);
  // Its committee is kept by the Sunday's owner (the Operations Lead).
  const canManage = hasRole(me.data, 'operations_lead') || p.owner_user_id === me.data?.id;
  // Nothing to show an ordinary Sunday's readers who cannot change it.
  if (!p.is_special_sunday && !decides) return null;
  return (
    <>
      <Card title="Special Sunday" action={p.is_special_sunday ? <Chip tone="info">Special</Chip> : undefined}>
        <p className="type-caption" style={{ margin: 0 }}>
          A Sunday with special guests or non-routine activities is planned like an event, with a planning committee. The Resident Pastor or
          the Operations Lead decides.
        </p>
        {decides && open && (
          <div>
            <Button variant="secondary" disabled={toggle.isPending} onClick={() => toggle.mutate(!p.is_special_sunday)}>
              {p.is_special_sunday ? 'Make it an ordinary Sunday' : 'Make it a special Sunday'}
            </Button>
          </div>
        )}
        {toggle.isError && <Notice tone="danger">{friendlyError(toggle.error)}</Notice>}
      </Card>
      {p.is_special_sunday && <CommitteeCard p={p} canManage={canManage} />}
    </>
  );
}
