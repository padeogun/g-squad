-- =====================================================================================
-- G-Squad Planner: 32. A run of show for every event; the G-Squad Coordinator approves
-- extra teams and extra concurrent projects (decisions of 12 Nov 2026)
--
-- 1. Every event has a run of show. The Sunday service grid is the run of show for a Sunday;
--    church events, outreach and team events now get the same thing (service_grids, with
--    segments and printed blocks). Routine team activities (rehearsals, training, team meetings)
--    and the monthly Brief do not.
--      * projects.is_event: true unless the owner marks a team project as a routine team
--        activity (church projects are always events); the Brief's project is set false.
--      * The owner (or the Operations Lead) builds and finalises an event's run of show; the
--        event's approver approves it: the Purpose Head for a team event, the Operations Lead
--        for a church event (decision). The Resident Pastor still approves Sunday grids.
--      * An event cannot be approved until its run of show has been started.
--      * Versions and re-approval after a change work as for Sundays (R11).
-- 2. What makes a project a Sunday service. Until now "a project with a service grid" (security
--    review 19, Z04), because only the Operations Lead made grids. Events now have grids too,
--    so a Sunday is a grid marked is_sunday, which is set by the database from the project's
--    is_sunday_service flag, and that flag can now be set only by the Operations Lead (or
--    create_sunday_service) and never changed afterwards. The hours, rest, booking and
--    leaders'-load rules use app.is_sunday_project() instead of "has a grid".
-- 3. The Resident Pastor does not attend to operational tasks (decision). The G-Squad
--    Coordinator now approves:
--      * a member joining more teams than the church allows (R3, default 2), before the
--        Resident Pastor's;
--      * NEW: a member serving on a third project whose dates overlap two others they already
--        serve on (church_settings.projects_before_approval, default 2). Sunday services do not
--        count. Such a booking waits as "pending_approval" (migration 31).
--    public.decide_serving_approval() is how the Coordinator approves or declines;
--    public.serving_approvals() lists what is waiting and what was decided in the last 90 days,
--    for the Coordinator, the Operations Lead and, read-only, the Resident Pastor (kept in the
--    loop, decision).
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Events and Sundays on projects
-- -------------------------------------------------------------------------------------
alter table public.projects
  add column is_event boolean not null default true;
comment on column public.projects.is_event is
  'An event has a run of show (service_grids). False only for a routine team activity or the Brief''s project.';

-- Existing data (system change: the guards skip it). A project is a Sunday service exactly when
-- it has a grid today (all existing grids are Sundays); the Brief's projects are not events.
update public.projects p set is_sunday_service = true
 where not p.is_sunday_service and exists (select 1 from public.service_grids g where g.project_id = p.id);
update public.projects p set is_sunday_service = false
 where p.is_sunday_service and not exists (select 1 from public.service_grids g where g.project_id = p.id);
update public.projects p set is_event = false
 where exists (select 1 from public.newsletter_issues i where i.project_id = p.id);

-- Who may mark a project a Sunday service or a routine team activity.
create or replace function app.project_kind_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return new; end if;
  if tg_op = 'INSERT' then
    -- Only the Operations Lead sets up Sundays (create_sunday_service runs as the caller).
    if new.is_sunday_service and not app.has_role('operations_lead') then
      raise exception 'Only the Operations Lead sets up a Sunday service' using errcode = '42501';
    end if;
    if new.is_sunday_service then new.is_event := true; end if;
    if not new.is_event and new.level <> 'unit' then
      raise exception 'A church project is an event; only a team project can be a routine team activity'
        using errcode = '23514';
    end if;
    return new;
  end if;

  -- Never changed afterwards: the Sunday rules (hours, rest, bookings, leaders' load) rest on it.
  if new.is_sunday_service is distinct from old.is_sunday_service then
    raise exception 'A project cannot become or stop being a Sunday service' using errcode = '42501';
  end if;
  if new.is_event is distinct from old.is_event then
    -- The Brief's own project is marked by the newsletter trigger below.
    if not new.is_event and exists (select 1 from public.newsletter_issues i where i.project_id = new.id) then
      return new;
    end if;
    if old.status <> 'draft' then
      raise exception 'Whether this is an event is decided before it is submitted' using errcode = '23514';
    end if;
    if new.is_sunday_service then
      raise exception 'A Sunday service is an event' using errcode = '23514';
    end if;
    -- A routine team activity has no run of show; a started one would be left behind.
    if not new.is_event and exists (select 1 from public.service_grids g where g.project_id = new.id) then
      raise exception 'Delete its run of show first' using errcode = '23514';
    end if;
  end if;
  if not new.is_event and new.level <> 'unit'
     and not exists (select 1 from public.newsletter_issues i where i.project_id = new.id) then
    raise exception 'A church project is an event; only a team project can be a routine team activity'
      using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function app.project_kind_guard() from public, anon, authenticated;
grant execute on function app.project_kind_guard() to service_role;
create trigger project_kind_guard before insert or update on public.projects
  for each row execute function app.project_kind_guard();

-- The Brief's project is not an event (it has no run of show and is never submitted).
create or replace function app.issue_project_not_event() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.projects p set is_event = false where p.id = new.project_id and p.is_event;
  return null;
end $$;
revoke all on function app.issue_project_not_event() from public, anon, authenticated;
grant execute on function app.issue_project_not_event() to service_role;
create trigger issue_project_not_event after insert on public.newsletter_issues
  for each row execute function app.issue_project_not_event();

-- -------------------------------------------------------------------------------------
-- 2. Run of show (service_grids) for every event
-- -------------------------------------------------------------------------------------
alter table public.service_grids
  add column is_sunday boolean not null default false;
update public.service_grids set is_sunday = true;   -- every grid so far is a Sunday's
comment on column public.service_grids.is_sunday is
  'Set by the database from the project (is_sunday_service). A Sunday grid is approved by the Resident Pastor.';

-- Sundays only for a Sunday grid; one Sunday grid per church per Sunday (TEC runs one service).
alter table public.service_grids drop constraint service_grids_service_date_check;
alter table public.service_grids
  add constraint service_grids_sunday_date check (not is_sunday or extract(isodow from service_date) = 7);
drop index public.service_grids_one_per_sunday;
create unique index service_grids_one_per_sunday on public.service_grids (church_id, service_date) where is_sunday;

-- Is this project a Sunday service? Its grid says so, and only the Operations Lead makes those.
create or replace function app.is_sunday_project(p_project uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.service_grids g where g.project_id = p_project and g.is_sunday)
$$;
revoke all on function app.is_sunday_project(uuid) from public, anon, authenticated;
grant execute on function app.is_sunday_project(uuid) to service_role;

-- Who builds a run of show: the Operations Lead for a Sunday; the event's owner or the
-- Operations Lead (app.can_manage_project) for any other event. Only in the caller's church.
create or replace function app.can_edit_run_of_show(p_grid uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select case when g.is_sunday then app.has_role('operations_lead')
                               else app.can_manage_project(g.project_id) end
                   from public.service_grids g
                   where g.id = p_grid and g.church_id = app.current_church_id()), false)
$$;

-- Who approves it: the Resident Pastor for a Sunday; the event's approver otherwise (the
-- Purpose Head for a team event, the Operations Lead for a church event).
create or replace function app.can_approve_run_of_show(p_grid uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select case when g.is_sunday then app.has_role('resident_pastor')
                               else app.is_project_approver(p.level, p.unit_id) end
                   from public.service_grids g join public.projects p on p.id = g.project_id
                   where g.id = p_grid and g.church_id = app.current_church_id()), false)
$$;
revoke all on function app.can_edit_run_of_show(uuid), app.can_approve_run_of_show(uuid) from public, anon;
grant execute on function app.can_edit_run_of_show(uuid), app.can_approve_run_of_show(uuid) to authenticated, service_role;

-- A new run of show: Sunday or event, decided by the project, never by the caller.
-- Runs after app.grid_guard (name order), which resets status and version on insert.
create or replace function app.grid_kind_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_proj record;
begin
  select p.id, p.is_sunday_service, p.is_event, p.starts_at, p.ends_at, p.status
    into v_proj from public.projects p where p.id = new.project_id;
  if tg_op = 'INSERT' then
    new.is_sunday := coalesce(v_proj.is_sunday_service, false);
    if app.is_system() then return new; end if;
    if new.is_sunday then
      if not app.has_role('operations_lead') then
        raise exception 'Only the Operations Lead builds the Sunday service grid' using errcode = '42501';
      end if;
    else
      if not coalesce(v_proj.is_event, false) then
        raise exception 'Only an event has a run of show' using errcode = '23514';
      end if;
      if v_proj.status in ('done', 'cancelled') then
        raise exception 'The project is closed' using errcode = '23514';
      end if;
      if not app.can_manage_project(new.project_id) then
        raise exception 'Only the event''s owner or the Operations Lead starts its run of show' using errcode = '42501';
      end if;
    end if;
  elsif new.is_sunday is distinct from old.is_sunday and not app.is_system() then
    raise exception 'A run of show cannot change between Sunday and event' using errcode = '42501';
  end if;
  -- An event's run of show is for a day the event runs (UK dates, as review 11 Q07).
  if not new.is_sunday and not app.is_system()
     and (new.service_date < (v_proj.starts_at at time zone 'Europe/London')::date
          or new.service_date > (v_proj.ends_at at time zone 'Europe/London')::date) then
    raise exception 'The run of show must be for a day the event runs' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function app.grid_kind_guard() from public, anon, authenticated;
grant execute on function app.grid_kind_guard() to service_role;
create trigger grid_kind_guard before insert or update on public.service_grids
  for each row execute function app.grid_kind_guard();

-- Who may change grids, segments and printed blocks (row-level security). The guards above and
-- app.grid_guard decide the rest (approval only by the approver, edits only by the builder).
drop policy grids_insert on public.service_grids;
create policy grids_insert on public.service_grids for insert to authenticated
  with check (church_id = (select app.current_church_id())
              and ((select app.has_role('operations_lead')) or app.can_manage_project(project_id)));
drop policy grids_update on public.service_grids;
create policy grids_update on public.service_grids for update to authenticated
  using (church_id = (select app.current_church_id())
         and (app.can_edit_run_of_show(id) or app.can_approve_run_of_show(id)))
  with check (church_id = (select app.current_church_id()));
drop policy grids_delete on public.service_grids;
create policy grids_delete on public.service_grids for delete to authenticated
  using (church_id = (select app.current_church_id()) and status = 'draft' and app.can_edit_run_of_show(id));
drop policy segments_write on public.service_segments;
create policy segments_write on public.service_segments for all to authenticated
  using (church_id = (select app.current_church_id()) and app.can_edit_run_of_show(grid_id))
  with check (church_id = (select app.current_church_id()) and app.can_edit_run_of_show(grid_id));
drop policy grid_blocks_write on public.service_grid_blocks;
create policy grid_blocks_write on public.service_grid_blocks for all to authenticated
  using (church_id = (select app.current_church_id()) and app.can_edit_run_of_show(grid_id))
  with check (church_id = (select app.current_church_id()) and app.can_edit_run_of_show(grid_id));

-- Start an event's run of show, for the event's first day. SECURITY INVOKER: the policies and
-- guards above decide who may.
create or replace function public.start_run_of_show(p_project uuid)
returns uuid
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_grid uuid;
begin
  insert into public.service_grids (project_id, service_date)
  select p.id, (p.starts_at at time zone 'Europe/London')::date
  from public.projects p where p.id = p_project and p.church_id = app.current_church_id()
  returning id into v_grid;
  if v_grid is null then
    raise exception 'Project not found' using errcode = 'P0002';
  end if;
  return v_grid;
end $$;
revoke all on function public.start_run_of_show(uuid) from public, anon;
grant execute on function public.start_run_of_show(uuid) to authenticated, service_role;

-- What the caller may do with one run of show, for the screen (the database still decides).
create or replace function public.run_of_show_rights(p_grid uuid)
returns table (can_edit boolean, can_approve boolean, is_sunday boolean)
language sql stable security definer set search_path = ''
as $$
  select app.can_edit_run_of_show(g.id), app.can_approve_run_of_show(g.id), g.is_sunday
  from public.service_grids g
  where g.id = p_grid and g.church_id = app.current_church_id()
$$;
revoke all on function public.run_of_show_rights(uuid) from public, anon;
grant execute on function public.run_of_show_rights(uuid) to authenticated, service_role;

-- An event is approved only once its run of show has been started (it can still be a draft;
-- its own approval comes later, as a Sunday's does).
create or replace function app.project_run_of_show_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return new; end if;
  if new.status = 'approved' and old.status is distinct from 'approved'
     and new.is_event and not new.is_sunday_service
     and not exists (select 1 from public.service_grids g where g.project_id = new.id) then
    raise exception 'Start the event''s run of show before it is approved' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function app.project_run_of_show_guard() from public, anon, authenticated;
grant execute on function app.project_run_of_show_guard() to service_role;
create trigger project_run_of_show_guard before update on public.projects
  for each row execute function app.project_run_of_show_guard();

-- -------------------------------------------------------------------------------------
-- 3. The G-Squad Coordinator approves extra teams (R3) and extra concurrent projects
-- -------------------------------------------------------------------------------------
alter table public.church_settings
  add column projects_before_approval smallint not null default 2 check (projects_before_approval between 1 and 10);
comment on column public.church_settings.projects_before_approval is
  'Overlapping projects (not Sundays) a member may serve on before the G-Squad Coordinator must approve another.';

-- R3, re-created whole from migration 8 with the Coordinator in place of the Resident Pastor,
-- and each request logged (the Resident Pastor reads them in public.serving_approvals()).
create or replace function app.membership_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_live int;
  v_max int;
begin
  if app.is_system() then return new; end if;

  if tg_op = 'UPDATE' and (new.person_id <> old.person_id or new.unit_id <> old.unit_id or new.church_id <> old.church_id) then
    raise exception 'Person and unit of a membership cannot be changed; end it and add a new one' using errcode = '42501';
  end if;

  select s.units_before_approval into v_max from public.church_settings s where s.church_id = new.church_id;
  select count(*) into v_live from public.unit_memberships m
  where m.person_id = new.person_id and m.status = 'active' and m.id <> new.id;

  if tg_op = 'INSERT' then
    new.approved_by := null;
    if v_live >= v_max then
      if app.has_role('gsquad_coordinator') then
        new.status := 'active';
        new.approved_by := (select auth.uid());
      else
        new.status := 'pending_approval';     -- waits for the G-Squad Coordinator
        perform app.audit('serving_approval_requested', 'unit_memberships', new.id,
                          jsonb_build_object('kind', 'team', 'person_id', new.person_id, 'unit_id', new.unit_id));
      end if;
    elsif new.status = 'pending_approval' then
      new.status := 'active';
    end if;
    return new;
  end if;

  -- UPDATE: approving a pending membership is for the G-Squad Coordinator only.
  if old.status = 'pending_approval' and new.status = 'active' then
    if not app.has_role('gsquad_coordinator') then
      raise exception 'The G-Squad Coordinator must approve joining another team' using errcode = '42501';
    end if;
    new.approved_by := (select auth.uid());
  elsif new.approved_by is distinct from old.approved_by then
    raise exception 'approved_by is set automatically' using errcode = '42501';
  end if;
  -- Re-activating an ended membership counts as joining again.
  if old.status = 'ended' and new.status = 'active' and v_live >= v_max and not app.has_role('gsquad_coordinator') then
    new.status := 'pending_approval';
    perform app.audit('serving_approval_requested', 'unit_memberships', new.id,
                      jsonb_build_object('kind', 'team', 'person_id', new.person_id, 'unit_id', new.unit_id));
  end if;
  -- ended_on follows status.
  if new.status = 'ended' and new.ended_on is null then new.ended_on := current_date; end if;
  if new.status <> 'ended' then new.ended_on := null; end if;
  return new;
end $$;

-- How many other projects (not Sundays) a person serves on whose dates overlap this one's.
-- Bookings waiting for approval count, so two waiting requests cannot both slip under the limit.
create or replace function app.overlapping_projects(p_person uuid, p_project uuid) returns integer
language sql stable security definer set search_path = ''
as $$
  select count(distinct o.id)::int
  from public.projects this
  join public.assignments a on a.person_id = p_person and a.project_id <> this.id
                           and a.status in ('planned', 'served', 'pending_approval')
  join public.projects o on o.id = a.project_id
  where this.id = p_project
    and not app.is_sunday_project(o.id)
    and o.status not in ('cancelled', 'done')
    and o.starts_at <= this.ends_at and o.ends_at >= this.starts_at
$$;
revoke all on function app.overlapping_projects(uuid, uuid) from public, anon, authenticated;
grant execute on function app.overlapping_projects(uuid, uuid) to service_role;

-- Runs after app.assignment_guard and app.assignment_rest_guard (name order), which have set
-- the hours, checked the place, the limit and the rest rule, and taken the per-person lock.
create or replace function app.assignment_spread_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_max int;
  v_other int;
begin
  if app.is_system() then return new; end if;

  -- Only the database puts a booking into "waiting for approval", and only the Coordinator's
  -- decision (or the Team Lead withdrawing it, which cancels it) takes it out.
  if new.status = 'pending_approval' and (tg_op = 'INSERT' or old.status <> 'pending_approval') then
    raise exception 'Book the person; the database decides whether approval is needed' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and old.status = 'pending_approval' then
    if new.status = 'pending_approval' then
      if (new.project_id, new.unit_id, new.serve_date, new.church_role_id)
         is distinct from (old.project_id, old.unit_id, old.serve_date, old.church_role_id) then
        raise exception 'Withdraw this request and book again' using errcode = '23514';
      end if;
      return new;
    end if;
    if new.status <> 'cancelled' and not app.has_role('gsquad_coordinator') then
      raise exception 'The G-Squad Coordinator approves serving on another overlapping project' using errcode = '42501';
    end if;
    return new;   -- approved (re-checked by the guards before this one) or withdrawn
  end if;

  -- A booking that newly puts the person on this project.
  if new.status <> 'planned'
     or (tg_op = 'UPDATE' and old.status in ('planned', 'served') and new.project_id = old.project_id) then
    return new;
  end if;
  if app.is_sunday_project(new.project_id) then return new; end if;
  if exists (select 1 from public.assignments a
             where a.person_id = new.person_id and a.project_id = new.project_id and a.id <> new.id
               and a.status in ('planned', 'served')) then
    return new;   -- already serving on this project (another day or role)
  end if;
  v_max := coalesce((select s.projects_before_approval from public.church_settings s where s.church_id = new.church_id), 2);
  v_other := app.overlapping_projects(new.person_id, new.project_id);
  if v_other >= v_max then
    if app.has_role('gsquad_coordinator') then
      perform app.audit('serving_approval_decided', 'assignments', new.id,
                        jsonb_build_object('kind', 'project', 'decision', 'approved', 'direct', true,
                                           'person_id', new.person_id, 'project_id', new.project_id,
                                           'unit_id', new.unit_id, 'overlapping', v_other));
    else
      new.status := 'pending_approval';
      perform app.audit('serving_approval_requested', 'assignments', new.id,
                        jsonb_build_object('kind', 'project', 'person_id', new.person_id, 'project_id', new.project_id,
                                           'unit_id', new.unit_id, 'overlapping', v_other));
    end if;
  end if;
  return new;
end $$;
revoke all on function app.assignment_spread_guard() from public, anon, authenticated;
grant execute on function app.assignment_spread_guard() to service_role;
create trigger assignment_spread_guard before insert or update on public.assignments
  for each row execute function app.assignment_spread_guard();

-- The Coordinator approves or declines a waiting request. SECURITY DEFINER: the Coordinator
-- does not otherwise update memberships or bookings; the guards still run (as the Coordinator)
-- and re-check everything on approval (hours, rest, holidays, the place).
create or replace function public.decide_serving_approval(p_kind text, p_id uuid, p_approve boolean)
returns void
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_row record;
begin
  if not app.has_role('gsquad_coordinator') then
    raise exception 'Only the G-Squad Coordinator decides these requests' using errcode = '42501';
  end if;
  if p_approve is null or p_kind not in ('team', 'project') then
    raise exception 'Say which request and whether it is approved' using errcode = '22023';
  end if;
  if p_kind = 'team' then
    select m.id, m.person_id, m.unit_id, null::uuid as project_id into v_row
      from public.unit_memberships m
     where m.id = p_id and m.church_id = app.current_church_id() and m.status = 'pending_approval'
       for update;
    if v_row.id is null then
      raise exception 'That request is no longer waiting' using errcode = 'P0002';
    end if;
    update public.unit_memberships set status = case when p_approve then 'active' else 'ended' end::public.membership_status
     where id = p_id;
  else
    select a.id, a.person_id, a.unit_id, a.project_id into v_row
      from public.assignments a
     where a.id = p_id and a.church_id = app.current_church_id() and a.status = 'pending_approval'
       for update;
    if v_row.id is null then
      raise exception 'That request is no longer waiting' using errcode = 'P0002';
    end if;
    update public.assignments set status = case when p_approve then 'planned' else 'cancelled' end::public.assignment_status
     where id = p_id;
  end if;
  perform app.audit('serving_approval_decided', case when p_kind = 'team' then 'unit_memberships' else 'assignments' end, p_id,
                    jsonb_build_object('kind', p_kind, 'decision', case when p_approve then 'approved' else 'declined' end,
                                       'person_id', v_row.person_id, 'unit_id', v_row.unit_id, 'project_id', v_row.project_id));
end $$;
revoke all on function public.decide_serving_approval(text, uuid, boolean) from public, anon;
grant execute on function public.decide_serving_approval(text, uuid, boolean) to authenticated, service_role;

-- What is waiting, and what was decided in the last p_days days (at most 366). For the G-Squad
-- Coordinator (who decides), the Operations Lead and the Resident Pastor (read-only: kept in the
-- loop). Names are first name and surname, as the leaders already see them.
create or replace function public.serving_approvals(p_days integer default 90)
returns table (kind text, request_id uuid, state text, person_name text, unit_name text,
               project_name text, starts_on date, ends_on date, requested_at timestamptz,
               decided_at timestamptz, decided_by text, overlapping integer)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_church uuid := app.current_church_id();
  v_since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 90), 366)));
begin
  if not app.has_any_role(array['gsquad_coordinator', 'operations_lead', 'resident_pastor']::public.app_role[]) then
    raise exception 'Not allowed to see serving approvals' using errcode = '42501';
  end if;
  return query
  with req as (
    select distinct on (l.record_id) l.record_id, l.at, l.detail
    from public.audit_log l
    where l.church_id = v_church and l.action = 'serving_approval_requested'
    order by l.record_id, l.at desc
  ), dec as (
    select distinct on (l.record_id) l.record_id, l.at, l.actor_id, l.detail
    from public.audit_log l
    where l.church_id = v_church and l.action = 'serving_approval_decided' and l.at >= v_since
    order by l.record_id, l.at desc
  )
  -- Waiting: extra teams
  select 'team'::text, m.id, 'waiting'::text, p.first_name || ' ' || p.surname, u.name,
         null::text, null::date, null::date, r.at, null::timestamptz, null::text, null::int
  from public.unit_memberships m
  join public.people p on p.id = m.person_id
  join public.units u on u.id = m.unit_id
  left join req r on r.record_id = m.id
  where m.church_id = v_church and m.status = 'pending_approval'
  union all
  -- Waiting: extra overlapping projects
  select 'project', a.id, 'waiting', p.first_name || ' ' || p.surname, u.name,
         pr.name, a.serve_date, a.serve_date, r.at, null, null, (r.detail->>'overlapping')::int
  from public.assignments a
  join public.people p on p.id = a.person_id
  join public.units u on u.id = a.unit_id
  join public.projects pr on pr.id = a.project_id
  left join req r on r.record_id = a.id
  where a.church_id = v_church and a.status = 'pending_approval'
  union all
  -- Decided in the window
  select d.detail->>'kind', d.record_id, d.detail->>'decision',
         coalesce(p.first_name || ' ' || p.surname, 'Former member'), u.name, pr.name,
         a.serve_date, a.serve_date, r.at, d.at, au.display_name,
         coalesce((r.detail->>'overlapping')::int, (d.detail->>'overlapping')::int)
  from dec d
  -- The request this decision answered: the latest one before it (a booking can be asked for again).
  left join lateral (select l.at, l.detail from public.audit_log l
                     where l.church_id = v_church and l.action = 'serving_approval_requested'
                       and l.record_id = d.record_id and l.at <= d.at
                     order by l.at desc limit 1) r on true
  left join public.people p on p.id = (d.detail->>'person_id')::uuid
  left join public.units u on u.id = (d.detail->>'unit_id')::uuid
  left join public.projects pr on pr.id = nullif(d.detail->>'project_id', '')::uuid
  left join public.assignments a on a.id = d.record_id and d.detail->>'kind' = 'project'
  left join public.app_users au on au.id = d.actor_id
  order by 3 desc, 9 desc nulls last;
end $$;
revoke all on function public.serving_approvals(integer) from public, anon;
grant execute on function public.serving_approvals(integer) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 4. Functions copied whole from their latest migration, changed only where marked
-- "MIGRATION 32". A Sunday is now app.is_sunday_project() (a Sunday grid), not any grid.
-- -------------------------------------------------------------------------------------

-- From 20261023002800_one_limit_all_serving.sql: MIGRATION 32 replaces "has a service grid" (1x) with app.is_sunday_project().
create or replace function app.assignment_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_limit_h numeric;
  v_used_h numeric;
  v_proj record;
  v_place numeric;
begin
  if tg_op = 'UPDATE' and (new.person_id <> old.person_id or new.church_id <> old.church_id) then
    raise exception 'Reassign by cancelling this slot and adding a new one' using errcode = '42501';
  end if;
  -- Migration 28: a slot's hours come from the volunteers-needed row it fills (its project,
  -- team, role and day), or the church's hours per slot. Set by the database, never the caller.
  -- SECURITY REVIEW 19 (Z01): a planned slot also follows later changes to its place's hours
  -- (app.demand_hours_sync writes exactly the place's hours, and nothing else is accepted); a
  -- slot brought back from cancelled or no-show is counted afresh. Served slots keep theirs.
  v_place := app.place_hours(new.project_id, new.unit_id, new.church_role_id, new.serve_date);
  if tg_op = 'INSERT' or new.project_id <> old.project_id or new.serve_date <> old.serve_date
     or new.unit_id <> old.unit_id or new.church_role_id is distinct from old.church_role_id
     or (old.status not in ('planned', 'served') and new.status in ('planned', 'served')) then
    new.hours := coalesce(v_place, app.default_slot_hours(new.project_id));
  elsif not (old.status = 'planned' and new.status = 'planned' and v_place is not null and new.hours = v_place) then
    new.hours := old.hours;
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
  -- SECURITY REVIEW 19 (Z02): ... and the same role, because the role decides the hours. Before,
  -- a booking for a 1-hour role could be switched in place to an 8-hour one with no limit check.
  -- A slot whose place now has more hours (Z01) has its limit checked again, nothing else.
  if tg_op = 'UPDATE' and new.serve_date = old.serve_date and new.unit_id = old.unit_id
     and new.project_id = old.project_id and new.church_role_id is not distinct from old.church_role_id
     and old.status in ('planned', 'served') then
    if new.hours <= old.hours or app.is_system() then return new; end if;
  else
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

    -- SECURITY REVIEW 19 (Z04): outside Sunday services, a slot fills a place the team was asked
    -- for (a volunteers-needed row for this project, team and day, for the role or for any role)
    -- on an approved project, as the Rota page offers. Before, a Team Lead could book their
    -- members onto any project in the church: drafts never approved, another team's activities,
    -- or days nobody asked for, using up their hours and giving that project's owner their
    -- contact details. A Sunday service is a project with a service grid (only the Operations
    -- Lead makes grids), not merely one flagged as a Sunday; Sundays keep their rules (a Sunday
    -- project stays a draft, and its slot falls back to the usual hours).
    if not app.is_sunday_project(new.project_id) then
      if v_place is null then
        raise exception 'This team was not asked for anyone in that role on that day' using errcode = '23514';
      end if;
      if v_proj.status not in ('approved', 'in_progress') then
        raise exception 'People can be named once the project is approved' using errcode = '23514';
      end if;
    end if;

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
  end if;

  -- SECURITY REVIEW 19 (Z05): one booking at a time per person and month. Before, two Team Leads
  -- (or two tabs) booking the same person at the same moment each counted only committed slots,
  -- both passed and the person went over the limit (reproduced with two sessions). The lock is
  -- held until the transaction ends, so the second waits and then sees the first.
  perform pg_advisory_xact_lock(hashtextextended('gsquad-hours:' || new.person_id::text || ':'
                                                 || to_char(new.serve_date, 'YYYY-MM'), 0));

  -- R1 / R2, migration 28: one monthly limit across ALL serving (Sundays, events, outreach and
  -- team activities), counted in hours; the Ops Lead may override with a reason.
  -- SECURITY REVIEW 19 (Z08): no limit found counts as none left (fails closed).
  v_limit_h := coalesce(app.hours_limit(new.person_id), 0);
  v_used_h  := app.hours_in_month(new.person_id, new.serve_date, new.id);
  if v_used_h + new.hours > v_limit_h then
    if app.has_role('operations_lead') and coalesce(length(trim(new.override_reason)), 0) >= 5 then
      perform app.audit('override_limit', 'assignments', new.id,
                        jsonb_build_object('person_id', new.person_id, 'month', date_trunc('month', new.serve_date)::date,
                                           'limit_hours', v_limit_h, 'hours_before', v_used_h, 'hours', new.hours,
                                           -- SECURITY REVIEW 20 (F07): the written reason is kept in the log too,
                                           -- where a later change to the slot cannot blank it.
                                           'reason', left(trim(new.override_reason), 500)));
    else
      raise exception 'This person already has % of % hours this month; this needs %',
        trim_scale(v_used_h), trim_scale(v_limit_h), trim_scale(new.hours)
        using errcode = '23514', hint = 'The Operations Lead can override with a written reason.';
    end if;
  end if;
  return new;
end $$;

-- From 20261023003000_fair_share_rest_leaders.sql: MIGRATION 32 replaces "has a service grid" (1x) with app.is_sunday_project().
create or replace function app.sundays_served(p_person uuid, p_day date, p_exclude uuid default null) returns integer
language sql stable security definer set search_path = ''
as $$
  select count(distinct a.serve_date)::int
  from public.assignments a
  where a.person_id = p_person and a.status in ('planned', 'served')
    and a.serve_date >= date_trunc('month', p_day)::date
    and a.serve_date < (date_trunc('month', p_day) + interval '1 month')::date
    and (p_exclude is null or a.id <> p_exclude)
    and app.is_sunday_project(a.project_id)
$$;

-- From 20261023003000_fair_share_rest_leaders.sql: MIGRATION 32 replaces "has a service grid" (2x) with app.is_sunday_project().
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
  if not app.is_sunday_project(new.project_id) then return new; end if;
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
               and app.is_sunday_project(a.project_id)) then
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

-- From 20261023003000_fair_share_rest_leaders.sql: MIGRATION 32 replaces "has a service grid" (1x) with app.is_sunday_project().
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
                        and not app.is_sunday_project(p.id)) pr
  where u.is_active and (p_church is null or u.church_id = p_church)
$$;

-- From 20261023002800_one_limit_all_serving.sql: MIGRATION 32: the next Sunday grid, not the next event's run of show.
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
    where g.church_id = v_church and g.is_sunday and g.service_date >= v_today
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

-- From 20261023001900_sunday_operations.sql: MIGRATION 32 marks the two changed checks.
create or replace function app.grid_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if not app.is_system() then
      new.status := 'draft'; new.version := 1;
      new.finalised_at := null; new.approved_by := null; new.approved_at := null;
    end if;
    return new;
  end if;
  if app.is_system() then return new; end if;

  if new.project_id <> old.project_id or new.church_id <> old.church_id then
    raise exception 'A grid cannot move to another service' using errcode = '42501';
  end if;
  if new.version < old.version then
    raise exception 'Version numbers only go up' using errcode = '42501';
  end if;

  -- SECURITY REVIEW FIX Q05: "new version, approval withdrawn" is always allowed, whoever's
  -- change caused it. The content triggers (segments, blocks, reusable block text) make exactly
  -- this change; before, it was refused unless the caller was the Operations Lead, so any other
  -- path that touched a finalised grid (a Coordinator editing a block's text, a cascade) either
  -- failed or had to skip re-approval. It only ever takes approval away, so it is safe for
  -- anyone who can reach it (row-level security still limits direct updates to the Operations
  -- Lead and Resident Pastor).
  if old.status in ('finalised', 'approved') and new.status = 'finalised'
     and new.version = old.version + 1 and new.approved_by is null and new.approved_at is null
     and (to_jsonb(new) - array['status', 'version', 'approved_by', 'approved_at', 'updated_at'])
         = (to_jsonb(old) - array['status', 'version', 'approved_by', 'approved_at', 'updated_at']) then
    return new;
  end if;

  -- Approval: Resident Pastor only, from a finalised grid.
  if new.status = 'approved' and old.status <> 'approved' then
    -- MIGRATION 32: the Resident Pastor for a Sunday; the event's approver for an event.
    if not app.can_approve_run_of_show(new.id) then
      raise exception 'Only the Resident Pastor approves a Sunday grid, and the event''s approver its run of show' using errcode = '42501';
    end if;
    if old.status <> 'finalised' then
      raise exception 'Finalise the grid before approval' using errcode = '23514';
    end if;
    -- SECURITY REVIEW FIX F10: approving is not editing: the content must be what was finalised.
    if (new.theme, new.service_date, new.version) is distinct from (old.theme, old.service_date, old.version) then
      raise exception 'Approve the grid without changing it' using errcode = '42501';
    end if;
    new.approved_by := (select auth.uid()); new.approved_at := now();
    return new;
  end if;

  -- The Resident Pastor's other right here is approval; edits are the Ops Lead's.
  -- MIGRATION 32: the Operations Lead for a Sunday; the event's owner or the Operations Lead for an event.
  if not app.can_edit_run_of_show(new.id) then
    raise exception 'Only the Operations Lead edits a Sunday grid, and the event''s owner its run of show' using errcode = '42501';
  end if;
  -- SECURITY REVIEW FIX F10: approval and finalising stamps are set by this trigger only.
  new.approved_by := old.approved_by; new.approved_at := old.approved_at; new.finalised_at := old.finalised_at;

  if new.status = 'finalised' and old.status = 'draft' then
    new.finalised_at := now();
  end if;
  -- Editing the header of a finalised or approved grid issues a new version (needs re-approval).
  if old.status in ('finalised', 'approved') and new.status = old.status
     and (new.theme is distinct from old.theme or new.service_date <> old.service_date) then
    new.version := old.version + 1;
    new.status := 'finalised';
    new.approved_by := null; new.approved_at := null;
  end if;
  if new.status <> 'approved' then
    new.approved_by := null; new.approved_at := null;   -- F10: only an approved grid carries an approver
  end if;
  if new.status = 'draft' then
    new.finalised_at := null;
    -- SECURITY REVIEW FIX Q04: back to draft starts the next version. Before, approved v3 ->
    -- draft -> edits -> finalised came back as v3 again, so two different grids (and PDFs named
    -- "...-v3.pdf") carried the same number and the Resident Pastor could not tell them apart.
    if old.status <> 'draft' then
      new.version := greatest(new.version, old.version + 1);
    end if;
  end if;
  return new;
end $$;

-- From 20261023001900_sunday_operations.sql: MIGRATION 32 changes only the message (events have runs of show too).
create or replace function public.reorder_segments(p_grid uuid, p_segments uuid[])
returns void
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_count int;
  v_to_move int;
  v_moved int;
begin
  select count(*) into v_count from public.service_segments s where s.grid_id = p_grid;
  if v_count <> coalesce(cardinality(p_segments), 0)
     or v_count <> (select count(distinct x) from unnest(p_segments) x)
     or exists (select 1 from unnest(p_segments) x
                where not exists (select 1 from public.service_segments s where s.id = x and s.grid_id = p_grid)) then
    raise exception 'List every segment of this grid exactly once' using errcode = '22023';
  end if;
  -- SECURITY REVIEW FIX Q06: everyone can read segments, but segments_write lets only the
  -- Operations Lead change them, so for anyone else the update below quietly matched no rows
  -- and the call "succeeded". Count what should move, and refuse if row-level security
  -- stopped any of it.
  select count(*) into v_to_move
    from public.service_segments s
    join unnest(p_segments) with ordinality as o(id, ord) on o.id = s.id
   where s.grid_id = p_grid and s.position <> o.ord;
  update public.service_segments s
     set position = o.ord
    from unnest(p_segments) with ordinality as o(id, ord)
   where s.id = o.id and s.grid_id = p_grid and s.position <> o.ord;
  get diagnostics v_moved = row_count;
  if v_moved < v_to_move then
    raise exception 'You cannot reorder this run of show' using errcode = '42501';
  end if;
end $$;
