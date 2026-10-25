-- =====================================================================================
-- G-Squad Planner: 28. One limit for all serving, counted in hours (decision of 25 Oct 2026)
--
-- Every programme draws on the same G-Squad members. Until now only Sunday rotas named people,
-- so serving at events, outreach and team activities (rehearsals, training, team meetings)
-- never counted towards anyone's monthly limit. Now:
--   * every volunteers-needed row (team_demand) says how many hours each person gives
--     (default: the church's hours per slot, 3);
--   * each team's Team Lead names people for events and team activities on the Rota page, as
--     for Sundays (decision: Team Leads assign, not the project owner), and every slot
--     carries its hours;
--   * the monthly limit is counted in hours across all serving: serving_limit_per_month x
--     hours_per_slot (3 x 3 = 9 hours by default), or less if the member gives fewer hours
--     (people.available_hours_month). A 1-hour rehearsal counts 1, a full-day event 8.
--   * the rota candidates, the automatic "over the limit two months running" flag, the
--     Church Dashboard's "over limit" count and My Unit use hours.
-- The capacity calendar still counts people-slots per team (how many places a team can fill).
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Hours on volunteers needed and on each slot
-- -------------------------------------------------------------------------------------
alter table public.team_demand
  add column hours numeric(4,1) check (hours is null or (hours >= 0.5 and hours <= 16));

alter table public.assignments
  add column hours numeric(4,1) not null default 3 check (hours >= 0.5 and hours <= 16);

-- Existing slots take their church's hours per slot (system change, before the guard changes).
update public.assignments a set hours = s.hours_per_slot
from public.church_settings s where s.church_id = a.church_id and a.hours <> s.hours_per_slot;

-- The hours one slot gives: the matching volunteers-needed row's hours, else the church default.
create or replace function app.slot_hours(p_project uuid, p_unit uuid, p_role uuid, p_day date) returns numeric
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select max(d.hours) from public.team_demand d
      where d.project_id = p_project and d.unit_id = p_unit and d.on_date = p_day
        and d.church_role_id is not distinct from p_role and d.hours is not null),
    (select s.hours_per_slot from public.projects p join public.church_settings s on s.church_id = p.church_id
      where p.id = p_project),
    3)
$$;

-- Hours a person serves in the calendar month containing p_day, across all teams and projects.
create or replace function app.hours_in_month(p_person uuid, p_day date, p_exclude uuid default null) returns numeric
language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(a.hours), 0)
  from public.assignments a
  where a.person_id = p_person
    and a.status in ('planned', 'served')
    and date_trunc('month', a.serve_date) = date_trunc('month', p_day)
    and (p_exclude is null or a.id <> p_exclude)
$$;

-- A person's monthly limit in hours (R1/R10): the church limit, or less if they give fewer hours.
create or replace function app.hours_limit(p_person uuid) returns numeric
language sql stable security definer set search_path = ''
as $$
  select least(s.serving_limit_per_month * s.hours_per_slot,
               coalesce(p.available_hours_month, s.serving_limit_per_month * s.hours_per_slot))::numeric
  from public.people p
  join public.church_settings s on s.church_id = p.church_id
  where p.id = p_person
$$;

revoke all on function app.slot_hours(uuid, uuid, uuid, date), app.hours_in_month(uuid, date, uuid), app.hours_limit(uuid)
  from public, anon;
grant execute on function app.slot_hours(uuid, uuid, uuid, date), app.hours_in_month(uuid, date, uuid), app.hours_limit(uuid)
  to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 2. The assignment guard, re-created whole from migration 19: hours are set by the database
-- and the limit is checked in hours.
-- -------------------------------------------------------------------------------------
create or replace function app.assignment_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_limit_h numeric;
  v_used_h numeric;
  v_proj record;
begin
  -- Migration 28: a slot's hours come from the volunteers-needed row it fills (its project,
  -- team, role and day), or the church's hours per slot. Set by the database, never the caller;
  -- kept as it was when only the status changes.
  if tg_op = 'INSERT' or new.project_id <> old.project_id or new.serve_date <> old.serve_date
     or new.unit_id <> old.unit_id or new.church_role_id is distinct from old.church_role_id then
    new.hours := app.slot_hours(new.project_id, new.unit_id, new.church_role_id, new.serve_date);
  else
    new.hours := old.hours;
  end if;
  if tg_op = 'UPDATE' and (new.person_id <> old.person_id or new.church_id <> old.church_id) then
    raise exception 'Reassign by cancelling this slot and adding a new one' using errcode = '42501';
  end if;
  -- SECURITY REVIEW FIX Q09: "served" and "no-show" are recorded on or after the day (the
  -- table's own rule). Before, a slot months ahead could be marked served, which counts towards
  -- engagement (active / inactive) and the monthly report. Today is the UK date.
  if not app.is_system() and new.status in ('served', 'no_show')
     and (tg_op = 'INSERT' or new.status is distinct from old.status or new.serve_date <> old.serve_date)
     and new.serve_date > (now() at time zone 'Europe/London')::date then
    raise exception 'Mark served or no-show on or after the day' using errcode = '23514';
  end if;
  -- Only live slots are checked; marking served / no-show / cancelled is always allowed.
  if new.status not in ('planned', 'served') then return new; end if;
  -- SECURITY REVIEW FIX Q08: the shortcut for status-only changes also requires the same
  -- project. Before, a live slot could be moved to another project (a cancelled or finished
  -- one, or one whose dates do not include the serve date) with no checks at all.
  if tg_op = 'UPDATE' and new.serve_date = old.serve_date and new.unit_id = old.unit_id
     and new.project_id = old.project_id and old.status in ('planned', 'served') then
    return new;
  end if;

  -- The serve date must fall within the project's dates.
  select p.starts_at, p.ends_at, p.status into v_proj from public.projects p where p.id = new.project_id;
  -- SECURITY REVIEW FIX Q07: project times are compared as UK dates. A plain ::date uses the
  -- database's time zone (UTC on Supabase), so in summer anything starting before 01:00 UK
  -- time fell on the previous day and the allowed serve dates were off by one.
  if new.serve_date < (v_proj.starts_at at time zone 'Europe/London')::date
     or new.serve_date > (v_proj.ends_at at time zone 'Europe/London')::date then
    raise exception 'Serve date is outside the project dates' using errcode = '23514';
  end if;
  if v_proj.status in ('cancelled', 'done') then
    raise exception 'The project is closed' using errcode = '23514';
  end if;

  if app.is_system() then return new; end if;

  -- A Unit Lead assigns members of their own unit; borrowing across units is for the Ops Lead.
  if not app.has_role('operations_lead') and not exists (
       select 1 from public.unit_memberships m
       where m.person_id = new.person_id and m.unit_id = new.unit_id and m.status = 'active') then
    raise exception 'This person is not an active member of the unit' using errcode = '42501';
  end if;

  -- R10: people on holiday are not offered. No override.
  if app.on_holiday(new.person_id, new.serve_date) then
    raise exception 'This person is on holiday on that date' using errcode = '23514';
  end if;

  -- R1 / R2, migration 28: one monthly limit across ALL serving (Sundays, events, outreach and
  -- team activities), counted in hours; the Ops Lead may override with a reason.
  v_limit_h := app.hours_limit(new.person_id);
  v_used_h  := app.hours_in_month(new.person_id, new.serve_date, new.id);
  if v_used_h + new.hours > v_limit_h then
    if app.has_role('operations_lead') and coalesce(length(trim(new.override_reason)), 0) >= 5 then
      perform app.audit('override_limit', 'assignments', new.id,
                        jsonb_build_object('person_id', new.person_id, 'month', date_trunc('month', new.serve_date)::date,
                                           'limit_hours', v_limit_h, 'hours_before', v_used_h, 'hours', new.hours));
    else
      raise exception 'This person already has % of % hours this month; this needs %', v_used_h, v_limit_h, new.hours
        using errcode = '23514', hint = 'The Operations Lead can override with a written reason.';
    end if;
  end if;
  return new;
end $$;

revoke all on function app.assignment_guard() from public, anon, authenticated;
grant execute on function app.assignment_guard() to service_role;

-- -------------------------------------------------------------------------------------
-- 3. Who can serve: as migration 19, plus hours used and the hours limit, least hours first.
-- (The return type changes, so the function is dropped and made again.)
-- -------------------------------------------------------------------------------------
drop function public.rota_candidates(uuid, date);
create function public.rota_candidates(p_unit uuid, p_date date)
returns table (
  person_id uuid,
  first_name text,
  surname text,
  church_role_id uuid,
  slots_used integer,
  slot_limit integer,
  on_holiday boolean,
  serving_that_day boolean,
  hours_used numeric,
  hours_limit numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.units u where u.id = p_unit and u.church_id = app.current_church_id())
     or not (app.is_unit_lead_of(p_unit) or app.is_purpose_head_of_unit(p_unit)
             or app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])) then
    raise exception 'Not allowed to rota this unit' using errcode = '42501';
  end if;
  return query
    select p.id, p.first_name, p.surname, m.church_role_id,
           app.slots_in_month(p.id, p_date),
           app.personal_limit(p.id),
           app.on_holiday(p.id, p_date),
           exists (select 1 from public.assignments a
                   where a.person_id = p.id and a.serve_date = p_date and a.status in ('planned', 'served')),
           app.hours_in_month(p.id, p_date),
           app.hours_limit(p.id)
    from public.unit_memberships m
    join public.people p on p.id = m.person_id
    where m.unit_id = p_unit and m.status = 'active'
      and p.status = 'active' and p.anonymised_at is null
    order by 9, p.surname, p.first_name;   -- fewest hours this month first
end $$;
revoke all on function public.rota_candidates(uuid, date) from public, anon;
grant execute on function public.rota_candidates(uuid, date) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 4. Flags and dashboards, re-created whole (migrations 9 and 20) with the limit in hours.
-- -------------------------------------------------------------------------------------
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
    and app.hours_in_month(p.id, (date_trunc('month', current_date) - interval '1 month')::date) > app.hours_limit(p.id)
    and app.hours_in_month(p.id, (date_trunc('month', current_date) - interval '2 months')::date) > app.hours_limit(p.id)
  on conflict do nothing;
  get diagnostics v_rows = row_count; v_count := v_count + v_rows;

  return v_count;
end $$;

create or replace function public.church_dashboard()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_church uuid := app.current_church_id();
  v_today date := (now() at time zone 'Europe/London')::date;
  v_q date := date_trunc('quarter', v_today)::date;
  v jsonb;
begin
  -- The leadership group and the roles that plan across the church (app.is_dashboard_reader).
  if v_church is null or not app.is_dashboard_reader() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  with ppl as (   -- current G-Squad members (not left, not anonymised)
    select p.id, p.status, app.engagement_of(p.id) as eng
    from public.people p
    where p.church_id = v_church and p.status <> 'left' and p.anonymised_at is null
  ),
  live as (       -- their live memberships in active units
    select m.person_id, m.unit_id
    from public.unit_memberships m
    join ppl on ppl.id = m.person_id
    join public.units u on u.id = m.unit_id and u.is_active
    where m.status <> 'ended'
  ),
  next_grid as (
    select g.id, g.service_date, g.status, g.version, g.project_id
    from public.service_grids g
    where g.church_id = v_church and g.service_date >= v_today
    order by g.service_date limit 1
  )
  select jsonb_build_object(
    'as_of', v_today,
    'volunteers', (select count(*) from ppl),
    'team_places', (select count(*) from live),
    'multi_unit', (select count(*) from (select person_id from live group by person_id having count(*) >= 2) x),
    'units', (select count(*) from public.units u where u.church_id = v_church and u.is_active),
    'purposes', (select count(*) from public.purposes pu where pu.church_id = v_church),
    'engagement', jsonb_build_object(
        'active',     (select count(*) from ppl where eng = 'active'),
        'occasional', (select count(*) from ppl where eng = 'occasional'),
        'new',        (select count(*) from ppl where eng = 'new'),
        'inactive',   (select count(*) from ppl where eng = 'inactive'),
        'paused',     (select count(*) from ppl where eng = 'paused')),
    'over_limit', (select count(*) from ppl where ppl.status = 'active'
                   and app.hours_in_month(ppl.id, v_today) > app.hours_limit(ppl.id)),   -- migration 28: by hours
    -- SECURITY REVIEW 12 (R03): current members only, like every other figure here.
    'checkins_open', (select count(*) from public.checkin_flags f join ppl on ppl.id = f.person_id where f.status = 'open'),
    'inputs_outstanding', (select count(*) from public.project_inputs i where i.church_id = v_church and i.status <> 'received'),
    'inputs_overdue', (select count(*) from public.project_inputs i
                       where i.church_id = v_church and i.status <> 'received' and i.due_on < v_today),
    'units_table', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'unit_id', u.id, 'name', u.name, 'purpose', pu.name,
                 'headcount', (select count(*) from live where live.unit_id = u.id),
                 'target', u.target_headcount,
                 'active', (select count(*) from live join ppl on ppl.id = live.person_id
                            where live.unit_id = u.id and ppl.eng = 'active'),
                 'open_8_weeks', app.unit_open_slots(u.id, v_today, v_today + 56),
                 'one_to_ones_quarter', app.one_to_ones_seen(u.id, v_q))
               order by u.name)
        from public.units u left join public.purposes pu on pu.id = u.purpose_id
        where u.church_id = v_church and u.is_active), '[]'::jsonb),
    'next_sunday', (select jsonb_build_object(
                      'grid_id', ng.id, 'service_date', ng.service_date, 'status', ng.status, 'version', ng.version,
                      'units_needed', (select count(distinct td.unit_id) from public.team_demand td where td.project_id = ng.project_id),
                      'open_slots', (select coalesce(sum(app.unit_open_slots(x.unit_id, ng.service_date, ng.service_date)), 0)
                                     from (select distinct td.unit_id from public.team_demand td where td.project_id = ng.project_id) x))
                    from next_grid ng)
  ) into v;
  return v;
end $$;

create or replace function public.unit_dashboard(p_unit uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_church uuid := app.current_church_id();
  v_today date := (now() at time zone 'Europe/London')::date;
  v_q date := date_trunc('quarter', v_today)::date;
  v jsonb;
begin
  if not exists (select 1 from public.units u where u.id = p_unit and u.church_id = v_church)
     or not app.can_view_unit(p_unit) then
    raise exception 'Not allowed to view this unit' using errcode = '42501';
  end if;

  with team as (   -- live members of this unit who are current G-Squad members
    select m.person_id, m.leadership_stage_id, p.status, app.engagement_of(p.id) as eng
    from public.unit_memberships m
    join public.people p on p.id = m.person_id
    where m.unit_id = p_unit and m.status <> 'ended' and p.status <> 'left' and p.anonymised_at is null
  )
  select jsonb_build_object(
    'as_of', v_today,
    'headcount', (select count(*) from team),
    'target', (select u.target_headcount from public.units u where u.id = p_unit),
    'engagement', jsonb_build_object(
        'active',     (select count(*) from team where eng = 'active'),
        'occasional', (select count(*) from team where eng = 'occasional'),
        'new',        (select count(*) from team where eng = 'new'),
        'inactive',   (select count(*) from team where eng = 'inactive'),
        'paused',     (select count(*) from team where eng = 'paused')),
    'open_8_weeks', app.unit_open_slots(p_unit, v_today, v_today + 56),
    'one_to_ones_quarter', app.one_to_ones_seen(p_unit, v_q),
    'one_to_ones_visible', app.one_to_ones_seen(p_unit, v_q) is not null,
    'checkins_open', (select count(*) from public.checkin_flags f join team t on t.person_id = f.person_id where f.status = 'open'),
    -- Leadership pipeline: how many are at each stage (counts, in the stages' own order).
    'pipeline', coalesce((
        select jsonb_agg(jsonb_build_object('stage', ls.name, 'count',
                 (select count(*) from team t where t.leadership_stage_id = ls.id)) order by ls.sort_order)
        from public.leadership_stages ls where ls.church_id = v_church), '[]'::jsonb),
    -- Per-member serving figures. Names are not included: the screen joins them from people,
    -- which row-level security already limits to what the caller may see.
    'members', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'person_id', t.person_id,
                 'engagement', t.eng,
                 'slots_this_month', app.slots_in_month(t.person_id, v_today),
                 'slot_limit', app.personal_limit(t.person_id),
                 -- Migration 28: the limit is now counted in hours across all serving.
                 'hours_this_month', app.hours_in_month(t.person_id, v_today),
                 'hours_limit', app.hours_limit(t.person_id),
                 'holiday_from', h.starts_on, 'holiday_to', h.ends_on,
                 'last_one_to_one', (select max(o.held_on) from public.one_to_ones o
                                     where o.person_id = t.person_id and o.unit_id = p_unit
                                       and app.can_read_one_to_one(o.unit_id, o.lead_user_id))))
        from team t
        left join lateral (   -- current or next holiday
          select hh.starts_on, hh.ends_on from public.holidays hh
          where hh.person_id = t.person_id and hh.ends_on >= v_today
          order by hh.starts_on limit 1) h on true), '[]'::jsonb)
  ) into v;
  return v;
end $$;

revoke execute on function app.raise_automatic_flags() from public, anon, authenticated;
revoke all on function public.church_dashboard() from public, anon;
grant execute on function public.church_dashboard() to authenticated, service_role;
revoke all on function public.unit_dashboard(uuid) from public, anon;
grant execute on function public.unit_dashboard(uuid) to authenticated, service_role;
