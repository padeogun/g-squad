// Shown for any address the app doesn't know.
import { Link } from 'react-router-dom';
import { TEC } from '../design-system';

const { SectionHeading } = TEC;

export function NotFound() {
  return (
    <>
      <SectionHeading title="Page not found" rule />
      <p>
        That page doesn't exist. <Link to="/">Go to the dashboard</Link>.
      </p>
    </>
  );
}
