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

---

## Review 6: Leader invitations (slice 1a), 23 Oct 2026

Independent review of the slice 1a commit "invite leaders and manage roles". Every fix is marked `SECURITY REVIEW FIX Knn` in an inline comment.

### Scope

- Edge Function `supabase/functions/invite-leader/` (`index.ts`, `logic.ts`), its `verify_jwt` setting in `supabase/config.toml`, and its deploy step in `.github/workflows/deploy-database.yml`.
- Migration 13 (`20261023001300_coordinator_invites.sql`): the new `app_users` and `role_assignments` policies, `app.role_assignment_guard` and the new `app.app_user_guard`. Earlier migrations were read for context only (the helpers in migration 1, policies in migration 7, guards in migration 10).
- The app: `src/pages/admin/Leaders.tsx`, `src/auth/useMe.ts`, `src/lib/invite-landing.ts`, `src/app/AppShell.tsx`, `src/app/navigation.ts`, `src/data/*.ts`, `src/pages/SignIn.tsx`.
- The new database checks ("Slice 1 (migration 13)") and `src/lib/invite-logic.test.ts`.

Database fixes are in a new migration, `20261023001400_security_review_6.sql`. Nothing was connected to a real Supabase project.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| K01 | High | **The rollback could delete someone else's account.** Supabase re-sends an invitation to an address that was invited but has not accepted yet, and returns that *existing* user instead of an error. The function then tried to add the account row, which failed (the row already exists, or belongs to another church), and its "rollback" deleted that user with the secret key. Deleting the login also deleted their G-Squad account and roles, and no guard applies to the secret key. So inviting a pending leader's address a second time, by mistake or on purpose, wiped them out: a Coordinator could remove a pending Pastoral Lead the Resident Pastor had just invited, or a pending leader of another church on the same project. | The function notes when the request started. A user created before that (with 5 seconds' slack) is not new: the function stops with "already has an account or a pending invitation" and changes nothing. The rollback also checks that no account row exists that this request did not make (two invites of one address at the same moment) before deleting anything. Unit tests added. | `supabase/functions/invite-leader/index.ts`, `logic.ts` |
| K02 | Medium | **Switching an account back on was not protected.** Only switching off was. A switched-off account keeps its role rows, so switching it on gives those roles back. The Coordinator (or an Operations Lead) could switch on a former Resident Pastor, Pastoral Lead or Operations Lead whom the Resident Pastor had switched off, which in effect gives a senior role. | The account guard now treats switching on exactly like switching off: an account with a senior or Operations Lead role can be switched either way only by the Resident Pastor, and nobody switches their own account either way. 5 database checks added. | migration 14 |
| K03 | Low | The account guard's list of protected roles left out the Purpose Head while Purpose Heads may read pastoral notes, unlike the role guard (and the church's rule). The Coordinator could switch off or delete such a Purpose Head. | The guard adds Purpose Head to the protected roles while that church setting is on. 3 database checks added. | migration 14 |
| K04 | Low | Migration 13 gave the Coordinator and the Resident Pastor write access to `app_users`, including `person_id`, the link to their own G-Squad record. A leader could clear their own link and then recognise themselves, getting round the self-recognition check (G02). (The Operations Lead could already do this.) | Nobody can change the record linked to their own account; another admin sets it. Renaming your own account still works. 3 database checks added. | migration 14 |
| K05 | Low | When the roles could not be saved, the function passed the raw database message back to the browser. That can name constraints, columns and internal details. | Only our own rule messages (codes 42501, P0001, 23514, never the generic row-level security message) are passed on. Anything else becomes "These roles could not be given". Unit test added. | `index.ts`, `logic.ts` |
| K06 | Low | The function read the whole request body before checking its size, and counted characters, not bytes. | It refuses a missing-or-wrong `Content-Length` over 4,000 bytes before reading, then checks the real size in bytes. Unit test added. | `index.ts`, `logic.ts` |
| K07 | Low | The built-in list of allowed web addresses included `http://localhost:5173` and `http://127.0.0.1:5173` in production. Those addresses could call the function and become the invite link's return address, so a live invitation could be sent pointing at a local address. | The built-in list is the live app only. The local addresses are added only when the function runs on a local Supabase stack. `ALLOWED_ORIGINS` still overrides both. Unit test added. | `index.ts`, `logic.ts` |
| K08 | Medium | **No limit on invitations.** A mistake, a script, or a stolen admin session could send invitation emails without limit. Supabase has one email allowance per project, so using it up would also stop every leader's sign-in links (sign-in is by emailed link only). | At most 20 new accounts per church per hour (setting `INVITES_PER_HOUR`, 1 to 200). This is checked as the caller, so row-level security limits the count to their own church, before any email is sent. Unit test added. | `index.ts`, `logic.ts` |

### Checked and found sound

- **Role escalation through role rows.** `app.role_assignment_guard` checks both the old and new row on UPDATE. So changing `role`, `user_id` or `is_active` counts as removing one role and giving another: a Unit Lead row cannot be turned into a senior or Operations Lead role, moved to yourself, or switched on as a senior role. `church_id` is pinned by the policy's `with check`. Checks added for each.
- **Cross-church ids.** `unit_id`, `purpose_id` and `user_id` have composite foreign keys with `church_id`, and `church_id` defaults to the caller's church. A role cannot point at another church's unit or purpose. Check added.
- **Deleting an account to get round the guards.** DELETE runs the account guard (protected accounts: Resident Pastor only; never your own). The cascade to `role_assignments` also runs the role guard for each row, so a senior or Operations Lead role is never removed by someone else this way.
- **Switched-off accounts lose access everywhere.** `app.current_church_id`, `has_role`, `has_any_role`, `is_unit_lead_of` and `is_purpose_head_of_unit` all require `app_users.is_active`. Every policy and logged function (`can_see_faith`, `can_see_pastoral`) needs the caller's church. So a switched-off leader with a valid token reads nothing, and the Edge Function sees no roles for them and refuses.
- **The Edge Function's database writes** use the caller's token, so row-level security and both guards decide, as in the app. The secret key sends the invite, makes one read for the rollback check, and deletes only a user this request created. It is read from the function's runtime settings and never logged or returned. Logs hold only an HTTP status, no email address. `verify_jwt = true` is set, and the function also checks the user with `getUser()`.
- **CORS and the return address.** The allowed origin is echoed only for listed addresses (`Vary: Origin`). An unknown or missing `Origin` is refused, and the return address is always one of the listed origins, so there is no open redirect. Supabase's own redirect allow-list is a second check.
- **Input.** Strict JSON, email shape and length, a name without control characters, 1 to 5 known roles, UUID-shaped scopes, and the right scope for each role. `checkGrants` refuses before any email is sent and is stricter than the database (it always treats Purpose Head as senior).
- **Account enumeration.** "Already has an account" is shown only to inviters, after their roles are checked. Accepted (see residual risks).
- **Invite landing.** Tokens in the address fragment are dropped before the Supabase client starts, without adding a history entry. With PKCE, supabase-js ignores fragment tokens anyway. Only a "welcome" flag goes in sessionStorage, never a token.
- **App.** Role-based menus and buttons are a courtesy only; the database decides. React escapes leader names. Error messages go through `friendlyError`. There is no `innerHTML` and no token in `localStorage` beyond Supabase's own session.
- **Deploy.** The function is deployed only from main, after the migrations, with the access token only (Review 5, J02 and J03, still hold).

### Test results

- `scripts/db-types.sh` (local Postgres 16): **257 of 257 checks passed** (241 before, plus 16 for K02, K03, K04 and role-row updates). `src/lib/database.types.ts` regenerated with no change, because migration 14 changes no table.
- `npm run check`: lint clean, **43 of 43 unit tests pass** (5 new, for K01 and K05 to K08), build succeeds.
- `index.ts` type-checks against supabase-js with a small Deno shim. Deno is not installed here, so the function was not run.

### Residual risks and actions for TEC

1. **A pending invitation still gets a fresh email.** Supabase re-sends before the function can tell the user already exists (K01). Nothing is changed or deleted, and Supabase's per-address email frequency limits repeats. Set that limit to at least 60 seconds on the hosted project.
2. **Hosted project settings.** Set the `ALLOWED_ORIGINS` function secret to the live address only, and `INVITES_PER_HOUR` if 20 does not suit. Use custom SMTP, so the email allowance is TEC's own and not Supabase's small shared one. Keep the Auth redirect allow-list to exact production addresses.
3. **Second accounts.** An inviter can invite a second email address they control and give it any role they may give (for example Finance, or Operations Lead for an Operations Lead). The rules allow this. The audit log records who added each account and role. **The Resident Pastor should review new accounts and roles in the audit log monthly.**
4. **Operations Lead against Operations Lead.** One Operations Lead may remove another's Operations Lead role (allowed by the rule) and then switch the account off, because it is no longer protected. If TEC wants only the Resident Pastor to remove an Operations Lead, change the role guard.
5. **Deleting accounts.** Inviters can delete (not only switch off) accounts that are not protected. Accounts that own projects, recognitions or unit memberships cannot be deleted (foreign keys), but the screen offers "Switch off" only. Consider removing DELETE from the `app_users_admin` policy, so audit history always keeps its account names.
6. **Linking a leader to their own G-Squad record** is now done by another admin (K04). An admin could still unlink a colleague so that the colleague could recognise themselves. That needs collusion, and it shows in the audit log.
7. **Sessions after switch-off.** A switched-off leader's token stays valid until it expires (1 hour), but it reads and changes nothing. To end it at once, sign the user out in the Supabase dashboard.

---

## Review 7: Reference forms, members and My Unit (slice 1b and 1c), 23 Oct 2026

Independent review of the three commits on `slice-1b-reference` that are not on `slice-1a-leaders` ("reference forms", "members, member entry form and My Unit", "link colour and chip spacing"). Every fix is marked `SECURITY REVIEW FIX Lnn` in an inline comment.

### Scope

- Reference forms: `src/data/forms.ts`, `src/data/forms.test.ts`, `src/pages/admin/ReferenceForms.tsx` and the generic engine `src/pages/admin/ReferenceForm.tsx`.
- Members: `src/data/people.ts`, `src/pages/people/Members.tsx`, `MemberForm.tsx` and `MyUnit.tsx`.
- Routing and menu (`src/app/router.tsx`, `src/app/navigation.ts`) and `src/design-system/app.css`.
- The database rules these screens rely on were read for context (migrations 3, 4, 6, 7, 8, 9 and 11: `people`, `unit_memberships`, `person_faith`, `app.can_read_person`, `app.can_edit_person`, `app.can_see_faith`, `app.people_guard`, `app.membership_guard`, `get_person_faith`, `set_person_faith`, `app.anonymise`).
- Every query the screens make was run against the local test database as the fixture leaders (Unit Lead, Operations Lead, TECi Coordinator, Resident Pastor, another church's Operations Lead).

The commits had no database changes. The fixes need one: a new migration, `20261023001500_security_review_7.sql`. Nothing was connected to a real Supabase project.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| L01 | Medium | **Adding a member never worked, and its design would leave orphaned personal data.** The form inserted the person with `insert(...).select('id')`. Postgres checks the read policy on the returned row, and `app.can_read_person` cannot see a row the same statement is inserting, so *every* add was refused, even for the Operations Lead (confirmed on the test database). If that were "fixed" the obvious way, the form still made three separate calls (person, then membership, then faith fields). A failure after the first left a person with no unit: the Unit Lead could still see the record (they created it) but could not add a unit to it or remove it, pressing "Add member" again made a second copy, and the nightly retention job never anonymises an active record. | New function `public.create_member()` adds the person, the membership and any faith fields in **one transaction**: all or nothing. It is `SECURITY INVOKER`, so it runs as the leader and row-level security, the TECi and R3 guards and `set_person_faith`'s own check all still apply. It makes the id itself (no `RETURNING`), takes only the member columns (any `id`, `church_id`, `created_by` or `anonymised_at` in the payload is ignored), lower-cases the email as the unique index does, drops an anniversary unless married, and keeps status and leaving date consistent. 14 database checks, plus a unit test that no screen inserts into `people` directly. | migration 15, `MemberForm.tsx`, `people.test.ts` |
| L02 | Medium | **An anonymised record could be filled in again.** `people_guard` stopped anyone *changing* `anonymised_at`, but not changing the other columns while it was set. The Operations Lead, or the Unit Lead who entered the person, could open `/members/<id>` (the form did not leave anonymised records out) and type the name and email back in, undoing R8 or an erasure request. An anonymised person could also be added to a unit again. | `people_guard` (re-created whole) refuses any API change to an anonymised record; a new trigger refuses a membership for an anonymised person. The system jobs are unaffected. The form shows "not found" for an anonymised record. 2 database checks. | migration 15, `MemberForm.tsx` |
| L03 | Medium | **A failed faith load showed the fields as empty and editable.** If `get_person_faith` failed for any reason other than "not allowed" (network, timeout), the panel showed blank fields. Ticking one box then saved blanks over the person's real record: special category data lost, and the change logged as if deliberate. | The fields are shown only after a successful load. A failed load shows an error in the panel and nothing can be saved for the faith fields. | `MemberForm.tsx` |
| L04 | Low | **Faith fields were fetched on every opening of a member record.** Each fetch is a logged view, so opening a record only to correct an email address put special category data on screen and an entry in the audit log, which then over-states real looks. The global "retry once" also applied, so a call whose first answer was lost could log twice. | Faith fields load only when the leader presses "Show faith journey". No automatic retry for this query. `staleTime: Infinity` and `gcTime: 0` were checked and do what the comment says: no background re-fetch, and the copy leaves the cache as soon as the form closes. Nothing is put in `localStorage`, `sessionStorage` or the address. | `MemberForm.tsx` |
| L05 | Low | For a new member, the faith panel was offered to anyone who leads *any* unit. An Operations Lead who also leads unit X, adding someone to unit Y, could fill in faith fields that the database would then refuse. (With L01 the refusal now undoes the whole save, so nothing leaks; before, the person was saved and the faith fields lost.) | For a new member the panel appears only when the chosen unit is one the leader leads (or for the faith-reading roles). | `MemberForm.tsx` |
| L06 | Low | An edit re-sent the whole member row. It overwrote changes other leaders had made meanwhile, and it made a faith-only change by the Resident Pastor fail (the Resident Pastor may read but not edit member records), so the faith fields were never saved. A duplicate email was reported as "That name is already in use". | An edit sends only the columns that changed, and skips the update when nothing changed. A duplicate on this form is reported as an email already recorded. Unit test added. | `MemberForm.tsx`, `people.ts` |
| L07 | Low | The member lists fetched `created_by` (a leader's account id) for every person. No screen used it. | Removed from the selected columns. | `people.ts` |
| L08 | Low | In the reference-form engine, if the row being edited disappeared from the list (removed by someone else), the edit panel opened empty and "Save" **inserted** a new row instead of updating. | The panel opens only for "add" or a row still in the list. | `ReferenceForm.tsx` |

### Checked and found sound

- **The generic reference-form engine cannot be pointed elsewhere.** `formId` from the address only selects one of the eight fixed entries in `forms.ts`; an unknown id shows "not found". The table name comes from that fixed list, never from the address. The add and edit payload is built only from the form's own fields (`toRow` loops over `def.fields`), so `id`, `church_id`, `created_by` and `is_active` are never in it; switch on/off sends only `is_active`, and remove deletes by id. Crafted values (for example a select value changed in the browser) still meet the database's checks, foreign keys and `*_write` policies. The test that `editRoles` matches each table's write policy still passes.
- **Writes are checked by the database, not the screen.** Every update uses `.select('id').single()`, so a change refused by row-level security shows an error instead of a silent "saved". Confirmed on the test database: a Unit Lead's update to another unit's membership changes 0 rows; a Unit Lead cannot set or change a TECi stage (on entry or later); another church's Operations Lead cannot add to this church's unit; a Unit Lead cannot see a member of another unit.
- **My Unit** changes only team role, leadership stage and leader flag, by membership id. `memberships_update` limits this to the unit's lead (or the Operations Lead and Resident Pastor), and `membership_guard` stops the person, unit or approval being changed.
- **Faith fields** are read and written only through `get_person_faith` and `set_person_faith` (a unit test now fails if any source file touches `person_faith`). "Restricted" (code 42501) hides the fields and saves nothing. A refused read is not logged (the function raises before logging). Faith data is not put in the address, browser storage or the console. The Operations Lead is never offered the panel.
- **Data minimisation.** Birthday and anniversary are day and month only; anniversary is cleared unless married (now also in `create_member`); area only, no address. Email is trimmed and lower-cased in both the form and the function, matching `people_email_unique (church_id, lower(email))`. Status and leaving date always agree with `left_consistent`.
- **No injection paths.** No `dangerouslySetInnerHTML` or `innerHTML`; links use ids only (`/members/<uuid>`); `window.confirm` shows a name as plain text; no data is turned into an `href`; no CSV export in this slice. Error messages go through `friendlyError`, which passes on only our own rule messages.
- **Other churches.** Every query relies on row-level security for the church (`app.current_church_id()`); no screen filters by church itself or assumes a single church.
- **Routing.** `/admin` and the reference forms are readable by every leader (as the read policies allow); editing is offered only to the owning role and enforced by the database.

### Test results

- `scripts/db-test.sh` (local Postgres 16): **275 of 275 checks passed** (257 before, plus 18 for L01, L02 and the My Unit and Members queries).
- `scripts/db-types.sh`: `src/lib/database.types.ts` regenerated (adds `create_member`).
- `npm run check`: lint clean, **60 of 60 unit tests pass** (4 new), build succeeds.

### Residual risks and actions for TEC

1. **Email addresses can be confirmed by guessing.** Because email is unique in the church, a Unit Lead who types an address already recorded for someone outside their unit is told it exists. This follows from the unique index. Accept it, or make the index apply only within a unit's members.
2. **A Unit Lead keeps sight of everyone they entered** (`created_by`), even after the person moves to another unit. This is migration 3's design (so a new entry is visible before it has a unit). Consider limiting it to people with no live membership.
3. **Faith panel on save.** After saving changes with the faith panel open, the fields load again, which logs one more view. Acceptable; it shows what was saved.
4. **Removing a leadership stage or team role** clears it from every membership (`on delete set null`) without warning. Not a data-protection issue, but the Operations Lead may prefer "switch off" for these lists too.
5. **The Resident Pastor can read but not edit member records** (`app.can_edit_person`). The form still shows the fields as editable; a save of member details is refused by the database. Decide whether the Resident Pastor should edit, and hide the fields if not.
6. **Sample data only** until the DPIA is signed (unchanged).

## Review 8: Member edit rights (decisions of 23 Oct 2026)

Independent review of the latest commit on `slice-1b-reference` ("Member edit rights: Team Lead and G-Squad Coordinator only; Unit Leads see current units only"). Every fix is marked `SECURITY REVIEW FIX Mnn` in an inline comment. Migration 16 had not been applied anywhere, so the database fixes are made in it directly.

### Scope

- `supabase/migrations/20261023001600_member_edit_rights.sql`: `app.can_edit_person`, the new `people_update` policy, `app.people_guard` (compared line by line with migration 15's version), `app.can_edit_faith`, `public.set_person_faith`, `app.can_read_person` (without `created_by`), `app.is_new_entry_of_caller` and the new `memberships_write` policy.
- The new checks in `supabase/tests/10_access_and_rules.sql` and `src/pages/people/MemberForm.tsx` (read-only view, TECi stage, faith panel).
- Every other place in migrations 1 to 15 that relies on `can_edit_person`, `can_read_person` or `created_by`: holidays, check-in flags, one-to-ones, recognitions, assignments, `export_person`, `anonymise` / `anonymise_person`, `redeem_email_link` (unsubscribe), `create_member`, `newsletter_celebrations`, the membership policies and `membership_guard`.
- Each attack below was tried on the local test database as the fixture leaders.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| M01 | Medium | **A Unit Lead could get a former member back by re-opening their old membership.** `memberships_update` lets a Unit Lead change any membership of their unit, including setting an *ended* one back to `active`. Confirmed: after Mo moved from Production to Ushering, Production's Unit Lead re-opened the ended row and at once saw Mo again, could edit the record and (the row being active) read and write Mo's faith fields. This undid Decision 2, and also side-stepped F05 (adding an existing member of another unit is for the Operations Lead). | A new trigger, `app.membership_reopen_guard`, treats re-opening as joining again: only the Operations Lead or the Resident Pastor may do it, and never for an anonymised person (as L02 does for adding). Ending a membership, and changing team role, leader flag or stage on a live one, are unchanged. `membership_guard` (R3) is left as it was. 5 database checks. | migration 16 |
| M02 | Low | **Faith fields could be written back onto an anonymised record.** `app.anonymise()` deletes the faith row but leaves memberships in place, and `people_guard` closes only the member columns. The G-Squad Coordinator (or a Team Lead of a still-active membership) could call `set_person_faith` on an anonymised person and record special category data on a record wiped under R8 or an erasure request. | `app.can_edit_faith` refuses anonymised records. `set_person_faith` tells the G-Squad Coordinator plainly that the record has been anonymised (checked only after the refusal, so it tells no one else whether an id is anonymised). 2 database checks. | migration 16 |
| M03 | Low | For a **new** member, the faith panel was offered to every faith-reading role, though only the G-Squad Coordinator and the chosen unit's lead may record. An Operations Lead who is also the TECi Coordinator saw an empty, locked panel. Nothing could be saved (the database refuses and `create_member` undoes the whole add). | For a new member the panel appears only to someone who may record the fields. | `MemberForm.tsx` |
| M04 | Low | The "Units" card on a member record showed an **ended** membership as "Awaiting approval", suggesting the person was still joining a unit they had left. With Decision 2 a leader needs to see clearly where someone is now. | Ended memberships are shown as "Ended". | `MemberForm.tsx` |

### Checked and found sound

- **`people_guard` lost nothing.** Compared with migration 15: the system bypass, the closed anonymised record (L02), unchangeable id, church and creator, the anonymising marker (F09) and "use `anonymise_person`" are all still there, in the same order. The only changes are the two intended ones: an existing TECi stage is changed by the TECi Coordinator alone (the Operations Lead may still set one when adding), and "TECi stage only" now applies to anyone who is not an editor of *this* person. `anonymise_person` (Operations Lead) still works, because the marker branch returns before the new checks; the unsubscribe link runs as the system and is not affected.
- **The TECi route lets no one else edit.** The `people_update` policy admits the TECi Coordinator for every row in the church, but `people_guard` then refuses any change other than the TECi stage from anyone who is not this person's editor. Checked with a TECi Coordinator who also leads another unit: refused. The TECi Coordinator is a church-wide reader, so they never update a row they cannot see; another church's rows are excluded by `church_id`.
- **`is_new_entry_of_caller` cannot be used to claim people.** It is true only for a person the caller entered **and** who has never had any membership. Memberships cannot be deleted (no delete policy; units are `on delete restrict`), so once someone has been in a unit, ended or not, they never count as new again; a person entered long ago and placed in a unit, then moved, cannot be re-added by the Unit Lead who entered them. One Unit Lead cannot claim another's unplaced entry. As a callable function it only answers about the caller's own entries.
- **F05 still holds:** a Unit Lead cannot add an existing member of another unit, even knowing their id (existing check), and now cannot re-open an old membership either (M01).
- **`create_member` and faith fields.** A brand-new person has no active memberships and the church setting `units_before_approval` is at least 1, so the new membership is always `active` and the Unit Lead's faith fields are accepted in the same transaction; the "pending approval" case cannot arise for a new entry. The Operations Lead is not offered faith fields; if sent anyway, the clear message "Only their Team Lead or the G-Squad Coordinator can record faith fields" is returned and the whole add is undone (new check).
- **Other users of the changed helpers.** Holidays (`can_edit_person`) are now recorded by the Team Lead and the G-Squad Coordinator only, matching the decision. Check-in flags follow `can_read_person`, so a Unit Lead can no longer raise a flag on someone who has left their unit. Assignments, one-to-ones and recognitions use unit leadership and memberships, not these helpers, and are unchanged. `export_person`, `anonymise_person` and `newsletter_celebrations` are role-based and unaffected. Faith reading (`can_see_faith`) is unchanged.
- **Front end.** The read-only view is display only; every refusal is still made by the database (the record fields sit in a disabled fieldset, the save button is hidden when nothing can be saved, and an edit sends only changed columns, so a TECi Coordinator's save sends the stage alone). The faith panel's "recorded by" rule matches `app.can_edit_faith`.

### Test results

- `scripts/db-test.sh` (local Postgres 16): **306 of 306 checks passed** (293 before, plus 13 for M01, M02, the TECi route with a second role, the Operations Lead's add with faith fields and `is_new_entry_of_caller`).
- `scripts/db-types.sh`: `src/lib/database.types.ts` regenerated; no change (the new functions are in the `app` schema).
- `npm run check`: lint clean, **60 of 60 unit tests pass**, build succeeds.

### Residual risks and actions for TEC

1. **Holidays.** The Operations Lead, Resident Pastor and TECi Coordinator can no longer record or remove a member's holiday; only the Team Lead and the G-Squad Coordinator can. Confirm this is intended, as holidays affect rotas the Operations Lead builds.
2. **Anonymised people keep their memberships.** `app.anonymise()` does not end them, so a Team Lead still sees "Former member" in their unit. Nothing personal remains and nothing can be changed, but consider ending the memberships when anonymising.
3. **Re-joining a unit now goes through the Operations Lead** (or the Resident Pastor). A Unit Lead who ends a membership by mistake must ask them to re-open it.
4. **A Unit Lead can still enter a person and leave them out of every unit** by inserting into `people` directly rather than through `create_member`. Such a record is then invisible to them; only church-wide readers see it. Consider a periodic report of members with no unit.
5. **Sample data only** until the DPIA is signed (unchanged).

## Review 9: Anonymised members leave their units, 23 Oct 2026

Independent review of the latest commit on `slice-1b-reference` ("Anonymised members leave their units (migration 17)"), which acts on residual risk 2 of review 8. Every fix is marked `SECURITY REVIEW FIX Nnn` in an inline comment. Migration 17 had not been applied anywhere, so the fix is made in it directly.

### Scope

- `supabase/migrations/20261023001700_anonymised_leave_units.sql`: `app.anonymise` (compared line by line with migration 11's version), its grants, and the backfill.
- The callers: `public.anonymise_person` (migration 9) and `app.anonymise_expired_people` (migration 12) with its pg_cron schedule.
- The triggers on `unit_memberships`: `app.membership_guard` (migration 8), `app.membership_not_anonymised` (migration 15) and `app.membership_reopen_guard` (migration 16), run from the RPC as a signed-in Operations Lead (not the system shortcut).
- Everything that reads memberships: `app.can_read_person`, the membership policies, `app.unit_capacity` / `capacity_calendar`, `v_engagement`, `app.raise_automatic_flags`, `export_person`, `useMemberships` in `src/data/people.ts`.
- The new "M17" checks in `supabase/tests/10_access_and_rules.sql`.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| N01 | Low | **The new checks did not exercise the real paths.** The M17 checks call `app.anonymise` as the database owner, where `app.is_system()` is true and every membership trigger returns at once. Neither the Operations Lead's erasure request (`anonymise_person`, where the triggers run in full), a pending membership, the nightly job, nor the function's grants were checked. (Read-through found no fault in those paths; the gap was in the evidence.) | 8 database checks: `app.anonymise` is not executable by `anon` or `authenticated` and the Operations Lead cannot call it directly; `anonymise_person` stays granted to signed-in users only; as the Operations Lead (`test.login('ops')`, `set role authenticated`) it ends an active and a pending membership and is logged; the Unit Lead then no longer sees the person at all; the nightly job ends a long-gone leaver's membership. | tests |
| N02 | Low | **Memberships were ended "today", not when the person left.** The nightly job anonymises people a year or more after `date_left`, and the backfill covers people anonymised in the past; both set `ended_on = current_date`, recording them as serving in the unit long after they had gone (UK GDPR accuracy). No count uses `ended_on` today, so no figure was wrong, but any future "unit history" or turnover report would be. | `ended_on` is the person's `date_left` (which `app.anonymise` sets just before, defaulting to today), kept on or after `joined_on`, in both the function and the backfill. 1 database check. | migration 17 |

### Checked and found sound

- **Nothing dropped from `app.anonymise`.** A diff against migration 11 shows the body identical apart from the new membership update: the anonymising marker on and off, every wiped column of `people`, the deletes of faith, pastoral notes, one-to-ones, recognitions, holidays, check-in flags and email tokens, the clearing of community support roles and `app_users.person_id`, and F14's wipe of override reasons. No migration between 11 and 17 re-created it. `security definer` and `search_path = ''` are kept.
- **Grants.** `create or replace` keeps the existing grants; migration 17 restates them as intended by migration 9: no `public`, `anon` or `authenticated`, `service_role` only. `anonymise_person` (Operations Lead, own church, logged as `anonymise_request`) and `anonymise_expired_people` (service role and pg_cron as owner, logged as `anonymise_retention`) still reach it as the function owner; both now checked.
- **Triggers on the update.** `membership_guard` (non-system path): person, unit and church are unchanged; `approved_by` is untouched; the pending-to-active and re-activation branches do not apply to `ended`; `ended_on` is set by the function. `membership_reopen_guard` only acts when an *ended* row is re-opened. `membership_not_anonymised` is `before insert` only. The update runs after `people` is anonymised, and none of the triggers objects to that. The backfill runs as the owner (system) and meets the `status`/`ended_on` check constraint.
- **Audit and history.** `unit_memberships` has no row-audit trigger; the single `anonymise_request` / `anonymise_retention` entry records the action, as before. Rows are ended, not deleted, so serving history (assignments) and the membership history stay as anonymous records; assignments still count for the Values and engagement figures as before.
- **Counts and views.** `unit_capacity` already counted only `active` memberships of `active` people, and an anonymised person is always `left`, so capacity is unchanged for every month. `v_engagement` does not read memberships (a `left` person was already "left"). The `many_units` flag counts `active` people only. `useMemberships` (team lists and My Unit) shows only live memberships, so "Former member" no longer appears, which is the purpose of the change.
- **Visibility narrows, as intended.** `app.can_read_person` gives a Unit Lead or Purpose Head sight of a person only through a live membership, so after anonymising they no longer read the Former member's row at all; church-wide readers still do. Pending requests of an anonymised person are ended too, so none is left for the Resident Pastor to approve (approving would also have been refused by L02/M01).

### Test results

- `scripts/db-test.sh` (local Postgres 16): **317 of 317 checks passed** (309 before, plus 8 for N01 and N02).
- `scripts/db-types.sh`: `src/lib/database.types.ts` regenerated; no change (only `app` functions and data changed).
- `npm run check`: lint clean, **60 of 60 unit tests pass**, build succeeds.

### Residual risks and actions for TEC

1. **Future rota slots are not cancelled.** An anonymised person's `planned` assignments stay on rotas as "Former member" (they existed before this change too). Consider cancelling future planned slots when anonymising, or showing them to the rota owner as gaps to fill.
2. **A Unit Lead loses sight of the person behind past slots** in their unit once the membership ends (as for anyone who leaves a unit under Decision 2); past assignments remain as anonymous counts.
3. **Sample data only** until the DPIA is signed (unchanged).

## Review 10: G-Squad Coordinator full access, 23 Oct 2026

Independent review of the latest commit on `slice-1b-reference` ("G-Squad Coordinator full access (migration 18)"), which carries out the church's decision of 23 Oct 2026. Every fix is marked `SECURITY REVIEW FIX Pnn` in an inline comment. Migration 18 had not been applied anywhere; it needed no change.

### Scope

- `supabase/migrations/20261023001800_coordinator_full_access.sql`, each re-created function compared line by line with its previous version: `app.can_see_pastoral` (migration 3), `app.church_settings_guard` (migration 10; no later migration re-created it, including 12, 13 and 14), `app.role_assignment_guard` (migration 13), `app.app_user_guard` (migration 14); and every replaced policy (`flags_close`, the seven reference form `*_write` policies, `settings_update`) against migration 7.
- The updated and new checks in `supabase/tests/10_access_and_rules.sql`; `src/data/forms.ts` with `forms.test.ts`; `grantableRoles` in `src/auth/useMe.ts`; `checkGrants` in `supabase/functions/invite-leader/logic.ts` with `src/lib/invite-logic.test.ts` and the function's `index.ts`; `docs/database.md`.
- Every other place that names pastoral readers or senior roles: `audit_read`, `export_person`, `anonymise_person`, `get_pastoral_notes`, `pastoral_insert`, `flag_guard`, `core_values_write`, `has_role` / `has_any_role`, the role-row foreign keys (cascades from `purposes` and `units`).
- Each escalation route below was tried on the local test database as the fixture Coordinator.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| P01 | Low | **The database guide was out of date and overstated the change.** The RPC table still listed only the Pastoral Lead and Resident Pastor for `get_pastoral_notes`, and "full access" did not say what the Coordinator still cannot do, which TEC needs to know to rely on the Resident Pastor's oversight. | RPC table corrected (Coordinator, and Purpose Heads while the setting is on). A new line lists what stays outside the Coordinator's access: the Resident Pastor role and account, their own roles and account, the audit log, the core values, `export_person` / `anonymise_person`, sites and service grid blocks. | `docs/database.md` |
| P02 | Low | The comment on `SENIOR_ROLES` in the invite function still said these roles are given by the Resident Pastor only; the code below it (correctly) lets the Coordinator give them. A misleading comment beside a security check invites a wrong "fix". | Comment corrected. | `invite-leader/logic.ts` |
| P03 | Low | **The safeguards were not checked against the realistic routes.** The commit checked direct grant/removal of the Resident Pastor role and switching off the Resident Pastor's account, but not the indirect routes, the limits that stay, the flags, or two Coordinators. It also removed several earlier Coordinator checks (correctly, as the decision changed them). Read-through and manual attempts found no fault; the gap was in the evidence. | 23 database checks: Coordinator cannot switch a former Resident Pastor's role row back on, switch on an account holding the Resident Pastor role, delete the Resident Pastor's account, move the Resident Pastor row to someone else, or turn another senior row into the Resident Pastor role; still reads no audit log, cannot change core values, cannot call `export_person` / `anonymise_person`; closes a flag (recorded as closer); adds a team role, leadership stage and reusable block; Operations Lead still cannot touch flags, TECi stages or a Coordinator's account; Pastoral Lead still closes flags; one Coordinator can switch another off but not the Resident Pastor, the switched-off Coordinator loses pastoral notes at once and cannot strike back, and the Resident Pastor puts it right. | tests |

### Checked and found sound

- **Nothing dropped from the re-created functions.** `can_see_pastoral` is identical to migration 3 apart from the added role (church check, Purpose Head route and its setting kept). `church_settings_guard` keeps the system bypass, the fixed church, the pastoral switch rule and the "other settings" rule, with the Coordinator added to both; the Resident Pastor can still change only the pastoral switch. `role_assignment_guard` keeps the system bypass, the Purpose Head-while-the-setting-is-on rule, "nobody changes their own roles" and the Operations Lead rule; the new Resident Pastor rule runs before the senior-role rule. `app_user_guard` keeps the fixed id and church, K04 (own G-Squad link), K02 (switching on is protected like switching off), K03 (Purpose Heads) and "not your own account". All keep `security definer`, `search_path = ''` and the service-role-only grants; the triggers from migrations 10 and 13 still call them.
- **No route to Resident Pastor power.** Insert, update (of `role`, `user_id`, `is_active` or any other column) and delete of a Resident Pastor role row are all refused unless the caller is the Resident Pastor, because the guard tests both `old.role` and `new.role` whatever the change. An account with an active Resident Pastor row cannot be switched off, switched on or deleted by anyone else; deleting the account is refused in the `before delete` trigger before any cascade reaches the role rows. Inviting with the role `resident_pastor` is refused by `checkGrants` and, since the function inserts roles with the caller's token, by the database too. Church settings hold only rule thresholds, labels and the pastoral switch; none weakens a role or account guard. `core_values_write` (migration 11) is untouched and Resident Pastor only. `audit_read` does not include the Coordinator, so the Coordinator cannot see or alter the record of their own pastoral reads; nobody can delete audit entries.
- **Cascades.** The Coordinator can now delete purposes and units, which cascades to Purpose Head and Unit Lead rows. The role guard runs on each cascaded row with the caller's identity, so a cascade cannot remove the caller's own role or any Resident Pastor row.
- **Lock-out.** Neither one Coordinator nor two acting together can switch off, delete or demote the Resident Pastor, so the Resident Pastor can always undo what a Coordinator did. Two Coordinators can switch each other off (accepted by the decision); a switched-off account loses every right at once because `has_role` requires an active account.
- **Other roles unchanged.** The Operations Lead still cannot give senior roles, switch off senior accounts, change the pastoral switch, read pastoral notes or close flags; the TECi Coordinator still keeps TECi stages; the Pastoral Lead still closes flags. Only the Coordinator was added to each list.
- **Pastoral readers consistent.** `get_pastoral_notes` and `pastoral_insert` both use `can_see_pastoral`; flags follow `flags_close`. `export_person` gives pastoral notes and one-to-ones to the Resident Pastor only and is not open to the Coordinator; `anonymise_person` stays with the Operations Lead. These were not part of the decision and are unchanged (see actions).
- **App matches the database.** `forms.test.ts` compares each form's `editRoles` with the last `*_write` policy in the migrations; all eight forms pass (community types and Greatness Communities already included the Coordinator). `grantableRoles` offers the Resident Pastor role to the Resident Pastor only, senior roles to the Resident Pastor or Coordinator, Operations Lead also to an Operations Lead.

### Test results

- `scripts/db-test.sh` (local Postgres 16): **357 of 357 checks passed** (334 before, plus 23 for P03).
- `scripts/db-types.sh`: `src/lib/database.types.ts` regenerated; no change.
- `npm run check`: lint clean, **60 of 60 unit tests pass**, build succeeds.

### Residual risks and actions for TEC

1. **Concentration of access in one role.** A single G-Squad Coordinator can now read every pastoral note and faith field, change every setting (including who reads pastoral notes and how soon leavers' records are wiped), and give, remove and switch off every senior role and account except the Resident Pastor's. A compromised or mistaken Coordinator account could do serious harm before anyone notices. Suggested mitigations:
   - **Monthly audit review by the Resident Pastor** of `view_pastoral`, `view_faith`, role-assignment, account and `church_settings` entries (only the Resident Pastor sees them all). Consider a simple "Coordinator activity" report for this.
   - Keep the number of Coordinators to one or two named people; require multi-factor sign-in for every senior account in Supabase Auth.
   - Record in the DPIA that the Coordinator role now reads special category and pastoral data church-wide.
2. **A Coordinator can create further Coordinators**, including a second account they control, and a switched-off Coordinator can be switched back on by any other Coordinator. So the Resident Pastor switching off one Coordinator is only lasting if every other Coordinator is trusted, and "nobody changes their own roles" can be side-stepped with a second account. If TEC wants a firmer backstop, decide that the G-Squad Coordinator role itself is given only by the Resident Pastor (one line in `role_assignment_guard`, `checkGrants` and `grantableRoles`).
3. **The Coordinator can remove the last Operations Lead** (and the last Pastoral Lead or TECi Coordinator). Accepted by the decision. Until the Resident Pastor appoints another, nobody can anonymise a person on request, keep sites or service grid blocks, or add members except Unit Leads. Consider a check before removing the last holder of a role.
4. **Retention can be shortened by the Coordinator.** `retention_months` (R8) may be set as low as 1, after which the nightly job irreversibly wipes leavers' faith fields and pastoral notes. This was already true for the Operations Lead. Consider a floor (say 6 months) or making this setting the Resident Pastor's.
5. **Not covered by "full access":** `export_person`, `anonymise_person`, sites and service grid blocks remain with the Operations Lead (and the Resident Pastor for export). Confirm this is intended.
6. **If the only Resident Pastor's account is lost**, only the service role (SQL editor) can appoint a new one. Unchanged; keep a written procedure.
7. **Sample data only** until the DPIA is signed (unchanged).

## Review 11: Sunday operations (slice 2), 23 Oct 2026

Independent review of the two commits on `slice-2-sundays` that are not on `main` ("Slice 2a: Sundays and the service grid", "Slice 2b: Sunday rota and phone check-in"). Every fix is marked `SECURITY REVIEW FIX Qnn` in an inline comment. Migration 19 had not been applied anywhere, so the database fixes went straight into it.

### Scope

- `supabase/migrations/20261023001900_sunday_operations.sql`: the one-grid-per-Sunday index, `create_sunday_service`, `rota_candidates`, the statement-level version triggers that replace migration 8's row-level ones, and `reorder_segments`; read against `grid_guard`, `assignment_guard`, `project_guard`, the helper functions and the projects, assignments and grid policies (migrations 1, 4, 6, 7, 8).
- `src/data/sundays.ts`, `src/data/rota.ts`, `src/lib/gridPdf.ts`, `src/pages/sunday/*`, the router and navigation, the new CSS, and the "S2:" database checks and unit tests.
- The new dependencies (`jspdf` 4.2.1, `jspdf-autotable` 5.0.9 and what they pull in): `npm audit`, licences, the built chunks, and `netlify.toml`'s Content Security Policy.
- Every R11 route was tried as the fixture Operations Lead, Resident Pastor, Coordinator and Unit Leads on the local test database: no-op saves, reorders, moving segments between grids, back to draft, deleting the Sunday's project, editing a reusable block.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| Q01 | Medium | **A segment could be taken out of an approved grid without re-approval.** The update trigger only looked at the rows' new grid, so changing a segment's (or block's) `grid_id` moved it to another grid and left the grid it came from "approved" with different content (also true of migration 8's trigger). | The update trigger now reads the rows before and after and gives a new version to both grids. | migration 19 |
| Q02 | Low | **Saving without changing anything sent an approved grid back for approval.** A statement-level update trigger fires for every row the statement touches, changed or not (as the old row trigger did). Safe direction, but it would make re-approval routine and so less meaningful. | Only rows that actually differ count (`except` in both directions). | migration 19 |
| Q03 | Medium | **Deleting the Sunday's project removed its approved grid and all its serving history.** `create_sunday_service` makes a project that stays `draft` for ever, and drafts may be deleted by their owner or the Operations Lead. The cascade deleted the approved grid (which `grids_delete` otherwise protects) and every slot, including who served and who didn't. | A `before delete` guard refuses deleting a finalised or approved grid, including by cascade. `projects_delete` now also requires that the project has no served or no-show slots (`app.project_has_history`); cancel it instead. | migration 19 |
| Q04 | Low | **One version number for two different grids.** Approved v3 → back to draft → edits → finalised came back as v3. The Resident Pastor could approve "v3" again, and PDFs named `…-v3.pdf` differed. | Leaving finalised/approved for draft raises the version. | migration 19 (`grid_guard`) |
| Q05 | Medium | **Editing a reusable block changed approved grids without re-approval.** Block text is printed in the grid PDF, and the Operations Lead and Coordinator can edit blocks. Separately, the version bump was refused unless the caller was the Operations Lead, so any other route that touched a finalised grid could only fail or skip re-approval. | Editing a block's name or text gives every coming finalised or approved grid it is attached to a new version needing approval. `grid_guard` allows exactly "new version, approval withdrawn, nothing else changed" for anyone who can reach it (it only ever removes approval); row-level security still limits direct grid updates to the Operations Lead and Resident Pastor. | migration 19 |
| Q06 | Low | `reorder_segments` "succeeded" for callers who may not edit segments: row-level security silently matched no rows. | Counts the rows that should move and refuses (42501) if any were blocked. | migration 19 |
| Q07 | Low | **Project dates were compared in UTC.** `assignment_guard` used `starts_at::date`, which is the UTC date on Supabase, so in summer anything starting before 01:00 UK time allowed the wrong serve day. Sundays at 10:00 were not affected. | Compared as `Europe/London` dates. | migration 19 (`assignment_guard`) |
| Q08 | Low | The "status-only change" shortcut in `assignment_guard` did not check the project, so a Unit Lead could move a live slot to another project (closed, cancelled or on other dates) with no checks. | The shortcut also requires the same project. | migration 19 (`assignment_guard`) |
| Q09 | Low | **Slots could be marked served months ahead**, inflating engagement (active/inactive) and the monthly report. The table says status is recorded after the day. | Served and no-show only on or after the serve date (UK date). The check-in tests now use the Sunday just gone. | migration 19 (`assignment_guard`), tests |
| Q10 | Low | **The rota and check-in loaded everyone's member records just to show names**: email, birthday, marital status and anniversaries of every person the leader can see (the whole church for the Operations Lead and Coordinator). | New `usePersonNames(ids)` fetches `id, first_name, surname` for the people on screen only. | `people.ts`, `Rota.tsx`, `CheckIn.tsx` |
| Q11 | Low | Ambiguous buttons: every segment's "Edit" and "Remove", each demand row's "Remove" and each rota cell's "+ Assign" read the same to a screen reader, so the wrong segment or unit could be removed. | Each now names its segment, unit and role, or slot and date. | `ServiceGrid.tsx`, `Rota.tsx` |
| Q12 | Low | **Failures looked like data.** If the rota's assignments or demand failed to load, slots showed as open (inviting double booking) or "no Sundays"; pressing Download PDF before the blocks loaded printed the grid without them (e.g. the Guest Welcome Script). | The rota shows the error. The PDF button waits for the blocks and refuses to print if an attached block is missing. | `Rota.tsx`, `ServiceGrid.tsx` |
| Q13 | Low | The Coordinator was offered Assign and Remove on every unit's rota, which the database always refuses. | Only the unit's lead and the Operations Lead see them; others see "Open". | `Rota.tsx` |
| Q14 | Low | **Yoruba names printed as junk in the PDF.** jsPDF's built-in Helvetica has only Windows-1252 characters. One character outside them (ọ, ẹ, ṣ, ń) switched the whole line to a two-byte encoding that printed as spaced-out garbage. jsPDF does escape brackets and backslashes, so there was no PDF injection. | `pdfSafe()` keeps what the font has, drops only accents it lacks (ọ́ → ó, ṣ → s) and turns anything else into "?". 3 unit tests. | `gridPdf.ts`, `gridPdf.test.ts` |

### Checked and found sound

- **`rota_candidates` (SECURITY DEFINER).** `search_path = ''`, every name schema-qualified, not open to `anon`. It refuses units outside the caller's church and anyone who is not the unit's lead, its Purpose Head, the Operations Lead or the Coordinator. It returns only first name, surname and role for the unit's own active, non-anonymised members, who are people those roles can already see. From other units it gives only counts (slots this month, a yes/no "serving that day") and never says which unit or project. This is the minimum the cross-unit limit (R1) needs; recorded as accepted. A holiday shows only as a yes/no flag.
- **`create_sunday_service` (SECURITY INVOKER).** It runs as the caller, so `projects_insert`, `grids_insert` (Operations Lead only) and the project and grid guards still apply. Another role's call fails at the grid insert and the whole call rolls back. Church scoping comes from the policies and the `(church_id, site_id)` foreign key. The duplicate check is backed by the unique index, so a race also fails. Times are converted from `Europe/London` correctly across clock changes (the 10:00 check passes).
- **`reorder_segments`** cannot touch another church's grid (no rows visible, so only an empty list passes). It requires every segment exactly once, skips unchanged positions, and raises the version once.
- **The statement-level triggers preserve R11** for insert, update and delete of segments and grid blocks. Copying segments from another Sunday is one insert, so one new version. The old row triggers are dropped and the old function `app.grid_content_changed()` is left unused but harmless. TRUNCATE is not granted to API roles (migration 7). A path other than the Operations Lead that changes segments (for example the `set null` when a person record is deleted) now gives a new version and needs re-approval instead of failing (Q05).
- **Check-in** can change only the caller's own unit's slots (`assignments_update`; the "S2" check). Marking someone no-show then back to planned or served, or re-planning a cancelled slot, takes the full path in `assignment_guard`, so membership, holidays and the monthly limit are checked again. Only planned or served to planned or served on the same date, unit and project skips the checks (Q08).
- **Dependencies.** `npm audit` reports 0 vulnerabilities. jspdf, jspdf-autotable, fflate, canvg, html2canvas and core-js are MIT, and dompurify is MPL-2.0/Apache-2.0, all compatible with the project. jsPDF and autotable are only in the dynamically imported PDF chunk, not the main bundle. The only `Function(...)` in the built output is core-js's fallback inside the canvg chunk, which loads only for SVG images (not used). So the CSP needs no `unsafe-eval`, and saving uses a blob link and download, which the CSP allows. No fonts are fetched.
- **Front-end dates.** "Today" and "the Sunday just gone" use the device's own date, and date-only values are formatted at noon UTC, so there is no off-by-one. The PDF file name is built from the grid's date and version number only.

### Test results

- `scripts/db-test.sh` (local Postgres 16): **403 of 403 checks passed** (380 before; 23 added or reworked for Q01 to Q09 and the check-in on a past Sunday). Each new check was confirmed to fail against the migration as committed.
- `scripts/db-types.sh`: `src/lib/database.types.ts` regenerated; no change.
- `npm run check`: lint clean, **73 of 73 unit tests pass** (3 new for Q14), build succeeds. The main chunk is still over Vite's 500 kB warning, which does not come from this slice.

### Residual risks and actions for TEC

1. **Sunday projects are never approved.** They stay `draft`, which is why Q03 needed guarding. Decide whether a Sunday's project should be marked approved automatically when its grid is approved, or have its own lifecycle.
2. **Moving a grid to another date** (header edit) does not move its project's dates or its team demand, so the rota can disagree with the grid. Consider making `service_date` fixed after set-up, or moving all three together.
3. **Past grids' PDFs** still print a reusable block's current text, not the text when the grid was approved, and past grids are not re-versioned (Q05 covers coming Sundays only). If an exact record of past services matters, store a snapshot of the PDF or block text on approval.
4. **Unit Leads and Purpose Heads see cross-unit counts** (slots this month, serving that day) for their own members through `rota_candidates`. Needed for R1; record it in the DPIA.
5. **PDF font:** Q14 makes names readable but drops Yoruba under-dots. Embedding a Unicode font (for example Noto Sans, served from the site so the CSP needs no change) would print them exactly.
6. **Sample data only** until the DPIA is signed (unchanged).

## Review 12 — Slice 3: dashboards and capacity calendar

Independent review of the latest commit on `slice-3-dashboards` ("Slice 3: dashboards and capacity calendar"). Every database fix is marked `SECURITY REVIEW 12 (Rnn)` in an inline comment, and front-end fixes name their finding. Migration 20 had not been applied anywhere, so the database fixes went straight into it.

### Scope

- `supabase/migrations/20261023002000_dashboards.sql`: `app.engagement_of`, `app.unit_open_slots`, `public.church_dashboard()` and `public.unit_dashboard(p_unit)`; read against the access helpers (`can_read_person` as last changed in migration 16, `can_read_one_to_one`, `is_unit_lead_of`, `is_purpose_head_of_unit`, `is_church_wide_reader`), `capacity_calendar`, `v_engagement`, and the people, memberships, holidays, check-in flags, one-to-ones, assignments, inputs and grid policies (migrations 1, 3, 4, 6, 7, 16, 18).
- `src/data/dashboards.ts`, `src/pages/dashboard/{ChurchDashboard,Capacity,EngagementBar}.tsx`, `src/pages/Home.tsx`, `src/pages/people/MyUnit.tsx`, the router and navigation, the new CSS, and the "S3:" database checks.
- Both dashboards were called as the fixture Resident Pastor, Operations Lead, Coordinator, Purpose Head, Unit Leads (including a second lead of the same unit), newsletter editor and the other church's Operations Lead on the local test database.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| R01 | High | **The dashboards told people about one-to-ones they may not read.** One-to-ones are read only by the writing Unit Lead, the unit's Purpose Head, the Coordinator and the Resident Pastor; the Operations Lead cannot read them (decision of 22 Oct 2026). `unit_dashboard` gave the Operations Lead each member's last one-to-one date and the unit's count this quarter, and gave a second lead of the same unit the dates of one-to-ones written by the other lead. `church_dashboard` gave every dashboard role (Unit Leads of other units, the Operations Lead, TECi Coordinator, pastoral lead) the count for every unit. | New helper `app.one_to_ones_seen(unit, quarter)` counts only one-to-ones the caller may read and returns null when they have no read right in that unit. `last_one_to_one` applies `app.can_read_one_to_one` to each row. `unit_dashboard` also returns `one_to_ones_visible`, so screens say "Not shown to your role" instead of a misleading 0. 7 checks. | migration 20, `dashboards.ts`, `ChurchDashboard.tsx`, `MyUnit.tsx` |
| R02 | Low | **The two new helpers bypassed row-level security for any id.** `app.engagement_of` and `app.unit_open_slots` were SECURITY DEFINER with no church check and executable by every signed-in user. The `app` schema is not exposed through the API, so the browser could not reach them, but anything later calling them in an invoker context (a view, a policy) would have leaked across churches. | Both are now SECURITY INVOKER and executable only by the owner and `service_role`; the dashboards, which run as the owner, still use them. 1 check. | migration 20 |
| R03 | Low | **The church dashboard's "Check-ins open" counted flags of people who had left or been anonymised**, unlike every other figure on the page. | Counts flags of current members only (the same `ppl` set). 1 check. | migration 20 |
| R04 | Low | **Controls the database refuses, and silent failures, on the Church Dashboard.** The TECi Coordinator and pastoral lead see the dashboard but not the capacity calendar, so the shortfalls card always called `capacity_calendar`, was refused and showed an empty card. Errors loading the outstanding inputs or the capacity figures were not shown at all, and the inputs list was fetched whether or not the dashboard was shown. | One shared `CAPACITY_ROLES` list (mirrors `capacity_calendar`) for the page, navigation and dashboard; the shortfalls card shows only for those roles. Both lists now show their error. The inputs query runs only for dashboard roles. | `dashboards.ts`, `ChurchDashboard.tsx`, `Capacity.tsx` |
| R05 | Low | **A failure looked like data on My Unit.** While the unit figures were loading, or if the call failed, every member's last one-to-one read "None yet", which a leader could take as "no one-to-one held". | Shows "–" until the database has answered; "None yet" only when it says so. A loading line and a titled error notice for the figures. The column is now "Your last one-to-one" and the one-to-ones tile appears only when the caller may read them (R01). | `MyUnit.tsx` |
| R06 | Low | Accessibility and loading: the capacity calendar's year buttons read as "‹ 2025" to a screen reader; Home and the capacity page showed the welcome page or "not for your role" while the leader's roles were still loading. | Year buttons are labelled "Show 2025" and so on. Both pages wait for the roles. | `Capacity.tsx`, `Home.tsx` |

### Checked and found sound

- **SECURITY DEFINER hygiene.** `church_dashboard` and `unit_dashboard` have `search_path = ''`, every name schema-qualified, execute revoked from `public` and `anon` (the existing "S3" check), and both refuse a caller with no active account (`current_church_id()` null).
- **Church isolation.** Every table read in both functions is filtered by the caller's church, directly or through the unit; another church's unit is refused (existing check). `capacity_calendar` is unchanged.
- **`unit_dashboard` audience** is exactly the unit's lead, its Purpose Head, the Resident Pastor, the Operations Lead and the Coordinator; a Unit Lead of another unit and a newsletter editor are refused.
- **Per-member figures stay within what the caller can already see.** The member list is the unit's live (not ended) memberships of current, non-anonymised people, the same set `can_read_person` gives a Unit Lead or Purpose Head through a current membership; the three church-wide roles can already read everyone. Holiday dates match `holidays_read` (`can_read_person`), and the open check-in count matches `flags_read`. No names are returned; the screen joins them through row-level security.
- **No faith or pastoral data.** Neither function touches `person_faith`, `pastoral_notes` or one-to-one content (feeling, notes, values). Check-in flags appear only as counts, and flags carry no reason.
- **Church dashboard is counts only**: no person ids, names, emails or birthdays. Unit and purpose names, and the Outstanding inputs list (input title, project, the leader it is owed by), come from `v_project_inputs`, `projects` and `app_users`, which every signed-in leader in the church can already read. `useOutstandingInputs` reads nothing else.
- **ASHLIE (R20):** no values appear on either dashboard, so nothing is scored, rated or ranked.
- **Engagement bar**: the counts are printed in the legend and the bar is hidden from screen readers; the capacity table prints every number with its sign, so colour is never the only signal.
- **Navigation** shows the capacity calendar only to the roles the database allows, and the router adds no route that bypasses a database check.

### Test results

- `scripts/db-test.sh` (local Postgres 16): **425 of 425 checks passed** (415 before; 10 added: one fixture one-to-one and 9 checks for R01 to R03). The 7 checks that test the fixes were confirmed to fail against the migration as committed; the other 2 confirm the writing lead and the Coordinator still see their figures.
- `scripts/db-types.sh`: `src/lib/database.types.ts` regenerated; no change (no public signatures changed).
- `npm run check`: lint clean, **73 of 73 unit tests pass**, build succeeds. The main chunk is still over Vite's 500 kB warning, which does not come from this slice.

### Residual risks and actions for TEC

1. **Small numbers.** The church dashboard shows every unit's headcount and how many are Active to every dashboard role, including Unit Leads of other units. In a unit of one or two people this can identify a person who has not served lately. Engagement is not special-category data, but decide whether small units should show "fewer than 3" instead, and record it in the DPIA.
2. **Dashboard audience.** The spec defines the Leadership group as the Resident Pastor, Purpose Heads and Unit Leads. The function also admits the Coordinator, Operations Lead, TECi Coordinator and pastoral lead. Confirm this wider audience.
3. **Cross-unit slot counts.** "Slots this month" on My Unit counts a member's slots in all their units (needed for the serving limit, R1). As in review 11, record it in the DPIA.
4. **Older helpers.** Earlier `app` helpers (for example `slots_in_month`, `personal_limit`, `unit_capacity`) are still SECURITY DEFINER and executable by signed-in users. They are not reachable through the API; consider giving them the R02 treatment in a future migration.
5. **One-to-one counts are per writer.** A unit with two leads shows each lead only their own one-to-ones. If co-leads should see each other's, that is a change to `can_read_one_to_one`, not to the dashboards.
6. **Sample data only** until the DPIA is signed (unchanged).

## Review 13 — Team roles, Deputy Team Lead, TECi and layout

Independent review of the latest commit on `slice-3-dashboards` ("Team roles, Deputy Team Lead, Purpose Head rule, TECi verification, layout fixes"), which implements the decisions of 23 Oct 2026. Every database fix is marked `SECURITY REVIEW 13 (Snn)` in an inline comment, and front-end fixes name their finding. Migrations 21 and 22 had not been applied anywhere, so the database fixes went straight into migration 22; no applied migration was edited.

### Scope

- `supabase/migrations/20261023002100_deputy_role.sql` and `20261023002200_team_roles_and_teci.sql`: the Deputy's read helpers (`is_unit_deputy_of`, `sees_unit`, the split of `can_read_person`), `can_see_faith`, the re-created policies, `is_dashboard_reader` and `can_view_unit` (migration 20), `role_rules`, `add_default_team_roles` and its `gsquad.default_roles` marker, `church_roles_guard`, `membership_role_guard`, `people_guard` and `create_member`.
- Every policy and function in the built database that uses `can_read_person`, `sees_unit`, `can_view_unit`, `is_unit_lead_of`, `can_edit_person`, `can_see_faith` or `can_read_one_to_one` was listed from `pg_policies` and `pg_proc` and each write path checked: people, memberships, holidays, assignments, check-in flags, one-to-ones, recognitions, faith, pastoral notes, projects and their plans, and the SECURITY DEFINER functions (`rota_candidates`, `create_member`, `set_person_faith`, `export_person`, `values_in_action_counts`, both dashboards, `capacity_calendar`).
- The `invite-leader` Edge Function, `src/auth/useMe.ts`, `src/data/{teci,forms,reference,dashboards}.ts`, `src/pages/people/{MyUnit,MemberForm,Teci}.tsx`, `src/pages/admin/{Leaders,ReferenceForm}.tsx`, `src/pages/sunday/{Rota,CheckIn}.tsx`, navigation, router and `app.css`.
- The fixture Deputy, Team Lead, TECi Coordinator, Coordinator, Operations Lead and Resident Pastor were tried on the local test database, including two sessions at once for the "one Team Lead" and Purpose Head rules.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| S01 | Medium | **A Team Lead who became the Deputy of the same team kept reading the one-to-ones they wrote**, directly from the table and as dates on the unit dashboard. `can_read_one_to_one` let the writer read whatever role they now held, so the decision "the Deputy does not see one-to-ones" did not hold for the most likely Deputy: the previous Team Lead. | `can_read_one_to_one` re-created: the writer reads their one-to-ones except while they are that unit's Deputy. Purpose Head, Coordinator and Resident Pastor unchanged. 3 checks. | migration 22 |
| S02 | Medium | **Two Team Leads in one team.** The "this team already has a Team Lead" check in `membership_role_guard` reads committed rows only, so two changes at the same moment (two tabs, or the Team Lead and the Operations Lead) both passed; reproduced with two sessions. System changes skip the check altogether. | A unique index on live memberships flagged as team leader (the flag now follows the label). 1 check; the race now fails with a duplicate-key error. | migration 22 |
| S03 | Low | **The Purpose Head rule could be raced.** Giving someone Operations Lead while another request removed their Purpose Head role: each check saw the other's row as uncommitted, both passed, and the function was left with no holder (reproduced with two sessions). | `role_rules` takes a per-person transaction lock (in a fixed order, so no deadlock) before checking; the second request waits and is refused. 1 check; race re-run by hand. | migration 22 |
| S04 | Low | **The TECi route recorded more than it needs.** `create_member` (and a direct insert) accepted birthdays, marital status, anniversaries, area, availability, consent and leaving details from the TECi Coordinator, who cannot correct the record afterwards (only the G-Squad Coordinator can until the person joins a team). The screen only asks for name, email and stage. | `people_guard`: someone adding through the TECi route (not a Team Lead or the Operations Lead) records only names, email and stage. The Operations Lead's full entry is unchanged. 4 checks. | migration 22 |
| S05 | Low | **Existing data and the new rules.** Existing co-leads made the new unique index fail with a bare database error, and memberships flagged by the old "Team leader" checkbox kept the flag without the label (still shown as "(lead)" and hiding the Team Lead label on My Unit) until the row next changed. | Migration 22 now stops with a message naming the teams that have more than one Team Lead (role or label), and brings every membership's flag into line with its label before the index is built. 1 check. | migration 22 |
| S06 | Low | **Deputy invitations always failed.** The Leaders screen offers "Deputy Team Lead" in the invite form, but the `invite-leader` Edge Function did not know the role and refused it ("Unknown role", "Only a Unit Lead has a unit"). | The function accepts `deputy_unit_lead` with a team, like the Team Lead. 1 unit test (3 assertions). | `invite-leader/logic.ts`, `invite-logic.test.ts` |
| S07 | Low | **A look-alike Team Lead.** The name index is per team, so a team-specific role could be called "Team Lead" or "Deputy Team Lead". A member given it is shown as the team's Team Lead, but the no-co-leads rule does not count it. | `church_roles_guard` keeps the four default names for the default roles (adding or renaming to one is refused). 3 checks. | migration 22 |
| S08 | Low | **Failures looked like data on the TECi page.** While the list loaded, or if it failed, the four tiles showed zeros, including "Awaiting verification: 0". The "Add a TECi graduate" note said their Team Lead adds the rest of their details, but a Team Lead cannot add an existing person to a team (only the Operations Lead can). | The tiles appear once the list has loaded. The note says what is recorded and who does the next step. | `Teci.tsx` |
| S09 | Low | Accessibility: editing a default team role greyed out name, team and role type with no explanation (a screen reader says only "dimmed"). | A sentence above the fields says which ones can change and why. | `ReferenceForm.tsx` |

### Checked and found sound

- **The Deputy writes nothing.** Every write policy still names the Team Lead (`is_unit_lead_of`, `can_edit_person`, `can_edit_faith`, `can_recognise`, `can_manage_project`) or a named church role; none uses `can_read_person`, `sees_unit` or `can_view_unit`, and `flags_insert` now uses `can_read_person_as_leader`. Tried as the fixture Deputy: member records, memberships, holidays, assignments (insert and cancel), check-in flags (raise and close), one-to-ones, recognitions (give and delete), faith fields and `create_member` into their team were all refused or matched no rows. `rota_candidates` and `values_in_action_counts` refuse the Deputy, and the rota screen only calls the picker for those who may edit.
- **What the Deputy reads** matches the Team Lead of the unit: people with a live membership, memberships, the rota, holidays, open check-in flags (which carry no reason), recognitions, the unit and church dashboards and the capacity calendar. Faith fields only through `get_person_faith` (logged) and only for active memberships, as for the Team Lead (F07). No pastoral notes; no subject access export. `one_to_ones_seen` returns null for the Deputy and the screen hides the column and tile.
- **`v_engagement`, `v_project_inputs` and `v_service_segments`** are `security_invoker`, so they show the Deputy only rows their policies allow.
- **Role rules.** `role_rules` runs after each row once the whole statement has finished, so it sees every row of a multi-row insert or update (Purpose Head and Operations Lead in one invitation pass; two holders switched off together are caught). An UPDATE that changes role, user or `is_active` is checked on both the old and new row. Deleting an account cascades to its roles and passes only because the functions go with it. The `invite-leader` function inserts roles with the caller's token, so `role_assignment_guard` and `role_rules` both apply; only the service role and SQL editor skip them (`is_system`). Co-leads are also stopped by the unique index, and Team Lead and Deputy of the same team by the trigger.
- **The `gsquad.default_roles` marker** is set only inside `app.add_default_team_roles`, which signed-in users cannot execute and which runs from the `churches` insert trigger (no API role may insert churches). `set_config` lives in `pg_catalog`, which PostgREST does not expose (only `public` and `graphql_public`), and no `public` function calls it. Same accepted pattern as `gsquad.anonymising` (review 6).
- **TECi verification.** Only the TECi Coordinator can set or clear a verification; the time and person are always stamped by the database (a supplied date or `teci_verified_by` is ignored), a stage is required (also a check constraint), and a changed stage clears the old verification. A TECi Coordinator who is not the person's editor can change only the three TECi columns. Records added through the TECi route are readable by the church-wide readers (Resident Pastor, Coordinator, Operations Lead, pastoral lead, TECi Coordinator) and editable only by the Coordinator until the Operations Lead puts them in a team.
- **`membership_role_guard`.** Project roles and another team's roles are refused; a membership cannot move to another unit (`membership_guard`); another church's role is impossible (composite foreign key); `is_team_leader` sent by a client is overwritten.
- **SECURITY DEFINER hygiene and grants.** All new and re-created functions have `search_path = ''` and schema-qualified names. Trigger functions are executable only by `service_role`; helpers by signed-in users and `service_role`, never `anon` (they are in the unexposed `app` schema). `create_member` stays SECURITY INVOKER. No `public` function or table is open to `anon`, and every `public` table has row-level security.
- **Front end.** My Unit is read-only for the Deputy (no selects, no "Add a member", no one-to-ones column); MemberForm offers faith reading to the Deputy and recording only to the Team Lead and Coordinator; the Leaders screen offers only teams without a Team Lead and gives the two functions only to Purpose Heads and the Resident Pastor; the TECi Coordinator no longer gets the Church Dashboard. The CSS changes add no new colours or spacing values.

### Test results

- `scripts/db-test.sh` (local Postgres 16): **485 of 485 checks passed** (472 before; 13 added for S01 to S05 and S07). The 8 checks that test the fixes were confirmed to fail against migration 22 as committed; the other 5 confirm unchanged behaviour (the writing Team Lead, the Operations Lead's full entry, a TECi entry with name, email and stage, a team role with its own name, and the flag matching the label).
- The two races (S02, S03) were reproduced with two sessions before the fix and refused after it.
- `scripts/db-types.sh`: `src/lib/database.types.ts` regenerated; no change.
- `npm run check`: lint clean, **76 of 76 unit tests pass** (1 new for S06), build succeeds. The main chunk is still over Vite's 500 kB warning, which does not come from this change.

### Residual risks and actions for TEC

1. **Before applying migration 22**, make sure no team has two active Team Leads (`unit_lead`) and no church already has a church-wide role called "Team Lead" held by two members of one team; the migration now stops and names the teams (S05). Memberships ticked "Team leader" under the old checkbox lose that flag unless they hold the Team Lead label: set the label on My Unit afterwards. Team-specific roles already named like a default role are not renamed by the migration; rename them.
2. **Former Team Leads keep reading their one-to-ones** when they leave the role altogether (only being the Deputy stops it, S01). Decide whether the writer's access should end when they stop leading the unit.
3. **TECi-added people cannot be corrected by the TECi Coordinator** and cannot be added to a team by a Team Lead (only by the Operations Lead). Confirm this workflow, or give the Team Lead a way to take on an existing person who has no team.
4. **The Deputy sees the Church Dashboard** (every unit's headcount and engagement) and the capacity calendar, as the Team Lead does. Small-unit identification (review 12, item 1) now applies to Deputies too; record it in the DPIA.
5. **Switched-off or retyped roles.** A membership keeps a role that is later switched off or changed from operational to project; the guard checks only when the role is given. Review roles before changing their type.
6. **Sample data only** until the DPIA is signed (unchanged).

## Review 14 — Bulk upload of members

Independent review of the latest commit on `bulk-upload` ("Bulk upload of G-Squad members (Excel or CSV)"). Every database fix is marked `SECURITY REVIEW 14 (Tnn)` in an inline comment, and front-end fixes name their finding. Migration 23 had not been applied anywhere (production is at migration 22), so the database fixes went straight into it; no applied migration was edited.

### Scope

- `supabase/migrations/20261023002300_bulk_member_import.sql`: `public.import_members`, the re-created `people_insert` and `memberships_write` policies and `app.people_guard`; read against `create_member` and `people_guard` (migration 22), `set_person_faith` and `can_edit_faith` (migration 16), `is_new_entry_of_caller`, `membership_guard` (R3), `membership_not_anonymised`, `membership_role_guard`, `memberships_update`, the audit helpers and every `raise` on the insert path.
- `src/data/importMembers.ts`, `src/data/readSpreadsheet.ts`, `src/pages/people/{ImportMembers,Members,MemberForm}.tsx`, the router, `app.css`, `netlify.toml` (CSP), the new dependencies (`read-excel-file` 9.3.12, `papaparse` 5.7.0 and what they bring in) and the "M23:" checks.
- Uploads were run on the local test database as the fixture Coordinator, Operations Lead, Team Lead, newsletter editor and a signed-out visitor, including a 500-row upload with faith fields and uploads built to fail. Hostile `.xlsx` files were built with openpyxl and fflate and read with `read-excel-file`.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| T01 | Low | **Bulk uploads left almost no audit trail.** People and memberships have no audit trigger, so an upload of up to 500 people was recorded only in `people.created_by`; only the faith writes reached `audit_log` (through their own trigger). There was no record of which records came from an upload, or into which unit. | `import_members` writes one `import_member` audit row per person added: actor, time, record, unit and spreadsheet row; no names or other personal data. The rows are undone with the rest if the upload fails. 1 check. | migration 23, `docs/database.md` |
| T02 | Medium | **A full-size Excel file could not be read under our Content Security Policy.** fflate (inside `read-excel-file`) unpacks any XML part of 512 KB or more in a web worker made from a `blob:` URL; the CSP (`script-src 'self'`, no `worker-src`) rightly blocks it. A 500-member sheet with every column is about 530 KB of XML (532,594 bytes measured), so the advertised 500-row upload failed with a browser security error. The obvious workaround, adding `worker-src blob:`, would loosen the policy. | New `src/data/xlsxSafety.ts` unpacks the file synchronously, after the T04 checks, and re-packs only its XML parts with no compression; the library then copies each part as it is and never needs a worker. The CSP is unchanged. fflate (MIT, already installed through jspdf and read-excel-file) is now a direct dependency and loads only with the upload page. 2 unit tests. | `xlsxSafety.ts`, `readSpreadsheet.ts`, `package.json` |
| T03 | Low | **An odd row number aborted the upload with a bare error.** The spreadsheet row number was cast to an integer inside the exception handler, where errors are not caught: a `row` of 2.5 or 1e12 ended the call with "invalid input syntax for type integer" instead of the row list. Nothing was saved, so this was robustness, not access. | The row number is worked out before the row's block (nested `CASE`, so the type is tested before the cast); anything that is not a whole number from 1 to 1,048,576 falls back to the row's position. 1 check. | migration 23 |
| T04 | Low | **A small hostile `.xlsx` could crash the leader's browser tab.** `read-excel-file` builds a full table up to the furthest cell any row or cell refers to: a 4.8 KB file with one cell at XFD200000 ran Node out of memory at a 2 GB heap. A 2 MB zip can also declare thousands of XML parts to unpack. Only the person choosing the file is affected, but files are often forwarded by others. | Before unpacking, the declared sizes are checked (at most 200 XML parts and 20 MB unpacked; fflate never writes more than the declared size when unpacking synchronously). Each worksheet may refer to row 5,000 and column 200 at most. Clear messages for each case and for files that are not real `.xlsx` (for example password-protected). 4 unit tests. | `xlsxSafety.ts`, `readSpreadsheet.ts` |
| T05 | Low | Accessibility and small fixes on the upload page: the results of reading a file appeared silently further down the page; the file picker and the "Skip people already recorded" box stayed active while a file was being read or imported; the template's download link was revoked straight after `click()`, which can cancel the download in Firefox and Safari. | A status line says "Reading …" and then how many rows are ready and how many need fixing. The picker and box are disabled while reading or importing. The link is revoked a second later. | `ImportMembers.tsx` |

### Checked and found sound

- **All or nothing, and no refusal is swallowed.** Each row runs in its own block (a savepoint): a failed row's writes are undone to that savepoint, and the final `raise` undoes the whole call. `when others` does not catch `query_canceled` (statement timeout, cancel) or `assert_failure`, so those still abort everything. The only error that is passed over is `create_member`'s exact "A member with that email address is already recorded" (`P0001`), and only when skipping was asked; its row is undone. The people insert's row-level security check and `people_guard` run before the unique index, so that message reaches only someone allowed to add people. Any other failure in a row (membership policy, guards, Team Lead uniqueness, faith refusal) fails the upload. New checks: skipping does not skip a refusal, and with skipping on a failed upload names only the rows to fix, not the duplicates.
- **Error details leak nothing about other people.** Only `sqlerrm` is collected, never the inner error's DETAIL, so key values from unique or foreign-key violations are not echoed. Every `raise` on this path was listed: none interpolates another person's data (the only messages with values are on other paths). Cast errors echo only the caller's own input, each message is cut to 300 characters, and the email index is per church, so nothing crosses churches.
- **SECURITY INVOKER grants nothing.** `create_member` ignores `id`, `church_id` and `created_by` in the person JSON, `people_insert` pins `created_by` to the caller, `anon` cannot execute the function, and the newsletter editor and Deputy are refused by the policies.
- **`people_guard` copy fidelity.** The function bodies in migrations 22 and 23 were extracted and diffed: they are identical apart from `gsquad_coordinator` added to the three role lists. A TECi stage given by the Coordinator still arrives unverified (only the TECi Coordinator's is stamped), and `anonymised_at` is still forced to null on insert.
- **The Coordinator's new rights.** `memberships_write` gives the Coordinator the Operations Lead's branch, so they can also add an existing person to a team. R3 still holds (a third unit waits for the Resident Pastor) and an anonymised record cannot join a unit (2 checks). `is_new_entry_of_caller` is unchanged for Team Leads. Faith fields: the Coordinator through `can_edit_faith`; the Team Lead only for someone in an active membership of their unit (always so for a new member's first unit); the Operations Lead is refused (existing check).
- **Audit of faith writes.** A 500-row upload with faith fields wrote 500 `person_faith` audit rows (which the Operations Lead cannot read), now with 500 `import_member` rows beside them (T01).
- **Load.** 500 rows with faith fields took 1.6 seconds on the local database. The row cap, the column check constraints and the 300-character message cap bound the payload and the error list.
- **Browser parsing.** Headings are matched against a fixed list and results are kept in objects keyed only by known column names, with emails in a `Map`, so a heading such as `__proto__` only lands in "Columns left out" (no prototype pollution). React escapes all cell text, file names and server messages; there is no `dangerouslySetInnerHTML`. Nothing is exported back as a spreadsheet: the template is headings only and the app's other exports are PDFs, so formula injection does not arise. Papa Parse runs without workers; files over 2 MB and sheets over 500 members are refused before anything is sent.
- **Dependencies and CSP.** New packages and licences: `read-excel-file`, `papaparse`, `@types/papaparse`, `saxen`, `unzipper-esm`, `worker-f`, `node-int64` (MIT) and `graceful-fs` (ISC); `npm audit` reports 0 vulnerabilities. The dynamically loaded chunks are same-origin, which `script-src 'self'` allows, and the template download is a link to a `blob:` URL, which the CSP does not govern. With T02 no worker is needed.
- **Screens mirror the database.** Upload rights come from `unit_lead` units only (not the Deputy); the faith columns are offered as `can_edit_faith` allows; "Upload members" and the wider unit list on the member form appear for the Coordinator, matching `people_insert`.

### Test results

- `scripts/db-test.sh` (local Postgres 16): **504 of 504 checks passed** (498 before; 6 added). The 2 checks that test the fixes (T01, T03) were confirmed to fail against migration 23 as committed; the other 4 confirm unchanged behaviour (skipping does not skip a refusal, a failed upload with skipping on does not name duplicates, R3 for a third unit, anonymised records).
- T04 was reproduced before the fix (Node ran out of memory reading the 4.8 KB file). T02 cannot be reproduced under jsdom, where fflate uses Node's worker threads, so its test checks the property that avoids the worker (every part handed to the library is stored uncompressed) alongside a full-size read.
- `scripts/db-types.sh`: `src/lib/database.types.ts` regenerated; no change (no public signatures changed).
- `npm run check`: lint clean, **96 of 96 unit tests pass** (89 before; 7 new), build succeeds. The upload checks are in their own lazily loaded chunk. The main chunk is still over Vite's 500 kB warning, which does not come from this change.
- `npm audit`: 0 vulnerabilities.

### Residual risks and actions for TEC

1. **Email look-ups.** Anyone who may add members (Team Leads, the Operations Lead, the G-Squad Coordinator, the TECi Coordinator) can learn whether up to 500 email addresses are already recorded in the church in one call, with nothing saved (skipping off, plus one deliberately bad row). `create_member` gives the same answer one address at a time; with skipping on, a failed upload names no duplicates. Being on a church volunteer list can reveal religious belief, so record this in the DPIA and watch the Supabase API logs for repeated failed `import_members` calls.
2. **Failed uploads leave no audit row**, because everything in the call is undone. The Supabase API logs are the only record of them.
3. **Savepoints.** Each row uses two savepoints (one in `import_members`, one in `create_member`), so a 500-row upload holds about 1,000 subtransactions for a second or two, beyond Postgres's cache of 64 per session; other queries can slow briefly while it runs. Fine at TEC's size; use smaller files if uploads become frequent.
4. **Statement timeout.** Supabase's default for signed-in users is 8 seconds. 500 rows took 1.6 seconds locally; try a 500-row upload of sample data on the hosted database before relying on the maximum.
5. **The Coordinator adds memberships but cannot change or end them** (`memberships_update` still names the Team Lead, Operations Lead and Resident Pastor). They can also put an existing person into a team directly, as the Operations Lead can, which gives that team's Team Lead and Deputy access to the record and faith reading. Confirm both under the Coordinator's "all access".
6. **The Coordinator can give a TECi stage when adding someone**; it stays unverified until the TECi Coordinator confirms it. Confirm this is wanted.
7. **Sample data only** until the DPIA is signed (unchanged). Files are read in the browser and nothing is sent until Import, but uploaded spreadsheets of real people should still wait for the DPIA.

## Review 15 — Slice 4: projects and events

Independent review of the latest commit on `slice-4-projects` ("Slice 4: projects and events"). Every database fix is marked `SECURITY REVIEW 15 (Unn)` in an inline comment, and front-end fixes name their finding. Migration 24 had not been applied anywhere (production is at migration 23), so the database fixes went straight into it; no applied migration was edited.

### Scope

- `supabase/migrations/20261023002400_projects_and_events.sql`: `app.project_guard` and `app.event_plan_guard` (both bodies compared line by line with migration 8), `projects.decision_note`, `app.demand_dates_guard`, `public.project_readiness`; read against the tables in migration 4, the policies in migration 7, `input_guard` and `project_shortfall` (migration 8), `projects_delete` (migration 19), `assignments_read` and the capacity calendar (migration 22) and `create_sunday_service` (migration 19). No later migration re-creates any of these.
- `src/data/projects.ts`, `src/data/people.ts` (`usePeopleNames`), `src/pages/projects/{Projects,NewProject,Project,EventPlanCard,ProjectSide}.tsx`, the router, navigation and `app.css`.
- The fixture Team Lead (owner), Purpose Head, Resident Pastor, Operations Lead, Finance, another unit's Team Lead and the newsletter editor were tried on the local test database, including requests that change status and other columns together.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| U01 | Medium | **An approved project kept its approval for dates the approver never saw.** Changing the dates, level or unit sent an approved project back for approval only when the status stayed the same. The owner could move it to "In progress" or "Done" and change its dates in one request, for example to next week, under a Large event's 8-week minimum (R14), and it stayed approved. | Changed dates, level or unit of an approved or in-progress project always send it back to Submitted, whatever status the request asks for. 2 checks. | migration 24 |
| U02 | Medium | **The event checks could be skipped after approval.** R14, R15 and R16 were checked only at submission or approval. Afterwards the owner could add the event form to an approved project (the new page offers "Use the event planning form" on any project), make it Large and High complexity with no committee, or change the estimate (which resets the budget to pending), and Finance could reject the budget, all without the project leaving Approved. Approval itself did not check R15, so a plan changed after submission was approved without a committee. | New `app.event_plan_resubmit` (after insert or update on `event_plans`): a new plan, a changed size or complexity, a committee removed, or a budget no longer approved or "not needed" sends an approved or in-progress project back to Submitted. A transaction-local marker (`gsquad.plan_resubmit`, set only in that function) lets the move happen whoever changed the plan; on that path `project_guard` accepts only that status change. R15 is also checked at approval. The page says when a plan change will send the project back. 5 checks. | migration 24, `EventPlanCard.tsx`, `Project.tsx` |
| U03 | Low | **A finished project could be reopened by submitting it.** Moving back to Draft refused a Done project, but the Submitted branch did not check where the project came from, so its owner or the Operations Lead could take a closed project (inputs and review done) back into the approval flow. | Submitting a Done project is refused, as reopening it to Draft is. 1 check. | migration 24 |
| U04 | Medium | **Action points had no column guard.** `actions_update` lets the person an action is given to update it (to tick it done), but nothing limited what they changed: they could rewrite its text, section and due date, or move it to any other project in the church, including one they cannot manage. | New `app.action_guard`: no one moves an action point to another project, and anyone who does not manage the project may change only its status. 3 checks. | migration 24 |
| U05 | Low | **The approver's note could be written by others or rewritten later.** The owner could write `decision_note` in the same request as a date change on an approved project (the date-change return came before the note check), so the page showed their text as "Note from the approver". The approver could rewrite the note at any time, after approval or after the project closed, and an old note was carried into the next submission and shown as if it were the current decision. | The note is checked before every return, may change only while the project is Submitted and only by its approver, and is cleared on a new submission, on being sent back for approval, and on any move back to draft or cancelled other than the approver's send-back. 4 checks. | migration 24, `Project.tsx` |
| U06 | Low | **The R6 shortfall action could be changed by the wrong person or after the decision.** The Resident Pastor (who can update any project, but approves only church projects) could set it on a unit project, and anyone with update rights could clear or change it after approval, erasing the record of what was agreed. | The shortfall action and its note change only while the project is a draft or submitted, by its managers or (while submitted) its approver. 2 checks. | migration 24 |
| U07 | Low | **An input's receipt could be back-dated.** `input_guard` stamped `received_at` only when the status changed to received, so the person asked (or a manager) could send any date for an input already received. | `received_at` always follows the status: now on receipt, kept otherwise, cleared on reopening (system changes are not limited). `input_guard` re-created whole from migration 8. 1 check. | migration 24 |
| U08 | Low | **Volunteers needed could end up outside the project.** `demand_dates_guard` checks demand rows when they are added or changed, but moving the project's dates left existing demand on days outside it (counted in capacity and shown on the page). | Changing a project's dates is refused while volunteers are needed on a day outside the new (London) dates. 1 check. | migration 24 |
| U09 | Low | **The screens offered, hid or misreported things.** "No budget needed" was offered to the owner when an estimate was entered, which the database refuses (F11). A failed readiness call (for example no connection) hid every action and check with no message, so a manager saw a page with nothing to do. "Past" projects were worked out from the UTC date, so a project ending between midnight and 01:00 in summer moved to the day before. Input links relied on the table's check alone. Approvers were not told when they were approving their own project. | `budgetButtons` mirrors the guard; readiness errors other than "not allowed" are shown; `isPastProject` uses the London date; `safeHttpsUrl` makes a link only from an https address; the approve panel says when the project is the approver's own. 7 unit tests. | `projects.ts`, `Projects.tsx`, `Project.tsx`, `ProjectSide.tsx`, `EventPlanCard.tsx`, `projects.test.ts` |
| U10 | Low | Accessibility: the start and end time fields were both labelled "at"; "Give your input" had `aria-expanded` but did not name the form it opens; the status steps did not say which steps were done; "Open the link" did not say it opens a new tab. | Labels "Start time" and "End time"; `aria-controls` on the button; "(done)" and "(opens in a new tab)" for screen readers. | `NewProject.tsx`, `Project.tsx`, `ProjectSide.tsx` |

### Checked and found sound

- **Copy fidelity.** Apart from the changes listed in the migration's header and above, `project_guard` and `event_plan_guard` match migration 8 line by line: the church and owner checks, "approval is recorded automatically", the non-manager column list (now with `decision_note`), F10 (the approval cannot be rewritten while moving on) and F11 (an estimate needs Finance for "not needed").
- **No self-service approval or back-dating.** `approved_by` and `approved_at` are set by the database on approval, kept on the way to Done, and cleared on every other status change; budget decisions and the review time are always stamped `now()` (the review can be reopened, not back-dated). A non-approver cannot approve: the Team Lead owner, another unit's lead and the Resident Pastor on a unit project are refused. Approval needs Submitted, so Draft, In progress, Done or Cancelled cannot jump to Approved, and only managers move a project on.
- **The send-back path opens nothing else.** A Purpose Head who is not a manager may move only a submitted unit project of their purpose to Draft, with their note and (while submitted) the shortfall action; they cannot cancel, edit other columns, or send back an approved project. The Resident Pastor's existing right to return or cancel any open project is unchanged. `v_is_approver` reads the old level and unit, which a non-manager cannot change.
- **`project_readiness`.** SECURITY DEFINER with `search_path = ''`, executable by signed-in users and `service_role` only. It answers only for the caller's church (another church's project and an unknown id give the same refusal), and only to the project's managers and approver and the roles who already read the capacity calendar, from which the shortfall is worked out. Projects, team demand and inputs are readable church-wide already, so nothing else is revealed. Finance and the newsletter editor are refused, and the page then shows them no actions.
- **The plan marker.** `gsquad.plan_resubmit` is set (transaction-local) only inside `app.event_plan_resubmit`, which no API role can execute; `set_config` is in `pg_catalog`, which PostgREST does not expose. The project it moves is the plan's own, and the only change accepted on that path is Approved or In progress to Submitted with no other column, so it cannot be used to change anything else. Same pattern as `gsquad.anonymising` (review 6).
- **`demand_dates_guard` and Sunday services.** `create_sunday_service` creates no demand, and Sunday demand is added for the service's Sunday, which lies within the project. Dates are compared as London dates, matching the page. All Sunday operations checks still pass.
- **Inputs.** Only the project's managers request, remove or mark inputs received for others (`inputs_insert`, `inputs_update`); the person asked can change only body, link and status on their own input, and no input moves between projects. Links must be https with no spaces (F17), and the page now refuses anything else too.
- **Action points.** Only managers add or delete them (F15), and with U04 the person given one can only tick it.
- **Text and links in the page.** Descriptions, decision notes, input bodies and plan text are rendered by React as text (no `dangerouslySetInnerHTML`); links open with `rel="noopener noreferrer"`.
- **The people picker** (`usePeopleNames`) loads only `id`, `first_name` and `surname`, through the people policies, so leaders see only names they could already read; someone outside their view keeps their place as "Someone outside your view".
- **Buttons match the database.** Submit, Withdraw, Approve, Send back, Mark in progress, Mark done, Cancel and Delete draft appear only for the roles and statuses the guard and policies allow (Delete also needs a draft with no served slots). Accordion sections have `aria-expanded` and `aria-controls`, the current status step has `aria-current`, form fields have labels, and destructive actions ask for confirmation.
- **London time.** `londonToIso` gives the right instant on both clock-change days and either side of them; a time that does not exist (01:30 on the spring-forward day) becomes 02:30 BST, and an ambiguous one (01:30 on the autumn day) the later, GMT, reading. New unit test for the missing hour.

### Test results

- `scripts/db-test.sh` (local Postgres 16): **536 of 536 checks passed** (518 before; 18 added). 14 of them test the fixes: 13 failed against migration 24 as committed, and the 14th (a plan added to an approved project) was confirmed by hand, because in that run an earlier unfixed behaviour had already sent the test project back. The other 4 confirm unchanged behaviour (approval of the new dates, approval once the committee is in place, other plan changes keeping the approval, and the action owner ticking their action done).
- `scripts/db-types.sh`: `src/lib/database.types.ts` regenerated; no change (no public signatures changed).
- `npm run check`: lint clean, **110 of 110 unit tests pass** (103 before; 7 new), build succeeds. The main chunk is still over Vite's 500 kB warning, which does not come from this change.

### Residual risks and actions for TEC

1. **Approving your own project.** A Purpose Head can start a unit project in their purpose and approve it, and the Resident Pastor can do the same for a church project; the rules as specified allow it, and the page now says so when it happens. Decide whether a different approver is needed (for example the Resident Pastor for projects a Purpose Head owns, and the Operations Lead or a nominated deputy for the Resident Pastor's own).
2. **Safeguarding notes are readable by every leader** (open since review 1). The new page puts the field on every event, in front of everyone who opens it. The hint now says plainly that every leader can read it and that it is for arrangements only, never names, ages, needs or concerns. Before real data, move safeguarding notes to their own table readable only by the project's managers, its approver and the safeguarding lead, and record the decision in the DPIA.
3. **Volunteers added after approval.** R6 is checked at approval only, so demand added afterwards can create a shortfall with no recorded action; the Checks card and Volunteers needed card show it. Decide whether added demand on an approved project should send it back.
4. **Assignments outside the dates.** U08 keeps demand within the project's dates; volunteers already assigned are checked only when assigned, so a project moved by a day can keep slots on the old day. Review the rota after moving a project.
5. **Other columns after approval.** Name, description, type, site and the Sunday-service flag can be changed by the owner or the Operations Lead without a new approval. Ticking `is_sunday_service` on an event moves it into Sunday Operations and out of this list; consider fixing that flag when the project is created.
6. **Inputs are trusted to the person asked.** They can mark their own input received (the screen asks for text or a link; the database does not), which is what lets a project close under R9. Managers can reopen it.
7. **Sample data only** until the DPIA is signed (unchanged).

## Review 16 — Approvals, safeguarding notes, shortfalls, phones and emails

Independent review of the latest commit on `approvals-contacts-shortfalls` ("Approvals by the Operations Lead, restricted safeguarding notes, shortfalls on dashboards, more phones and emails"), which carries out the decisions of 25 Oct 2026. Every database fix is marked `SECURITY REVIEW 16 (Vnn)` in an inline comment, and front-end fixes name their finding. Migration 25 had not been applied anywhere (production is at migration 24), so the database fixes went straight into it; no applied migration was edited.

### Scope

- `supabase/migrations/20261023002500_approvals_safeguarding_contacts.sql`: `app.is_project_approver`, `app.user_is_resident_pastor`, the re-created `projects_insert` policy, `app.project_guard` and `public.project_readiness` (from migration 24), `public.event_safeguarding` with `app.can_see_safeguarding`, `get_event_safeguarding` and `set_event_safeguarding`, the copy and drop of `event_plans.safeguarding_notes`, `public.volunteer_shortfalls`, `people.phones` and `people.other_emails` with their checks, and the re-created `app.people_guard` (from 23), `public.create_member` (from 22) and `app.anonymise` (from 17). Read against `create_sunday_service` and `grid_guard` (migrations 19 and 8), `event_plan_resubmit` (24), `projects_update` (7), `unit_capacity` and the capacity calendar (6 and 22), the dashboard helpers (20 and 22), `export_person` (11) and the audit helpers (1).
- The five re-created functions were checked by building one database to migration 24 and one to migration 25 and diffing `pg_get_functiondef` for each.
- `src/data/{projects,people,importMembers}.ts`, `src/pages/dashboard/{ChurchDashboard,Shortfalls}.tsx`, `src/pages/people/{MemberForm,Members,MyUnit}.tsx`, `src/pages/projects/{Projects,NewProject,Project,EventPlanCard}.tsx` and the "M25:" checks.
- The fixture Operations Lead, Resident Pastor, Purpose Head, Pastoral Lead, Team Leads, TECi Coordinator, Coordinator, newsletter editor and another church's Operations Lead were tried on the local test database, including requests that change status together with level, unit, owner or the new columns.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| V01 | Medium | **The self-approval flag was worked out from today's owner.** The page showed "Self-approved" when `approved_by = owner_user_id`. The Operations Lead can hand any project to someone else after approval, so a self-approved project passed to another leader lost its flag, and a project handed to the person who had approved it was shown as self-approved when it was not. The decision asks for self-approval to be flagged; this record could be changed after the fact. | New `projects.self_approved`, set by a trigger (`app.project_self_approval`, after `project_guard`) at the moment of approval: true when the approver owned the project before or after that request. It is kept while the approval stands, cleared with it (send-back, plan change, new dates, cancel), and refused if anyone sends it. Existing approvals are filled in from today's owner. The page reads the flag. 4 checks. | migration 25, `Project.tsx`, `database.types.ts`, `docs/database.md` |
| V02 | Medium | **An approval could be made for a level or unit it was not submitted under.** The approval branch asked whether the caller approves the project's *new* level and unit. A manager could change them in the approving request: the Operations Lead could turn a submitted unit project into a church project and approve it in one step, so the unit's Purpose Head never saw it, and an owner who is Purpose Head of another purpose could move their unit project into a unit they head and approve it. | Level and unit cannot change in the request that approves; change them first, and the new level's approver decides. 2 checks. | migration 25 |
| V03 | Low | **Writes to safeguarding notes were logged against the church, not the event.** The generic `app.audit_row_change` keys a row by its `id` column and falls back to `church_id`; `event_safeguarding` has no `id`, so every insert, change and removal was recorded with the church's id. The log showed that someone changed some notes, but not which event's, so a removal could not be traced. | Its own trigger, `app.safeguarding_audit`, records the action, the actor and the event (`project_id`), never the text. 2 checks. | migration 25 |
| V04 | Low | **Empty (null) entries passed the phone and email checks.** `bool_and()` skips nulls, so `phones = '{NULL}'`, or a null beside a valid number, satisfied `app.valid_phones`, and the same for `app.valid_emails`. | A null entry is invalid in both. 2 checks. | migration 25 |
| V05 | Low | **The same number or address could be kept two or three times.** Nothing stopped a phone being repeated, an extra email being repeated, or the main email being entered again as Email 2; the bulk upload and member form passed such lists straight through. Repeats add nothing and make the record less accurate. | Table checks: no repeats in either list (`app.no_repeats`), and the other emails never include the main one. `app.clean_list` keeps the first of any repeat, and `create_member` (so the bulk upload) drops the main email from the others. The member form says "Already given above" next to a repeat. 4 checks, 1 unit test. | migration 25, `people.ts`, `MemberForm.tsx` |
| V06 | Low | **Shortfalls worked out capacity twice for every row.** `volunteer_shortfalls` called `app.unit_capacity` (each active member's limit, memberships and holidays) once to filter and again to display each coming project-unit-month, on every Church Dashboard and My Unit load. | Capacity is worked out once per row in a materialised step. Same results (existing checks). | migration 25 |
| V07 | Medium | **Every member save re-sent both contact lists.** `changedColumns` (review 7, L06) compares with `!==`, and two copies of the same list are never `===`, so `phones` and `other_emails` were always in the update. A leader changing someone's area overwrote numbers another leader had just changed (the lost update L06 had fixed), and a save with nothing changed still wrote the record. | Lists are compared entry by entry. 1 unit test (confirmed to fail before the fix). | `people.ts`, `people.test.ts` |
| V08 | Low | **The guidance on what to write in safeguarding notes was dropped.** The old field said "arrangements only, never names, ages, needs or concerns about anyone"; the new panel said only "Arrangements and who is responsible". The notes are now restricted, but they are still outside a person's export and anonymising, so details about a child or a concern about someone would sit there with no route for correction or erasure. | The hint says the notes are for arrangements and the leaders responsible only, never names or details of children or anyone at risk, and no concerns about a person. | `EventPlanCard.tsx` |

### Checked and found sound

- **Copy fidelity.** Diffing `pg_get_functiondef` between databases built to migrations 24 and 25: `project_guard` differs only by the Resident Pastor ownership checks on insert and on owner change, the approver helper in place of the inline role test (twice) and comments (plus V02); `project_readiness` by the helper and `self_approval`; `people_guard` by the two phone and email conditions (TECi route and anonymising marker); `create_member` by the two new columns (plus V05); `anonymise` by the one line clearing both lists. Grants, `SECURITY DEFINER`/`INVOKER` and `search_path = ''` are unchanged.
- **Only the Operations Lead approves church projects, only the unit's Purpose Head unit projects.** The Resident Pastor and a Purpose Head are refused on church projects, the Operations Lead on unit projects. Approval still needs Submitted and is stamped by the database. Non-managers can change only status, shortfall action and note, so an approver cannot change level, unit or owner. The `gsquad.plan_resubmit` path accepts only Approved or In progress to Submitted with nothing else changed, and clears the approval (and now the flag). Owner changes keep the approval but cannot be combined with approving to dodge the flag (the approver owning it before *or* after counts).
- **The Resident Pastor owns no projects.** `projects_insert` no longer names the role and `project_guard` refuses a Resident Pastor as owner on insert and on owner change (system changes excepted). `create_sunday_service` runs as the caller, so the Operations Lead still sets up Sundays (existing checks) and the Resident Pastor is refused (new check). Sunday grids are still approved by the Resident Pastor alone (`grid_guard` untouched; existing R11 checks). The Resident Pastor keeps the right to send back or cancel an open project. `user_is_resident_pastor` cannot be called by signed-in users.
- **`self_approval` in readiness** is true exactly when the caller is the approver and the owner, which matches the "This is your own project" notice. Purpose Heads approving their own unit projects are flagged the same way.
- **Safeguarding notes are reached only through the two functions.** The table has row-level security on, no policies and no grants for `anon` or `authenticated` (direct read and write refused, checks). Both functions are `SECURITY DEFINER` with `search_path = ''`, not executable by `anon`, and check the caller's church first, so another church's Operations Lead, Resident Pastor or Pastoral Lead is refused (checks). Every read is logged (`view_safeguarding`) before the text is returned, failed reads return nothing, and a read over a read-only (GET) call fails rather than going unlogged. Writes are for the owner and Operations Lead only.
- **Copy then drop.** The old column was limited to 2,000 characters, the same as the new table, so nothing is cut; blank notes are not copied. No view, function or policy referred to `event_plans.safeguarding_notes` (the drop would have failed, and every function body was searched); `export_person` never included event plans. The generated types and the plan form no longer have the field, and `sectionStatus` never used it.
- **Shortfalls.** Restricted to the caller's church and to the Church Dashboard audience (all units) or that unit's viewers (one unit); a unit in another church is refused. It returns project, unit, month and slot figures only, no names. Drafts and Sunday services are included on purpose: both are coming demand, and R6 is checked against the same capacity at approval. At most 200 rows.
- **Phones and emails.** The phone rule uses ASCII `[0-9]` only, so other scripts' digits are refused, and the `tel:` link keeps only `+` and digits; React escapes the rest. Emails follow the main email's rule and must be stored in lower case (the form and `create_member` lower-case them). `export_person` includes both lists (it exports the whole row), `anonymise` clears them and the anonymising marker refuses a row that still has them. The TECi Coordinator's route records neither (check), and the TECi Coordinator still cannot change other columns of an existing record. The newsletter and duplicate spotting use only the main email (`people_email_unique`). Phones arriving from Excel as numbers are refused with a clear fix.
- **Screens mirror the database.** "Waiting for your decision" lists submitted church projects for the Operations Lead and unit projects for their Purpose Heads; "New project" and its church option are not offered to the Resident Pastor; the safeguarding panel appears for exactly the roles `can_see_safeguarding` allows, loads the notes only when asked (one logged view per click, no retries) and offers editing only to managers. The new fields have labels, the panel has a heading, and the "Saved." message is a status region.

### Test results

- `scripts/db-test.sh` (local Postgres 16): **582 of 582 checks passed** (563 before; 19 added). The 12 checks that test the database fixes (V01 to V05) were confirmed to fail against migration 25 as committed; the other 7 confirm sound behaviour (the flag cannot be cleared by hand, no notes text in the audit log, no direct writes, another church's Operations Lead can neither read nor write notes, shortfalls stay within the church, and the Resident Pastor cannot set up a Sunday).
- `scripts/db-types.sh`: `src/lib/database.types.ts` regenerated; `projects.self_approved` added.
- `npm run check`: lint clean, **115 of 115 unit tests pass** (113 before; 2 new), build succeeds. The main chunk is still over Vite's 500 kB warning, which does not come from this change.

### Residual risks and actions for TEC

1. **One person holding both roles.** Someone who is both Resident Pastor and Operations Lead can no longer start projects or Sundays. Giving the Resident Pastor role to someone who already owns projects leaves them as owner: before go-live, check that no project is owned by the Resident Pastor and hand any on.
2. **Self-approval.** The Operations Lead can approve church projects they own, and a Purpose Head unit projects they own; both are allowed and now recorded. Existing approvals were marked from today's owner, the best record available. Decide whether the leadership team wants a second person to look at self-approved projects, for example a monthly list.
3. **Level or unit changed while Submitted.** Done as its own request, the new level's approver decides without a new submission. Decide whether such a change should send the project back to Draft.
4. **Safeguarding notes.** They are kept for as long as the project and are not part of a person's export or anonymising. The Resident Pastor and Pastoral Lead read every event's notes; there is no Safeguarding Lead role yet. Views are logged, but someone needs to look at the log: agree who reviews `view_safeguarding` entries and how often, set a retention period, and record both in the DPIA.
5. **Shortfall figures for the Pastoral Lead.** The Church Dashboard audience includes the Pastoral Lead, who does not see the capacity calendar, so they now see each short unit's spare capacity (figures, no names), and the "Capacity calendar" link is refused for them. Confirm this is wanted.
6. **Contact details.** Phone numbers are checked for form, not normalised (07700 900123 and 07700900123 are both accepted as different), and the same number or extra email may appear on more than one member (for example a shared family address). Phones now show in the members list to everyone who can read the record, including project owners for volunteers assigned to them. Record the new fields, who sees them and why in the DPIA and privacy notice.
7. **Sample data only** until the DPIA is signed (unchanged).

## Review 17 — Slice 5: one-to-ones

Independent review of the latest commit on `slice-5-care-growth` ("Slice 5: one-to-ones (care and growth)"), which carries out the decisions of 23 and 25 Oct 2026. Every database fix is marked `SECURITY REVIEW 17 (Wnn)` in an inline comment, and front-end fixes name their finding. Migration 26 had not been applied anywhere (production is at migration 25), so the database fixes went straight into it; no applied migration was edited.

### Scope

- `supabase/migrations/20261023002600_one_to_ones.sql`: the new `one_to_ones` columns, `app.can_read_one_to_one_id`, `app.writes_one_to_one`, `public.one_to_one_walk` with `app.walk_audit`, `app.can_see_walk`, `get_one_to_one_walk` and `set_one_to_one_walk`, `one_to_one_prompts` and `one_to_one_answers` with their policies and `app.answer_guard`, and `export_person` (diffed against migration 11: the only change is the two new keys). Read against `one_to_ones` and its helpers (migration 3), the policies and `audit_read` (7), `author_fixed` (8), the ASHLIE columns and recognitions (11), anonymising (17 and 25), the dashboards' `one_to_ones_seen` (20) and `can_read_one_to_one` with the Deputy (22).
- `src/data/oneToOnes.ts`, `src/pages/care/{OneToOnes,OneToOneForm,LeadershipQuestions}.tsx`, the router, navigation, `app.css` and the "M26:" checks.
- The fixture Team Lead (writer), Deputy, Purpose Head, G-Squad Coordinator, Resident Pastor, Operations Lead and Pastoral Lead were tried on the local test database, including reading the audit log, exporting and anonymising a member, changing a one-to-one's date after answers, and changing an answered question.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| W01 | Medium | **The Operations Lead could see who wrote and viewed walk-with-God notes.** `audit_read` (F04) keeps entries about faith fields, pastoral notes and one-to-ones for the Resident Pastor, but not the new `one_to_one_walk` table or the `view_walk` action. The Operations Lead, who may not read one-to-ones at all, saw every write, removal and view of the notes, by whom and for which one-to-one. | `audit_read` re-created whole from migration 7 with `one_to_one_walk` and `view_walk` added. 2 checks. | migration 26 |
| W02 | Low | **A one-to-one's date could be in the future, or move away from its answers.** The table check keeps `held_on` inside its quarter only, so a Team Lead could record one dated later this quarter (counted as held on the dashboards before it happened). `answer_guard` checks the question's period only when an answer is written, so moving the date afterwards left answers to questions that were not being asked on the new day. | New `app.one_to_one_date_guard`: the date is never after today (London), and cannot move outside the period of a question already answered. The date picker no longer offers future days. 4 checks, 2 unit tests. | migration 26, `oneToOnes.ts`, `OneToOneForm.tsx` |
| W03 | Medium | **An answered question could be reworded or re-dated, and its author was taken from the request.** The Coordinator or Resident Pastor could change the wording of a question after Team Leads had recorded answers, so members' answers would read as answers to a question they were never asked, or move its dates so its answers fell outside it. `created_by` had only a default, so a question could be recorded as set by someone else. | New `app.prompt_guard`: author and time are set by the database and cannot change; once a question has answers its wording is fixed and its period must still cover every one-to-one that answered it. Switching it off and on, widening the period and rewording an unanswered question still work. The page says the wording is fixed once answered. 6 checks. | migration 26, `LeadershipQuestions.tsx` |
| W04 | Low | **A part-saved one-to-one was reported as "Not saved".** The form saves the one-to-one first, then the walk notes, answers and check-in flag. If a later step failed, the page said "Not saved"; saving again tried to add a second one-to-one for the quarter and failed with "That name is already in use", so the walk notes and answers could not be saved at all. After a successful save of an existing one-to-one the check-in box stayed ticked, so the next save raised another flag once the first was closed. | The new one-to-one's id is kept so saving again updates it; the message says "Partly saved" and what is left; a second one-to-one for the quarter is explained; the check-in box, walk and typed answers reset after a save. 2 unit tests. | `oneToOnes.ts`, `OneToOneForm.tsx` |
| W05 | Low | **The walk-with-God panel was offered by role, not by the rule, and was hard to use with a screen reader.** A writer who no longer leads the team (whom the database still lets read their own notes, except as that team's Deputy) was told "Not shown to your role", and a refusal for a Deputy writer was never shown; on a new one-to-one opened by someone who cannot write it, the panel said "Nothing recorded". The button said only "Show this section", without naming it or saying the view is recorded; the two ASHLIE note fields were both labelled "How" and were disabled with no reason given. | `walkAccess` mirrors `can_see_walk` and leaves the refusal to the database (shown); the button is named "Show the personal walk with God notes (your view is recorded)" and described by the panel's caption, the loaded notes are a status region; the note fields are "How they live it out" and "How they could grow in it", with "Choose a value first" while disabled. 3 unit tests. | `oneToOnes.ts`, `OneToOneForm.tsx` |
| W06 | Low | **Load errors looked like data.** If the values, questions or saved answers failed to load, the form showed no values, no "Questions from the leadership" card or empty answers, with no message, and saving before the answers loaded added a typed answer a second time (refused as a duplicate). | A "Part of this one-to-one did not load" notice, and saving waits for the saved answers. | `OneToOneForm.tsx` |
| W07 | Low | **Leadership questions could draw out faith or pastoral matters for the Purpose Head.** Answers are read by everyone who reads the one-to-one, including the Purpose Head, who must not read the walk with God; nothing told the Coordinator that. | The "Add a question" card says who reads the answers and not to ask about a member's walk with God, health or other pastoral matters. | `LeadershipQuestions.tsx` |
| W08 | Low | **"Support needed: a pastoral check-in" told no one.** It is a note on the one-to-one, which the pastoral team cannot read; only the check-in flag reaches them, and nothing linked the two. | When that support is chosen and the box is not ticked, the form says to tick it so the pastoral team is told. | `OneToOneForm.tsx` |

### Checked and found sound

- **Walk with God is reached only through the two functions.** `one_to_one_walk` has row-level security on, no policies and no grants for `anon` or `authenticated` (direct read refused, check). Both functions are `SECURITY DEFINER` with `search_path = ''`, executable by signed-in users and `service_role` only, and check the caller's church first. Reads are for the writer (not while that team's Deputy), the G-Squad Coordinator and the Resident Pastor; the Purpose Head, the Deputy, the Operations Lead, the Pastoral Lead and other Team Leads are refused. Every read is logged before the text is returned; the function is `VOLATILE`, so a read over a read-only (GET) call fails rather than going unlogged. Writes are for the writer while they lead the team; the Coordinator and Resident Pastor read but do not write.
- **No other route to the notes.** The audit log entries carry no text (`'{}'`, and now Resident Pastor only, W01); answers, the unit and church dashboards (`one_to_ones_seen`, `last_one_to_one`), `values_in_action_counts` and the generated types hold nothing from the walk table. `export_person` includes the notes and answers only for the Resident Pastor, the only exporter who also reads one-to-ones; the Operations Lead's export has them as null (check by hand). The walk is not logged as a separate view inside an export; the export itself is logged.
- **Answers.** Read by whoever reads the one-to-one, written only by its writer while they lead the team (the Deputy and Purpose Head are refused, checks). An answer cannot move to another one-to-one, question or church; the question must belong to the same church (composite key), have been switched on and cover the day it was held; an answered question cannot be deleted (key restricts), only switched off. With W02 and W03 the day and the period stay consistent afterwards. Answer writes are not audited, the same as the one-to-one itself.
- **Questions.** Read by signed-in users of the church (they hold nothing personal) and written only by the G-Squad Coordinator and Resident Pastor; every change is audited with column names only.
- **Erasure.** Anonymising a member deletes their one-to-ones, and the walk notes and answers go with them (cascade; tried by hand), each removal of notes logged against the one-to-one.
- **R20 and R19.** No score, rating or ranking of values anywhere: one-to-ones hold a value lived out and one to grow in, with notes; Values in Action shows counts by value for a team, never per person. The serving chips show how the member says they are finding it, which is the one-to-one's own content, not a value. The recognition card starts with sharing unticked, offers the newsletter and meeting only after agreement is ticked, and the table check refuses sharing without agreement.
- **Check-in flag.** Raised only by the writer (the box is shown only to them), as `manual` and open with themselves as raiser, under the existing policy (the Deputy cannot raise flags); a second open flag is stopped by the unique index and treated as already raised.
- **Screens mirror the database.** Navigation shows One-to-ones to Team Leads, Purpose Heads, the Coordinator and the Resident Pastor, not the Deputy; a one-to-one the reader cannot see opens as Not found; write controls appear only for the writer while they lead the team; Leadership questions are editable only by the two roles that may write them. New styles use the design tokens for colour and spacing.

### Test results

- `scripts/db-test.sh` (local Postgres 16): **615 of 615 checks passed** (602 before; 13 added). 7 of them test the database fixes and were confirmed to fail against migration 26 as committed (W01 1, W02 2, W03 4); the other 6 confirm behaviour that must stay (the Resident Pastor still reads the log, dates move freely without answers, a period can grow, an unanswered question can be reworded, and the fixture answer).
- `scripts/db-types.sh`: `src/lib/database.types.ts` regenerated; no change (no public signatures changed).
- `npm run check`: lint clean, **126 of 126 unit tests pass** (119 before; 7 new), build succeeds. The main chunk is still over Vite's 500 kB warning, which does not come from this change.

### Residual risks and actions for TEC

1. **Retention of one-to-one notes.** Sense of family, competence, ASHLIE notes, answers and walk-with-God notes are kept for as long as the member is with the church (removed only when they are anonymised, 12 months after leaving by default). Decide how long one-to-ones are kept (for example two years) and record it in the DPIA; a scheduled clean-up can then be added.
2. **Walk-with-God notes are special category data.** They are held apart and every view is logged, but someone needs to look at the log: agree who reviews `view_walk` entries and how often. Give Team Leads a short guide on what to write (a few words on the member's own account, nothing about anyone else).
3. **The writer keeps reading.** A Team Lead who steps down (but keeps an account) still reads the one-to-ones and walk notes they wrote, except as that team's Deputy, which matches the decision as written. The new Team Lead does not see their predecessor's one-to-ones. Decide whether either should change, for example on handover.
4. **Leadership questions reach the Purpose Head.** Their answers follow the one-to-one's readers, so a question about faith or a pastoral matter would expose the answer to the Purpose Head. The page now warns against it; the Coordinator and Resident Pastor should agree the wording of each question.
5. **Answers are not audited.** Like the one-to-ones themselves, changes to answers are not logged. Decide whether one-to-ones and answers should be.
6. **Sample data only** until the DPIA is signed (unchanged).

## Review 18 — Slice 6: The Greatness Brief

Independent review of the latest commit on `slice-6-newsletter` ("Slice 6: The Greatness Brief (building, approving and sending)"), which carries out the decisions of 25 Oct 2026. Every fix is marked `SECURITY REVIEW 18 (Ynn)` in an inline comment. Migration 27 had not been applied anywhere (production is at migration 26), so the database fixes went straight into it; no applied migration was edited.

### Scope

- `supabase/migrations/20261023002700_newsletter_sending.sql`: `start_newsletter_issue`, `app.newsletter_content` and `newsletter_issue_content`, `issue_guard` and `issue_item_changed` (diffed against migration 8), the snapshot trigger and `newsletter_snapshots`, `newsletter_deliveries`, the `church_settings` columns and `church_settings_guard` (diffed against migration 18), the service-role sending functions, `peek_email_link`, `newsletter_test_send`, `newsletter_issue_stats`, `export_person` (diffed against migration 26) and the pg_cron job. Read against the newsletter tables and `email_link_tokens` (migration 5), `redeem_email_link` and the celebrations (6), the policies (7), `is_system` (8), housekeeping and anonymising (9, 12, 17, 25), the settings guard (10, 18), recognitions and R19 (11) and project ownership (4, 7, 25).
- `supabase/functions/send-newsletter/index.ts`, `supabase/functions/email-link/index.ts`, `supabase/functions/_shared/newsletter.ts`, `supabase/config.toml`, `.github/workflows/{deploy-database,ci}.yml`.
- `src/data/newsletter.ts`, `src/pages/newsletter/{Issues,Issue}.tsx`, `src/pages/EmailLink.tsx`, the router, navigation and `app.css`, and the "X." checks and both unit test files.
- The fixture editor, Team Lead, G-Squad Coordinator, Resident Pastor, Operations Lead, service role and anonymous caller were tried on the local test database, including changing a team update between the two approvals, switching real sending off part-way, a sending run that dies after the email service accepted a batch, an empty test list, an outside test address and links of a member who has left.

### Findings

| ID | Severity | Finding | Fix | File |
|----|----------|---------|-----|------|
| Y01 | High | **Content could go out that the approvers never saw (R17).** Team updates, recognitions, celebrations and gatherings are drawn in live, and none of them sends an issue back when it changes. A Team Lead could rewrite their update after the G-Squad Coordinator approved, and it went out with only the Resident Pastor's approval; anything that changed after the Resident Pastor opened the page (their page is not refreshed) went out with nobody's. | `newsletter_issue_content` returns a `version` (MD5 of the content, worked out in UTC). Each approval must send back the version on the approver's screen, and the Resident Pastor's must equal the one the Coordinator approved; otherwise the approval is refused and the page reloads the content. 6 checks. | migration 27, `Issue.tsx`, `newsletter.ts` |
| Y02 | Medium | **Members and the test list could be mixed in one issue.** The live switch was read afresh for every batch and at the finish, but the TEST marking was taken from the first claim. Switching real sending on during a test-mode send sent members an email headed "Test email: links in it do nothing" (the links did work); "Stop sending to members" part-way sent the rest to the test list and recorded the issue as "sent (test list)" although members had it. After a test-mode send, re-approving an edited issue skipped the test addresses that had the old version. | The first claim fixes the issue's mode (`send_live`). A members' issue stops when the switch goes off (not claimed, no recipients handed over, "Sending to members was switched off") and carries on for members when it comes back on; a test-mode issue stays on the test list. Mode and test deliveries are cleared when an issue leaves approval. 6 checks. | migration 27, `send-newsletter`, `Issue.tsx` |
| Y03 | Medium | **A run that died, or a changed batch, could stop the issue for good or repeat it.** Deliveries were recorded only after the email service accepted a batch. If the function stopped in between, the next run listed the same people with fresh links, so the batch differed and Resend refused the reused key (409) on every retry until sending gave up; after 24 hours the key expires and the batch would go twice. The key was the first recipient and the batch size, so two different batches could share a key and the second was refused as a repeat. | Recipients are recorded as handed over when listed and confirmed afterwards; a refused batch is handed back (`newsletter_release_deliveries`); the next claim releases unconfirmed rows and the same batch goes under the same key, and a 409 now means "already sent" and confirms them. The key is a SHA-256 of all the batch's recipients. "Received" counts and the export count confirmed deliveries only. 4 checks, 1 unit test. | migration 27, `send-newsletter`, `newsletter.ts` (shared) |
| Y04 | Medium | **The test list accepted any address.** The Coordinator or Operations Lead could have each issue (members' names, birthdays, recognitions and team updates) sent to up to 10 outside addresses, 10 times a day per issue, with only the count logged; before the DPIA that is the only email that goes out. | Test addresses must be the sign-in addresses of active leader accounts in the church, checked when the list is saved and again at every send (a switched-off account drops out). 3 checks. | migration 27 |
| Y05 | Medium | **Starting an issue made the editor a full project owner.** `start_newsletter_issue` gives the editor a church project so they can request team updates, but ownership also let them ask units for volunteers (and then read assigned volunteers' records and contact details), add event plans, budgets, safeguarding notes and grids, and submit it for approval onto the calendar. | An issue's project takes no demand, assignments, event plans, actions, grids or safeguarding notes, and its status, level, unit, dates, type and site are fixed (system changes excepted); team updates, its name, description and owner still change. 6 checks. | migration 27 |
| Y06 | Medium | **Editors could attach an issue to any church project.** The `issues_insert` policy (migration 7) allowed a direct insert naming any existing project: the event disappeared from the gatherings, its inputs (written for leaders) were printed to every member as team updates, and with Y05 it would have been frozen. | The policy is dropped; issues are started only through `start_newsletter_issue`. 1 check (fixture changed to a system insert). | migration 27, tests |
| Y07 | Low | **An issue that reached nobody was marked sent.** With an empty test list (or no subscribed members) the first run found no one left and marked the issue sent, which is final, so it could never go out. | Finishing needs at least one confirmed delivery; otherwise the issue stays approved with "There are no test addresses that belong to leaders" or "No members are subscribed". 3 checks. | migration 27 |
| Y08 | Low | **An issue that gave up could never be sent.** After 5 failed attempts nothing reset the count: "Send now" worked only once and the attempts were reset only by a status change, which is refused once anyone has the issue. The page said "ask the Operations Lead", who could not help either. | The Coordinator or Resident Pastor can "Try sending again" once sending has given up, even part-sent (the database allows it then only, and never while a run holds the issue). 4 checks, 1 unit test. | migration 27, `newsletter.ts`, `Issue.tsx` |
| Y09 | Low | **The approval snapshot was kept for ever.** After sending it still held person ids, names and birthdays, outside the subject access export and anonymising, with no use. | Deleted when the issue is sent. 1 check. | migration 27 |
| Y10 | Low | **The open endpoints said more and read more than needed.** Anyone could call `tick` and get back every claimed issue's id and outcome. Both functions read the whole request body into memory before checking its size. Calls to Resend had no time limit. | `tick` answers with counts only; bodies are read up to the limit and dropped beyond it (Content-Length checked first); Resend calls time out after 30 seconds (the batch is then handed back, see Y03). 1 unit test. | `send-newsletter`, `email-link`, `newsletter.ts` (shared) |
| Y11 | Low | **Only CR and LF were removed from the subject.** Other control characters (including NEL) and the Unicode line and paragraph separators reached the Subject header, which some mail software treats as line ends. | All C0 and C1 controls and U+2028/U+2029 become spaces. 1 unit test. | `newsletter.ts` (shared) |
| Y12 | Low | **Links kept working after a member left.** For 60 days an RSVP or reaction was recorded for someone no longer active, and an RSVP for a gathering since cancelled or postponed. | `peek_email_link` and `redeem_email_link` (re-created whole from migration 6) treat such links as not valid; unsubscribing always works. 3 checks. | migration 27 |
| Y13 | Low | **The public link page was hard to use with a screen reader.** It had no main heading, "One moment…" and the answer were not announced, and focus was lost when the Confirm button disappeared. | A heading, a polite live region for the card body, and focus moved to the answer. | `EmailLink.tsx`, `app.css` |

### Checked and found sound

- **Copy fidelity.** `issue_guard` differs from migration 8 only by the exclusions, the sending columns, Send now and the lock (plus Y01, Y02, Y08); `issue_item_changed` only by the lock; `church_settings_guard` from migration 18 only by the live switch and test list rules (plus Y04); `export_person` from migration 26 only by `newsletter_deliveries`; `redeem_email_link` from migration 6 only by Y12. Grants, `SECURITY DEFINER` and `search_path = ''` are kept.
- **No early, unapproved or repeated sending.** `tick` needs no secret, but it can only claim approved issues that are due (past the send hour in London on the send date, or Send now pressed by the Coordinator or Resident Pastor), each held for 15 minutes with `FOR UPDATE SKIP LOCKED`, at most 5 attempts. Every sending function refuses any caller but the service role (`is_system`) and is not executable by `anon` or signed-in users (checks for every new function). Test sends need a signed-in leader, are logged and limited to 10 a day per issue, and use the test list only.
- **Approval cannot be bypassed.** Editors change content only; any edit, exclusion or item change after an approval sends the issue back to the Coordinator; approvals, the sending record and Send now are set by the database; the snapshot is taken in the same transaction as final approval, and email is made only from it; once anyone has the issue, or while a run holds it, nothing can change. R18 is re-checked at every forward step and at sending.
- **Withdrawn consent.** At sending, celebrations are re-checked for opt-in, status and anonymising; recognitions for agreement and the offer to the newsletter (R19); team updates for still being received; gatherings for still going ahead; recipients for being subscribed, active, not anonymised and with an email. An unsubscribe mid-send is honoured for the remaining batches. Anonymising deletes the person's links; the snapshot drops them at sending.
- **No personal data leaks.** The app's content has no person ids; celebrations are first name and initial, day and month; baptisms are counts; editors see counts only for RSVPs, reactions and deliveries. Snapshots, deliveries, links, RSVPs and reactions have RLS on, no policies and no API privileges. The audit log records counts and column names only. The generated types hold no data. The link page shows only what the link is for and the event's name.
- **Tokens.** 244 random bits from two `gen_random_uuid()` values, stored only as SHA-256 hashes, one purpose each, 60-day expiry, housekeeping removes expired ones. Opening a link (GET) changes nothing; the page asks first and acts on Confirm; one-click unsubscribe (RFC 8058) needs a POST with `List-Unsubscribe=One-Click` and an unsubscribe link. CORS allows the app's origins only, and `Referrer-Policy` keeps the token out of other sites' logs.
- **Email.** Every value is escaped for HTML and attributes; links are built from the app's own address and URL-encoded tokens; From is checked against a strict pattern; List-Unsubscribe uses the Supabase functions URL. The preview frame has `sandbox=""` (no scripts, forms or pop-ups) and inherits the app's Content Security Policy. The Resend key stays in the function's secrets and is never logged; errors stored on the issue are fixed messages with the HTTP status only.
- **Settings.** Only the Resident Pastor switches real sending on; the Resident Pastor, Coordinator or Operations Lead can switch it off; every change is in the audit log. `start_newsletter_issue` is limited to editors, the Coordinator and the Operations Lead, this month or the next 12, one issue a month, and refuses the Resident Pastor as owner (project_guard).
- **Screens.** Approve buttons wait for the content and send its version; Send now and Try again appear only for the two roles that may use them; the page shows the issue's own mode once sending has started. New styles use the design tokens. Layout was reviewed in the code (wrapping rows, the email frame never wider than the screen) but not rendered at 390px.

### Test results

- `scripts/db-test.sh` (local Postgres 16): **747 of 747 checks passed** (676 before; 71 added, 34 of them the grant checks for each new function). The checks for Y01 to Y09 and Y12 were confirmed to fail against migration 27 as committed (22 checks); the rest confirm behaviour that must stay.
- `scripts/db-types.sh`: `src/lib/database.types.ts` regenerated (`send_live`, `approved_version`, `newsletter_release_deliveries`).
- `npm run check`: lint clean, **151 of 151 unit tests pass** (147 before; 4 new), build succeeds. The main chunk is still over Vite's 500 kB warning, which does not come from this change. `deno check` passes for all three Edge Functions.

### Residual risks and actions for TEC

1. **Approving takes a still picture.** With Y01, anything that changes between the two approvals (a team update edited, a member opting in or out) means the Resident Pastor returns the issue and it is approved again. Agree with Team Leads that updates are final once the issue goes to the Coordinator.
2. **At-least-once at the edges.** If the email service accepts a batch but the answer is lost and no retry happens within 24 hours, those members are counted as not yet sent and could receive it twice when sending is tried again. Watch the "Not finished sending" notice and try again promptly.
3. **Test-list issues are final.** An issue sent to the test list before the DPIA is signed is marked "Sent (test list)" and cannot be sent to members later. Decide whether that is wanted, or start real sending before the issue's send date.
4. **Baptism counts.** Counts of last month's baptisms go to every member. A count of one can identify the person to those who were there. Decide whether small numbers are shown, and record it in the DPIA (faith data is special category).
5. **Retention.** Deliveries (including test addresses) and RSVPs and reactions are kept indefinitely; personal links last 60 days, so an unsubscribe link in an old email stops working (newer emails carry fresh ones). Set retention periods and record them in the DPIA and privacy notice.
6. **The test list is visible to all leaders.** `church_settings` is readable by every signed-in leader of the church, so the test addresses (leaders' sign-in addresses) are too. Confirm this is acceptable.
7. **Function secrets.** Set `RESEND_API_KEY` and `NEWSLETTER_FROM` (on the domain verified in Resend) only in Supabase's function secrets, with SPF, DKIM and DMARC set for that domain. The pg_cron job posts to the production project's address; do not apply migration 27 to any other project without changing it.
8. **Sample data only** until the DPIA is signed (unchanged). Switching real sending on is a promise that the DPIA is signed; the Resident Pastor should do it only then.
