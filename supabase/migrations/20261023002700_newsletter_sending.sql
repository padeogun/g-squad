-- =====================================================================================
-- G-Squad Planner: 27. The Greatness Brief: building and sending an issue (slice 6;
-- decisions of 25 Oct 2026)
--
-- Migrations 5, 6 and 8 already hold the issue, its items, the approval order (R17: editors,
-- then the G-Squad Coordinator, then the Resident Pastor), named items needing agreement (R18),
-- celebrations, recipient counts and personal email links. This migration adds:
--   1. Starting an issue in one step: its church project, the issue, and a team-update
--      request to every Team Lead (due on the church's newsletter day, the 25th, R17).
--   2. The issue's content as one JSON document, built in the database so the app's preview
--      and the email are made from exactly the same data. Editors may leave out a gathering,
--      team update or recognition (newsletter_issues.excluded).
--   3. A snapshot of that content when the Resident Pastor gives final approval. The email is
--      made from the snapshot, so what goes out is what was approved. At sending time anything
--      whose permission has since been withdrawn (celebration opt-in, a recognition's
--      agreement, an unsubscribed member) or that is no longer happening is left out, and
--      nothing new is added.
--   4. Sending (decisions: full issue in the email; sent automatically at 9am London time on
--      its send date, or straight away when the Coordinator or Resident Pastor presses Send
--      now; Resend is the email service). The send-newsletter Edge Function, as the service
--      role, claims due issues, asks for recipients in batches with their personal links,
--      records each delivery, and marks the issue sent. A delivery table makes retries safe.
--   5. Until the DPIA is signed, only a test list receives email (church_settings.
--      newsletter_live off, newsletter_test_recipients). Only the Resident Pastor switches
--      real sending on, and every change is in the audit log.
--   6. A pg_cron job (when pg_cron and pg_net exist, as on Supabase) that asks the Edge
--      Function every 15 minutes to send whatever is due. The call needs no secret: it can
--      only cause an issue that is approved and due to be sent, once.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. New columns
-- -------------------------------------------------------------------------------------
alter table public.newsletter_issues
  -- Gatherings, team updates and recognitions the editors chose to leave out (their ids).
  add column excluded        uuid[] not null default '{}' check (cardinality(excluded) <= 300),
  -- "Send now" pressed by the Coordinator or Resident Pastor after final approval.
  add column send_now_at     timestamptz,
  -- Set by the sending job while it works (a claim, so two runs never send at once).
  add column send_started_at timestamptz,
  add column send_attempts   smallint not null default 0 check (send_attempts between 0 and 100),
  add column send_error      text check (length(send_error) <= 500),
  -- True when the issue went to the test list only (before the DPIA, see section 5).
  add column sent_as_test    boolean not null default false;

alter table public.church_settings
  -- Real sending, off until the DPIA is signed. Only the Resident Pastor switches it on.
  add column newsletter_live boolean not null default false,
  -- Who receives the issue while real sending is off (and every test send): up to 10 addresses.
  add column newsletter_test_recipients text[] not null default '{}'
    check (cardinality(newsletter_test_recipients) <= 10
           and app.valid_emails(newsletter_test_recipients) and app.no_repeats(newsletter_test_recipients)),
  -- The hour (London time) an approved issue goes out on its send date.
  add column newsletter_send_hour smallint not null default 9 check (newsletter_send_hour between 6 and 20);

-- -------------------------------------------------------------------------------------
-- 2. Tables only the sending job touches (RLS on, no policies, no API privileges)
-- -------------------------------------------------------------------------------------

-- What the Resident Pastor approved, frozen at that moment. Holds person ids (to re-check
-- permission at sending time), so it is never readable through the API.
create table public.newsletter_snapshots (
  issue_id   uuid primary key,
  church_id  uuid not null,
  content    jsonb not null check (length(content::text) <= 500000),
  taken_at   timestamptz not null default now(),
  taken_by   uuid,
  foreign key (church_id, issue_id) references public.newsletter_issues(church_id, id) on delete cascade
);
alter table public.newsletter_snapshots enable row level security;
revoke all on public.newsletter_snapshots from public, anon, authenticated;

-- One row per email sent: a member (live) or a test address. A retry skips anyone listed here.
create table public.newsletter_deliveries (
  id            bigint generated always as identity primary key,
  church_id     uuid not null,
  issue_id      uuid not null,
  person_id     uuid,
  test_address  text check (test_address is null or length(test_address) <= 254),
  provider_id   text check (length(provider_id) <= 200),
  sent_at       timestamptz not null default now(),
  foreign key (church_id, issue_id)  references public.newsletter_issues(church_id, id) on delete cascade,
  foreign key (church_id, person_id) references public.people(church_id, id) on delete cascade,
  check ((person_id is null) <> (test_address is null))
);
create unique index newsletter_deliveries_person on public.newsletter_deliveries (issue_id, person_id) where person_id is not null;
create unique index newsletter_deliveries_test   on public.newsletter_deliveries (issue_id, test_address) where test_address is not null;
create index newsletter_deliveries_person_id on public.newsletter_deliveries (person_id);
alter table public.newsletter_deliveries enable row level security;
revoke all on public.newsletter_deliveries from public, anon, authenticated;

-- -------------------------------------------------------------------------------------
-- 3. Starting an issue
-- -------------------------------------------------------------------------------------
-- Editors cannot create projects (migration 7), and the issue needs one for its team-update
-- requests, so this SECURITY DEFINER function makes both. The caller owns the project, which
-- lets them request and remove team updates on its page. Team updates are asked of every
-- active unit's Team Lead, due on the church's newsletter day in the month before the issue.
create or replace function public.start_newsletter_issue(p_month date) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_church uuid := app.current_church_id();
  v_month  date := date_trunc('month', p_month)::date;
  v_start  timestamptz;
  v_end    timestamptz;
  v_due    date;
  v_project uuid;
  v_issue  uuid;
  v_label  text;
begin
  if not app.has_any_role(array['newsletter_editor','gsquad_coordinator','operations_lead']::public.app_role[]) then
    raise exception 'Issues are started by a newsletter editor, the G-Squad Coordinator or the Operations Lead' using errcode = '42501';
  end if;
  if p_month is null or v_month < date_trunc('month', current_date)::date
     or v_month > (date_trunc('month', current_date) + interval '12 months')::date then
    raise exception 'Choose this month or one of the next 12' using errcode = '22023';
  end if;
  if exists (select 1 from public.newsletter_issues i where i.church_id = v_church and i.issue_month = v_month) then
    raise exception 'There is already an issue for that month' using errcode = '23505';
  end if;

  v_start := (v_month::timestamp) at time zone 'Europe/London';
  v_end   := ((v_month + interval '1 month')::timestamp at time zone 'Europe/London') - interval '1 second';
  v_label := trim(to_char(v_month, 'FMMonth YYYY'));
  select (v_month - interval '1 month')::date + (s.newsletter_update_due_day - 1)
    into v_due from public.church_settings s where s.church_id = v_church;
  -- A late start: give Team Leads at least a week.
  v_due := greatest(coalesce(v_due, v_month - 7), current_date + 7);

  insert into public.projects (church_id, level, name, description, starts_at, ends_at, owner_user_id)
  values (v_church, 'church', 'The Greatness Brief: ' || v_label,
          'The newsletter for ' || v_label || '. Team updates for it are requested here.',
          v_start, v_end, (select auth.uid()))
  returning id into v_project;

  insert into public.newsletter_issues (church_id, project_id, issue_month, send_on)
  values (v_church, v_project, v_month, greatest(v_month, current_date))
  returning id into v_issue;

  -- One team update per active unit that has a Team Lead (one per unit, migration 22).
  insert into public.project_inputs (church_id, project_id, title, requested_from_user_id, unit_id, due_on, is_required)
  select v_church, v_project, 'Team update for The Greatness Brief, ' || v_label, ra.user_id, u.id, v_due, false
  from public.units u
  join public.role_assignments ra
    on ra.unit_id = u.id and ra.role = 'unit_lead' and ra.is_active and ra.church_id = v_church
  where u.church_id = v_church and u.is_active;

  perform app.audit('start_issue', 'newsletter_issues', v_issue);
  return v_issue;
end $$;
revoke all on function public.start_newsletter_issue(date) from public, anon;
grant execute on function public.start_newsletter_issue(date) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 4. The issue's content
-- -------------------------------------------------------------------------------------
-- p_mode:
--   'editor'   for the app: everything, with excluded items marked, and no person ids.
--   'snapshot' for the approval snapshot: excluded items left out, person ids kept so the
--              sending job can re-check permission.
-- Celebrations and recognitions use first name and surname initial only, as migration 6.
-- Gatherings: approved church-level events (not Sunday services or newsletter issues) that
-- start in the issue month. Baptisms: counts only, for the month before the issue. New
-- members: joined in the month before. Recognitions: offered and agreed (R19), from the month
-- before. Team updates: received inputs on the issue's project.
create or replace function app.newsletter_content(p_issue uuid, p_mode text) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  i public.newsletter_issues;
  v_prev date;
  v_next date;
  v_ids boolean := p_mode = 'snapshot';
  v_all boolean := p_mode = 'editor';
begin
  select * into i from public.newsletter_issues where id = p_issue;
  if not found then return null; end if;
  v_prev := (i.issue_month - interval '1 month')::date;
  v_next := (i.issue_month + interval '1 month')::date;

  return jsonb_build_object(
    'issue_id',    i.id,
    'issue_month', i.issue_month,
    'headline',    i.headline,
    'standfirst',  i.standfirst,
    'pastor_word', i.pastor_word,
    'pastor_name', i.pastor_name,
    'gatherings', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'name', p.name, 'starts_at', p.starts_at, 'ends_at', p.ends_at,
               'tag', t.newsletter_tag, 'site', s.name, 'excluded', p.id = any (i.excluded))
             order by p.starts_at), '[]')
      from public.projects p
      left join public.project_types t on t.id = p.type_id
      left join public.sites s on s.id = p.site_id
      where p.church_id = i.church_id and p.level = 'church'
        and p.status in ('approved', 'in_progress') and not p.is_sunday_service
        and not exists (select 1 from public.newsletter_issues ni where ni.project_id = p.id)
        and (p.starts_at at time zone 'Europe/London')::date >= i.issue_month
        and (p.starts_at at time zone 'Europe/London')::date < v_next
        and (v_all or not p.id = any (i.excluded))),
    'celebrations', (
      select coalesce(jsonb_agg(c.j order by c.kind, c.month, c.day), '[]') from (
        select x.kind, x.month, x.day,
               jsonb_build_object('kind', x.kind, 'name', x.display_name, 'day', x.day, 'month', x.month)
               || case when v_ids then jsonb_build_object('person_id', x.person_id) else '{}'::jsonb end as j
        from (
          select 'birthday'::text as kind, p.id as person_id, p.first_name || ' ' || left(p.surname, 1) || '.' as display_name,
                 p.birth_day::int as day, p.birth_month::int as month
          from public.people p
          where p.church_id = i.church_id and p.status = 'active' and p.anonymised_at is null
            and p.celebration_opt_in and p.birth_month = extract(month from i.issue_month)
          union all
          select 'anniversary', p.id, p.first_name || ' ' || left(p.surname, 1) || '.', p.anniversary_day, p.anniversary_month
          from public.people p
          where p.church_id = i.church_id and p.status = 'active' and p.anonymised_at is null
            and p.celebration_opt_in and p.anniversary_month = extract(month from i.issue_month)
          union all
          select 'new_member', p.id, p.first_name || ' ' || left(p.surname, 1) || '.',
                 extract(day from p.date_joined)::int, extract(month from p.date_joined)::int
          from public.people p
          where p.church_id = i.church_id and p.status = 'active' and p.anonymised_at is null
            and p.celebration_opt_in and p.date_joined >= v_prev and p.date_joined < i.issue_month
        ) x
      ) c),
    'baptisms', (
      select jsonb_build_object(
               'water',       count(*) filter (where f.water_baptism_date >= v_prev and f.water_baptism_date < i.issue_month),
               'holy_spirit', count(*) filter (where f.holy_spirit_baptism_date >= v_prev and f.holy_spirit_baptism_date < i.issue_month))
      from public.person_faith f where f.church_id = i.church_id),
    'team_updates', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', pi.id, 'unit', u.name, 'body', pi.body, 'excluded', pi.id = any (i.excluded))
             order by u.name), '[]')
      from public.project_inputs pi
      left join public.units u on u.id = pi.unit_id
      where pi.project_id = i.project_id and pi.status = 'received' and nullif(btrim(pi.body), '') is not null
        and (v_all or not pi.id = any (i.excluded))),
    'recognitions', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', r.id, 'letter', v.letter, 'value', v.name,
               'name', p.first_name || ' ' || left(p.surname, 1) || '.',
               'description', r.description, 'excluded', r.id = any (i.excluded))
             || case when v_ids then jsonb_build_object('person_id', p.id) else '{}'::jsonb end
             order by v.sort_order, r.recognised_on), '[]')
      from public.recognitions r
      join public.core_values v on v.id = r.value_id
      join public.people p on p.id = r.person_id
      where r.church_id = i.church_id and r.offered_to_newsletter and r.person_agreed
        and p.status = 'active' and p.anonymised_at is null
        and r.recognised_on >= v_prev and r.recognised_on < i.issue_month
        and (v_all or not r.id = any (i.excluded))),
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', it.id, 'kind', it.kind, 'title', it.title, 'body', it.body,
               'names_a_person', it.names_a_person, 'agreement_ticked', it.agreement_ticked)
             order by it.kind, it.position, it.created_at), '[]')
      from public.newsletter_items it where it.issue_id = i.id)
  );
end $$;
revoke all on function app.newsletter_content(uuid, text) from public, anon, authenticated;
grant execute on function app.newsletter_content(uuid, text) to service_role;

-- For the app's editor and preview: the same readers as the issue itself (migration 7).
create or replace function public.newsletter_issue_content(p_issue uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not app.has_any_role(array['newsletter_editor','gsquad_coordinator','resident_pastor','operations_lead']::public.app_role[])
     or not exists (select 1 from public.newsletter_issues i where i.id = p_issue and i.church_id = app.current_church_id()) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return app.newsletter_content(p_issue, 'editor');
end $$;
revoke all on function public.newsletter_issue_content(uuid) from public, anon;
grant execute on function public.newsletter_issue_content(uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 5. Approval guard, re-created whole from migration 8 with: the editors' exclusions as
-- content; the sending job's columns protected; "Send now"; and no change while an issue is
-- being sent or once anyone has received it.
-- -------------------------------------------------------------------------------------
create or replace function app.issue_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_content_changed boolean;
  v_editor boolean;
begin
  if tg_op = 'INSERT' then
    if not app.is_system() then
      new.status := 'draft';
      new.coordinator_approved_by := null; new.coordinator_approved_at := null;
      new.pastor_approved_by := null; new.pastor_approved_at := null; new.sent_at := null;
      new.send_now_at := null; new.send_started_at := null; new.send_attempts := 0;
      new.send_error := null; new.sent_as_test := false;
    end if;
    return new;
  end if;

  if new.project_id <> old.project_id or new.church_id <> old.church_id or new.issue_month <> old.issue_month then
    raise exception 'An issue cannot move' using errcode = '42501';
  end if;

  -- Sending is done by the email job (service role) only; a sent issue is final.
  if old.status = 'sent' then
    raise exception 'A sent issue cannot be changed' using errcode = '23514';
  end if;
  if app.is_system() then
    if new.status = 'sent' and old.status <> 'approved' then
      raise exception 'Only an approved issue can be sent' using errcode = '23514';
    end if;
    -- SECURITY REVIEW FIX F06 (R18): re-checked at every step, see below.
    if new.status = 'sent' and exists (select 1 from public.newsletter_items i
               where i.issue_id = new.id and i.names_a_person and not i.agreement_ticked) then
      raise exception 'A named item is missing the person''s agreement (R18)' using errcode = '23514';
    end if;
    if new.status = 'sent' then new.sent_at := coalesce(new.sent_at, now()); end if;
    return new;
  end if;
  if new.status = 'sent' then
    raise exception 'Issues are sent by the email job' using errcode = '42501';
  end if;

  -- Migration 27: once sending has begun, or anyone has received the issue, it is fixed.
  if exists (select 1 from public.newsletter_deliveries d where d.issue_id = old.id and d.person_id is not null)
     or (old.send_started_at is not null and old.send_started_at > now() - interval '15 minutes') then
    raise exception 'This issue is being sent and cannot be changed' using errcode = '23514';
  end if;
  -- The sending job's own columns.
  if (new.send_started_at, new.send_attempts, new.send_error, new.sent_as_test, new.sent_at)
     is distinct from (old.send_started_at, old.send_attempts, old.send_error, old.sent_as_test, old.sent_at) then
    raise exception 'Sending is recorded automatically' using errcode = '42501';
  end if;
  -- "Send now": the Coordinator or Resident Pastor, on an approved issue, changing nothing else.
  if new.send_now_at is distinct from old.send_now_at then
    if new.send_now_at is null or old.send_now_at is not null or old.status <> 'approved' or new.status <> 'approved'
       or not app.has_any_role(array['gsquad_coordinator','resident_pastor']::public.app_role[])
       or (to_jsonb(new) - array['send_now_at','updated_at']) <> (to_jsonb(old) - array['send_now_at','updated_at']) then
      raise exception 'Only the G-Squad Coordinator or Resident Pastor can send an approved issue now' using errcode = '42501';
    end if;
    new.send_now_at := now();
    return new;
  end if;

  if (new.coordinator_approved_by, new.coordinator_approved_at, new.pastor_approved_by, new.pastor_approved_at)
     is distinct from (old.coordinator_approved_by, old.coordinator_approved_at, old.pastor_approved_by, old.pastor_approved_at)
     and new.status = old.status then
    raise exception 'Approvals are recorded automatically' using errcode = '42501';
  end if;

  v_editor := app.has_any_role(array['newsletter_editor','operations_lead']::public.app_role[]);
  v_content_changed := (new.headline, new.standfirst, new.pastor_word, new.pastor_name, new.send_on, new.excluded)
                       is distinct from (old.headline, old.standfirst, old.pastor_word, old.pastor_name, old.send_on, old.excluded);

  if v_content_changed and not v_editor then
    raise exception 'Only newsletter editors change the content' using errcode = '42501';
  end if;
  if new.send_on is distinct from old.send_on and new.send_on is not null and new.send_on < current_date then
    raise exception 'The send date cannot be in the past' using errcode = '23514';
  end if;

  -- An edit after any approval sends the issue back to the Coordinator.
  if v_content_changed and old.status in ('awaiting_pastor', 'approved') then
    new.status := 'awaiting_coordinator';
    new.coordinator_approved_by := null; new.coordinator_approved_at := null;
    new.pastor_approved_by := null; new.pastor_approved_at := null;
    new.send_now_at := null;
    return new;
  end if;

  if new.status = old.status then return new; end if;

  -- SECURITY REVIEW FIX F06 (R18): every forward step re-checks named items.
  if new.status in ('awaiting_coordinator', 'awaiting_pastor', 'approved')
     and exists (select 1 from public.newsletter_items i
                 where i.issue_id = new.id and i.names_a_person and not i.agreement_ticked) then
    raise exception 'A named item is missing the person''s agreement (R18)' using errcode = '23514';
  end if;

  -- Leaving "approved" in any direction cancels a pending "Send now".
  new.send_now_at := null;

  if new.status = 'awaiting_coordinator' then
    if not v_editor then
      raise exception 'Only newsletter editors submit an issue' using errcode = '42501';
    end if;
    new.coordinator_approved_by := null; new.coordinator_approved_at := null;
    new.pastor_approved_by := null; new.pastor_approved_at := null;
  elsif new.status = 'awaiting_pastor' then
    if old.status <> 'awaiting_coordinator' or not app.has_role('gsquad_coordinator') then
      raise exception 'The G-Squad Coordinator approves first' using errcode = '42501';
    end if;
    new.coordinator_approved_by := (select auth.uid()); new.coordinator_approved_at := now();
    new.pastor_approved_by := null; new.pastor_approved_at := null;   -- F10: cannot be pre-filled
  elsif new.status = 'approved' then
    if old.status <> 'awaiting_pastor' or not app.has_role('resident_pastor') then
      raise exception 'The Resident Pastor approves after the Coordinator' using errcode = '42501';
    end if;
    new.pastor_approved_by := (select auth.uid()); new.pastor_approved_at := now();
    -- F10: the Coordinator's approval record cannot be rewritten by the second approver.
    new.coordinator_approved_by := old.coordinator_approved_by; new.coordinator_approved_at := old.coordinator_approved_at;
  elsif new.status = 'draft' then
    if not (v_editor or app.has_any_role(array['gsquad_coordinator','resident_pastor']::public.app_role[])) then
      raise exception 'You cannot return this issue to draft' using errcode = '42501';
    end if;
    new.coordinator_approved_by := null; new.coordinator_approved_at := null;
    new.pastor_approved_by := null; new.pastor_approved_at := null;
  end if;
  -- A fresh approval round starts with a clean sending record.
  new.send_attempts := 0; new.send_error := null; new.send_started_at := null;
  return new;
end $$;
revoke all on function app.issue_guard() from public, anon, authenticated;
grant execute on function app.issue_guard() to service_role;

-- Items: re-created from migration 8, plus: no change once anyone has received the issue or
-- while it is being sent.
create or replace function app.issue_item_changed() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_issue uuid := coalesce(new.issue_id, old.issue_id);
  i public.newsletter_issues;
begin
  select * into i from public.newsletter_issues where id = v_issue;
  if i.status = 'sent' then
    raise exception 'A sent issue cannot be changed' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and new.issue_id <> old.issue_id then
    raise exception 'An item cannot move to another issue' using errcode = '42501';
  end if;
  if exists (select 1 from public.newsletter_deliveries d where d.issue_id = v_issue and d.person_id is not null)
     or (i.send_started_at is not null and i.send_started_at > now() - interval '15 minutes') then
    raise exception 'This issue is being sent and cannot be changed' using errcode = '23514';
  end if;
  if i.status in ('awaiting_pastor', 'approved') then
    update public.newsletter_issues
       set status = 'awaiting_coordinator',
           coordinator_approved_by = null, coordinator_approved_at = null,
           pastor_approved_by = null, pastor_approved_at = null
     where id = v_issue;
  end if;
  return coalesce(new, old);
end $$;
revoke all on function app.issue_item_changed() from public, anon, authenticated;
grant execute on function app.issue_item_changed() to service_role;

-- The snapshot: taken when an issue becomes approved, dropped when it leaves approval
-- (an edit or a return to draft). AFTER the update, so it reads the row as saved.
create or replace function app.issue_snapshot() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then
    insert into public.newsletter_snapshots (issue_id, church_id, content, taken_by)
    values (new.id, new.church_id, app.newsletter_content(new.id, 'snapshot'), (select auth.uid()))
    on conflict (issue_id) do update set content = excluded.content, taken_at = now(), taken_by = excluded.taken_by;
  elsif new.status not in ('approved', 'sent') then
    delete from public.newsletter_snapshots where issue_id = new.id;
  end if;
  return null;
end $$;
revoke all on function app.issue_snapshot() from public, anon, authenticated;
grant execute on function app.issue_snapshot() to service_role;
-- Not "update of status": the guard also changes the status when content is edited.
create trigger issue_snapshot after update on public.newsletter_issues
  for each row when (old.status is distinct from new.status) execute function app.issue_snapshot();

-- -------------------------------------------------------------------------------------
-- 6. Church settings guard, re-created whole from migration 18 with: real newsletter
-- sending switched ON only by the Resident Pastor (the DPIA sign-off); switched off by the
-- Resident Pastor, Coordinator or Operations Lead. The test list follows the "other
-- settings" rule (Operations Lead or Coordinator).
-- -------------------------------------------------------------------------------------
create or replace function app.church_settings_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return new; end if;
  if new.church_id <> old.church_id then
    raise exception 'Church cannot be changed' using errcode = '42501';
  end if;
  if new.purpose_heads_read_pastoral is distinct from old.purpose_heads_read_pastoral
     and not app.has_any_role(array['resident_pastor','gsquad_coordinator']::public.app_role[]) then
    raise exception 'Only the Resident Pastor or G-Squad Coordinator decides whether Purpose Heads read pastoral notes'
      using errcode = '42501';
  end if;
  if new.newsletter_live and not old.newsletter_live and not app.has_role('resident_pastor') then
    raise exception 'Only the Resident Pastor switches on sending to members (after the DPIA is signed)' using errcode = '42501';
  end if;
  if not new.newsletter_live and old.newsletter_live
     and not app.has_any_role(array['resident_pastor','gsquad_coordinator','operations_lead']::public.app_role[]) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if not app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])
     and (to_jsonb(new) - array['purpose_heads_read_pastoral','newsletter_live','updated_at'])
         <> (to_jsonb(old) - array['purpose_heads_read_pastoral','newsletter_live','updated_at']) then
    raise exception 'Only the Operations Lead or G-Squad Coordinator changes the other settings' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app.church_settings_guard() from public, anon, authenticated;
grant execute on function app.church_settings_guard() to service_role;

-- -------------------------------------------------------------------------------------
-- 7. Sending, for the send-newsletter Edge Function (service role only)
-- -------------------------------------------------------------------------------------

-- Due issues, claimed for 15 minutes so overlapping runs never send the same issue. Due:
-- approved, and either "Send now" was pressed or it is past the send hour (London) on its
-- send date. Gives up after 5 attempts (the app shows the last error).
create or replace function public.newsletter_claim_due()
returns table (issue_id uuid, church_id uuid, live boolean)
language plpgsql security definer set search_path = ''
as $$
begin
  if not app.is_system() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    with due as (
      select i.id from public.newsletter_issues i
      join public.church_settings s on s.church_id = i.church_id
      where i.status = 'approved'
        and (i.send_now_at is not null
             or (i.send_on is not null
                 and now() >= ((i.send_on::timestamp + make_interval(hours => s.newsletter_send_hour)) at time zone 'Europe/London')))
        and (i.send_started_at is null or i.send_started_at < now() - interval '15 minutes')
        and i.send_attempts < 5
      for update of i skip locked
    )
    update public.newsletter_issues i
       set send_started_at = now(), send_attempts = i.send_attempts + 1
      from due, public.church_settings s
     where i.id = due.id and s.church_id = i.church_id
    returning i.id, i.church_id, s.newsletter_live;
end $$;
revoke all on function public.newsletter_claim_due() from public, anon, authenticated;
grant execute on function public.newsletter_claim_due() to service_role;

-- The approved snapshot as it may be sent now: anything whose permission was withdrawn, or
-- that is no longer happening, is left out; nothing is added. Person ids are removed.
create or replace function app.newsletter_send_content(p_issue uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  c jsonb;
begin
  select s.content into c from public.newsletter_snapshots s
  join public.newsletter_issues i on i.id = s.issue_id
  where s.issue_id = p_issue and i.status = 'approved';
  if c is null then return null; end if;
  return c
    || jsonb_build_object('gatherings', (
         select coalesce(jsonb_agg(g - 'excluded' order by g ->> 'starts_at'), '[]')
         from jsonb_array_elements(c -> 'gatherings') g
         join public.projects p on p.id = (g ->> 'id')::uuid
         where p.status in ('approved', 'in_progress')))
    || jsonb_build_object('celebrations', (
         select coalesce(jsonb_agg(x - 'person_id'), '[]')
         from jsonb_array_elements(c -> 'celebrations') x
         join public.people p on p.id = (x ->> 'person_id')::uuid
         where p.status = 'active' and p.anonymised_at is null and p.celebration_opt_in))
    || jsonb_build_object('recognitions', (
         select coalesce(jsonb_agg((x - 'person_id') - 'excluded'), '[]')
         from jsonb_array_elements(c -> 'recognitions') x
         join public.recognitions r on r.id = (x ->> 'id')::uuid
         join public.people p on p.id = r.person_id
         where r.offered_to_newsletter and r.person_agreed and p.status = 'active' and p.anonymised_at is null))
    || jsonb_build_object('team_updates', (
         select coalesce(jsonb_agg(x - 'excluded'), '[]')
         from jsonb_array_elements(c -> 'team_updates') x
         join public.project_inputs pi on pi.id = (x ->> 'id')::uuid
         where pi.status = 'received'));
end $$;
revoke all on function app.newsletter_send_content(uuid) from public, anon, authenticated;
grant execute on function app.newsletter_send_content(uuid) to service_role;

create or replace function public.newsletter_send_content(p_issue uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not app.is_system() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return app.newsletter_send_content(p_issue);
end $$;
revoke all on function public.newsletter_send_content(uuid) from public, anon, authenticated;
grant execute on function public.newsletter_send_content(uuid) to service_role;

-- The next batch of recipients still to receive a claimed issue, each with fresh personal
-- links (live) or none (test list). Only a SHA-256 hash of each link is stored (migration 5);
-- the raw tokens go only to the Edge Function, which puts them in that person's email.
-- Links last 60 days. The main email address is used (decision of 25 Oct 2026).
create or replace function public.newsletter_next_recipients(p_issue uuid, p_limit integer default 50)
returns table (person_id uuid, email text, first_name text, links jsonb)
language plpgsql security definer set search_path = ''
as $$
declare
  i public.newsletter_issues;
  v_live boolean;
  v_tests text[];
  v_gatherings uuid[];
  r record;
  v_links jsonb;
  v_tok text;
  g uuid;
  x public.reaction_kind;
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  if not app.is_system() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  select * into i from public.newsletter_issues where id = p_issue;
  if not found or i.status <> 'approved' or i.send_started_at is null then
    raise exception 'This issue is not being sent' using errcode = '23514';
  end if;
  select s.newsletter_live, s.newsletter_test_recipients into v_live, v_tests
  from public.church_settings s where s.church_id = i.church_id;

  if not coalesce(v_live, false) then
    return query
      select null::uuid, t.addr, null::text, null::jsonb
      from unnest(v_tests) as t(addr)
      where not exists (select 1 from public.newsletter_deliveries d where d.issue_id = p_issue and d.test_address = t.addr)
      limit v_limit;
    return;
  end if;

  select coalesce(array_agg((g2 ->> 'id')::uuid), '{}') into v_gatherings
  from jsonb_array_elements(app.newsletter_send_content(p_issue) -> 'gatherings') g2;

  for r in
    select p.id, p.email, p.first_name from public.people p
    where p.church_id = i.church_id and p.status = 'active' and p.newsletter_subscribed
      and p.email is not null and p.anonymised_at is null
      and not exists (select 1 from public.newsletter_deliveries d where d.issue_id = p_issue and d.person_id = p.id)
    order by p.id
    limit v_limit
  loop
    v_links := '{}'::jsonb;
    -- 64 hex characters from two random UUIDs (244 random bits): matches redeem_email_link's pattern.
    v_tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
    insert into public.email_link_tokens (token_hash, church_id, person_id, issue_id, purpose, expires_at)
    values (pg_catalog.sha256(pg_catalog.convert_to(v_tok, 'UTF8')), i.church_id, r.id, i.id, 'unsubscribe', now() + interval '60 days');
    v_links := v_links || jsonb_build_object('unsubscribe', v_tok);
    foreach x in array enum_range(null::public.reaction_kind) loop
      v_tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
      insert into public.email_link_tokens (token_hash, church_id, person_id, issue_id, purpose, reaction, expires_at)
      values (pg_catalog.sha256(pg_catalog.convert_to(v_tok, 'UTF8')), i.church_id, r.id, i.id, 'react', x, now() + interval '60 days');
      v_links := jsonb_set(v_links, array['react'], coalesce(v_links -> 'react', '{}'::jsonb) || jsonb_build_object(x::text, v_tok));
    end loop;
    foreach g in array v_gatherings loop
      v_tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
      insert into public.email_link_tokens (token_hash, church_id, person_id, issue_id, purpose, target_project, expires_at)
      values (pg_catalog.sha256(pg_catalog.convert_to(v_tok, 'UTF8')), i.church_id, r.id, i.id, 'rsvp', g, now() + interval '60 days');
      v_links := jsonb_set(v_links, array['rsvp'], coalesce(v_links -> 'rsvp', '{}'::jsonb) || jsonb_build_object(g::text, v_tok));
    end loop;
    person_id := r.id; email := r.email; first_name := r.first_name; links := v_links;
    return next;
  end loop;
end $$;
revoke all on function public.newsletter_next_recipients(uuid, integer) from public, anon, authenticated;
grant execute on function public.newsletter_next_recipients(uuid, integer) to service_role;

-- Record the emails the service accepted: [{ "person_id": … | "test_address": …, "provider_id": … }].
create or replace function public.newsletter_record_deliveries(p_issue uuid, p_rows jsonb) returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  i public.newsletter_issues;
  v_count int;
begin
  if not app.is_system() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  select * into i from public.newsletter_issues where id = p_issue;
  if not found or i.status <> 'approved' then
    raise exception 'This issue is not being sent' using errcode = '23514';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 100 then
    raise exception 'Give up to 100 deliveries' using errcode = '22023';
  end if;
  insert into public.newsletter_deliveries (church_id, issue_id, person_id, test_address, provider_id)
  select i.church_id, i.id, (x ->> 'person_id')::uuid, nullif(x ->> 'test_address', ''), left(x ->> 'provider_id', 200)
  from jsonb_array_elements(p_rows) x
  on conflict do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end $$;
revoke all on function public.newsletter_record_deliveries(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.newsletter_record_deliveries(uuid, jsonb) to service_role;

-- Finish a run: with no error and nobody left, the issue is sent; otherwise the error is kept
-- and the claim released, so the next run (15 minutes later) carries on where this one stopped.
create or replace function public.newsletter_finish(p_issue uuid, p_error text default null) returns text
language plpgsql security definer set search_path = ''
as $$
declare
  i public.newsletter_issues;
  v_live boolean;
  v_left int;
begin
  if not app.is_system() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  select * into i from public.newsletter_issues where id = p_issue;
  if not found or i.status <> 'approved' then return 'not_approved'; end if;
  select s.newsletter_live into v_live from public.church_settings s where s.church_id = i.church_id;

  if coalesce(v_live, false) then
    select count(*) into v_left from public.people p
    where p.church_id = i.church_id and p.status = 'active' and p.newsletter_subscribed
      and p.email is not null and p.anonymised_at is null
      and not exists (select 1 from public.newsletter_deliveries d where d.issue_id = p_issue and d.person_id = p.id);
  else
    select count(*) into v_left
    from unnest((select s.newsletter_test_recipients from public.church_settings s where s.church_id = i.church_id)) t(addr)
    where not exists (select 1 from public.newsletter_deliveries d where d.issue_id = p_issue and d.test_address = t.addr);
  end if;

  if p_error is null and v_left = 0 then
    update public.newsletter_issues
       set status = 'sent', sent_as_test = not coalesce(v_live, false), send_started_at = null, send_error = null
     where id = p_issue;
    return 'sent';
  end if;
  update public.newsletter_issues
     set send_started_at = null,
         send_error = left(coalesce(p_error, v_left || ' still to send'), 500)
   where id = p_issue;
  return 'retry';
end $$;
revoke all on function public.newsletter_finish(uuid, text) from public, anon, authenticated;
grant execute on function public.newsletter_finish(uuid, text) to service_role;

-- What an email link is for, without using it: the app's confirmation page shows this before
-- the member presses Confirm (so a mail scanner that opens links changes nothing).
create or replace function public.peek_email_link(p_token text) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  t public.email_link_tokens%rowtype;
begin
  if not app.is_system() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if p_token is null or length(p_token) < 32 or length(p_token) > 256 or p_token !~ '^[A-Za-z0-9_-]+$' then
    return jsonb_build_object('purpose', 'invalid');
  end if;
  select * into t from public.email_link_tokens
  where token_hash = pg_catalog.sha256(pg_catalog.convert_to(p_token, 'UTF8'));
  if not found or t.expires_at < now() then
    return jsonb_build_object('purpose', 'invalid');
  end if;
  return jsonb_build_object(
    'purpose',  t.purpose,
    'reaction', t.reaction,
    'event',    (select p.name from public.projects p where p.id = t.target_project),
    'used',     t.used_at is not null);
end $$;
revoke all on function public.peek_email_link(text) from public, anon, authenticated;
grant execute on function public.peek_email_link(text) to service_role;

-- -------------------------------------------------------------------------------------
-- 8. Test sends and the editors' figures
-- -------------------------------------------------------------------------------------
-- Before sending a test, the Edge Function asks as the signed-in caller: allowed (an editor,
-- the Coordinator, the Resident Pastor or the Operations Lead), at most 10 a day per issue,
-- logged. Returns the test list (leaders' own addresses, set by the Coordinator or Ops Lead).
create or replace function public.newsletter_test_send(p_issue uuid) returns text[]
language plpgsql security definer set search_path = ''
as $$
declare
  v_list text[];
begin
  if not app.has_any_role(array['newsletter_editor','gsquad_coordinator','resident_pastor','operations_lead']::public.app_role[])
     or not exists (select 1 from public.newsletter_issues i where i.id = p_issue and i.church_id = app.current_church_id()) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if (select count(*) from public.audit_log a
      where a.action = 'newsletter_test_send' and a.record_id = p_issue and a.at > now() - interval '1 day') >= 10 then
    raise exception 'Ten test emails have been sent for this issue today. Try again tomorrow' using errcode = '54000';
  end if;
  select s.newsletter_test_recipients into v_list from public.church_settings s where s.church_id = app.current_church_id();
  if coalesce(cardinality(v_list), 0) = 0 then
    raise exception 'Add test addresses in the newsletter settings first' using errcode = '23514';
  end if;
  perform app.audit('newsletter_test_send', 'newsletter_issues', p_issue, jsonb_build_object('recipients', cardinality(v_list)));
  return v_list;
end $$;
revoke all on function public.newsletter_test_send(uuid) from public, anon;
grant execute on function public.newsletter_test_send(uuid) to authenticated, service_role;

-- RSVP and reaction counts (migration 6) plus how many received it. Counts only.
create or replace function public.newsletter_issue_stats(p_issue uuid)
returns table (item text, label text, total integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not app.has_any_role(array['newsletter_editor','gsquad_coordinator','resident_pastor',
                                'operations_lead']::public.app_role[])
     or not exists (select 1 from public.newsletter_issues i
                    where i.id = p_issue and i.church_id = app.current_church_id()) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select 'delivered'::text, 'Received'::text, count(*)::int
    from public.newsletter_deliveries d where d.issue_id = p_issue
    union all
    select 'rsvp'::text, pr.name, count(r.person_id)::int
    from public.newsletter_rsvps r join public.projects pr on pr.id = r.project_id
    where r.issue_id = p_issue group by pr.name
    union all
    select 'reaction', x.reaction::text, count(*)::int
    from public.newsletter_reactions x where x.issue_id = p_issue group by x.reaction;
end $$;
revoke all on function public.newsletter_issue_stats(uuid) from public, anon;
grant execute on function public.newsletter_issue_stats(uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 9. Subject access export, re-created whole from migration 26 with the newsletters a
-- member was sent.
-- -------------------------------------------------------------------------------------
create or replace function public.export_person(p_person uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v jsonb;
begin
  if not (app.has_role('operations_lead') or app.has_role('resident_pastor'))
     or not exists (select 1 from public.people p where p.id = p_person and p.church_id = app.current_church_id()) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'person',        (select to_jsonb(p) - 'created_by' from public.people p where p.id = p_person),
    'memberships',   (select coalesce(jsonb_agg(to_jsonb(m)), '[]') from public.unit_memberships m where m.person_id = p_person),
    'holidays',      (select coalesce(jsonb_agg(to_jsonb(h)), '[]') from public.holidays h where h.person_id = p_person),
    'assignments',   (select coalesce(jsonb_agg(to_jsonb(a) - 'override_reason'), '[]') from public.assignments a where a.person_id = p_person),
    'one_to_ones',   case when app.has_role('resident_pastor')
                          then (select coalesce(jsonb_agg(to_jsonb(o)), '[]') from public.one_to_ones o where o.person_id = p_person)
                     end,
    'one_to_one_walk', case when app.has_role('resident_pastor')
                          then (select coalesce(jsonb_agg(to_jsonb(w)), '[]') from public.one_to_one_walk w
                                join public.one_to_ones o on o.id = w.one_to_one_id where o.person_id = p_person)
                     end,
    'one_to_one_answers', case when app.has_role('resident_pastor')
                          then (select coalesce(jsonb_agg(jsonb_build_object('question', q.question, 'answer', a.answer, 'quarter', o.quarter_start)), '[]')
                                from public.one_to_one_answers a
                                join public.one_to_ones o on o.id = a.one_to_one_id
                                join public.one_to_one_prompts q on q.id = a.prompt_id
                                where o.person_id = p_person)
                     end,
    'faith',         case when app.can_see_faith(p_person)
                          then (select to_jsonb(f) from public.person_faith f where f.person_id = p_person)
                     end,
    'pastoral_notes', case when app.has_role('resident_pastor')
                          then (select coalesce(jsonb_agg(to_jsonb(n)), '[]') from public.pastoral_notes n where n.person_id = p_person)
                     end,
    'recognitions',  (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from public.recognitions r where r.person_id = p_person),
    'newsletter_rsvps', (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from public.newsletter_rsvps r where r.person_id = p_person),
    'newsletter_reactions', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from public.newsletter_reactions x where x.person_id = p_person),
    -- Migration 27: which issues were emailed to them, and when.
    'newsletter_deliveries', (select coalesce(jsonb_agg(jsonb_build_object('issue_month', i.issue_month, 'sent_at', d.sent_at)), '[]')
                              from public.newsletter_deliveries d join public.newsletter_issues i on i.id = d.issue_id
                              where d.person_id = p_person),
    'checkin_flags',    (select coalesce(jsonb_agg(to_jsonb(cf)), '[]') from public.checkin_flags cf where cf.person_id = p_person),
    'community_roles',  (select coalesce(jsonb_agg(to_jsonb(c)), '[]') from public.community_support_roles c where c.person_id = p_person)
  ) into v;
  perform app.audit('export_person', 'people', p_person);
  return v;
end $$;
revoke all on function public.export_person(uuid) from public, anon;
grant execute on function public.export_person(uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 10. Every 15 minutes, ask the Edge Function to send whatever is due (Supabase only).
-- The address is this project's; the request carries no secret (see the header).
-- -------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron')
     and exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_cron;
    create extension if not exists pg_net;
    perform cron.schedule('gsquad-newsletter', '*/15 * * * *',
      $job$select net.http_post(
              url := 'https://zcysodfxcpjzinjxvayx.supabase.co/functions/v1/send-newsletter',
              body := '{"action":"tick"}'::jsonb,
              headers := '{"Content-Type":"application/json"}'::jsonb)$job$);
  end if;
end $$;
