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

## Design choices worth knowing

- **Church separation is built into every link.** Every row carries `church_id`, and every child row points at its parent through `(church_id, id)`. A record therefore can't be linked to another church's record, even by an app bug. `church_id` fills in automatically from the signed-in user.
- **Faith fields and pastoral notes have no direct read access.** The app reads them through `get_person_faith()` and `get_pastoral_notes()`. Both check who is asking and write every view to the audit log.
- **Faith fields have no direct write access either.** The app writes them through `set_person_faith()`, and every write is also audited.
- **Some values are worked out rather than stored.** Engagement level, Overdue inputs, grid end times and spare capacity are calculated each time they're read, so they're never out of date.
- **People are anonymised, not deleted.** Serving history stays as anonymous counts. Faith fields, pastoral notes, one-to-ones and holidays are deleted.
- **Approvals are recorded automatically.** The app can't write `approved_by` or `approved_at` itself. Approving is a status change, and the database checks who is making it.
- **Who grants roles (from the security review).**
  - No one can change their own roles.
  - Only the Resident Pastor grants Resident Pastor, G-Squad Coordinator, TECi Coordinator and Pastoral Lead. Purpose Head is added to that list when Purpose Heads may read pastoral notes.
  - Only the Resident Pastor can switch on Purpose Heads reading pastoral notes.
  - The Operations Lead can't see audit entries about faith fields, pastoral notes or one-to-ones.
- **Adding members to a unit (from the security review).** A Unit Lead can add only people they entered themselves. Adding an existing member of another unit goes through the Operations Lead, so a lead can't reach someone's details just by adding them.
- **The system convention.** A change with no signed-in user (the service role, or a scheduled job) skips the role checks. Signed-out visitors (`anon`) have no access to anything, so they can't use this route.

## Functions the app calls (RPC)

| Function | Who | What |
| --- | --- | --- |
| `get_person_faith(person)` | Resident Pastor, G-Squad Coordinator, TECi Coordinator, the person's Unit Lead | Faith fields; logged |
| `set_person_faith(...)` | Same | Records faith fields; audited |
| `get_pastoral_notes(person)` | Pastoral lead, Resident Pastor | Notes; logged |
| `baptism_counts(month)` | Coordinator, Resident Pastor, TECi Coordinator, editors, Purpose Heads | Counts only |
| `monthly_report_figures(month)` | Coordinator and readers of the monthly report | Automatic report figures |
| `capacity_calendar(year)` | Leadership group, Operations Lead | Spare capacity per unit per month |
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
