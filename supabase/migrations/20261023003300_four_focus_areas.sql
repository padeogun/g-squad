-- =====================================================================================
-- Migration 33: the four focus areas (decision of 24 Nov 2026, Paul).
--
-- The global church assesses everything against four areas:
--   discipleship   Discipleship and maturity: discipleship courses and the Greatness Track,
--                  maturity habits (evangelism, prayer, water and Holy Spirit baptism).
--   assimilation   Church level: every visitor engaged within 48 hours and connected to a
--                  community. G-Squad level: a member feels part of the family, is active in a
--                  community, has adopted ASHLIE, and feels at home beyond their own team.
--   pastoral_care  Check-ins, no one going through difficult times alone, regular one-to-ones
--                  with their team's leadership, special moments celebrated.
--   soul_winning   Every effort to bring more people to accept Jesus as Lord and Saviour.
--
-- Three levels, as Paul set out:
--   1. Events: before approval the owner names the areas the event aims at, one of them
--      primary, each with an intended outcome (required to approve). After the event each area
--      is rated on five levels (0 not achieved .. 4 fully), with the event's counts; every area
--      it aimed at must be rated before it can close. Events are assessed; people never are.
--   2. Teams: a quarterly team conversation, one short note per area (what went well, what
--      next), written by the Team Lead.
--   3. Members: in the one-to-one, the member chooses one area to grow in this quarter and a
--      next step; the next one-to-one records how that step went. A commitment, never a score
--      (in the spirit of R20: values and people are not rated).
-- Soul winning at events is counts only (first-time guests, decisions for Christ), never names.
-- =====================================================================================

create type public.focus_area as enum ('discipleship', 'assimilation', 'pastoral_care', 'soul_winning');
create type public.growth_progress as enum ('done', 'in_progress', 'not_yet');

-- An event that the four areas apply to: an event (migration 32), not a Sunday service (the
-- Sunday grid has its own rhythm) and not a routine team activity.
create or replace function app.is_focus_event(p_project uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.projects p
                 where p.id = p_project and p.is_event and not p.is_sunday_service)
$$;
revoke all on function app.is_focus_event(uuid) from public, anon;
grant execute on function app.is_focus_event(uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 1. Events: what the event aims at (planned) ...
-- -------------------------------------------------------------------------------------
create table public.project_focus (
  id                uuid primary key default gen_random_uuid(),
  church_id         uuid not null,
  project_id        uuid not null,
  area              public.focus_area not null,
  is_primary        boolean not null default false,
  intended_outcome  text not null check (length(btrim(intended_outcome)) between 1 and 500),
  target_count      integer check (target_count between 0 and 100000),   -- optional, e.g. 40 first-time guests
  updated_by        uuid default auth.uid(),
  updated_at        timestamptz not null default now(),
  unique (project_id, area),
  foreign key (church_id, project_id) references public.projects(church_id, id) on delete cascade
);
-- One primary area per event.
create unique index project_focus_one_primary on public.project_focus (project_id) where is_primary;
comment on table public.project_focus is
  'The focus areas an event aims at, named before approval (migration 33). One is primary.';

-- ... how it went, per area (rated after the event) ...
create table public.project_focus_review (
  id           uuid primary key default gen_random_uuid(),
  church_id    uuid not null,
  project_id   uuid not null,
  area         public.focus_area not null,
  rating       smallint not null check (rating between 0 and 4),  -- 0 not achieved, 1 a little, 2 partly, 3 mostly, 4 fully
  story        text check (length(story) <= 1000),
  reviewed_by  uuid default auth.uid(),
  reviewed_at  timestamptz not null default now(),
  unique (project_id, area),
  foreign key (church_id, project_id) references public.projects(church_id, id) on delete cascade
);
comment on table public.project_focus_review is
  'After the event: each focus area rated 0 (not achieved) to 4 (fully), with a short story. The event is rated, never a person.';

-- ... and the event's counts. Counts only: no names, so nothing here identifies a guest.
create table public.project_outcomes (
  project_id              uuid primary key,
  church_id               uuid not null,
  first_time_guests       integer check (first_time_guests between 0 and 100000),
  decisions_for_christ    integer check (decisions_for_christ between 0 and 100000),
  guests_contacted_48h    integer check (guests_contacted_48h between 0 and 100000),
  connected_to_community  integer check (connected_to_community between 0 and 100000),
  next_step_signups       integer check (next_step_signups between 0 and 100000),
  care_followups          integer check (care_followups between 0 and 100000),
  updated_by              uuid default auth.uid(),
  updated_at              timestamptz not null default now(),
  -- Guests followed up within 48 hours cannot be more than the guests who came.
  check (guests_contacted_48h is null or first_time_guests is null or guests_contacted_48h <= first_time_guests),
  foreign key (church_id, project_id) references public.projects(church_id, id) on delete cascade
);
comment on table public.project_outcomes is
  'Event counts for the four focus areas, counts only (decision of 24 Nov 2026: no names).';

-- Who may write, and when. The aims are part of what is approved, so they change only while
-- the event is a draft or waiting for a decision; the review and counts only once the event
-- has started and before it is closed. The database sets who wrote it and when.
create or replace function app.project_focus_write_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  p public.projects;
  v_row_project uuid := case when tg_op = 'DELETE' then old.project_id else new.project_id end;
begin
  if app.is_system() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'UPDATE' and (new.project_id <> old.project_id or new.church_id <> old.church_id) then
    raise exception 'An event''s focus record cannot be moved to another event' using errcode = '42501';
  end if;
  select * into p from public.projects where id = v_row_project;
  if not found or not p.is_event or p.is_sunday_service then
    raise exception 'Focus areas are recorded for events' using errcode = '23514';
  end if;
  if not app.can_manage_project(p.id) then
    raise exception 'Only the event''s owner or the Operations Lead can change this' using errcode = '42501';
  end if;
  if tg_table_name = 'project_focus' then
    if p.status not in ('draft', 'submitted') then
      raise exception 'The focus areas were part of the approval and cannot be changed now' using errcode = '23514';
    end if;
  else
    if p.status not in ('approved', 'in_progress') then
      raise exception 'The review is written once the event is approved and before it is closed' using errcode = '23514';
    end if;
    if p.starts_at > now() then
      raise exception 'The review is written once the event has started' using errcode = '23514';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if tg_table_name = 'project_focus_review' then
    new.reviewed_by := (select auth.uid());
    new.reviewed_at := now();
  else
    new.updated_by := (select auth.uid());
    new.updated_at := now();
  end if;
  return new;
end $$;
revoke all on function app.project_focus_write_guard() from public, anon, authenticated;
grant execute on function app.project_focus_write_guard() to service_role;
create trigger project_focus_write_guard before insert or update or delete on public.project_focus
  for each row execute function app.project_focus_write_guard();
create trigger project_focus_write_guard before insert or update or delete on public.project_focus_review
  for each row execute function app.project_focus_write_guard();
create trigger project_focus_write_guard before insert or update or delete on public.project_outcomes
  for each row execute function app.project_focus_write_guard();

-- Read by every leader of the church, as the event plan is (event_plans_read); written by the
-- event's owner or the Operations Lead, under the guard above.
alter table public.project_focus enable row level security;
alter table public.project_focus_review enable row level security;
alter table public.project_outcomes enable row level security;
revoke all on public.project_focus, public.project_focus_review, public.project_outcomes from public, anon;
grant select, insert, update, delete on public.project_focus, public.project_focus_review, public.project_outcomes to authenticated;

create policy project_focus_read on public.project_focus for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy project_focus_write on public.project_focus for all to authenticated
  using (church_id = (select app.current_church_id()) and app.can_manage_project(project_id))
  with check (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));
create policy project_focus_review_read on public.project_focus_review for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy project_focus_review_write on public.project_focus_review for all to authenticated
  using (church_id = (select app.current_church_id()) and app.can_manage_project(project_id))
  with check (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));
create policy project_outcomes_read on public.project_outcomes for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy project_outcomes_write on public.project_outcomes for all to authenticated
  using (church_id = (select app.current_church_id()) and app.can_manage_project(project_id))
  with check (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));

-- Approval needs the aims; closing needs every aimed area rated. Named so it fires after
-- app.project_guard (BEFORE triggers run in name order), which may still send a project back.
create or replace function app.project_outcome_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return new; end if;
  if not new.is_event or new.is_sunday_service then return new; end if;
  if new.status = 'approved' and old.status is distinct from 'approved'
     and not exists (select 1 from public.project_focus f where f.project_id = new.id and f.is_primary) then
    raise exception 'Name the event''s focus areas, and which one is primary, before it is approved' using errcode = '23514';
  end if;
  if new.status = 'done' and old.status is distinct from 'done'
     and exists (select 1 from public.project_focus f
                 where f.project_id = new.id
                   and not exists (select 1 from public.project_focus_review r
                                   where r.project_id = f.project_id and r.area = f.area)) then
    raise exception 'Rate each focus area the event aimed at before closing it' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function app.project_outcome_guard() from public, anon, authenticated;
grant execute on function app.project_outcome_guard() to service_role;
create trigger project_outcome_guard before update on public.projects
  for each row execute function app.project_outcome_guard();

-- -------------------------------------------------------------------------------------
-- 2. Teams: the quarterly conversation on the four areas.
-- -------------------------------------------------------------------------------------
create table public.unit_focus_reflections (
  id             uuid primary key default gen_random_uuid(),
  church_id      uuid not null,
  unit_id        uuid not null,
  quarter_start  date not null check (extract(day from quarter_start) = 1 and extract(month from quarter_start) in (1, 4, 7, 10)),
  area           public.focus_area not null,
  went_well      text check (length(went_well) <= 600),
  next_step      text check (length(next_step) <= 600),
  check (length(btrim(coalesce(went_well, ''))) > 0 or length(btrim(coalesce(next_step, ''))) > 0),
  updated_by     uuid default auth.uid(),
  updated_at     timestamptz not null default now(),
  unique (unit_id, quarter_start, area),
  foreign key (church_id, unit_id) references public.units(church_id, id) on delete cascade
);
comment on table public.unit_focus_reflections is
  'A team''s quarterly conversation on the four focus areas: what went well and what next, per area (migration 33).';

-- The Team Lead writes this quarter's notes, or catches up on last quarter's; earlier quarters
-- are history. The team, quarter and area of a note do not change.
create or replace function app.unit_reflection_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_q date := date_trunc('quarter', (now() at time zone 'Europe/London'))::date;
  v_row public.unit_focus_reflections := case when tg_op = 'DELETE' then old else new end;
begin
  if app.is_system() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'UPDATE' and (new.unit_id <> old.unit_id or new.quarter_start <> old.quarter_start
                           or new.area <> old.area or new.church_id <> old.church_id) then
    raise exception 'A note''s team, quarter and area cannot be changed' using errcode = '42501';
  end if;
  if v_row.quarter_start not in (v_q, (v_q - interval '3 months')::date)
     or (tg_op = 'UPDATE' and old.quarter_start not in (v_q, (v_q - interval '3 months')::date)) then
    raise exception 'Notes are written for this quarter or the last one' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  new.updated_by := (select auth.uid());
  new.updated_at := now();
  return new;
end $$;
revoke all on function app.unit_reflection_guard() from public, anon, authenticated;
grant execute on function app.unit_reflection_guard() to service_role;
create trigger unit_reflection_guard before insert or update or delete on public.unit_focus_reflections
  for each row execute function app.unit_reflection_guard();

-- Read by those who see the team (its lead and deputy, its Purpose Head, the Coordinator, the
-- Operations Lead and the Resident Pastor); written by the team's lead.
alter table public.unit_focus_reflections enable row level security;
revoke all on public.unit_focus_reflections from public, anon;
grant select, insert, update, delete on public.unit_focus_reflections to authenticated;
create policy unit_reflections_read on public.unit_focus_reflections for select to authenticated
  using (church_id = (select app.current_church_id()) and app.can_view_unit(unit_id));
create policy unit_reflections_write on public.unit_focus_reflections for all to authenticated
  using (church_id = (select app.current_church_id()) and app.is_unit_lead_of(unit_id))
  with check (church_id = (select app.current_church_id()) and app.is_unit_lead_of(unit_id));

-- -------------------------------------------------------------------------------------
-- 3. Members: one area to grow in this quarter, a next step, and how the last step went.
--    On the one-to-one itself, so it is read by those who read the one-to-one. Faith details
--    stay in the restricted "walk with God" note; the page says so beside these fields.
-- -------------------------------------------------------------------------------------
alter table public.one_to_ones
  add column growth_area public.focus_area,
  add column growth_step text check (length(growth_step) <= 500),
  add column last_step   public.growth_progress,
  add constraint one_to_ones_growth_step_needs_area check (growth_step is null or growth_area is not null);
comment on column public.one_to_ones.growth_area is 'The focus area the member chose to grow in this quarter (migration 33).';
comment on column public.one_to_ones.growth_step is 'The next step they agreed. A commitment, never a score.';
comment on column public.one_to_ones.last_step is 'How the step agreed at their last one-to-one went.';

-- -------------------------------------------------------------------------------------
-- 4. The quarter at a glance, counts only, for the Church Dashboard. Read by the roles that
--    read the monthly report (it includes baptism counts, as that report does).
-- -------------------------------------------------------------------------------------
create or replace function public.focus_areas_summary(p_quarter date default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_church uuid := app.current_church_id();
  v_q date := date_trunc('quarter', coalesce(p_quarter, (now() at time zone 'Europe/London')::date))::date;
  v_end date := (v_q + interval '3 months')::date;
  v_areas jsonb;
  v_outcomes jsonb;
  v_gsquad jsonb;
begin
  if not app.has_any_role(array['gsquad_coordinator','resident_pastor','purpose_head',
                                'operations_lead','pastoral_lead']::public.app_role[]) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  -- Events in the quarter (by their London start date), not cancelled.
  with ev as (
    select p.id from public.projects p
    where p.church_id = v_church and p.is_event and not p.is_sunday_service and p.status <> 'cancelled'
      and (p.starts_at at time zone 'Europe/London')::date >= v_q
      and (p.starts_at at time zone 'Europe/London')::date < v_end
  )
  select jsonb_agg(jsonb_build_object(
           'area', a.area,
           'events_aimed', (select count(*) from public.project_focus f join ev on ev.id = f.project_id where f.area = a.area),
           'events_primary', (select count(*) from public.project_focus f join ev on ev.id = f.project_id where f.area = a.area and f.is_primary),
           'events_rated', (select count(*) from public.project_focus_review r join ev on ev.id = r.project_id where r.area = a.area),
           'rating_counts', (select jsonb_agg((select count(*) from public.project_focus_review r join ev on ev.id = r.project_id
                                               where r.area = a.area and r.rating = lvl) order by lvl)
                             from generate_series(0, 4) lvl),
           'members_growing', (select count(*) from public.one_to_ones o
                               where o.church_id = v_church and o.quarter_start = v_q and o.growth_area = a.area),
           'teams_talked', (select count(distinct u.unit_id) from public.unit_focus_reflections u
                            where u.church_id = v_church and u.quarter_start = v_q and u.area = a.area)
         ) order by a.area)
    into v_areas
  from unnest(enum_range(null::public.focus_area)) as a(area);

  select jsonb_build_object(
           'events', count(*),
           'first_time_guests', coalesce(sum(o.first_time_guests), 0),
           'decisions_for_christ', coalesce(sum(o.decisions_for_christ), 0),
           'guests_contacted_48h', coalesce(sum(o.guests_contacted_48h), 0),
           'connected_to_community', coalesce(sum(o.connected_to_community), 0),
           'next_step_signups', coalesce(sum(o.next_step_signups), 0),
           'care_followups', coalesce(sum(o.care_followups), 0))
    into v_outcomes
  from public.project_outcomes o join public.projects p on p.id = o.project_id
  where o.church_id = v_church and p.status <> 'cancelled'
    and (p.starts_at at time zone 'Europe/London')::date >= v_q
    and (p.starts_at at time zone 'Europe/London')::date < v_end;

  -- The G-Squad itself, from what the app already holds.
  select jsonb_build_object(
           'members', (select count(*) from public.people p
                       where p.church_id = v_church and p.status = 'active' and p.anonymised_at is null),
           'in_community', (select count(*) from public.people p
                            where p.church_id = v_church and p.status = 'active' and p.anonymised_at is null
                              and p.greatness_community_id is not null),
           'one_to_ones', (select count(distinct o.person_id) from public.one_to_ones o
                           where o.church_id = v_church and o.quarter_start = v_q),
           'steps_done', (select count(*) from public.one_to_ones o
                          where o.church_id = v_church and o.quarter_start = v_q and o.last_step = 'done'),
           'steps_followed_up', (select count(*) from public.one_to_ones o
                                 where o.church_id = v_church and o.quarter_start = v_q and o.last_step is not null),
           'open_checkins', (select count(*) from public.checkin_flags f where f.church_id = v_church and f.status = 'open'),
           'celebrations_opted_in', (select count(*) from public.people p
                                     where p.church_id = v_church and p.status = 'active' and p.celebration_opt_in),
           'recognitions', (select count(*) from public.recognitions r
                            where r.church_id = v_church and r.recognised_on >= v_q and r.recognised_on < v_end),
           'in_teci', (select count(*) from public.people p
                       where p.church_id = v_church and p.status = 'active' and p.teci_stage_id is not null),
           'water_baptisms', (select count(*) from public.person_faith f
                              where f.church_id = v_church and f.water_baptism_date >= v_q and f.water_baptism_date < v_end),
           'spirit_baptisms', (select count(*) from public.person_faith f
                               where f.church_id = v_church and f.holy_spirit_baptism_date >= v_q
                                 and f.holy_spirit_baptism_date < v_end))
    into v_gsquad;

  return jsonb_build_object('quarter_start', v_q, 'quarter_end', (v_end - 1),
                            'areas', v_areas, 'outcomes', v_outcomes, 'gsquad', v_gsquad);
end $$;
revoke all on function public.focus_areas_summary(date) from public, anon;
grant execute on function public.focus_areas_summary(date) to authenticated, service_role;

-- project_readiness gains the focus check (re-created whole from migration 25 with the one
-- marked addition), so the page shows it with the other checks before approval.
create or replace function public.project_readiness(p_project uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  p public.projects;
  v_plan public.event_plans;
  v_has_plan boolean;
  v_weeks_needed int;
  v_weeks_to_go numeric;
begin
  select * into p from public.projects where id = p_project and church_id = app.current_church_id();
  if not found then
    raise exception 'Project not found' using errcode = '42501';
  end if;
  if not (app.can_manage_project(p.id)
          or app.is_project_approver(p.level, p.unit_id)
          or app.has_any_role(array['resident_pastor','purpose_head','gsquad_coordinator','unit_lead',
                                    'deputy_unit_lead','operations_lead']::public.app_role[])) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  select * into v_plan from public.event_plans e where e.project_id = p.id;
  v_has_plan := found;
  if v_has_plan then
    select case v_plan.size when 'small' then s.lead_time_small_weeks
                            when 'medium' then s.lead_time_medium_weeks
                            else s.lead_time_large_weeks end
      into v_weeks_needed from public.church_settings s where s.church_id = p.church_id;
  end if;
  v_weeks_to_go := round((extract(epoch from (p.starts_at - now())) / 604800)::numeric, 1);

  return jsonb_build_object(
    'status', p.status,
    'is_event', v_has_plan,
    -- R14: weeks before the start, against the minimum for the event's size.
    'lead_time', case when v_has_plan then jsonb_build_object(
        'size', v_plan.size, 'weeks_to_go', v_weeks_to_go, 'weeks_needed', v_weeks_needed,
        'ok', p.starts_at >= now() + make_interval(weeks => coalesce(v_weeks_needed, 0))) end,
    -- R15: a High complexity event needs a planning committee.
    'committee', case when v_has_plan then jsonb_build_object(
        'needed', v_plan.complexity = 'high', 'ok', v_plan.complexity <> 'high' or v_plan.has_planning_committee) end,
    -- R16: budget approved or not needed.
    'budget', case when v_has_plan then jsonb_build_object(
        'status', v_plan.budget_status, 'ok', v_plan.budget_status in ('approved', 'not_needed')) end,
    -- R6: the first unit-month short of volunteers, and whether an action is recorded.
    'shortfall', app.project_shortfall(p.id),
    'shortfall_action', p.shortfall_action,
    -- R9: required inputs still to come (closing needs none).
    'inputs_outstanding', (select count(*) from public.project_inputs i
                           where i.project_id = p.id and i.is_required and i.status <> 'received'),
    'inputs_overdue', (select count(*) from public.project_inputs i
                       where i.project_id = p.id and i.status <> 'received' and i.due_on < current_date),
    'review_done', case when v_has_plan then v_plan.review_completed_at is not null end,
    -- Migration 33: the focus areas (needed to approve an event; each rated before closing).
    'focus', case when p.is_event and not p.is_sunday_service then jsonb_build_object(
        'named', (select count(*) from public.project_focus f where f.project_id = p.id),
        'ok', exists (select 1 from public.project_focus f where f.project_id = p.id and f.is_primary),
        'unrated', (select count(*) from public.project_focus f where f.project_id = p.id
                    and not exists (select 1 from public.project_focus_review r
                                    where r.project_id = f.project_id and r.area = f.area))) end,
    -- Who may do what next (the guard decides; this is for showing the right buttons).
    'can_manage', app.can_manage_project(p.id),
    'can_approve', app.is_project_approver(p.level, p.unit_id),
    'self_approval', app.is_project_approver(p.level, p.unit_id) and p.owner_user_id = (select auth.uid())
  );
end $$;
revoke all on function public.project_readiness(uuid) from public, anon;
grant execute on function public.project_readiness(uuid) to authenticated, service_role;
