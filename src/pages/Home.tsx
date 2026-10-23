// Home page for slice 0: confirms the app, the design system and the database connection
// work. The real Church Dashboard arrives in slice 3.
import { useQuery } from '@tanstack/react-query';
import { TEC } from '../design-system';
import { supabase } from '../lib/supabase';

const { SectionHeading, Card, Notice, ValuesStrip } = TEC;

export function Home() {
  // core_values is readable by every signed-in member of the church (RLS), so it doubles
  // as a check that sign-in, the API key and row-level security are all working.
  const values = useQuery({
    queryKey: ['core_values'],
    queryFn: async () => {
      const { data, error } = await supabase.from('core_values').select('*').limit(10);
      if (error) throw error;
      return data;
    },
  });

  return (
    <>
      <SectionHeading eyebrow="G-Squad Planner" title="Welcome" rule />
      <Notice tone="info" title="Early build">
        This is the first build of the app. Screens are added slice by slice; the sidebar shows what is coming.
      </Notice>
      <Card title="Our core values">
        <ValuesStrip />
      </Card>
      <Card title="Connection check">
        {values.isPending && <p>Checking the database…</p>}
        {values.isError && (
          <Notice tone="danger" title="Couldn't reach the database">
            {(values.error as Error).message}
          </Notice>
        )}
        {values.isSuccess && (
          <p>
            Connected. Your account can see {values.data.length} core value
            {values.data.length === 1 ? '' : 's'} for your church.
          </p>
        )}
      </Card>
    </>
  );
}
