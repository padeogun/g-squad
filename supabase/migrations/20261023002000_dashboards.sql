-- =====================================================================================
-- G-Squad Planner: 20. Dashboards (slice 3)
--   public.church_dashboard()  totals for the leadership group: counts only, no names or
--                              personal details (spec: "Leadership group view: totals only").
--   public.unit_dashboard(u)   one unit, for those with that unit in scope: its Unit Lead and
--                              Purpose Head, the Resident Pastor, Operations Lead and G-Squad
--                              Coordinator. Includes per-member serving figures (slots this month
--                              against their limit, engagement, holiday, last one-to-one) for
--                              people the caller can already see through row-level security.
-- Both are SECURITY DEFINER because the figures need rows the caller can't read one by one
-- (e.g. slots held in other units count toward one limit). Each checks the caller first and
-- returns only what its audience may know.
-- Sensitive data stays out: no faith fields, no pastoral notes, no one-to-one content, and
-- check-in flags only as counts (never reasons, which flags don't carry anyway).
-- SECURITY REVIEW 12 (R01): one-to-one dates and counts follow the one-to-ones read rule
-- (app.can_read_one_to_one: the writing lead, the unit's Purpose Head, the Coordinator and the
-- Resident Pastor). The Operations Lead, and leaders of other units, get null, not 0.
-- SECURITY REVIEW 12 (R02): the two helpers below run as the caller (security invoker) and
-- are not callable by signed-in users; only the dashboards, which run as the owner, use them.
-- =====================================================================================

-- Live engagement of one person, as v_engagement defines it (reused below without RLS).
create or replace function app.engagement_of(p_person uuid) returns text
language sql stable security invoker set search_path = ''
as $$
  select e.engagement from public.v_engagement e where e.person_id = p_person
$$;
revoke all on function app.engagement_of(uuid) from public, anon, authenticated;
grant execute on function app.engagement_of(uuid) to service_role;

-- Open slots a unit has between two dates: each Sunday/project's demand minus the live
-- slots filled for the same project and date (never below zero per demand row).
create or replace function app.unit_open_slots(p_unit uuid, p_from date, p_to date) returns integer
language sql stable security invoker set search_path = ''
as $$
  select coalesce(sum(greatest(d.need - coalesce(f.filled, 0), 0)), 0)::int
  from (
    select td.project_id, td.on_date, sum(td.slots_needed) as need
    from public.team_demand td
    join public.projects p on p.id = td.project_id and p.status <> 'cancelled'
    where td.unit_id = p_unit and td.on_date between p_from and p_to
    group by td.project_id, td.on_date
  ) d
  left join (
    select a.project_id, a.serve_date, count(*) as filled
    from public.assignments a
    where a.unit_id = p_unit and a.status in ('planned', 'served') and a.serve_date between p_from and p_to
    group by a.project_id, a.serve_date
  ) f on f.project_id = d.project_id and f.serve_date = d.on_date
$$;
revoke all on function app.unit_open_slots(uuid, date, date) from public, anon, authenticated;
grant execute on function app.unit_open_slots(uuid, date, date) to service_role;

-- One-to-ones held in a unit this quarter, counting only those the caller may read
-- (app.can_read_one_to_one). Null when the caller has no read right in this unit at all
-- (not its lead or Purpose Head, nor Coordinator or Resident Pastor), so a screen can say
-- "not shown" instead of a misleading 0. Called only from the dashboards below.
create or replace function app.one_to_ones_seen(p_unit uuid, p_quarter date) returns integer
language sql stable security invoker set search_path = ''
as $$
  select case
    when app.has_any_role(array['resident_pastor','gsquad_coordinator']::public.app_role[])
      or app.is_purpose_head_of_unit(p_unit) or app.is_unit_lead_of(p_unit)
    then (select count(*)::int from public.one_to_ones o
          where o.unit_id = p_unit and o.quarter_start = p_quarter
            and o.church_id = app.current_church_id()
            and app.can_read_one_to_one(o.unit_id, o.lead_user_id))
  end
$$;
revoke all on function app.one_to_ones_seen(uuid, date) from public, anon, authenticated;
grant execute on function app.one_to_ones_seen(uuid, date) to service_role;

-- -------------------------------------------------------------------------------------
-- Church Dashboard: totals only.
-- -------------------------------------------------------------------------------------
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
  -- The leadership group and the roles that plan across the church.
  if v_church is null or not app.has_any_role(array['resident_pastor','purpose_head','unit_lead','gsquad_coordinator',
                                                    'operations_lead','teci_coordinator','pastoral_lead']::public.app_role[]) then
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
                   and app.slots_in_month(ppl.id, v_today) > app.personal_limit(ppl.id)),
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
revoke all on function public.church_dashboard() from public, anon;
grant execute on function public.church_dashboard() to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- Unit Dashboard: one unit, for those with it in scope.
-- -------------------------------------------------------------------------------------
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
     or not (app.is_unit_lead_of(p_unit) or app.is_purpose_head_of_unit(p_unit)
             or app.has_any_role(array['resident_pastor','operations_lead','gsquad_coordinator']::public.app_role[])) then
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
revoke all on function public.unit_dashboard(uuid) from public, anon;
grant execute on function public.unit_dashboard(uuid) to authenticated, service_role;
