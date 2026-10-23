// Placeholder for a screen that a later build slice delivers.
import { TEC } from '../design-system';

const { SectionHeading, Notice } = TEC;

export function ComingSoon({ title, slice }: { title: string; slice: number }) {
  return (
    <>
      <SectionHeading eyebrow="Coming soon" title={title} rule />
      <Notice tone="info" title={`Arrives in slice ${slice}`}>
        This screen is designed and will be built in slice {slice} of the build plan.
      </Notice>
    </>
  );
}
