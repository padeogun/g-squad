// -------------------------------------------------------------------------------------
// The four focus areas, this quarter or last, on the Church Dashboard (migration 33). Counts
// only, from public.focus_areas_summary: for each area, the events that aimed at it and how far
// they achieved it, members growing in it (one-to-ones), teams that talked it through, and what
// the app already knows about the G-Squad in that area. No names. Read by the roles that read
// the monthly report (it carries baptism counts, as that report does); the database checks.
// -------------------------------------------------------------------------------------
import { useState } from "react";
import { Link } from "react-router-dom";
import { TEC } from "../../design-system";
import { friendlyError } from "../../data/errors";
import { todayIso } from "../../data/sundays";
import { hasRole, useMe } from "../../auth/useMe";
import {
  FOCUS_AREAS,
  previousQuarter,
  quarterName,
  quarterOf,
  ratingSpread,
  SUMMARY_READERS,
  useFocusSummary,
  type FocusArea,
  type FocusSummary,
} from "../../data/focus";

const { Card, Notice, Segmented } = TEC;

export function FocusSummaryCard() {
  const me = useMe();
  const reader = hasRole(me.data, ...SUMMARY_READERS);
  const [thisQ] = useState(() => quarterOf(todayIso()));
  const lastQ = previousQuarter(thisQ);
  const [q, setQ] = useState(thisQ);
  const summary = useFocusSummary(q, reader);
  if (!reader) return null;
  const labels = [
    `This quarter (${quarterName(thisQ)})`,
    `Last quarter (${quarterName(lastQ)})`,
  ];

  return (
    <Card title="Four focus areas">
      <p className="type-caption" style={{ margin: 0 }}>
        Events are assessed on the four areas; people never are. Counts only.
        Growth in discipleship and leadership is in the{" "}
        <Link to="/maturity">quarterly Maturity report</Link>.
      </p>
      <Segmented
        label="Quarter"
        options={labels}
        value={q === thisQ ? labels[0] : labels[1]}
        onChange={(x) => setQ(x === labels[0] ? thisQ : lastQ)}
      />
      {summary.error && (
        <Notice tone="danger">{friendlyError(summary.error)}</Notice>
      )}
      {summary.isPending && <p style={{ margin: 0 }}>Loading…</p>}
      {summary.data && (
        <div className="app-focus-grid">
          {FOCUS_AREAS.map((a) => (
            <Area key={a.key} name={a.name} area={a.key} s={summary.data} />
          ))}
        </div>
      )}
    </Card>
  );
}

// What the G-Squad already shows in each area, besides events (all counts).
function markers(
  area: FocusArea,
  s: FocusSummary,
): Array<[string, string | number]> {
  const g = s.gsquad;
  const o = s.outcomes;
  switch (area) {
    case "discipleship":
      return [
        ["Signed up for a next step at events", o.next_step_signups],
        ["Members in TECi", `${g.in_teci} of ${g.members}`],
        ["Water baptisms", g.water_baptisms],
        ["Holy Spirit baptisms", g.spirit_baptisms],
        ["Discipleship courses completed", g.discipleship_courses],
        ["Members discipling one another", g.discipling],
        ["Leadership training completed", g.leadership_courses],
        ["Apprentices beside a leader", g.apprentices],
      ];
    case "assimilation":
      return [
        [
          "Guests contacted within 48 hours",
          `${o.guests_contacted_48h} of ${o.first_time_guests}`,
        ],
        ["Guests connected to a community", o.connected_to_community],
        [
          "Members in a Greatness Community",
          `${g.in_community} of ${g.members}`,
        ],
        ["New members with a buddy", `${g.new_with_buddy} of ${g.new_members}`],
        [
          "30-day and 90-day conversations held",
          `${g.day_30_held} and ${g.day_90_held}`,
        ],
        ["Values in Action recognitions", g.recognitions],
      ];
    case "pastoral_care":
      return [
        ["Members with a one-to-one", `${g.one_to_ones} of ${g.members}`],
        ["Check-ins open", g.open_checkins],
        ["Celebrating birthdays and anniversaries", g.celebrations_opted_in],
        ["Prayer or care follow-ups at events", o.care_followups],
      ];
    case "soul_winning":
      return [
        ["First-time guests at events", o.first_time_guests],
        ["Decisions for Christ", o.decisions_for_christ],
      ];
  }
}

function Area({
  name,
  area,
  s,
}: {
  name: string;
  area: FocusArea;
  s: FocusSummary;
}) {
  const a = s.areas.find((x) => x.area === area);
  if (!a) return null;
  const spread = ratingSpread(a.rating_counts);
  return (
    <section className="app-focus-area" aria-label={name}>
      <h4>{name}</h4>
      <dl className="app-focus-counts">
        <div>
          <dt>Events aiming at it</dt>
          <dd>
            {a.events_aimed}
            {a.events_primary > 0 && (
              <span className="type-caption">
                {" "}
                ({a.events_primary} primary)
              </span>
            )}
          </dd>
        </div>
        <div>
          <dt>Rated mostly or fully</dt>
          <dd>
            {spread.rated === 0
              ? "None rated yet"
              : `${spread.mostlyOrMore} of ${spread.rated}`}
          </dd>
        </div>
        <div>
          <dt>Members growing in it</dt>
          <dd>{a.members_growing}</dd>
        </div>
        <div>
          <dt>Teams that talked it through</dt>
          <dd>{a.teams_talked}</dd>
        </div>
        {markers(area, s).map(([label, value]) => (
          <div key={label}>
            <dt>{label}</dt>
            <dd>{value}</dd>
          </div>
        ))}
      </dl>
    </section>
  );
}
