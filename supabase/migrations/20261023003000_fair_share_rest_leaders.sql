-- =====================================================================================
-- G-Squad Planner: 30. Fair share, rest and leaders' load (steps 3 to 5 of the executive
-- summary; decisions of 25 Oct 2026)
--
--   Step 3, fair share: public.fair_share(month) gives the Church Dashboard, in counts only,
--     how many members served 0, up to 3, 3 to 6, 6 to 9 and over 9 hours that month; the
--     share of all hours the busiest fifth gave; and how many active members have not been
--     asked to serve at all in the last three months.
--   Step 4, rest: at least one Sunday off each month (church_settings.sundays_off_per_month,
--     default 1). Enforced when a Sunday slot is booked, as the hours limit is: only the
--     Operations Lead may go over it, with a written reason, and that is logged.
--   Step 5, leaders' load: leaders holding more than church_settings.leader_roles_max
--     (default 2) of: Team Lead or Deputy Team Lead roles, and live projects they own. Shown
--     as a count on the Dashboard, by name to the G-Squad Coordinator, Resident Pastor,
--     Operations Lead and Pastoral Lead, and raised as a pastoral check-in flag when the
--     leader's account is linked to their G-Squad record. Their serving limit is unchanged.
-- =====================================================================================

alter table public.church_settings
  add column sundays_off_per_month smallint not null default 1 check (sundays_off_per_month between 0 and 3),
  add column leader_roles_max      smallint not null default 2 check (leader_roles_max between 1 and 10);

-- SECURITY REVIEW 20 (F09): the usual slot is in half-hours, as volunteers-needed rows are
-- (review 19, Z08) and as the Serving rules card offers. Before, 2.7 hours could be saved by
-- typing it in, giving limits and bookings that no screen could show or match. NOT VALID, as
-- Z08's range check is, so a stored value cannot stop this migration; new changes are checked.
alter table public.church_settings
  add constraint church_settings_hours_per_slot_half_hours check (hours_per_slot * 2 = trunc(hours_per_slot * 2)) not valid;

-- -------------------------------------------------------------------------------------
-- 1. Sundays (step 4)
-- -------------------------------------------------------------------------------------
-- A Sunday service is a project with a service grid (security review 19, Z04).
-- Distinct Sundays a person serves in the calendar month of p_day (planned or served).
create or replace function app.sundays_served(p_person uuid, p_day date, p_exclude uuid default null) returns integer
language sql stable security definer set search_path = ''
as $$
  select count(distinct a.serve_date)::int
  from public.assignments a
  where a.person_id = p_person and a.status in ('planned', 'served')
    and a.serve_date >= date_trunc('month', p_day)::date
    and a.serve_date < (date_trunc('month', p_day) + interval '1 month')::date
    and (p_exclude is null or a.id <> p_exclude)
    and exists (select 1 from public.service_grids g where g.project_id = a.project_id)
$$;

-- How many Sundays of that calendar month a person may serve: the month's Sundays less the
-- Sundays off the church asks for (never below 0).
create or replace function app.sundays_allowed(p_church uuid, p_day date) returns integer
language sql stable security definer set search_path = ''
as $$
  select greatest(0,
           (select count(*)::int from generate_series(date_trunc('month', p_day)::date,
                                                      (date_trunc('month', p_day) + interval '1 month - 1 day')::date,
                                                      interval '1 day') d
            where extract(isodow from d) = 7)
           - coalesce((select s.sundays_off_per_month from public.church_settings s where s.church_id = p_church), 1))
$$;

revoke all on function app.sundays_served(uuid, date, uuid), app.sundays_allowed(uuid, date) from public, anon, authenticated;
grant execute on function app.sundays_served(uuid, date, uuid), app.sundays_allowed(uuid, date) to service_role;

-- Runs after app.assignment_guard (triggers fire in name order), which has already set the
-- hours, checked the place and taken the per-person monthly lock. Checks only a booking that
-- newly takes up a Sunday: a new slot, a slot moved to another day or project, or one brought
-- back from cancelled or no-show. A second slot on a Sunday already served does not use up
-- another Sunday.
create or replace function app.assignment_rest_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_allowed int;
  v_served int;
  v_off int;
begin
  if app.is_system() or new.status not in ('planned', 'served') then return new; end if;
  if tg_op = 'UPDATE' and new.serve_date = old.serve_date and new.project_id = old.project_id
     and old.status in ('planned', 'served') then
    return new;
  end if;
  if not exists (select 1 from public.service_grids g where g.project_id = new.project_id) then return new; end if;
  -- SECURITY REVIEW 20 (F06): take the same per-person, per-month lock as assignment_guard
  -- (review 19, Z05) here too. Every path that reaches this point has already taken it there,
  -- but only because triggers fire in name order; renaming either trigger would have let two
  -- Sunday bookings at the same moment both pass. The lock is re-entrant, so this costs nothing.
  perform pg_advisory_xact_lock(hashtextextended('gsquad-hours:' || new.person_id::text || ':'
                                                 || to_char(new.serve_date, 'YYYY-MM'), 0));
  -- Already serving that Sunday in another slot: no new Sunday is used.
  if exists (select 1 from public.assignments a
             where a.person_id = new.person_id and a.serve_date = new.serve_date and a.id <> new.id
               and a.status in ('planned', 'served')
               and exists (select 1 from public.service_grids g where g.project_id = a.project_id)) then
    return new;
  end if;
  v_allowed := app.sundays_allowed(new.church_id, new.serve_date);
  v_served  := app.sundays_served(new.person_id, new.serve_date, new.id);
  if v_served + 1 > v_allowed then
    -- SECURITY REVIEW 20 (F07): the written reason goes into the log as well. Before, it lived
    -- only on the slot, where a later change to the slot (by the Team Lead too, on the same day
    -- and project, which this guard lets through) could blank or rewrite it.
    if app.has_role('operations_lead') and coalesce(length(trim(new.override_reason)), 0) >= 5 then
      perform app.audit('override_rest', 'assignments', new.id,
                        jsonb_build_object('person_id', new.person_id, 'month', date_trunc('month', new.serve_date)::date,
                                           'sundays_allowed', v_allowed, 'sundays_before', v_served,
                                           'reason', left(trim(new.override_reason), 500)));
    else
      -- SECURITY REVIEW 20 (F10): say how many Sundays off the church asks for (0 to 3), not
      -- always "one".
      v_off := coalesce((select s.sundays_off_per_month from public.church_settings s where s.church_id = new.church_id), 1);
      raise exception 'This person already serves % of the % Sundays they may serve this month (% Sunday% off a month)',
        v_served, v_allowed, v_off, case when v_off = 1 then '' else 's' end
        using errcode = '23514', hint = 'The Operations Lead can override with a written reason.';
    end if;
  end if;
  return new;
end $$;
revoke all on function app.assignment_rest_guard() from public, anon, authenticated;
grant execute on function app.assignment_rest_guard() to service_role;
create trigger assignment_rest_guard before insert or update on public.assignments
  for each row execute function app.assignment_rest_guard();

-- Who can serve, as migration 28 plus Sundays served and allowed that month.
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
  hours_limit numeric,
  sundays_served integer,
  sundays_allowed integer)
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
           app.hours_limit(p.id),
           app.sundays_served(p.id, p_date),
           app.sundays_allowed(p.church_id, p_date)
    from public.unit_memberships m
    join public.people p on p.id = m.person_id
    where m.unit_id = p_unit and m.status = 'active'
      and p.status = 'active' and p.anonymised_at is null
    order by 9, p.surname, p.first_name;   -- fewest hours this month first
end $$;
revoke all on function public.rota_candidates(uuid, date) from public, anon;
grant execute on function public.rota_candidates(uuid, date) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 2. Leaders' load (step 5)
-- -------------------------------------------------------------------------------------
-- One row per active leader account: Team Lead and Deputy roles held, live projects owned
-- (submitted, approved or under way, not Sunday services, which the Operations Lead owns by
-- design), and whether that is more than the church allows.
-- SECURITY REVIEW 20 (F05): for one church (p_church), or every church only for the nightly
-- job (null). Before, the Dashboard and the named list worked out every leader in every church
-- on each call and filtered afterwards.
-- SECURITY REVIEW 20 (F04): roles count only in active teams (a role left on a closed team is
-- not load), and a Sunday service is a project with a service grid (review 19, Z04). Before,
-- any project flagged is_sunday_service was left out, a flag the owner of a church project
-- sets themselves, so a leader could take their own projects out of the count.
create or replace function app.leader_loads(p_church uuid default null)
returns table (church_id uuid, user_id uuid, person_id uuid, display_name text, team_roles integer, live_projects integer, over boolean)
language sql stable security definer set search_path = ''
as $$
  select u.church_id, u.id, u.person_id, u.display_name, r.n, pr.n,
         (r.n + pr.n) > coalesce(s.leader_roles_max, 2)
  from public.app_users u
  left join public.church_settings s on s.church_id = u.church_id
  cross join lateral (select count(*)::int as n from public.role_assignments ra
                      where ra.user_id = u.id and ra.is_active and ra.role in ('unit_lead', 'deputy_unit_lead')
                        and (ra.unit_id is null
                             or exists (select 1 from public.units un where un.id = ra.unit_id and un.is_active))) r
  cross join lateral (select count(*)::int as n from public.projects p
                      where p.owner_user_id = u.id and p.status in ('submitted', 'approved', 'in_progress')
                        and not exists (select 1 from public.service_grids g where g.project_id = p.id)) pr
  where u.is_active and (p_church is null or u.church_id = p_church)
$$;
revoke all on function app.leader_loads(uuid) from public, anon, authenticated;
grant execute on function app.leader_loads(uuid) to service_role;

-- By name, for those who look after leaders.
create or replace function public.leaders_carrying_too_much()
returns table (user_id uuid, display_name text, team_roles integer, live_projects integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if app.current_church_id() is null
     or not app.has_any_role(array['gsquad_coordinator','resident_pastor','operations_lead','pastoral_lead']::public.app_role[]) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select l.user_id, l.display_name, l.team_roles, l.live_projects
    from app.leader_loads(app.current_church_id()) l
    where l.over
    order by l.team_roles + l.live_projects desc, l.display_name;
end $$;
revoke all on function public.leaders_carrying_too_much() from public, anon;
grant execute on function public.leaders_carrying_too_much() to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 3. Fair share (step 3): counts only, for the Church Dashboard audience
-- -------------------------------------------------------------------------------------
create or replace function public.fair_share(p_month date)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_church uuid := app.current_church_id();
  v_from date := date_trunc('month', coalesce(p_month, current_date))::date;
  v_to date := (date_trunc('month', coalesce(p_month, current_date)) + interval '1 month')::date;
  v jsonb;
begin
  -- The Church Dashboard's readers (migration 22: not the TECi Coordinator).
  if v_church is null or not app.is_dashboard_reader() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  with members as (
    -- Active members in at least one team.
    -- SECURITY REVIEW 20 (F08): ... that is still running, as the Church Dashboard counts
    -- (migration 28). Before, members left only in a closed team were counted as "not asked".
    select p.id from public.people p
    where p.church_id = v_church and p.status = 'active' and p.anonymised_at is null
      and exists (select 1 from public.unit_memberships m join public.units u on u.id = m.unit_id and u.is_active
                  where m.person_id = p.id and m.status = 'active')
  ),
  hrs as (
    -- SECURITY REVIEW 20 (F05): only this month's live slots are joined (the person and date
    -- index), not every slot each member ever had.
    select m.id, coalesce(sum(a.hours), 0) as h
    from members m
    left join public.assignments a on a.person_id = m.id and a.status in ('planned', 'served')
                                   and a.serve_date >= v_from and a.serve_date < v_to
    group by m.id
  ),
  ranked as (
    select h, row_number() over (order by h desc) as rn, count(*) over () as n from hrs
  )
  select jsonb_build_object(
    'month', v_from,
    'members', (select count(*) from hrs),
    'bands', jsonb_build_object(
      'none',        (select count(*) from hrs where h = 0),
      'up_to_3',     (select count(*) from hrs where h > 0 and h <= 3),
      'three_to_6',  (select count(*) from hrs where h > 3 and h <= 6),
      'six_to_9',    (select count(*) from hrs where h > 6 and h <= 9),
      'over_9',      (select count(*) from hrs where h > 9)),
    -- Share of all hours given by the busiest fifth; null with no hours.
    -- SECURITY REVIEW 20 (F01): and null with fewer than 10 members, so the busiest fifth is
    -- always at least two people. Before, with five members or fewer the "fifth" was one person
    -- and, with the church's total hours (also returned), every dashboard reader, Team Leads
    -- included, could work out that one person's hours. The total is no longer returned: the
    -- screen never showed it.
    'busiest_fifth_share', (select case when sum(h) > 0 and count(*) >= 10
                                        then round(100 * sum(h) filter (where rn <= ceil(n * 0.2)) / sum(h))
                                   end from ranked),
    -- Active members with no slot at all (any status but cancelled) in the three months to the
    -- end of this one.
    'not_asked_3_months', (select count(*) from members m
                           where not exists (select 1 from public.assignments a
                                             where a.person_id = m.id and a.status <> 'cancelled'
                                               and a.serve_date >= (v_from - interval '2 months')::date
                                               and a.serve_date < v_to)),
    'leaders_over', (select count(*) from app.leader_loads(v_church) l where l.over)
  ) into v;
  return v;
end $$;
revoke all on function public.fair_share(date) from public, anon;
grant execute on function public.fair_share(date) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 4. The nightly flags, re-created whole from migration 28 with leaders carrying too much.
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

  -- Migration 30 (decision of 25 Oct 2026): leaders holding more leadership at once than the
  -- church allows (Team Lead or Deputy roles, plus live projects they own), when their account
  -- is linked to their G-Squad record. A flag only: their serving limit is unchanged.
  -- SECURITY REVIEW 20 (F02): only on a current G-Squad member (not left, paused or
  -- anonymised), and not again within 90 days of the last such check-in being closed. Before,
  -- a flag closed by the Pastoral Lead ("we have talked") was raised again the next night for
  -- as long as the leader held the same roles, and a flag could be raised on an anonymised record.
  insert into public.checkin_flags (church_id, person_id, source, raised_by)
  select l.church_id, l.person_id, 'leader_load', null
  from app.leader_loads(null) l
  join public.people p on p.id = l.person_id and p.church_id = l.church_id
  where l.over and p.status = 'active' and p.anonymised_at is null
    and not exists (select 1 from public.checkin_flags f
                    where f.person_id = l.person_id and f.source = 'leader_load'
                      and (f.status = 'open' or f.closed_at > now() - interval '90 days'))
  on conflict do nothing;
  get diagnostics v_rows = row_count; v_count := v_count + v_rows;

  return v_count;
end $$;
revoke execute on function app.raise_automatic_flags() from public, anon, authenticated;
