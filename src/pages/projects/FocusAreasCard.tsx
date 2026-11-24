// -------------------------------------------------------------------------------------
// The four focus areas on an event's page (migration 33, decision of 24 Nov 2026).
// Before approval the owner names the areas the event aims at, one primary, each with an
// intended outcome and an optional target; approval needs them. Once the event has started the
// owner rates each area from "not achieved" to "fully" with a short story, and records the
// event's counts (never names); closing needs every aimed area rated. Others read only.
// The database decides every change (app.project_focus_write_guard, app.project_outcome_guard);
// this card shows its message when it says no.
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { TEC } from '../../design-system';
import { friendlyError } from '../../data/errors';
import type { Project } from '../../data/projects';
import {
  aimProblems,
  aimsEditable,
  FOCUS_AREAS,
  OUTCOME_FIELDS,
  parseCount,
  RATINGS,
  ratingLabel,
  reviewOpen,
  useFocusReviews,
  useProjectFocus,
  useProjectOutcomes,
  useRemoveAim,
  useSaveAim,
  useSaveOutcomes,
  useSaveReview,
  type FocusAreaInfo,
  type FocusReview,
  type ProjectFocus,
  type ProjectOutcomes,
} from '../../data/focus';

const { Card, Button, Chip, Notice, SelectField, TextField, Checkbox } = TEC;

export function FocusAreasCard({ p, canManage }: { p: Project; canManage: boolean }) {
  const aims = useProjectFocus(p.id);
  const reviews = useFocusReviews(p.id);
  const outcomes = useProjectOutcomes(p.id);
  const editAims = canManage && aimsEditable(p.status);
  const showReview = reviewOpen(p.status, p.starts_at) || p.status === 'done';
  const editReview = canManage && reviewOpen(p.status, p.starts_at);
  const rows = aims.data ?? [];
  const problems = aimProblems(rows);

  return (
    <Card title="Four focus areas">
      <p className="type-caption" style={{ margin: 0 }}>
        What this event aims to achieve for Discipleship &amp; Maturity, Assimilation, Pastoral Care and Soul Winning, and afterwards how far it
        did. The event is assessed, never the people in it.
      </p>
      <details className="app-focus-help">
        <summary className="type-caption">What the four areas mean</summary>
        <dl>
          {FOCUS_AREAS.map((a) => (
            <div key={a.key}>
              <dt>{a.name}</dt>
              <dd>{a.definition}</dd>
            </div>
          ))}
        </dl>
      </details>
      {aims.error && <Notice tone="danger">{friendlyError(aims.error)}</Notice>}
      {aims.isPending && <p style={{ margin: 0 }}>Loading…</p>}

      {aims.data && (
        <>
          <h4 className="app-subhead">{editAims ? 'What it aims at' : 'Aims'}</h4>
          {editAims && problems.length > 0 && (
            <Notice tone="warn" title="Needed before approval">
              {problems.join(' ')}
            </Notice>
          )}
          {!editAims && rows.length === 0 && (
            <p style={{ margin: 0 }}>{p.status === 'draft' || p.status === 'submitted' ? 'No focus areas named yet.' : 'No focus areas were named for this event.'}</p>
          )}
          <ul className="app-focus-list">
            {FOCUS_AREAS.map((a) => {
              const row = rows.find((r) => r.area === a.key);
              if (!editAims && !row) return null;
              return editAims ? <AimEditor key={a.key} projectId={p.id} info={a} row={row} /> : <AimRead key={a.key} info={a} row={row!} />;
            })}
          </ul>
        </>
      )}

      {showReview && aims.data && (
        <>
          <h4 className="app-subhead">How it went</h4>
          {editReview && (
            <p className="type-caption" style={{ margin: 0 }}>
              Rate each area it aimed at before closing the event. You can rate the others too if the event touched them.
            </p>
          )}
          {reviews.error && <Notice tone="danger">{friendlyError(reviews.error)}</Notice>}
          <ul className="app-focus-list">
            {/* Areas the event aimed at first (they must be rated), then the optional ones. */}
            {[...FOCUS_AREAS].sort((x, y) => Number(rows.some((r) => r.area === y.key)) - Number(rows.some((r) => r.area === x.key))).map((a) => {
              const aimed = rows.some((r) => r.area === a.key);
              const review = reviews.data?.find((r) => r.area === a.key);
              if (!editReview && !review) return null;
              return editReview ? (
                <ReviewEditor key={a.key} projectId={p.id} info={a} aimed={aimed} review={review} />
              ) : (
                <ReviewRead key={a.key} info={a} aimed={aimed} review={review!} />
              );
            })}
          </ul>
          {outcomes.data !== undefined && (
            <Outcomes projectId={p.id} row={outcomes.data} editable={editReview} />
          )}
        </>
      )}
    </Card>
  );
}

function AimRead({ info, row }: { info: FocusAreaInfo; row: ProjectFocus }) {
  return (
    <li>
      <div className="app-focus-head">
        <strong>{info.name}</strong>
        {row.is_primary && <Chip tone="app">Primary</Chip>}
      </div>
      <span>{row.intended_outcome}</span>
      {row.target_count !== null && <span className="type-caption">Target: {row.target_count}</span>}
    </li>
  );
}

function AimEditor({ projectId, info, row }: { projectId: string; info: FocusAreaInfo; row: ProjectFocus | undefined }) {
  const save = useSaveAim(projectId);
  const remove = useRemoveAim(projectId);
  const [on, setOn] = useState(!!row);
  const [primary, setPrimary] = useState(row?.is_primary ?? false);
  const [outcome, setOutcome] = useState(row?.intended_outcome ?? '');
  const [target, setTarget] = useState(row?.target_count == null ? '' : String(row.target_count));
  const [problem, setProblem] = useState<string | null>(null);
  const id = `aim-${info.key}`;
  const changed =
    !row || row.is_primary !== primary || row.intended_outcome !== outcome.trim() || String(row.target_count ?? '') !== target.trim();

  const onSave = () => {
    const t = parseCount(target);
    if (!outcome.trim()) return setProblem('Write the outcome this event aims for.');
    if (!t.ok) return setProblem('The target is a whole number, or leave it blank.');
    setProblem(null);
    save.mutate({ area: info.key, is_primary: primary, intended_outcome: outcome, target_count: t.value });
  };
  const onToggle = (checked: boolean) => {
    setOn(checked);
    // Unticking a saved aim removes it.
    if (!checked && row) remove.mutate(info.key);
  };

  return (
    <li>
      <Checkbox id={`${id}-on`} label={`Aims at ${info.name}`} checked={on} onChange={(e) => onToggle(e.target.checked)} disabled={remove.isPending} />
      <span className="type-caption">{info.short}</span>
      {on && (
        <div className="app-focus-edit">
          <label className="tec-field app-field-wide" htmlFor={`${id}-outcome`}>
            <span>Intended outcome</span>
            <textarea id={`${id}-outcome`} className="tec-input app-textarea" rows={2} maxLength={500} value={outcome} onChange={(e) => setOutcome(e.target.value)} />
          </label>
          <TextField id={`${id}-target`} label="Target (optional)" hint="A number, e.g. guests or sign-ups" inputMode="numeric" value={target} onChange={(e) => setTarget(e.target.value)} />
          <Checkbox id={`${id}-primary`} label="Primary focus of this event" checked={primary} onChange={(e) => setPrimary(e.target.checked)} />
          <span>
            <Button size="sm" variant="secondary" disabled={save.isPending || !changed} onClick={onSave}>
              {save.isPending ? 'Saving…' : row ? 'Save changes' : 'Save'}
            </Button>
          </span>
          {problem && <Notice tone="warn">{problem}</Notice>}
        </div>
      )}
      {(save.error || remove.error) && <Notice tone="danger">{friendlyError(save.error ?? remove.error)}</Notice>}
    </li>
  );
}

function ReviewRead({ info, aimed, review }: { info: FocusAreaInfo; aimed: boolean; review: FocusReview }) {
  return (
    <li>
      <div className="app-focus-head">
        <strong>{info.name}</strong>
        {!aimed && <span className="type-caption">(not an aim)</span>}
        <Chip tone={review.rating >= 3 ? 'ok' : review.rating >= 2 ? 'info' : 'warn'}>{ratingLabel(review.rating)}</Chip>
      </div>
      {review.story && <span>{review.story}</span>}
    </li>
  );
}

function ReviewEditor({ projectId, info, aimed, review }: { projectId: string; info: FocusAreaInfo; aimed: boolean; review: FocusReview | undefined }) {
  const save = useSaveReview(projectId);
  const [rating, setRating] = useState(review ? String(review.rating) : '');
  const [story, setStory] = useState(review?.story ?? '');
  const id = `rev-${info.key}`;
  const changed = !review || String(review.rating) !== rating || (review.story ?? '') !== story.trim();
  return (
    <li>
      <div className="app-focus-head">
        <strong>{info.name}</strong>
        {aimed ? <Chip tone={review ? 'ok' : 'warn'}>{review ? 'Rated' : 'Aimed at: rate it'}</Chip> : <span className="type-caption">(optional)</span>}
      </div>
      <div className="app-focus-edit">
        <SelectField
          id={`${id}-rating`}
          label="How far it was achieved"
          value={rating}
          onChange={(e) => setRating(e.target.value)}
          options={[{ value: '', label: 'Choose' }, ...RATINGS.map((r) => ({ value: String(r.value), label: `${r.value} · ${r.label}` }))]}
        />
        <label className="tec-field app-field-wide" htmlFor={`${id}-story`}>
          <span>What happened (optional)</span>
          <textarea id={`${id}-story`} className="tec-input app-textarea" rows={2} maxLength={1000} value={story} onChange={(e) => setStory(e.target.value)} />
        </label>
        <span>
          <Button
            size="sm"
            variant="secondary"
            disabled={save.isPending || rating === '' || !changed}
            onClick={() => save.mutate({ area: info.key, rating: Number(rating), story })}
          >
            {save.isPending ? 'Saving…' : 'Save rating'}
          </Button>
        </span>
      </div>
      {save.error && <Notice tone="danger">{friendlyError(save.error)}</Notice>}
    </li>
  );
}

type CountKey = (typeof OUTCOME_FIELDS)[number]['key'];

function Outcomes({ projectId, row, editable }: { projectId: string; row: ProjectOutcomes | null; editable: boolean }) {
  const save = useSaveOutcomes(projectId);
  const [v, setV] = useState<Record<CountKey, string>>(
    () => Object.fromEntries(OUTCOME_FIELDS.map((f) => [f.key, row?.[f.key] == null ? '' : String(row[f.key])])) as Record<CountKey, string>,
  );
  const [problem, setProblem] = useState<string | null>(null);
  if (!editable && !row) return null;

  const onSave = () => {
    const out: Partial<Record<CountKey, number | null>> = {};
    for (const f of OUTCOME_FIELDS) {
      const c = parseCount(v[f.key]);
      if (!c.ok) return setProblem(`${f.label}: a whole number, or leave it blank.`);
      out[f.key] = c.value;
    }
    setProblem(null);
    save.mutate(out);
  };

  return (
    <div className="app-form">
      <h4 className="app-subhead">The event&rsquo;s numbers</h4>
      <p className="type-caption" style={{ margin: 0 }}>Counts only, never names.</p>
      {editable ? (
        <>
          <fieldset className="app-fieldset tec-fields">
            <legend className="app-visually-hidden">The event&rsquo;s numbers</legend>
            {OUTCOME_FIELDS.map((f) => (
              <TextField key={f.key} id={`out-${f.key}`} label={f.label} inputMode="numeric" value={v[f.key]} onChange={(e) => setV({ ...v, [f.key]: e.target.value })} />
            ))}
          </fieldset>
          <span>
            <Button size="sm" variant="secondary" disabled={save.isPending} onClick={onSave}>
              {save.isPending ? 'Saving…' : 'Save numbers'}
            </Button>
          </span>
          {problem && <Notice tone="warn">{problem}</Notice>}
          {save.error && <Notice tone="danger">{friendlyError(save.error)}</Notice>}
          {save.isSuccess && !save.isPending && <p className="type-caption" role="status" style={{ margin: 0 }}>Numbers saved.</p>}
        </>
      ) : (
        <dl className="app-focus-counts">
          {OUTCOME_FIELDS.filter((f) => row?.[f.key] != null).map((f) => (
            <div key={f.key}>
              <dt>{f.label}</dt>
              <dd>{row![f.key]}</dd>
            </div>
          ))}
        </dl>
      )}
    </div>
  );
}
