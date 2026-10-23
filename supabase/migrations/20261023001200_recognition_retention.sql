-- =====================================================================================
-- G-Squad Planner: 12. Retention for Values in Action recognitions
-- Decision of 23 Oct 2026: recognitions are kept for 12 months from the date of the act of
-- service (recognised_on), then deleted by the nightly housekeeping job. The period is a
-- church setting the Operations Lead can change, like the other retention periods.
-- The leader's agreement tick remains the record of the member's agreement, so it goes with
-- the recognition; the audit log keeps who ticked it and when (column names only, G04) for
-- its own 2 years.
-- =====================================================================================

-- SECURITY REVIEW FIX H02: bounds raised from 1-120 to 6-36 months. Below 6, a slip of the
-- keyboard (1 for 12) would delete almost every recognition the next night and break the
-- newsletter feed (previous month) and quarterly counts. Above 36, free text about members
-- would be kept far beyond the period the church decided and will state in its privacy notice.
-- Only the Operations Lead can change it (settings_update policy + app.church_settings_guard),
-- and every change is logged by church_settings_audit.
alter table public.church_settings
  add column recognition_retention_months smallint not null default 12
    check (recognition_retention_months between 6 and 36);

-- Nightly housekeeping (re-created whole, as in migration 9, with recognitions added):
--   * audit log kept 2 years
--   * expired email link tokens removed after 7 days
--   * recognitions older than the church's retention period removed
-- The audit log is purged first, so the delete rows the recognitions_audit trigger (G04) writes
-- for this run (actor empty, no text) are kept for the full 2 years.
-- The cut-off uses current_date in the session time zone. pg_cron and the service role use the
-- database default (UTC on Supabase); the 02:45 UTC run is the same calendar day in the UK, so at
-- most the cut-off moves by one day. A recognition dated exactly N months ago is kept until the
-- next night; month ends clamp (29 Feb minus 12 months is 28 Feb).
create or replace function app.housekeeping() returns void
language sql security definer set search_path = ''
as $$
  delete from public.audit_log where at < now() - interval '2 years';
  delete from public.email_link_tokens where expires_at < now() - interval '7 days';
  -- SECURITY REVIEW FIX H03: a church without a settings row (none is created automatically)
  -- would never have its recognitions purged. Fall back to the 12-month default.
  delete from public.recognitions r
   where r.recognised_on < current_date - make_interval(months => coalesce(
           (select s.recognition_retention_months from public.church_settings s where s.church_id = r.church_id),
           12));
$$;

-- CREATE OR REPLACE keeps existing grants; restate them so this file is self-contained:
-- the job is for the service role and pg_cron only, never for signed-in users.
revoke all on function app.housekeeping() from public, anon, authenticated;
grant execute on function app.housekeeping() to service_role;

-- SECURITY REVIEW FIX H01: retention is keyed on recognised_on, which the author may edit. Moving
-- it forward to today, again and again, would keep a recognition for ever and could put an old,
-- already-agreed recognition back in the newsletter feed. The act of service cannot have happened
-- after the recognition was written, so recognised_on may not be later than the day it was created.
-- Correcting it to an earlier date is still allowed. (The future-date check stays in recognition_guard.)
create or replace function app.recognition_date_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return new; end if;
  if new.recognised_on > old.created_at::date then
    raise exception 'The date of service cannot be after the recognition was written' using errcode = '23514';
  end if;
  return new;
end $$;

create trigger recognition_date_guard before update of recognised_on on public.recognitions
  for each row execute function app.recognition_date_guard();

-- Trigger function: not callable by API roles (triggers do not need EXECUTE grants).
revoke all on function app.recognition_date_guard() from public, anon, authenticated;
grant execute on function app.recognition_date_guard() to service_role;

-- -------------------------------------------------------------------------------------
-- Every church gets its settings row automatically (raised as a residual risk in Review 3):
-- without one, the nightly anonymisation job (R8) would skip that church's leavers, and the
-- business rules would have no thresholds. Existing churches without a row get one now.
-- -------------------------------------------------------------------------------------
create or replace function app.church_settings_default() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.church_settings (church_id) values (new.id) on conflict (church_id) do nothing;
  return new;
end $$;

create trigger churches_settings_default after insert on public.churches
  for each row execute function app.church_settings_default();

insert into public.church_settings (church_id)
select c.id from public.churches c
where not exists (select 1 from public.church_settings s where s.church_id = c.id);

revoke all on function app.church_settings_default() from public, anon, authenticated;
grant execute on function app.church_settings_default() to service_role;

-- SECURITY REVIEW FIX I01: the settings row can still go missing if someone deletes it (the
-- service role or SQL editor; signed-in users have no delete policy). Without it, anonymisation
-- (R8) skips the church's leavers, the engagement view and automatic flags (R4, R5) drop its
-- people, and R3 (units before approval) and R14 (lead time) compare against NULL and so let
-- everything through. The row may now only be removed with its church (ON DELETE CASCADE);
-- change values instead of deleting. TRUNCATE is not granted to API roles.
create or replace function app.church_settings_keep() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from public.churches c where c.id = old.church_id) then
    raise exception 'A church''s settings row cannot be deleted; change the values instead' using errcode = '42501';
  end if;
  return old;
end $$;

create trigger church_settings_keep before delete on public.church_settings
  for each row execute function app.church_settings_keep();

-- SECURITY REVIEW FIX I04: now that every church has a settings row, deleting a church always
-- cascades to it, and the delete audit row (church_settings_audit) then pointed at the church
-- being deleted, so the foreign key on audit_log refused the whole delete: no church could ever
-- be removed. After I01 a settings row is only deleted with its church, whose audit rows are
-- deleted too, so the delete event is no longer audited for this table. Inserts and updates are.
drop trigger church_settings_audit on public.church_settings;
create trigger church_settings_audit after insert or update on public.church_settings
  for each row execute function app.audit_row_change();

revoke all on function app.church_settings_keep() from public, anon, authenticated;
grant execute on function app.church_settings_keep() to service_role;

-- SECURITY REVIEW FIX I02: defence in depth, as H03 did for recognitions. R8 anonymisation
-- (re-created whole from migration 9; no later migration changed it) falls back to the
-- 12-month default if a church has no settings row, instead of skipping its leavers.
-- Everything else is unchanged: the per-person app.anonymise() (as re-created in migration 11)
-- and the audit row with no actor.
create or replace function app.anonymise_expired_people() returns integer
language plpgsql security definer set search_path = ''
as $$
declare r record; n int := 0;
begin
  for r in
    select p.id from public.people p left join public.church_settings s on s.church_id = p.church_id
    where p.status = 'left' and p.anonymised_at is null
      and p.date_left < current_date - make_interval(months => coalesce(s.retention_months, 12))
  loop
    perform app.anonymise(r.id);
    insert into public.audit_log (church_id, actor_id, action, table_name, record_id)
    select p.church_id, null, 'anonymise_retention', 'people', r.id from public.people p where p.id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- CREATE OR REPLACE keeps migration 9's grants; restated: the job is for the service role and
-- pg_cron (the owner) only.
revoke all on function app.anonymise_expired_people() from public, anon, authenticated;
grant execute on function app.anonymise_expired_people() to service_role;
