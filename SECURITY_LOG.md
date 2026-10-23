# G-Squad Planner: database security review

- **Date:** 23 Oct 2026
- **Reviewer:** Independent AI security review agent
- **Result:** 19 findings fixed in SQL, plus residual risks listed below. 139 of 139 automated checks pass.

## Scope

Files reviewed (all of them, line by line):

- `supabase/migrations/20261023000100_foundation.sql` to `20261023000900_jobs_and_rights.sql` (9 migrations)
- `supabase/seed/seed.sql`
- `supabase/tests/00_supabase_shim.sql` (test-only Supabase stand-in)
- `supabase/tests/10_access_and_rules.sql`, `run_tests.sh`, `run_local.sh`

Added: `supabase/migrations/20261023001000_security_review_fixes.sql`. Every change in an earlier file is marked `SECURITY REVIEW FIX Fnn` in an inline comment.

All testing used a local Postgres 16 database. Nothing connected to a real Supabase project.

## Findings

| ID | Severity | Finding | Fix or decision | File |
|----|----------|---------|-----------------|------|
| F01 | High | The Operations Lead could grant themselves (or change any role row to) Resident Pastor, G-Squad Coordinator, TECi Coordinator or Pastoral Lead, and then read faith fields, pastoral notes and one-to-ones. Any role-writer could also give themselves Unit Lead, Purpose Head or Finance. | New trigger `app.role_assignment_guard`. Nobody can change their own role assignments. Only the Resident Pastor can grant, change or remove the four faith/pastoral roles. Purpose Head is added to that list while Purpose Heads may read pastoral notes. The Resident Pastor can now write role assignments. Bootstrapping still works through the service role or SQL editor. | 0700, 1000 |
| F02 | High | The Operations Lead could switch on `purpose_heads_read_pastoral`, which widens who can read pastoral notes. | Only the Resident Pastor may change that setting, and the Resident Pastor may change only that setting. Enforced by the settings policy plus the new trigger `app.church_settings_guard`. | 0700, 1000 |
| F03 | Medium | `get_person_faith` and `get_pastoral_notes` were STABLE. PostgREST runs STABLE functions in a read-only transaction, so the audit insert would fail and the feature would break on Supabase. The local tests could not show this. | Marked VOLATILE, so the audited read works over the API. | 0600 |
| F04 | High | The audit log leaked special category data to the Operations Lead. For faith updates it recorded the changed column names, so `water_baptism_date` changing showed that someone had been baptised. It also showed `view_pastoral` and `pastoral_notes` entries, which reveal who receives pastoral care. | No column names are logged for `person_faith`, `pastoral_notes` or `one_to_ones`. The Operations Lead can no longer see audit rows for those tables or `view_faith`/`view_pastoral` actions. The Resident Pastor sees everything. | 0100, 0700 |
| F05 | High | A Unit Lead could add any person id to their unit. Person ids are visible church-wide in `app_users`, event plans, grids and support roles. Doing this gave the lead that person's contact details and faith fields. | A Unit Lead may add only a person they entered themselves. Adding an existing member of another unit goes through the Operations Lead. | 0700 |
| F06 | Medium | R18 could be bypassed. A named item without the person's agreement, added after the issue was submitted, was never checked again, so the issue could be approved and sent with it. | The agreement check now runs on every forward step: submit, coordinator approval, pastor approval and send. | 0800 |
| F07 | Medium | A membership still waiting for the Resident Pastor's approval (R3) already made that unit's lead "their" Unit Lead for faith fields. | Faith access needs an active membership. | 0300 |
| F08 | Medium | `app.is_system()` treated any caller without `auth.uid()` as a system change, and that includes `anon`. No anon route exists today, but any future slip in grants would have skipped every trigger guard. | `is_system()` is now also false when the request's role is `anon` or `authenticated`. `redeem_email_link` also checks it (see F13). | 0800 |
| F09 | Low | The `gsquad.anonymising` marker let any edit of a person through `people_guard`. PostgREST callers cannot set it, but the guard trusted it completely. | The marker is accepted only if the row comes out anonymised (status left, no email, area, birthday or anniversary). | 0800 |
| F10 | Low | Approval stamps could be forged. The project owner could rewrite `approved_by` when moving a project to in progress or done. The Operations Lead could write a grid's `approved_by` without approving it. The Resident Pastor could edit a grid while approving it. Each newsletter approver could pre-fill or overwrite the other approver's stamp. | Stamps are now kept or set only by the triggers. Approving a grid cannot change its content. | 0800 |
| F11 | Low | R16 could be bypassed. A project owner could mark a costed budget as "not needed" and skip Finance. | "Not needed" with an estimate above zero needs Finance or the Resident Pastor. | 0800 |
| F12 | Low | `log_export` stored free-text `p_scope` in the audit detail, so it could hold a name. | The scope must be a short code matching `^[a-z0-9_]{1,40}$`. | 0600 |
| F13 | Low | `redeem_email_link` relied only on EXECUTE grants and accepted any characters in the token. | It refuses any signed-in or anonymous API identity and rejects tokens that are not URL-safe. The length limit of 32 to 256 is kept. Only SHA-256 hashes are stored, and the lookup is an indexed hash match, so timing attacks are not practical. | 0600 |
| F14 | Medium | Anonymisation left `assignments.override_reason` in place. That free text can describe a person's circumstances. The subject access export also left out check-in flags and newsletter reactions. | Override reasons are wiped on anonymisation, and the export now includes flags and reactions. | 0900 |
| F15 | Low | Anyone could add action points to any project by naming themselves as the owner. | Only the project's manager can add or delete action points. The action owner can still update their own. | 0700 |
| F16 | Low | A one-to-one could be moved to another unit, which changes which Purpose Head can read it. | `unit_id` is now fixed by the `author_fixed` trigger. | 0800 |
| F17 | Low | Some inputs had no limits: `preferred_times` and `sub_points` arrays, `link_url` length and content, email length, the `labels` JSON and `unfilled_reminder_weeks`. | Added CHECK limits: at most 10 preferred times (500 characters in all), at most 20 sub-points (4,000 characters), https URLs up to 2,000 characters with no spaces, emails up to 254 characters, labels up to 4 KB, at most 10 reminder weeks. | 0100, 0300, 0400 |
| F18 | Medium | Revokes covered only objects that already existed. Any function added by a later migration would be executable by PUBLIC and anon by default. | Default privileges are revoked: PUBLIC loses EXECUTE on new functions, and anon gets no tables, sequences or functions in `public`. | 1000 |
| F19 | Info | Some lookups used by RLS, the logged reads and anonymisation had no index. | Indexes added on pastoral notes, flags, tokens, RSVPs and reactions (by person), projects by owner, one-to-ones by unit, assignments by project. | 1000 |

**Checked and found sound:**

- Every public table has RLS enabled, and anon has no table or function rights.
- Every policy checks the church first. Composite `(church_id, id)` foreign keys stop cross-church links.
- Faith fields, pastoral notes, tokens, RSVPs and reactions have no direct read path.
- All three views use `security_invoker`.
- Every SECURITY DEFINER function pins `search_path = ''` and schema-qualifies every name.
- Job functions are not callable by `authenticated`.
- Exports leave out faith fields for the Operations Lead.
- The one-to-one read rule matches the spec.

## Test results

`run_tests.sh`: **139 of 139 checks passed.** That is the 98 original checks, unchanged, plus 41 new checks in section 11 of the test file (F01 to F18).

## Not changed (decisions) and residual risks

1. **Operations Lead sock-puppet account (Medium).** The Operations Lead can still create an `app_users` row for a second sign-in they control and make it a Unit Lead. That account could then read that unit's faith fields. This cannot be fully blocked in SQL without taking away legitimate admin work. Mitigations:
   - Make sign-up invite-only.
   - Have the Resident Pastor review role changes in the audit log each month.
   - Consider requiring Resident Pastor approval for new Unit Lead grants.
2. **Event plans are readable church-wide (Medium).** This includes `safeguarding_notes` and `committee_members`. I left it as specified. Either narrow the read policy to the project's managers and approvers, or tell users never to put personal details in those fields.
3. **Free text that anonymisation cannot clean (Medium).** These fields may name people: newsletter items, event plan text, `project_inputs.body`, monthly report commentary and `service_segments.led_by_text`. Set a retention period for them (for example, purge newsletter items 12 months after sending) and cover it in the privacy notice. RSVPs and reactions stay linked to the anonymised person id for counts, which is acceptable.
4. **Leader accounts are not anonymised.** `app_users.display_name` is not touched when a person is anonymised. Handle leader off-boarding separately: deactivate the account, then delete the auth user.
5. **Operations Lead can deactivate the Resident Pastor's account.** This is an admin denial-of-service risk, but it is audited. Deleting the account is now blocked by F01.
6. **Small-number counts.** Baptism counts go to editors, Purpose Heads and the Operations Lead. That is acceptable for a public act such as baptism, but avoid month-by-month breakdowns for very small groups.
7. **Error messages.** The unique email index tells a Unit Lead that an email already exists in the church. This is low risk and left as is.

## Go-live recommendations (outside SQL)

- **Multi-factor authentication** for every leader account. Consider requiring `aal2` in the JWT, checked in `app.can_see_faith` and `app.can_see_pastoral`, before faith fields or pastoral notes can be read.
- **Supabase settings:**
  - Expose only the `public` schema. Never add `app`: its helpers are SECURITY DEFINER and executable by `authenticated`.
  - Turn off public sign-ups and use short JWT expiry.
  - Enforce SSL and keep the database password and `service_role` key secret, used only inside Edge Functions.
  - Run the Security Advisor and Performance Advisor.
  - Do not add `person_faith`, `pastoral_notes`, `one_to_ones`, `audit_log` or `email_link_tokens` to the `supabase_realtime` publication.
  - If pg_graphql is enabled, confirm it respects the same grants or disable it.
  - Enable pg_cron (in the `extensions`/`cron` schema), confirm the three jobs run, and watch `cron.job_run_details`.
- **Edge Function token handling:**
  - Generate tokens with at least 256 bits from a cryptographic random source, base64url-encoded, and store only the SHA-256 hash.
  - Never log raw tokens or full URLs.
  - Rate-limit by IP address.
  - Show a confirm page that needs a click (a POST) before RSVP or unsubscribe takes effect, because email link scanners open links automatically.
  - Set `Referrer-Policy: no-referrer`.
  - Keep expiry short for RSVP and reaction links. Keep unsubscribe links working long enough to meet PECR.
- **Data protection:**
  - Complete a DPIA before launch, because this is special category data (religious belief) under UK GDPR Article 9. The likely conditions are 9(2)(d), not-for-profit religious body, and explicit consent.
  - Update the privacy notice and the record of processing activities.
  - Put a data processing agreement in place with Supabase and choose a UK or EU region.
  - Set retention for pastoral notes and one-to-ones. They are currently kept until the person is anonymised.
  - Point-in-time backups also hold faith data: document their retention.
  - Keep Postgres statement logging off, so parameters such as faith dates or tokens are not written to logs.
- **Process:** each quarter, the Resident Pastor reviews role assignments and the faith and pastoral view log.

---

## Review 2: Core values (ASHLIE), 23 Oct 2026

- **Reviewer:** Independent AI security review agent (did not write the code under review)
- **Result:** 5 findings fixed in SQL (G01 to G05), 6 decisions or residual risks recorded. 185 of 185 automated checks pass.

### Scope

Only the new and changed code:

- `supabase/migrations/20261023001100_ashlie_values.sql` (new): `core_values`, the value columns on `one_to_ones`, `recognitions`, `app.can_recognise`, `app.can_read_recognition`, `app.recognition_guard`, `app.one_to_one_values_guard`, `public.newsletter_recognitions`, `public.values_in_action_counts`, and the re-created `app.anonymise` and `public.export_person`.
- `supabase/seed/seed.sql` (core values seed).
- `supabase/tests/10_access_and_rules.sql`, section "11. Core values (ASHLIE)".

All fixes are in the new migration, marked `SECURITY REVIEW FIX Gnn`. No earlier migration was changed. Testing used the local Postgres 16 database only.

### Findings

| ID | Severity | Finding | Fix or decision | File |
|----|----------|---------|-----------------|------|
| G01 | Medium | Agreement to share (R19) could not be withdrawn in practice. Only the author could edit a recognition, and only while they could still recognise in that unit. Once the author changed role, or the member left the unit, nobody could untick sharing short of deleting the record. The recognition stayed in the newsletter feed. Consent must be as easy to withdraw as to give. | New `public.withdraw_recognition_sharing(id)`. Anyone who may read the recognition can call it: the author (even after losing the role), the unit's lead and Purpose Head, and the church-wide leaders. It can only switch sharing off: both offers and the agreement tick. Editors and other units cannot call it. | 1100 |
| G02 | Low | A leader who also serves in a unit could recognise themselves, tick their own agreement and put themselves in the newsletter. | Recognising your own linked person record is refused. | 1100 |
| G03 | Low | A recognition could be tagged with a retired core value. One-to-ones already refused this. Such recognitions also dropped silently out of `values_in_action_counts`, which lists active values only. | A current value is required on insert and when the value changes. | 1100 |
| G04 | Low | Changes to recognitions, including the agreement tick, were not audited. There was no record of who said the member agreed, or when. | `recognitions_audit` trigger (the generic `app.audit_row_change`). It logs the action and changed column names only, never the description. Those column names are not special category data, and the Operations Lead can already read the table, so these rows stay visible to them. | 1100 |
| G05 | Info | `authenticated` had table-wide UPDATE (from the default privileges), so authors could rewrite `created_at`. Person, unit, author and church were held only by the trigger. | Table-level UPDATE revoked. UPDATE is granted only on `value_id`, `description`, `recognised_on`, `offered_to_newsletter`, `offered_to_meeting` and `person_agreed`. The trigger stays as a second guard. | 1100 |

**Checked and found sound:**

- **Both new tables:** RLS is on and anon has no rights. Every policy checks the church first. Composite `(church_id, …)` foreign keys stop cross-church person, unit, value and author links.
- **Insert:** the policy needs the caller's unit role and an active membership (not pending, not ended). A Unit Lead cannot recognise in, or read, another unit. Errors look the same for "not a member" and "not your unit", so they cannot be used to probe who is a member.
- **Author:** `recognised_by` cannot be forged. The BEFORE trigger overwrites it with the caller, and the policy check runs after the trigger. The author cannot be changed afterwards.
- **Core values:** writable only by the Resident Pastor, and audited (column names only).
- **SECURITY DEFINER functions:** all pin `search_path = ''` and schema-qualify every name. Role checks come first.
- **Newsletter feed:** `newsletter_recognitions` returns only recognitions that are offered and agreed, for active, non-anonymised people. It shows first name and surname initial, never the author.
- **EXECUTE grants:** none for PUBLIC or anon. Trigger functions are not granted to `authenticated`. The new public RPCs are role-checked.
- **One-to-ones:** the new columns on `one_to_ones` add no new read path. `one_to_ones` has no audit trigger, and it stays excluded from column-name logging (F04). `author_fixed` and F16 still apply. The column-limited trigger `one_to_one_values_guard` checks only the value ids.
- **Re-created functions:** `app.anonymise` and `public.export_person` match migration 9 line for line, plus the recognitions lines. That keeps F09 (the anonymising marker), F14 (override reasons wiped, flags and reactions exported), and the Resident-Pastor-only one-to-ones and pastoral notes in the export. `create or replace` kept the existing grants: `app.anonymise` is still not callable by `authenticated`.

### Decisions (not changed)

1. **Counts and small groups (R20).** A Unit Lead or Purpose Head can ask for counts over a single day, or for a one-person unit, and so tie a count to a person. This adds nothing they cannot already see: the same leaders can read every recognition in their unit directly. The same holds for church-wide leaders. The function never returns per-person rows and never ranks, so R20 is met. If editors or wider audiences are ever given counts, set a minimum date range or suppress small numbers.
2. **Former authors.** An author who loses their unit role keeps read and delete rights on what they wrote, and (after G01) can withdraw sharing. They can no longer edit it. This mirrors one-to-ones and is acceptable: it is their own record, and deleting only reduces data.
3. **Authors who are later anonymised.** `recognised_by` points to the leader's `app_users` account, not to a people record. Anonymising that leader's people record leaves `app_users.display_name` in place. This is the same residual risk as risk 4 in Review 1, so handle leader off-boarding separately. The `on delete restrict` link from `recognised_by` also blocks deleting the account while recognitions remain, as for one-to-ones and pastoral notes. The newsletter feed never shows the author.
4. **Anonymisation deletes recognitions.** Value counts for past periods therefore fall when someone is anonymised. Erasure takes priority over historical counts.

### Test results

`run_tests.sh`: **185 of 185 checks passed.** That is the 168 earlier checks, unchanged, plus 17 new checks (G01 to G05) at the end of the ASHLIE section. They use a new fixture member, p4, because p1 to p3 have been anonymised by that point. Every new check failed before its fix was applied.

### Residual risks

1. **Agreement is the leader's word (Medium).** `person_agreed` is ticked by the leader. The member never confirms it in the system. Have leaders ask in writing (for example a message the member replies to), or later add a member-side confirmation through the email-link tokens.
2. **No retention period for recognitions (Medium).** Recognitions are free text about a person, kept until that person is anonymised. The church should set a period (for example 24 months after `recognised_on`) and add the purge to `app.housekeeping`. Cover it in the privacy notice and the DPIA.
3. **Free text can name other people (Low).** A description can mention a second person, and anonymising that second person does not clean it. This extends risk 3 from Review 1. Guide leaders to describe the act, not other people.
4. **Copies outside the table (Low).** Once an editor copies a recognition into a newsletter item, or it is read out at a meeting, withdrawing agreement (G01) or anonymising does not reach that copy. Editors should take recognitions from `newsletter_recognitions` close to sending.
5. Do not add `recognitions` to the `supabase_realtime` publication.

---

## Review 3: Recognition retention, 23 Oct 2026

- **Reviewer:** Independent AI security review agent (did not write the code under review)
- **Result:** 3 findings fixed in SQL (H01 to H03), 2 decisions recorded. 205 of 205 automated checks pass.

### Scope

Only the new code:

- `supabase/migrations/20261023001200_recognition_retention.sql` (new): `church_settings.recognition_retention_months` and the re-created `app.housekeeping()`.
- `supabase/tests/10_access_and_rules.sql`, section "12. Recognition retention".

Church decision under review: recognitions are kept 12 months from `recognised_on`, then deleted nightly. The leader's agreement tick remains the record of the member's agreement, so it is deleted with the recognition.

All fixes are in the new migration, marked `SECURITY REVIEW FIX Hnn`. No earlier migration was changed. Testing used the local Postgres 16 database only.

### Findings

| ID | Severity | Finding | Fix or decision | File |
|----|----------|---------|-----------------|------|
| H01 | Medium | Retention is keyed on `recognised_on`, which the author may edit. By moving it forward to today, an author could keep a recognition for ever, and put an old, already-agreed recognition back into the newsletter feed for last month. | New trigger `app.recognition_date_guard`: `recognised_on` may not be later than the day the recognition was written (`created_at`, which API users cannot change since G05). Correcting it to an earlier day still works. The future-date check in `recognition_guard` is unchanged. | 1200 |
| H02 | Low | The period allowed 1 to 120 months. A slip (1 for 12) would delete almost every recognition the next night and break the newsletter feed (previous month) and quarterly counts. 120 months would keep free text about members for 10 years, far beyond the church's decision. | Bounds changed to 6 to 36 months. The Operations Lead can already delete any recognition directly (`recognitions_delete`, audited per row), so a low value gives no new power; the floor guards against mistakes and keeps the features working. | 1200 |
| H03 | Low | The purge joined `church_settings`. No settings row is created automatically for a church, so a church without one would never have recognitions purged. | Falls back to the 12-month default when the row is missing. | 1200 |

**Checked and found sound:**

- **Housekeeping keeps every earlier statement.** The 2-year audit purge and the 7-day expired token purge match migration 9 exactly. No later migration (10 or 11) changed `housekeeping`.
- **Grants.** Only `service_role` and the owner (which pg_cron runs as) can execute it. `create or replace` kept migration 9's ACL, and the new file restates it. Migration 10's default privileges do not apply to a replaced function. The new trigger function has no API grants.
- **Who can change the period.** Only the Operations Lead: the `settings_update` policy admits the Operations Lead and Resident Pastor, and `app.church_settings_guard` limits the Resident Pastor to `purpose_heads_read_pastoral`. Unit Leads and other churches change nothing. Every change is logged by `church_settings_audit` with the actor and column name.
- **Audit interaction (G04).** Each deletion by the job writes a `delete` row with no actor and no text. The audit purge runs before the recognition purge, so these rows are kept their full 2 years. Earlier audit rows for a deleted recognition (column names such as `person_agreed`) outlive it by up to 12 months; they hold only the record id and no personal data.
- **Date maths.** `current_date` uses the session time zone. pg_cron and the service role use the database default (UTC on Supabase), and the 02:45 UTC run falls on the same calendar day in the UK, so the cut-off can move by one day at most. A recognition dated exactly 12 months ago is kept until the next night. Month ends clamp correctly (29 Feb minus 12 months is 28 Feb).
- **SECURITY DEFINER:** `search_path = ''` and schema-qualified names, as before.

### Decisions (not changed)

1. **Retention starts at the act of service, not the date written.** This is as the church decided. An author can back-date a new recognition so it is purged sooner. That only reduces data, so it is accepted.
2. **The agreement record goes with the recognition.** After deletion, nothing shows what the member agreed to. That is acceptable because the shared copy (newsletter or meeting) should be no older than the recognition. The audit log still shows who ticked agreement and when, for 2 years.

### Test results

`run_tests.sh`: **205 of 205 checks passed.** That is the 189 earlier checks, unchanged, plus 16 new checks in section 12 (H01 to H03, grants, who can change the period, the audit trail, and the 12-month boundary). With the migration as submitted, 4 of the new checks failed (H01, both H02 bounds, H03).

### Residual risks

1. **Copies outside the table (Low).** Purging does not reach newsletter items, meeting notes or exports that already hold the text (Review 2, risk 4).
2. **Same missing-settings gap in anonymisation (Low, outside scope).** `app.anonymise_expired_people` (R8) also joins `church_settings`, so a church without a settings row is never anonymised. Create the settings row whenever a church is created, or add the same fallback there.
3. **Backups.** Point-in-time backups keep deleted recognitions for the backup period. Cover this in the privacy notice and the DPIA, with the 12-month period.

## Review 4: Church settings row, 23 Oct 2026

- **Reviewer:** Independent AI security review agent (did not write the code under review)
- **Result:** 4 findings fixed (I01 to I04). 219 of 219 automated checks pass.

### Scope

The follow-up to Review 3, residual risk 2: `app.church_settings_default()` and its trigger `churches_settings_default`, the backfill and grants at the end of `20261023001200_recognition_retention.sql`; the seed's labels upsert; the test fixture change and the two new checks. Fixes are in the same migration (and one in the seed), marked `SECURITY REVIEW FIX Inn`. Local Postgres 16 only.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| I01 | Medium | The settings row could still be deleted (service role or SQL editor). Without it, R8 anonymisation skips the church's leavers, `v_engagement` and the automatic flags drop its people, and R3 (units before approval) and R14 (lead time) compare against NULL and let everything through (fail open). | New `BEFORE DELETE` trigger `app.church_settings_keep`: the row can only go when its church is deleted (cascade). Applies to every role, including the service role. | 1200 |
| I02 | Low | `app.anonymise_expired_people` still inner-joined `church_settings` (defence in depth, matching H03). | Re-created whole from migration 9 (no later change), with a left join and a 12-month fallback. Grants restated (service role and owner only). | 1200 |
| I03 | Low | The seed's upsert overwrote `labels` on every run, so re-running it would replace the church's own words. | The upsert now updates only while `labels` is still `{}`. | seed.sql |
| I04 | Low | Found while testing I01. Every church now has a settings row, so deleting a church always cascades to it. The settings `delete` audit row then referenced the church being deleted, so the `audit_log` foreign key refused the whole delete. No church could be removed. | `church_settings_audit` re-created for `insert or update` only. After I01 a settings row is only deleted with its church, and that church's audit rows are deleted too. | 1200 |

**Checked and found sound:**

- **`church_settings_default` (SECURITY DEFINER):** `search_path = ''`, schema-qualified names, and it inserts only `church_id = new.id` with every other column at its default. `on conflict do nothing` makes it idempotent. EXECUTE is revoked from API roles (triggers need no grant).
- **Who can fire it:** only whoever can insert into `public.churches`. `authenticated` has only `churches_read` (no insert policy), `anon` has no table rights, and no SECURITY DEFINER function inserts churches. So only the service role or the owner can fire it. A test confirms that a signed-in Operations Lead cannot create a church.
- **Interaction with `church_settings_guard`:** that guard is `before update` only, so the trigger's insert does not reach it. The seed's upsert update runs as a system change. **Audit:** the automatic insert is audited with no actor (tested). `church_settings` is excluded from the `church_id` default, which does not matter here because `church_id` is given explicitly.
- **Backfill** covers churches created before migration 12. A test confirms that every church has a row.

### Test results

`run_tests.sh`: **219 of 219 checks passed.** That is the 207 earlier checks plus 12 new ones under "Security review 4": audit of the automatic row, trigger-function grants, no church creation by signed-in users, settings deletion refused for the Operations Lead and the service role, church delete still cascades (I04), no orphan or missing settings rows, I02 anonymisation with a missing row (over and under 12 months), anonymisation grants, and the I03 seed re-run. The H03 setup now switches `church_settings_keep` off just to simulate a missing row. The H03 check itself is unchanged. One earlier check was renamed (not weakened): "deleting a church still removes its settings row" became "I01/I04: …".

### Residual risks

1. **The owner can still bypass this (accepted).** The database owner can disable the trigger or `TRUNCATE` the table. API roles have no `TRUNCATE` or `TRIGGER` rights.
2. **Other audited tables (Low).** Any other audited table that cascades from `churches` would block a church delete in the same way. Today they use `on delete restrict`, so all of a church's data has to be removed first anyway. Check this if church offboarding becomes a feature.
3. **The rules still fail open in principle.** R3, R14 and `personal_limit` still read the settings row without a fallback. I01 makes a missing row impossible outside owner action, so no change was made.

---

## Review 5: App set-up (slice 0), 23 Oct 2026

- **Reviewer:** Independent AI security review agent (did not write the code under review)
- **Result:** 7 findings fixed (J01 to J07). 28 of 28 unit tests and 219 of 219 database checks pass.

### Scope

The new app and tooling only. The migrations were not re-reviewed (Reviews 1 to 4).

- `src/`: the Supabase client, the settings guard `src/lib/env.ts`, invite-only sign-in `src/pages/SignIn.tsx`, the redirect guard `src/lib/paths.ts`, `AuthProvider`, `RequireAuth`, the `AppShell` link handling and the design-system loader (including `bundle.js`).
- `netlify.toml` (CSP, security headers, SPA redirect), `index.html`, `vite.config.ts`.
- `.github/workflows/ci.yml`, `.github/workflows/deploy-database.yml`, `.github/dependabot.yml`.
- `scripts/db-test.sh`, `scripts/db-types.sh`, `scripts/build-tokens.mjs`.
- `supabase/config.toml` auth settings, `.gitignore`, `.env.example`, `package.json` and the lockfile.

Every fix is marked `SECURITY REVIEW FIX Jnn` in an inline comment. New test file: `scripts/security-guards.test.ts`. Nothing connected to a real Supabase project.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| J01 | Medium | `parseEnv(import.meta.env)` passed the whole env object, so Vite inlined **every** `VITE_*` variable from the build environment into the public JavaScript, used or not. Confirmed with a test build: a dummy `VITE_LEAK_CANARY` appeared in the bundle. A secret key added to Netlify as any `VITE_*` variable would have been published. The secret-key check in `env.ts` runs in the browser, so it fired only after the key was public. | The client now reads the two variables by name. New `isSecretKey()` (also catches upper case). `vite.config.ts` runs it over every `VITE_*` variable and stops the build if one holds a secret or service-role key. A test fails if any file in `src/` uses `import.meta.env` as a whole object. | `src/lib/supabase.ts`, `src/lib/env.ts`, `vite.config.ts` |
| J02 | Medium | "Run workflow" on Deploy database lets anyone with write access choose any branch. That would push unreviewed migrations from an unmerged branch to the database, round branch protection and CI. | The job runs only when `github.ref` is `refs/heads/main`. The environment should also be limited to main (see actions). | `deploy-database.yml` |
| J03 | Medium | The Supabase access token and database password were job-wide, so every step saw them, including the third-party action `supabase/setup-cli@v1`. That is a movable tag: whoever controls it could read the secrets, or swap the CLI binary. | Secrets are now set only on the four CLI steps. The CLI comes from `package-lock.json` (exact version and integrity hash, and its binary is an npm package with no install script) through `npm ci --ignore-scripts`. The third-party action is gone. | `deploy-database.yml` |
| J04 | Low | Leader enumeration through the sign-in form. Supabase limits repeat links per address only for real accounts. Asking twice for one address showed "Something went wrong" (429) for an invited leader and "Check your email" for anyone else. | A 429 gets the same neutral message. The message now says to check spam and try again after a few minutes. Test added. | `src/pages/SignIn.tsx` |
| J05 | Info | `safePath` checked only the start of the path. Browsers strip tabs and newlines from URLs and read `\` as `/`, so `"/<tab>/evil.example"` would become `//evil.example`. Not exploitable today (`from` comes from router state the app sets, and the router refuses cross-origin pushes), but the guard should hold by itself. | Any backslash or control character now gives `/`. Tests added. | `src/lib/paths.ts` |
| J06 | Medium | The `db-test.sh` guard was a lower-case match on `supabase.co`. It let through upper-case host names, IP addresses, `?host=`/`?hostaddr=` parameters, and `PGHOST`/`PGHOSTADDR` in the environment. The script drops and creates a database and runs the auth shim, so it must never reach a hosted database. | The host must be in the URL and on an allow-list (`localhost`, `127.0.0.1`, `[::1]`, plus `DB_TEST_ALLOWED_HOSTS`). Host and service parameters are refused, and libpq's `PG*` host variables are cleared. A second check refuses any server with the `supabase_admin` role, which catches a tunnel to a hosted database. 15 tests use a fake `psql`, so they never connect. `db-types.sh` runs this script first, so it is covered too. | `scripts/db-test.sh` |
| J07 | Low | Supply chain. CI audited only production dependencies, but Vite, its plugins and the Supabase CLI build or deploy what ships. Dependabot proposed new releases at once, the window in which hijacked npm releases usually do their damage. | CI also runs `npm audit --audit-level=critical` over all dependencies. Dependabot waits 7 days (`cooldown`) before proposing a release. Security updates are not delayed. | `ci.yml`, `dependabot.yml` |

### Checked and found sound

- **No secrets in the repo or bundle.** Only the project URL and publishable key are used. `.env` and `.env.*` are git-ignored except `.env.example`, which holds no key. The build has no source maps. Staged files hold no JWTs, `sb_secret_` keys or passwords.
- **PKCE sign-in.** `flowType: 'pkce'`. supabase-js refuses tokens in a URL fragment when PKCE is set, so an attacker cannot sign a victim into the attacker's account with a crafted link. The code is useless without the verifier stored in the same browser, and it is removed from the address bar after exchange. `shouldCreateUser: false`, and the "not invited" reply (422) shows the same message as success.
- **Redirects.** `RequireAuth` stores only `location.pathname`. `AppShell` routes same-origin links only, by path, and leaves other links to the browser. `emailRedirectTo` is the app's own origin.
- **CSP works with the build.** Checked `dist/` after `npm run build`: one external module script, one stylesheet, fonts and the logo under `/assets`. No inline scripts, no `data:` fonts, no third-party hosts. The design-system bundle makes no network calls and uses no `eval` or `innerHTML`. `'unsafe-inline'` covers style attributes only.
- **Headers.** `frame-ancestors 'none'` and `X-Frame-Options: DENY` (clickjacking), `object-src 'none'`, `base-uri 'self'`, `form-action 'self'`, HSTS, `nosniff`, a referrer policy that sends only the origin to other sites, a Permissions-Policy and COOP. `noindex` in both a header and a meta tag.
- **CI.** Uses `pull_request`, never `pull_request_target`. `contents: read` only. `persist-credentials: false`. No `${{ }}` inside `run:` scripts (no script injection). CI holds no secrets, so fork pull requests get nothing. The test database is a throwaway service container.
- **Scripts.** `build-tokens.mjs` reads and writes fixed paths only. `db-types.sh` builds the database through `db-test.sh` (guarded) and writes the types through a temporary file.
- **Local auth config** (`supabase/config.toml`, local stack only): sign-ups and anonymous sign-ins off, refresh-token rotation on, 1-hour JWT, `double_confirm_changes` and `secure_password_change` on.
- **Dependencies.** `npm audit`: 0 vulnerabilities. No package in the lockfile has an install script.

### Test results

- `npm run check`: lint clean, **28 of 28 unit tests pass** (10 earlier, unchanged, plus 18 new: J01 ×3, J04 ×1, J05 in the `safePath` test, J06 ×15), build succeeds.
- A test build with an extra `VITE_LEAK_CANARY` no longer contains it. A build with `VITE_OOPS=sb_secret_…` stops with an error.
- `scripts/db-test.sh` against local Postgres: **219 of 219 checks passed**.

### Residual risks and actions for TEC

1. **Supabase Auth settings (dashboard, before go-live).** `config.toml` covers only the local stack. On the hosted project:
   - Turn off sign-ups and anonymous sign-ins. Invite leaders from the dashboard or an Edge Function.
   - Site URL: the production address. Redirect URLs: exact production addresses only. **No wildcards**, especially for Netlify deploy previews. If an attacker's preview address were allowed, they could start a sign-in for a leader's email with their own PKCE verifier, and the leader's click would hand them a session.
   - In Netlify, switch off deploy previews for pull requests from forks, or point previews at a separate test project.
   - Set a per-address email frequency of at least 60 seconds, a short email link expiry (for example 15 minutes, then update the sign-in message), and custom SMTP.
   - Turn on CAPTCHA (Cloudflare Turnstile or hCaptcha) for auth. The Supabase endpoint itself still says whether an address is invited (422 against 200), whatever the app shows, so J04 only fixes the app. CAPTCHA and rate limits are the real control. Adding CAPTCHA needs the provider's hosts in `script-src`, `frame-src` and `connect-src`.
   - Plan TOTP MFA for leaders who can see faith fields or pastoral notes (Review 1).
2. **Email link scanners.** Some mail systems (for example Microsoft Safe Links) open links on arrival, which uses up the one-time link. If leaders report dead links, offer the 6-digit code as well.
3. **Session in localStorage.** Any script injection could read the session. The strict CSP is the main control: keep third-party scripts out. Consider an idle sign-out and "sign out everywhere" for shared church computers.
4. **GitHub settings (needs a human).**
   - Protect `main`: pull request with review, required checks `app` and `database`, no force pushes, no deletion.
   - Environment `supabase-test`: deployment branches "main" only (J02), and a required reviewer.
   - Actions: read-only default `GITHUB_TOKEN`, and approval for workflows from fork contributors.
   - **Pin actions to commit SHAs.** `actions/checkout@v4` and `actions/setup-node@v4` are still tags. The GitHub API for other repositories is blocked here, so the SHAs could not be looked up. Replace each with `owner/action@<full SHA> # v4.x.y`. Dependabot keeps pinned SHAs up to date.
5. **Supabase access token.** `SUPABASE_ACCESS_TOKEN` is a personal token with access to every project of that account. Use an account that only holds the G-Squad project, set an expiry, and rotate it when people change roles.
6. **CSP and the live project.** `connect-src` names the test project. When the live project is added, add only its URL. Consider Trusted Types later.
7. **Netlify environment.** Only `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`. J01 now stops a build that holds a secret-looking value, but no other secrets belong in Netlify at all.
