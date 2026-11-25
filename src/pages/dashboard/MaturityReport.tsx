// -------------------------------------------------------------------------------------
// The quarterly Maturity report (migration 35, decision of 25 Nov 2026): how the G-Squad is
// growing, in counts only, never names. Leadership stages and moves, the discipleship pathway
// (Encounter to Sending) and moves on it, courses completed, baptisms, settling in, mentoring
// and one-to-ones. Any of the last four quarters; printable for the leadership meeting.
// Read by the roles that read the monthly report (the database checks in maturity_report).
// -------------------------------------------------------------------------------------
import { useState } from "react";
import { TEC } from "../../design-system";
import { friendlyError } from "../../data/errors";
import { todayIso } from "../../data/sundays";
import { hasRole, useMe } from "../../auth/useMe";
import { previousQuarter, quarterName, quarterOf } from "../../data/focus";
import { mentorKind } from "../../data/growth";
import {
  MATURITY_READERS,
  share,
  useMaturityReport,
  type MaturityReport as Report,
} from "../../data/maturity";

const { SectionHeading, Card, Notice, Button, SelectField } = TEC;

export function MaturityReport() {
  const me = useMe();
  const allowed = hasRole(me.data, ...MATURITY_READERS);
  const [thisQ] = useState(() => quarterOf(todayIso()));
  // This quarter and the three before it.
  const quarters = [thisQ];
  for (let i = 0; i < 3; i++)
    quarters.push(previousQuarter(quarters[quarters.length - 1]));
  const [q, setQ] = useState(thisQ);
  const report = useMaturityReport(q, allowed);
  const before = useMaturityReport(previousQuarter(q), allowed);

  if (me.isPending) return <p>Loading…</p>;
  return (
    <>
      <SectionHeading eyebrow="Maturity" title="Quarterly Maturity report" rule>
        How the G-Squad is growing as disciples and leaders. Counts only, never
        names; people are never scored.
      </SectionHeading>
      {!allowed ? (
        <Notice tone="info">
          The Maturity report is for the Coordinator, Resident Pastor, Purpose
          Heads, Operations Lead and Pastoral Lead.
        </Notice>
      ) : (
        <>
          <div
            className="tec-row app-no-print"
            style={{ padding: 0, alignItems: "flex-end" }}
          >
            <SelectField
              id="maturity-quarter"
              label="Quarter"
              value={q}
              onChange={(e) => setQ(e.target.value)}
              options={quarters.map((x, i) => ({
                value: x,
                label: `${quarterName(x)}${i === 0 ? " (this quarter)" : ""}`,
              }))}
            />
            <Button variant="secondary" onClick={() => window.print()}>
              Print
            </Button>
          </div>
          {report.error && (
            <Notice tone="danger">{friendlyError(report.error)}</Notice>
          )}
          {report.isPending && <p>Loading…</p>}
          {report.data && <Body r={report.data} prev={before.data} />}
        </>
      )}
    </>
  );
}

// "+2 on last quarter", for figures that are counted within a quarter.
function Change({ now, prev }: { now: number; prev: number | undefined }) {
  if (prev === undefined) return null;
  const d = now - prev;
  return (
    <span className="type-caption">
      {" "}
      ({d === 0 ? "same as" : d > 0 ? `+${d} on` : `${d} on`} the quarter
      before)
    </span>
  );
}

function Row({
  label,
  value,
  prev,
}: {
  label: string;
  value: number | string;
  prev?: number;
}) {
  return (
    <div>
      <dt>{label}</dt>
      <dd>
        {value}
        {typeof value === "number" && <Change now={value} prev={prev} />}
      </dd>
    </div>
  );
}

// One bar per stage: how many members are at it now, as a share of those with a stage.
function StageBars({
  rows,
  total,
  caption,
}: {
  rows: Array<{ stage: string; members: number }>;
  total: number;
  caption: string;
}) {
  // The caption sits above as plain text (the design system styles <caption> as a heading).
  return (
    <>
      <p className="type-caption" style={{ margin: 0 }}>
        {caption}
      </p>
      <table className="tec-table app-maturity-bars" aria-label={caption}>
        <thead>
          <tr>
            <th scope="col">Stage</th>
            <th scope="col">Members</th>
            <th scope="col">Share</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.stage}>
              <td>{r.stage}</td>
              <td>{r.members}</td>
              <td>
                <span className="app-maturity-bar" aria-hidden="true">
                  <span style={{ width: `${share(r.members, total)}%` }} />
                </span>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </>
  );
}

function Body({ r, prev }: { r: Report; prev: Report | undefined }) {
  const withLeadStage = r.leadership.stages.reduce((n, s) => n + s.members, 0);
  const withPathway = r.pathway.stages.reduce((n, s) => n + s.members, 0);
  const discipleship = r.courses.filter((c) => c.kind === "discipleship");
  const leadership = r.courses.filter((c) => c.kind === "leadership");
  const prevCourse = (name: string) =>
    prev?.courses.find((c) => c.course === name)?.completed;
  const prevPair = (kind: string) =>
    prev?.pairings.find((p) => p.kind === kind);
  return (
    <div className="app-maturity">
      <p className="type-caption" style={{ margin: 0 }}>
        {quarterName(r.quarter_start)}: {r.members} active G-Squad members.
        Stage counts are where members stand at the end of the quarter.
      </p>

      <Card title="Discipleship pathway">
        <StageBars
          rows={r.pathway.stages}
          total={withPathway}
          caption={`Members by pathway stage (${withPathway} with a stage recorded)`}
        />
        <dl className="app-focus-counts">
          <Row
            label="Moved on to a later stage this quarter"
            value={r.pathway.moved_on}
            prev={prev?.pathway.moved_on}
          />
          <Row
            label="First stage recorded this quarter"
            value={r.pathway.first_recorded}
            prev={prev?.pathway.first_recorded}
          />
          <Row label="No stage recorded yet" value={r.pathway.not_recorded} />
        </dl>
      </Card>

      <Card title="Leadership development">
        <StageBars
          rows={r.leadership.stages}
          total={withLeadStage}
          caption={`Members by leadership stage (${withLeadStage} with a stage)`}
        />
        <dl className="app-focus-counts">
          <Row
            label="Moves to a later leadership stage"
            value={r.leadership.moves_up}
            prev={prev?.leadership.moves_up}
          />
          <Row
            label="Members who moved up"
            value={r.leadership.members_moved_up}
            prev={prev?.leadership.members_moved_up}
          />
          <Row
            label="Leadership training completed"
            value={r.leadership.leadership_courses}
            prev={prev?.leadership.leadership_courses}
          />
          <Row
            label="Members with no leadership stage"
            value={r.leadership.no_stage}
          />
        </dl>
      </Card>

      <Card title="Courses and baptisms">
        <dl className="app-focus-counts">
          {discipleship.map((c) => (
            <Row
              key={c.course}
              label={c.course}
              value={c.completed}
              prev={prevCourse(c.course)}
            />
          ))}
          {leadership.map((c) => (
            <Row
              key={c.course}
              label={c.course}
              value={c.completed}
              prev={prevCourse(c.course)}
            />
          ))}
          <Row
            label="Water baptisms"
            value={r.water_baptisms}
            prev={prev?.water_baptisms}
          />
          <Row
            label="Holy Spirit baptisms"
            value={r.spirit_baptisms}
            prev={prev?.spirit_baptisms}
          />
        </dl>
      </Card>

      <Card title="Settling in and mentoring">
        <dl className="app-focus-counts">
          <Row
            label="New members"
            value={r.new_members}
            prev={prev?.new_members}
          />
          <Row
            label="Settled in (all six steps done)"
            value={r.settled_in}
            prev={prev?.settled_in}
          />
          <Row
            label="30-day conversations held"
            value={r.day_30_held}
            prev={prev?.day_30_held}
          />
          <Row
            label="90-day conversations held"
            value={r.day_90_held}
            prev={prev?.day_90_held}
          />
          {r.pairings.map((p) => (
            <Row
              key={p.kind}
              label={`${mentorKind(p.kind).label} pairings open (${p.started} started this quarter)`}
              value={p.open}
              prev={prevPair(p.kind)?.open}
            />
          ))}
          <Row
            label="Members with a one-to-one"
            value={`${r.one_to_ones} of ${r.members}`}
          />
        </dl>
      </Card>
    </div>
  );
}
