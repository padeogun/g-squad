// -------------------------------------------------------------------------------------
// Engagement mix as one stacked bar with a legend: Active, Occasional, New, Inactive, Paused.
// Colours are the design system's data tokens (data-1..5), in a fixed order so a colour
// always means the same thing. Counts are printed in the legend, so the bar is never the only
// carrier of the numbers (accessibility), and the bar itself is hidden from screen readers.
// -------------------------------------------------------------------------------------
import type { EngagementMix } from '../../data/dashboards';

const ORDER: { key: keyof EngagementMix; label: string; token: string }[] = [
  { key: 'active', label: 'Active', token: 'var(--data-1)' },
  { key: 'occasional', label: 'Occasional', token: 'var(--data-2)' },
  { key: 'new', label: 'New', token: 'var(--data-3)' },
  { key: 'inactive', label: 'Inactive', token: 'var(--data-4)' },
  { key: 'paused', label: 'Paused', token: 'var(--data-5)' },
];

export function EngagementBar({ mix }: { mix: EngagementMix }) {
  const total = ORDER.reduce((n, o) => n + mix[o.key], 0);
  if (total === 0) return <p>No members yet.</p>;
  return (
    <div className="app-mix">
      <div className="app-mix-bar" aria-hidden="true">
        {ORDER.filter((o) => mix[o.key] > 0).map((o) => (
          <span key={o.key} style={{ flexGrow: mix[o.key], background: o.token }} />
        ))}
      </div>
      <ul className="app-mix-legend">
        {ORDER.map((o) => (
          <li key={o.key}>
            <span className="app-mix-swatch" style={{ background: o.token }} aria-hidden="true" />
            {o.label} <strong>{mix[o.key]}</strong>
          </li>
        ))}
      </ul>
    </div>
  );
}
