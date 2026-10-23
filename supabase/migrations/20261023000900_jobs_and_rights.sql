-- =====================================================================================
-- G-Squad Planner: 9. Scheduled jobs and people's rights
--   R5  automatic check-in flags (nightly)
--   R8  anonymise people who left more than the retention period ago (nightly)
--   audit log kept for 2 years; expired email link tokens removed
--   one-click export of everything held on a person; anonymise on request
-- Reminder emails (R7, R9, R12, R13, R17) are sent by an Edge Function that reads
-- public.v_project_inputs and the other views; they need no extra tables.
-- =====================================================================================

-- R5: raise flags. One open flag per person per source (unique index), so re-running is safe.
create or replace function app.raise_automatic_flags() returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_count int := 0; v_rows int;
begin
  -- Inactive volunteers.
  insert into public.checkin_flags (church_id, person_id, source, raised_by)
  select e.church_id, e.person_id, 'inactive', null
  from public.v_engagement e where e.engagement = 'inactive'
  on conflict do nothing;
  get diagnostics v_rows = row_count; v_count := v_count + v_rows;

  -- New volunteers reaching 90 days (or the church's setting), flagged once.
  insert into public.checkin_flags (church_id, person_id, source, raised_by)
  select p.church_id, p.id, 'new_90_days', null
  from public.people p join public.church_settings s on s.church_id = p.church_id
  where p.status = 'active'
    and p.date_joined between current_date - (s.new_volunteer_days + 6) and current_date - s.new_volunteer_days
    and not exists (select 1 from public.checkin_flags f where f.person_id = p.id and f.source = 'new_90_days')
  on conflict do nothing;
  get diagnostics v_rows = row_count; v_count := v_count + v_rows;

  -- Serving in more units than the church allows.
  insert into public.checkin_flags (church_id, person_id, source, raised_by)
  select p.church_id, p.id, 'many_units', null
  from public.people p join public.church_settings s on s.church_id = p.church_id
  where p.status = 'active'
    and (select count(*) from public.unit_memberships m where m.person_id = p.id and m.status = 'active') > s.units_before_approval
  on conflict do nothing;
  get diagnostics v_rows = row_count; v_count := v_count + v_rows;

  -- Over their limit in each of the last two full months.
  insert into public.checkin_flags (church_id, person_id, source, raised_by)
  select p.church_id, p.id, 'over_limit_two_months', null
  from public.people p
  where p.status = 'active'
    and app.slots_in_month(p.id, (date_trunc('month', current_date) - interval '1 month')::date) > app.personal_limit(p.id)
    and app.slots_in_month(p.id, (date_trunc('month', current_date) - interval '2 months')::date) > app.personal_limit(p.id)
  on conflict do nothing;
  get diagnostics v_rows = row_count; v_count := v_count + v_rows;

  return v_count;
end $$;

-- Wipes a person's personal details but keeps anonymous serving history for the counts.
create or replace function app.anonymise(p_person uuid) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  -- Marker read by app.people_guard() so this one update may set anonymised_at.
  perform set_config('gsquad.anonymising', 'on', true);
  update public.people set
    first_name = 'Former', other_names = null, surname = 'member',
    email = null, area = null, marital_status = null,
    birth_day = null, birth_month = null, anniversary_day = null, anniversary_month = null,
    greatness_community_id = null, available_hours_month = null, preferred_times = '{}',
    newsletter_subscribed = false, celebration_opt_in = false,
    status = 'left', date_left = coalesce(date_left, current_date),
    anonymised_at = now()
  where id = p_person and anonymised_at is null;
  delete from public.person_faith where person_id = p_person;
  delete from public.pastoral_notes where person_id = p_person;
  delete from public.one_to_ones where person_id = p_person;
  delete from public.holidays where person_id = p_person;
  delete from public.checkin_flags where person_id = p_person;
  delete from public.email_link_tokens where person_id = p_person;
  update public.community_support_roles set person_id = null where person_id = p_person;
  update public.app_users set person_id = null where person_id = p_person;
  -- SECURITY REVIEW FIX F14: the free-text override reason can describe the person's
  -- circumstances; wipe it with the rest of their personal details.
  update public.assignments set override_reason = null where person_id = p_person and override_reason is not null;
  perform set_config('gsquad.anonymising', 'off', true);
end $$;

-- R8: nightly anonymisation of people who left more than the retention period ago.
create or replace function app.anonymise_expired_people() returns integer
language plpgsql security definer set search_path = ''
as $$
declare r record; n int := 0;
begin
  for r in
    select p.id from public.people p join public.church_settings s on s.church_id = p.church_id
    where p.status = 'left' and p.anonymised_at is null
      and p.date_left < current_date - make_interval(months => s.retention_months)
  loop
    perform app.anonymise(r.id);
    insert into public.audit_log (church_id, actor_id, action, table_name, record_id)
    select p.church_id, null, 'anonymise_retention', 'people', r.id from public.people p where p.id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Housekeeping: 2-year audit retention and expired email tokens.
create or replace function app.housekeeping() returns void
language sql security definer set search_path = ''
as $$
  delete from public.audit_log where at < now() - interval '2 years';
  delete from public.email_link_tokens where expires_at < now() - interval '7 days';
$$;

-- Anonymise on request (a person's right to erasure). Operations Lead only; logged.
create or replace function public.anonymise_person(p_person uuid) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not app.has_role('operations_lead')
     or not exists (select 1 from public.people p where p.id = p_person and p.church_id = app.current_church_id()) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  perform app.anonymise(p_person);
  perform app.audit('anonymise_request', 'people', p_person);
end $$;

-- One click exports everything held on a person (subject access request). Operations Lead
-- only; faith fields only if the caller may see them; pastoral notes only for a pastor
-- (spec: left out of every export except a pastor's own). Logged.
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
    'faith',         case when app.can_see_faith(p_person)
                          then (select to_jsonb(f) from public.person_faith f where f.person_id = p_person)
                     end,
    'pastoral_notes', case when app.has_role('resident_pastor')
                          then (select coalesce(jsonb_agg(to_jsonb(n)), '[]') from public.pastoral_notes n where n.person_id = p_person)
                     end,
    'newsletter_rsvps', (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from public.newsletter_rsvps r where r.person_id = p_person),
    -- SECURITY REVIEW FIX F14: a subject access export must hold everything kept on the person.
    'newsletter_reactions', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from public.newsletter_reactions x where x.person_id = p_person),
    'checkin_flags',    (select coalesce(jsonb_agg(to_jsonb(cf)), '[]') from public.checkin_flags cf where cf.person_id = p_person),
    'community_roles',  (select coalesce(jsonb_agg(to_jsonb(c)), '[]') from public.community_support_roles c where c.person_id = p_person)
  ) into v;
  perform app.audit('export_person', 'people', p_person);
  return v;
end $$;

revoke execute on function public.anonymise_person(uuid), public.export_person(uuid) from anon, public;
grant execute on function public.anonymise_person(uuid), public.export_person(uuid) to authenticated;
revoke all on all functions in schema app from public;
grant execute on all functions in schema app to service_role;
-- Signed-in users need the RLS helpers, but not the job functions.
revoke execute on function app.raise_automatic_flags(), app.anonymise(uuid), app.anonymise_expired_people(),
                           app.housekeeping() from authenticated;

-- Schedule the jobs with pg_cron when it is available (it is on Supabase; enable it under
-- Database > Extensions first). Skipped quietly on plain Postgres.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('gsquad-flags',        '15 2 * * *', 'select app.raise_automatic_flags()');
    perform cron.schedule('gsquad-anonymise',    '30 2 * * *', 'select app.anonymise_expired_people()');
    perform cron.schedule('gsquad-housekeeping', '45 2 * * *', 'select app.housekeeping()');
  end if;
end $$;
