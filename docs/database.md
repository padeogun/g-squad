# G-Squad Planner: database schema

The Postgres schema for the G-Squad and Event Planning app, written as Supabase migrations. It follows the App Specification (22 Oct 2026): the three sections (People and Teams, Planning Framework, Projects), the 11 forms, the newsletter, and business rules R1 to R18.

Access is enforced in the database with row-level security (RLS), not only by hiding parts of the screen.

## What's in the folder

| Path | What it is |
| --- | --- |
| `supabase/migrations/` | Nine migrations (plus any security-review fixes), applied in filename order |
| `supabase/seed/seed.sql` | TEC Manchester's starting reference lists (see below) |
| `supabase/tests/00_supabase_shim.sql` | **Local testing only.** A stand-in for Supabase's auth schema and API roles |
| `supabase/tests/10_access_and_rules.sql` | Automated checks of access rules and business rules |
| `run_local.sh`, `run_tests.sh` | Rebuild a throwaway local database and run the checks |
| `SECURITY_LOG.md` | The independent security review and the changes it made |

The seed sets up:
- the church, its site and its settings
- 5 TECi stages, as placeholders for the TECi Coordinator to name
- 4 leadership stages
- 7 Greatness Community types
- 9 project and event types
- the two reusable grid blocks

Units, purposes and people come from importing the G-Squad 2027 Volunteer Model spreadsheet.

## The migrations

| # | Migration | Main tables |
| --- | --- | --- |
| 1 | Foundation | `churches`, `sites`, `church_settings` (every rule threshold), `app_users`, `purposes`, `units`, `role_assignments`, `audit_log`; RLS helper functions in the private `app` schema |
| 2 | Reference forms | `church_roles` (Roles form), `teci_stages`, `leadership_stages`, `community_types`, `greatness_communities`, `project_types`, `reusable_blocks` |
| 3 | People and Teams | `people` (member entry form), `person_faith` (restricted), `unit_memberships` (team role, team leader, leadership stage), `holidays`, `community_support_roles`, `checkin_flags`, `pastoral_notes` (restricted), `one_to_ones` |
| 4 | Projects | `projects`, `team_demand`, `assignments`, `project_inputs` (input tracker), `event_plans` (High-level Event Planning form, sections 1 to 12), `event_plan_actions`, `service_grids`, `service_segments`, `service_grid_blocks` |
| 5 | Reports and newsletter | `monthly_reports`, `newsletter_issues`, `newsletter_items`, `newsletter_rsvps`, `newsletter_reactions`, `email_link_tokens` |
| 6 | Views and read functions | `v_engagement`, `v_project_inputs` (shows Overdue), `v_service_segments` (works out end times), plus the logged reads and count functions listed below |
| 7 | Row-level security | Policies for every table, by church and role |
| 8 | Business rules | Triggers for R2, R3, R6, R9, R10, R11, R14 to R18, plus the column guards |
| 9 | Jobs and people's rights | Nightly check-in flags (R5), anonymisation after the retention period (R8), audit retention, export of everything held on a person, and anonymisation on request |
| 10 | Security review fixes | Role-grant and settings guards, default privileges, RLS indexes |
| 11 | Core values (ASHLIE) | `core_values` (seeded), one-to-one value fields, `recognitions` (Values in Action) with RLS; `newsletter_recognitions()`, `values_in_action_counts()`, `withdraw_recognition_sharing()`; values are never scored (R20) |
| 12 | Recognition retention | Recognitions deleted nightly after `recognition_retention_months` (12 by default, 6 to 36); every church gets a settings row automatically and it cannot be deleted while the church exists |
| 13–20 | Leaders, member rights, Coordinator access, Sunday operations, dashboards | See each file's header and `SECURITY_LOG.md` |
| 21 | Deputy role | Adds the `deputy_unit_lead` access role (on its own, because Postgres can't use a new enum value in the migration that adds it) |
| 22 | Team roles and TECi | Four default team roles per church (Team Lead, Deputy Team Lead, Welfare and Pastoral Coordinator, Member) that can't be renamed, switched off or deleted; `church_roles.permanence` (operational or project); one Team Lead per team; Deputy Team Lead view-only access without one-to-ones; G-Squad Coordinator and Operations Lead only for a Purpose Head or the Resident Pastor; TECi verification (`people.teci_verified_at/by`) and adding TECi graduates with no team |
| 23 | Bulk member upload | `import_members(rows, skip_existing)`: many members in one all-or-nothing call, each through `create_member`; the G-Squad Coordinator may now add members |

## Design choices worth knowing

- **Church separation is built into every link.** Every row carries `church_id`, and every child row points at its parent through `(church_id, id)`. A record therefore can't be linked to another church's record, even by an app bug. `church_id` fills in automatically from the signed-in user.
- **Faith fields and pastoral notes have no direct read access.** The app reads them through `get_person_faith()` and `get_pastoral_notes()`. Both check who is asking and write every view to the audit log.
- **Faith fields have no direct write access either.** The app writes them through `set_person_faith()`, and every write is also audited.
- **Some values are worked out rather than stored.** Engagement level, Overdue inputs, grid end times and spare capacity are calculated each time they're read, so they're never out of date.
- **People are anonymised, not deleted.** Serving history stays as anonymous counts. Faith fields, pastoral notes, one-to-ones and holidays are deleted.
- **Approvals are recorded automatically.** The app can't write `approved_by` or `approved_at` itself. Approving is a status change, and the database checks who is making it.
- **Who grants roles (from the security review).**
  - No one can change their own roles.
  - The Resident Pastor and the G-Squad Coordinator grant the senior roles: G-Squad Coordinator, TECi Coordinator, Pastoral Lead, and Purpose Head while Purpose Heads may read pastoral notes (migration 18). The Resident Pastor role itself is granted, removed and switched off by the Resident Pastor only.
  - The Resident Pastor or G-Squad Coordinator switches Purpose Heads reading pastoral notes on or off.
  - The G-Squad Coordinator has full access (migration 18): member records, faith fields, pastoral notes, check-in flags, reference forms, settings, senior roles and senior accounts. Member records are otherwise edited only by the person's Team Lead (migration 16).
  - What stays outside the Coordinator's access (security review 10): the Resident Pastor role and any account holding it; their own roles and account; the audit log (Resident Pastor, and the Operations Lead without sensitive entries); the ASHLIE core values (Resident Pastor); `export_person` and `anonymise_person`; sites and service grid blocks (Operations Lead).
  - The Operations Lead can't see audit entries about faith fields, pastoral notes or one-to-ones.
- **Team leadership (migration 22).** Each team has one Team Lead (`unit_lead`), and may have a Deputy Team Lead (`deputy_unit_lead`) who sees what the Team Lead sees, view-only, without one-to-ones. The team-role label "Team Lead" can be held by one member of a team at a time, and `unit_memberships.is_team_leader` follows it. The G-Squad Coordinator and Operations Lead functions are given only to someone holding Purpose Head or Resident Pastor, and that role can't be removed while they hold the function. Assignments made before migration 22 are not re-checked.
- **Adding members to a unit (from the security review).** A Unit Lead can add only people they entered themselves. Adding an existing member of another unit goes through the Operations Lead, so a lead can't reach someone's details just by adding them.
- **The system convention.** A change with no signed-in user (the service role, or a scheduled job) skips the role checks. Signed-out visitors (`anon`) have no access to anything, so they can't use this route.

## Functions the app calls (RPC)

| Function | Who | What |
| --- | --- | --- |
| `get_person_faith(person)` | Resident Pastor, G-Squad Coordinator, TECi Coordinator, the person's Team Lead and Deputy Team Lead | Faith fields; logged |
| `set_person_faith(...)` | G-Squad Coordinator, the person's Team Lead | Records faith fields; audited |
| `create_member(person, unit, ...)` | Team Lead (to their team), Operations Lead; with no unit, the TECi Coordinator or Operations Lead for a TECi graduate (stage required) | Adds a member in one step |
| `import_members(rows, skip_existing)` | G-Squad Coordinator, Operations Lead (any team); Team Lead (own team) | Up to 500 members; all or nothing, with failing rows listed; each added person audited (`import_member`) |
| `church_dashboard()` / `unit_dashboard(unit)` | Leadership group and Deputy Team Leads (not the TECi Coordinator) / the unit's Team Lead, Deputy, Purpose Head, Resident Pastor, Operations Lead, Coordinator | Counts; one-to-one figures only for those who may read them |
| `get_pastoral_notes(person)` | Pastoral Lead, Resident Pastor, G-Squad Coordinator (migration 18); a unit's Purpose Head while Purpose Heads may read pastoral notes | Notes; logged |
| `baptism_counts(month)` | Coordinator, Resident Pastor, TECi Coordinator, editors, Purpose Heads | Counts only |
| `monthly_report_figures(month)` | Coordinator and readers of the monthly report | Automatic report figures |
| `capacity_calendar(year)` | Leadership group, Deputy Team Leads, Operations Lead | Spare capacity per unit per month |
| `newsletter_celebrations(month)` | Editors, Coordinator, Resident Pastor, Operations Lead | Opted-in birthdays, anniversaries and new members; first name and surname initial only |
| `newsletter_recipient_count()` | Same | A count, never addresses |
| `newsletter_issue_stats(issue)` | Same | RSVP and reaction counts |
| `log_export(scope, rows)` | Anyone exporting | Logs an export |
| `export_person(person)` | Operations Lead, Resident Pastor | Everything held on a person (subject access request) |
| `anonymise_person(person)` | Operations Lead | Erasure on request |
| `redeem_email_link(token)` | **Service role only** (the email-link Edge Function) | RSVP, reaction or unsubscribe |

## Applying it to Supabase

1. Create a Supabase project in a UK or EU region. Use a separate project as the test copy.
2. Enable `pg_cron` under Database > Extensions. Migration 9 then schedules the nightly jobs.
3. Apply the migrations in order with the Supabase CLI (`supabase db push`) or the SQL editor. **Don't run `tests/00_supabase_shim.sql` on Supabase**, because Supabase already provides those parts.
4. Run `seed/seed.sql` once.
5. Create the first Operations Lead:
   - Add the user in Supabase Auth.
   - Insert their `app_users` and `role_assignments` rows from the SQL editor.
   - From then on, they add the other leaders in the app.
6. Run Supabase's Security Advisor and check it reports no warnings.

## Running the checks locally

You need Postgres 16 or later, running locally. Then run:

```
./run_tests.sh
```

It rebuilds a database called `gsquad_test`, applies the shim, the migrations and the seed, and runs every check. The last line reports how many checks passed.

## Still open in the spec

These affect the schema:

- **Who maintains the Greatness Community forms.** The Operations Lead and the G-Squad Coordinator can for now; narrow `community_*` policies once this is decided.
- **Whether Purpose Heads may read pastoral notes.** This is the `church_settings.purpose_heads_read_pastoral` setting, which is off by default.
- **The service lead for Sunday planning.** There is no role for this yet; the Operations Lead edits the grid.
- **Event size thresholds.** The workbook's "Small (>100)" is taken to mean under 100 people.
