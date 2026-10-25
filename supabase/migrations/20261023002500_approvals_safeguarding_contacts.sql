-- =====================================================================================
-- G-Squad Planner: 25. Approvals, safeguarding notes, shortfalls, phones and emails
-- (decisions of 25 Oct 2026)
--   1. Church projects are approved by the leadership team through the Operations Lead
--      (before: the Resident Pastor); unit projects by the unit's Purpose Head, as before.
--      An Operations Lead may approve a church project they own; the page flags it.
--      The Resident Pastor does not own projects.
--   2. Event safeguarding notes move out of event_plans (readable by every leader) into
--      public.event_safeguarding, with no direct access: read through
--      public.get_event_safeguarding (every view logged) by the project's owner, the
--      Operations Lead, its approver, the Resident Pastor and the Pastoral Lead; written
--      through public.set_event_safeguarding by the owner or Operations Lead.
--   3. Volunteer shortfalls are always shown: public.volunteer_shortfalls(unit) lists every
--      coming project-unit-month short of volunteers, for the Church Dashboard (all units)
--      and My Unit (one unit). Before, the shortfall rule (R6) was only checked at approval.
--   4. Members have up to 3 phone numbers and up to 3 email addresses (the main email, used
--      for the newsletter and to spot duplicates, plus 2 more).
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Approvals.
-- -------------------------------------------------------------------------------------
-- Who decides a project: the Operations Lead for church projects, the unit's Purpose Head
-- for unit projects.
create or replace function app.is_project_approver(p_level public.project_level, p_unit uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select (p_level = 'church' and app.has_role('operations_lead'))
      or (p_level = 'unit' and app.is_purpose_head_of_unit(p_unit))
$$;
revoke all on function app.is_project_approver(public.project_level, uuid) from public, anon;
grant execute on function app.is_project_approver(public.project_level, uuid) to authenticated, service_role;

-- Does this account hold the Resident Pastor role?
create or replace function app.user_is_resident_pastor(p_user uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.role_assignments ra
                 where ra.user_id = p_user and ra.role = 'resident_pastor' and ra.is_active)
$$;
revoke all on function app.user_is_resident_pastor(uuid) from public, anon, authenticated;
grant execute on function app.user_is_resident_pastor(uuid) to service_role;

-- Creating projects: the Resident Pastor no longer starts church projects (they don't own
-- projects); the rest as migration 7.
drop policy projects_insert on public.projects;
create policy projects_insert on public.projects for insert to authenticated
  with check (
    church_id = (select app.current_church_id())
    and owner_user_id = (select auth.uid())
    and (
      (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[]))
      or (level = 'church' and (select app.has_role('purpose_head')))
      or (level = 'unit' and (app.is_unit_lead_of(unit_id) or app.is_purpose_head_of_unit(unit_id)))
    ));

-- project_guard, re-created whole from migration 24: the approver helper above, and the
-- Resident Pastor never owns a project.
create or replace function app.project_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_plan public.event_plans%rowtype;
  v_has_plan boolean;
  v_short text;
  v_weeks int;
  v_is_manager boolean;
  v_is_approver boolean;
begin
  if tg_op = 'INSERT' then
    -- Decision of 25 Oct 2026: the Resident Pastor does not own projects.
    if not app.is_system() and app.user_is_resident_pastor(new.owner_user_id) then
      raise exception 'The Resident Pastor does not own projects: ask the Operations Lead or a Purpose Head to start it'
        using errcode = '42501';
    end if;
    -- Every project starts as a draft with no approval, whatever the app sends.
    if not app.is_system() then
      new.status := 'draft';
      new.approved_by := null;
      new.approved_at := null;
      new.decision_note := null;   -- SECURITY REVIEW 15 (U05): the note is the approver's
    end if;
    return new;
  end if;

  if app.is_system() then return new; end if;

  -- SECURITY REVIEW 15 (U02): an approved event whose plan changed in a way the approval
  -- checked (size, complexity, committee, budget) goes back for approval. app.event_plan_resubmit
  -- marks the one project it is moving with the transaction-local gsquad.plan_resubmit setting
  -- (set only inside that trigger function; set_config is not reachable through the API), so
  -- Finance or the Resident Pastor rejecting a budget can move the status they could not
  -- otherwise change. Only that move is accepted on this path.
  if current_setting('gsquad.plan_resubmit', true) = old.id::text then
    if new.status <> 'submitted' or old.status not in ('approved', 'in_progress')
       or (to_jsonb(new) - array['status','approved_by','approved_at','updated_at'])
          <> (to_jsonb(old) - array['status','approved_by','approved_at','updated_at']) then
      raise exception 'Unexpected change while sending the project back for approval' using errcode = '42501';
    end if;
    new.approved_by := null; new.approved_at := null; new.decision_note := null;
    return new;
  end if;

  if new.church_id <> old.church_id then
    raise exception 'Church cannot be changed' using errcode = '42501';
  end if;
  if new.owner_user_id <> old.owner_user_id and not app.has_role('operations_lead') then
    raise exception 'Only the Operations Lead can change a project owner' using errcode = '42501';
  end if;
  if new.owner_user_id <> old.owner_user_id and app.user_is_resident_pastor(new.owner_user_id) then
    raise exception 'The Resident Pastor does not own projects' using errcode = '42501';
  end if;
  if new.approved_by is distinct from old.approved_by or new.approved_at is distinct from old.approved_at then
    if new.status = old.status then
      raise exception 'Approval is recorded automatically' using errcode = '42501';
    end if;
  end if;

  v_is_manager := old.owner_user_id = (select auth.uid()) or app.has_role('operations_lead');
  -- The person who decides this project (migration 25): the Operations Lead, for the
  -- leadership team, for church projects; the unit's Purpose Head for unit projects.
  v_is_approver := app.is_project_approver(old.level, old.unit_id);

  -- Non-managers (approvers) may only change the status, the shortfall action and their note.
  if not v_is_manager and
     (to_jsonb(new) - array['status','approved_by','approved_at','updated_at','shortfall_action','shortfall_action_note','decision_note'])
     <> (to_jsonb(old) - array['status','approved_by','approved_at','updated_at','shortfall_action','shortfall_action_note','decision_note']) then
    raise exception 'Only the project owner or the Operations Lead can edit the project' using errcode = '42501';
  end if;

  -- The decision note is the approver's: written by them, kept when others edit.
  -- SECURITY REVIEW 15 (U05): checked before the "dates changed" return below (the owner could
  -- write it alongside a date change), and only while the project waits for their decision,
  -- so a note cannot be rewritten after approval or after the project has closed.
  if new.decision_note is distinct from old.decision_note then
    if not v_is_approver then
      raise exception 'Only the person approving this project can write the decision note' using errcode = '42501';
    end if;
    if old.status <> 'submitted' then
      raise exception 'The decision note is written when approving or sending back' using errcode = '23514';
    end if;
  end if;

  -- SECURITY REVIEW 15 (U06): the shortfall action (R6) is part of the approval record. It is
  -- recorded before or at approval, by the project's managers or its approver, and is then
  -- kept. Before, the Resident Pastor could change it on any unit project, and anyone with
  -- update rights could clear it after approval.
  if new.shortfall_action is distinct from old.shortfall_action
     or new.shortfall_action_note is distinct from old.shortfall_action_note then
    if old.status not in ('draft', 'submitted') then
      raise exception 'The shortfall action is part of the approval and cannot be changed now' using errcode = '23514';
    end if;
    if not (v_is_manager or (v_is_approver and old.status = 'submitted')) then
      raise exception 'Only the owner, the Operations Lead or the approver can record the shortfall action' using errcode = '42501';
    end if;
  end if;

  -- SECURITY REVIEW 15 (U08): volunteers needed must stay within the project's (London) dates
  -- when the dates change, as app.demand_dates_guard checks when they are added.
  if (new.starts_at <> old.starts_at or new.ends_at <> old.ends_at)
     and exists (select 1 from public.team_demand td
                 where td.project_id = old.id
                   and (td.on_date < (new.starts_at at time zone 'Europe/London')::date
                        or td.on_date > (new.ends_at at time zone 'Europe/London')::date)) then
    raise exception 'Volunteers are needed on a day outside the new dates: move or remove them first' using errcode = '23514';
  end if;

  -- Changing dates, level or unit of an approved project sends it back for approval.
  -- SECURITY REVIEW 15 (U01): also when the same request moves it on (to in progress or done),
  -- which before kept the approval for dates the approver never saw (R14).
  if old.status in ('approved', 'in_progress') and new.status in ('approved', 'in_progress', 'done') and
     (new.starts_at <> old.starts_at or new.ends_at <> old.ends_at or new.level <> old.level
      or new.unit_id is distinct from old.unit_id) then
    new.status := 'submitted';
    new.approved_by := null;
    new.approved_at := null;
    new.decision_note := null;
    return new;
  end if;

  if new.status = old.status then return new; end if;

  select * into v_plan from public.event_plans e where e.project_id = new.id;
  v_has_plan := found;

  -- draft -> submitted (owner / Ops Lead): R15 owner and committee.
  if new.status = 'submitted' then
    if not v_is_manager then
      raise exception 'Only the owner or the Operations Lead can submit' using errcode = '42501';
    end if;
    -- SECURITY REVIEW 15 (U03): a finished project cannot be reopened this way either.
    if old.status = 'done' then
      raise exception 'A finished project cannot be reopened' using errcode = '23514';
    end if;
    if v_has_plan and v_plan.complexity = 'high' and not v_plan.has_planning_committee then
      raise exception 'A High complexity event needs a planning committee (R15)' using errcode = '23514';
    end if;
    new.approved_by := null; new.approved_at := null;
    -- A new submission starts without the last decision's note (U05).
    new.decision_note := null;
    return new;
  end if;

  -- submitted -> approved: unit projects by the unit's Purpose Head, church projects by the
  -- Operations Lead for the leadership team (migration 25). Checks R6, R14, R15, R16.
  -- An Operations Lead approving a church project they own is allowed (decision of 25 Oct
  -- 2026); the page shows it as self-approved (approved_by = owner_user_id).
  if new.status = 'approved' then
    if old.status <> 'submitted' then
      raise exception 'Only a submitted project can be approved' using errcode = '23514';
    end if;
    if not app.is_project_approver(new.level, new.unit_id) then
      raise exception 'You cannot approve this project' using errcode = '42501';
    end if;
    -- R6: shortfall needs a recorded action.
    v_short := app.project_shortfall(new.id);
    if v_short is not null and new.shortfall_action is null then
      raise exception 'Shortfall in %: record the action taken (move, scale down, borrow, recruit) (R6)', v_short
        using errcode = '23514';
    end if;
    if v_has_plan then
      -- SECURITY REVIEW 15 (U02): R15 again at approval, since the plan can change after submission.
      if v_plan.complexity = 'high' and not v_plan.has_planning_committee then
        raise exception 'A High complexity event needs a planning committee (R15)' using errcode = '23514';
      end if;
      -- R14: minimum lead time by size.
      select case v_plan.size when 'small' then s.lead_time_small_weeks
                              when 'medium' then s.lead_time_medium_weeks
                              else s.lead_time_large_weeks end
        into v_weeks from public.church_settings s where s.church_id = new.church_id;
      if new.starts_at < now() + make_interval(weeks => v_weeks) then
        raise exception 'Lead time is under % weeks for a % event: scale down or reschedule (R14)', v_weeks, v_plan.size
          using errcode = '23514';
      end if;
      -- R16: budget approved or not needed.
      if v_plan.budget_status not in ('approved', 'not_needed') then
        raise exception 'The budget must be approved or marked not needed (R16)' using errcode = '23514';
      end if;
    end if;
    new.approved_by := (select auth.uid());
    new.approved_at := now();
    return new;
  end if;

  -- approved -> in_progress -> done (owner / Ops Lead). R9 and the event review.
  if new.status in ('in_progress', 'done') then
    if not v_is_manager then
      raise exception 'Only the owner or the Operations Lead can move the project on' using errcode = '42501';
    end if;
    if old.status not in ('approved', 'in_progress') then
      raise exception 'The project must be approved first' using errcode = '23514';
    end if;
    -- SECURITY REVIEW FIX F10: the approval record cannot be rewritten while moving on.
    new.approved_by := old.approved_by; new.approved_at := old.approved_at;
    if new.status = 'done' then
      if exists (select 1 from public.project_inputs i
                 where i.project_id = new.id and i.is_required and i.status <> 'received') then
        raise exception 'A required input is still outstanding (R9)' using errcode = '23514';
      end if;
      if v_has_plan and v_plan.review_completed_at is null then
        raise exception 'Complete the event review before closing' using errcode = '23514';
      end if;
    end if;
    return new;
  end if;

  -- Back to draft (rework) or cancelled: owner, Ops Lead, or Resident Pastor; and the approver
  -- of a submitted project may send it back to draft (migration 24: before, a Purpose Head
  -- could approve a unit project but not return it for changes).
  if new.status in ('draft', 'cancelled') then
    if not (v_is_manager or app.has_role('resident_pastor')
            or (v_is_approver and old.status = 'submitted' and new.status = 'draft')) then
      raise exception 'You cannot change this project''s status' using errcode = '42501';
    end if;
    if old.status = 'done' then
      raise exception 'A finished project cannot be reopened' using errcode = '23514';
    end if;
    new.approved_by := null; new.approved_at := null;
    -- U05: only the approver's send-back carries a note; any other move back drops the last one,
    -- so an old approval note is never shown as the reason for a draft.
    if not (v_is_approver and old.status = 'submitted' and new.status = 'draft') then
      new.decision_note := null;
    end if;
    return new;
  end if;

  return new;
end $$;

-- project_readiness, re-created whole from migration 24 with the approver helper and a
-- self_approval flag (the caller approves a project they own).
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
    -- Who may do what next (the guard decides; this is for showing the right buttons).
    'can_manage', app.can_manage_project(p.id),
    'can_approve', app.is_project_approver(p.level, p.unit_id),
    'self_approval', app.is_project_approver(p.level, p.unit_id) and p.owner_user_id = (select auth.uid())
  );
end $$;

-- -------------------------------------------------------------------------------------
-- 2. Safeguarding notes: restricted and logged.
-- -------------------------------------------------------------------------------------
create table public.event_safeguarding (
  project_id  uuid primary key,
  church_id   uuid not null,
  notes       text not null check (length(notes) between 1 and 2000),
  updated_by  uuid default auth.uid(),
  updated_at  timestamptz not null default now(),
  foreign key (church_id, project_id) references public.projects(church_id, id) on delete cascade
);
alter table public.event_safeguarding enable row level security;
-- No policies and no grants: like person_faith, reached only through the functions below.
revoke all on public.event_safeguarding from public, anon, authenticated;
create trigger event_safeguarding_touch before update on public.event_safeguarding
  for each row execute function app.touch_updated_at();
-- Every write is audited (column names only, never the text).
create trigger event_safeguarding_audit after insert or update or delete on public.event_safeguarding
  for each row execute function app.audit_row_change();

-- Existing notes move across, then the open column goes.
insert into public.event_safeguarding (project_id, church_id, notes, updated_by)
select e.project_id, e.church_id, left(e.safeguarding_notes, 2000), null
from public.event_plans e
where nullif(btrim(e.safeguarding_notes), '') is not null;
alter table public.event_plans drop column safeguarding_notes;

-- Who reads them: the project's owner, the Operations Lead, its approver, the Resident
-- Pastor and the Pastoral Lead.
create or replace function app.can_see_safeguarding(p_project uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.projects p
    where p.id = p_project and p.church_id = app.current_church_id()
      and (app.can_manage_project(p.id)
           or app.is_project_approver(p.level, p.unit_id)
           or app.has_any_role(array['resident_pastor','pastoral_lead']::public.app_role[])))
$$;
revoke all on function app.can_see_safeguarding(uuid) from public, anon;
grant execute on function app.can_see_safeguarding(uuid) to authenticated, service_role;

-- Read (logged). VOLATILE so the audit insert works (as get_person_faith, F03).
create or replace function public.get_event_safeguarding(p_project uuid) returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare v text;
begin
  if not app.can_see_safeguarding(p_project) then
    raise exception 'Not allowed to view safeguarding notes for this event' using errcode = '42501';
  end if;
  perform app.audit('view_safeguarding', 'event_safeguarding', p_project);
  select s.notes into v from public.event_safeguarding s where s.project_id = p_project;
  return v;
end $$;
revoke all on function public.get_event_safeguarding(uuid) from public, anon;
grant execute on function public.get_event_safeguarding(uuid) to authenticated, service_role;

-- Write: the project's owner or the Operations Lead. Empty text removes the notes.
create or replace function public.set_event_safeguarding(p_project uuid, p_notes text) returns void
language plpgsql volatile security definer set search_path = ''
as $$
declare v_church uuid;
begin
  select p.church_id into v_church from public.projects p
  where p.id = p_project and p.church_id = app.current_church_id();
  if v_church is null or not app.can_manage_project(p_project) then
    raise exception 'Only the event owner or the Operations Lead can record safeguarding notes' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_notes, '')), '') is null then
    delete from public.event_safeguarding where project_id = p_project;
  else
    insert into public.event_safeguarding as s (project_id, church_id, notes, updated_by)
    values (p_project, v_church, btrim(p_notes), (select auth.uid()))
    on conflict (project_id) do update set notes = excluded.notes, updated_by = excluded.updated_by;
  end if;
end $$;
revoke all on function public.set_event_safeguarding(uuid, text) from public, anon;
grant execute on function public.set_event_safeguarding(uuid, text) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 3. Volunteer shortfalls for the dashboards: every coming project (not done or cancelled)
-- whose volunteers needed from a unit in a month exceed that unit's spare capacity
-- (app.unit_capacity, with the project itself left out, as R6 checks at approval).
-- p_unit null = all units (Church Dashboard audience); a unit = My Unit (that unit's viewers).
-- Project and unit names are already readable church-wide; no personal data.
-- -------------------------------------------------------------------------------------
create or replace function public.volunteer_shortfalls(p_unit uuid default null)
returns table (project_id uuid, project_name text, is_sunday_service boolean, grid_id uuid,
               project_status public.project_status, unit_id uuid, unit_name text, month date,
               slots_needed integer, spare numeric)
language plpgsql stable security definer set search_path = ''
as $$
declare v_church uuid := app.current_church_id();
begin
  if v_church is null
     or (p_unit is null and not app.is_dashboard_reader())
     or (p_unit is not null and not (exists (select 1 from public.units u where u.id = p_unit and u.church_id = v_church)
                                     and app.can_view_unit(p_unit))) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    with need as (
      select td.project_id, td.unit_id, date_trunc('month', td.on_date)::date as m, sum(td.slots_needed)::int as n
      from public.team_demand td
      join public.projects p on p.id = td.project_id
      where p.church_id = v_church
        and p.status not in ('done', 'cancelled')
        and td.on_date >= (now() at time zone 'Europe/London')::date
        and (p_unit is null or td.unit_id = p_unit)
      group by 1, 2, 3
    )
    select p.id, p.name, p.is_sunday_service,
           (select g.id from public.service_grids g where g.project_id = p.id limit 1),
           p.status, u.id, u.name, n.m, n.n, round(app.unit_capacity(n.unit_id, n.m, n.project_id), 1)
    from need n
    join public.projects p on p.id = n.project_id
    join public.units u on u.id = n.unit_id
    where app.unit_capacity(n.unit_id, n.m, n.project_id) < n.n
    order by n.m, p.starts_at, u.name
    limit 200;
end $$;
revoke all on function public.volunteer_shortfalls(uuid) from public, anon;
grant execute on function public.volunteer_shortfalls(uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 4. Phones and emails.
-- -------------------------------------------------------------------------------------
-- Trims a list, drops empty entries and (for emails) lower-cases them.
create or replace function app.clean_list(p text[], p_lower boolean) returns text[]
language sql immutable set search_path = ''
as $$
  select coalesce(array_agg(case when p_lower then lower(btrim(x)) else btrim(x) end order by o), '{}')
  from unnest(coalesce(p, '{}')) with ordinality as t(x, o)
  where nullif(btrim(x), '') is not null
$$;
-- A phone number: digits with optional +, spaces, brackets and dashes, 7 to 20 characters.
create or replace function app.valid_phones(p text[]) returns boolean
language sql immutable set search_path = ''
as $$ select coalesce(bool_and(x ~ '^\+?[0-9][0-9 ()-]{5,18}[0-9]$'), true) from unnest(p) x $$;
-- The same email rule as people.email (RFC 5321 length, lower case as stored).
create or replace function app.valid_emails(p text[]) returns boolean
language sql immutable set search_path = ''
as $$ select coalesce(bool_and(length(x) <= 254 and x ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and x = lower(x)), true) from unnest(p) x $$;
revoke all on function app.clean_list(text[], boolean), app.valid_phones(text[]), app.valid_emails(text[]) from public, anon;
grant execute on function app.clean_list(text[], boolean), app.valid_phones(text[]), app.valid_emails(text[]) to authenticated, service_role;

alter table public.people
  add column phones text[] not null default '{}'
    check (cardinality(phones) <= 3 and app.valid_phones(phones)),
  -- Up to 2 more, after the main email (3 in all).
  add column other_emails text[] not null default '{}'
    check (cardinality(other_emails) <= 2 and app.valid_emails(other_emails));

-- people_guard, re-created whole from migration 23: the TECi route records no phones or extra
-- emails (name, email and stage only, S04), and anonymising must clear them.
create or replace function app.people_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return new; end if;

  if tg_op = 'INSERT' then
    -- The TECi stage is set by the TECi Coordinator (or the Ops Lead), not on entry.
    if new.teci_stage_id is not null
       and not app.has_any_role(array['teci_coordinator','operations_lead','gsquad_coordinator']::public.app_role[]) then
      raise exception 'Only the TECi Coordinator can set a TECi stage' using errcode = '42501';
    end if;
    -- The TECi Coordinator adds members who have completed a TECi level.
    if new.teci_stage_id is null and not app.has_any_role(array['unit_lead','operations_lead','gsquad_coordinator']::public.app_role[]) then
      raise exception 'Choose the TECi stage they have completed' using errcode = '22023';
    end if;
    -- SECURITY REVIEW 13 (S04): the TECi route records the minimum: name, email and the stage.
    -- create_member (and a direct insert) accepted birthdays, marital status, anniversaries,
    -- area, availability and so on from the TECi Coordinator, who cannot edit or correct the
    -- record afterwards (only the G-Squad Coordinator can until they join a team). The rest is
    -- added once the Operations Lead has put them in a team and their Team Lead can edit them.
    if not app.has_any_role(array['unit_lead','operations_lead','gsquad_coordinator']::public.app_role[])
       and (new.birth_day is not null or new.birth_month is not null or new.marital_status is not null
            or new.anniversary_day is not null or new.anniversary_month is not null or new.area is not null
            or new.greatness_community_id is not null or new.available_hours_month is not null
            or coalesce(cardinality(new.preferred_times), 0) > 0 or new.date_left is not null
            or new.status <> 'active' or new.celebration_opt_in
            or coalesce(cardinality(new.phones), 0) > 0 or coalesce(cardinality(new.other_emails), 0) > 0
            or new.consent_notice_version is not null or new.consent_at is not null) then
      raise exception 'The TECi Coordinator records only a name, email address and TECi stage; the rest is added when they join a team'
        using errcode = '42501';
    end if;
    if new.teci_verified_at is not null and new.teci_stage_id is not null and app.has_role('teci_coordinator') then
      new.teci_verified_at := now();
      new.teci_verified_by := (select auth.uid());
    else
      new.teci_verified_at := null;
      new.teci_verified_by := null;
    end if;
    new.anonymised_at := null;
    return new;
  end if;

  -- An anonymised record stays anonymised (migration 15, L02).
  if old.anonymised_at is not null then
    raise exception 'This record has been anonymised and cannot be changed' using errcode = '42501';
  end if;

  -- UPDATE: identity columns never change through the API.
  if new.id <> old.id or new.church_id <> old.church_id or new.created_by is distinct from old.created_by then
    raise exception 'id, church and creator cannot be changed' using errcode = '42501';
  end if;
  -- Anonymising goes through app.anonymise() (migration 8, F09).
  if current_setting('gsquad.anonymising', true) = 'on' then
    if new.anonymised_at is null or new.email is not null or new.area is not null
       or cardinality(new.phones) > 0 or cardinality(new.other_emails) > 0
       or new.status <> 'left' or new.birth_day is not null or new.anniversary_day is not null then
      raise exception 'The anonymising marker may only be used to anonymise' using errcode = '42501';
    end if;
    return new;
  end if;
  if new.anonymised_at is distinct from old.anonymised_at then
    raise exception 'Use public.anonymise_person() to anonymise a record' using errcode = '42501';
  end if;
  -- Decision 1 (migration 16): the TECi stage of an existing member is the TECi Coordinator's alone.
  if new.teci_stage_id is distinct from old.teci_stage_id and not app.has_role('teci_coordinator') then
    raise exception 'Only the TECi Coordinator can change a TECi stage' using errcode = '42501';
  end if;
  -- Verification: only the TECi Coordinator, always as themselves and now.
  if new.teci_verified_at is distinct from old.teci_verified_at or new.teci_verified_by is distinct from old.teci_verified_by then
    if not app.has_role('teci_coordinator') then
      raise exception 'Only the TECi Coordinator can verify a TECi stage' using errcode = '42501';
    end if;
    if new.teci_verified_at is not null then
      if new.teci_stage_id is null then
        raise exception 'Set a TECi stage before verifying it' using errcode = '22023';
      end if;
      new.teci_verified_at := now();
      new.teci_verified_by := (select auth.uid());
    else
      new.teci_verified_by := null;
    end if;
  elsif new.teci_stage_id is distinct from old.teci_stage_id then
    -- A changed stage is unverified until it is confirmed again.
    new.teci_verified_at := null;
    new.teci_verified_by := null;
  end if;
  -- Someone who is not this person's editor (the TECi Coordinator route) changes TECi only.
  if not app.can_edit_person(old.id)
     and (to_jsonb(new) - 'teci_stage_id' - 'teci_verified_at' - 'teci_verified_by' - 'updated_at')
         <> (to_jsonb(old) - 'teci_stage_id' - 'teci_verified_at' - 'teci_verified_by' - 'updated_at') then
    raise exception 'Only their Team Lead or the G-Squad Coordinator can edit this record' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app.people_guard() from public, anon, authenticated;
grant execute on function app.people_guard() to service_role;

-- create_member, re-created whole from migration 22 (as last changed there) with the new lists.
create or replace function public.create_member(
  p_person jsonb,
  p_unit uuid,
  p_church_role uuid default null,
  p_is_team_leader boolean default false,
  p_leadership_stage uuid default null,
  p_faith jsonb default null)
returns uuid
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  -- The id is made here, not returned by INSERT ... RETURNING, which people_read refuses.
  v_id uuid := gen_random_uuid();
  r public.people;
begin
  r := jsonb_populate_record(null::public.people, coalesce(p_person, '{}'::jsonb));
  if p_unit is null then
    if not app.has_any_role(array['teci_coordinator','operations_lead']::public.app_role[]) then
      raise exception 'Choose the unit they are joining' using errcode = '22023';
    end if;
    if r.teci_stage_id is null then
      raise exception 'Choose the TECi stage they have completed' using errcode = '22023';
    end if;
  end if;

  begin
    insert into public.people (id, first_name, other_names, surname, email, area,
        birth_day, birth_month, marital_status, anniversary_day, anniversary_month,
        date_joined, date_left, status, teci_stage_id, teci_verified_at, greatness_community_id,
        newsletter_subscribed, celebration_opt_in, phones, other_emails)
    values (v_id, r.first_name, r.other_names, r.surname,
        -- Same normalisation as the unique index people_email_unique (lower(email)).
        nullif(lower(btrim(r.email)), ''), r.area,
        r.birth_day, r.birth_month, r.marital_status,
        -- An anniversary is kept only for married members (data minimisation).
        case when r.marital_status = 'married' then r.anniversary_day end,
        case when r.marital_status = 'married' then r.anniversary_month end,
        coalesce(r.date_joined, current_date), r.date_left,
        -- left_consistent: a leaving date means "left".
        case when r.date_left is not null then 'left'::public.person_status
             else coalesce(nullif(r.status, 'left'), 'active') end,
        -- people_guard keeps a verification only from the TECi Coordinator, stamped now.
        r.teci_stage_id, r.teci_verified_at, r.greatness_community_id,
        coalesce(r.newsletter_subscribed, true), coalesce(r.celebration_opt_in, false),
        -- Migration 25: up to 3 phone numbers and 2 more email addresses, trimmed (emails in
        -- lower case); empty entries dropped. The table's checks decide what is valid.
        app.clean_list(r.phones, false), app.clean_list(r.other_emails, true));
  exception when unique_violation then
    raise exception 'A member with that email address is already recorded' using errcode = 'P0001';
  end;

  if p_unit is not null then
    insert into public.unit_memberships (person_id, unit_id, church_role_id, leadership_stage_id)
    values (v_id, p_unit, p_church_role, p_leadership_stage);
  end if;

  -- Faith fields only through the logged function (it checks access and audits the write).
  if p_faith is not null then
    perform public.set_person_faith(v_id,
      (p_faith->>'salvation_date')::date,
      coalesce((p_faith->>'water_baptism')::boolean, false),       (p_faith->>'water_baptism_date')::date,
      coalesce((p_faith->>'holy_spirit_baptism')::boolean, false), (p_faith->>'holy_spirit_baptism_date')::date,
      coalesce((p_faith->>'speaks_in_tongues')::boolean, false),   (p_faith->>'speaks_in_tongues_date')::date);
  end if;
  return v_id;
end $$;

-- app.anonymise, re-created whole from migration 17: also wipes phones and extra emails.
create or replace function app.anonymise(p_person uuid) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  -- Marker read by app.people_guard() so this one update may set anonymised_at.
  perform set_config('gsquad.anonymising', 'on', true);
  update public.people set
    first_name = 'Former', other_names = null, surname = 'member',
    email = null, area = null, marital_status = null,
    phones = '{}', other_emails = '{}',   -- migration 25
    birth_day = null, birth_month = null, anniversary_day = null, anniversary_month = null,
    greatness_community_id = null, available_hours_month = null, preferred_times = '{}',
    newsletter_subscribed = false, celebration_opt_in = false,
    status = 'left', date_left = coalesce(date_left, current_date),
    anonymised_at = now()
  where id = p_person and anonymised_at is null;
  delete from public.person_faith where person_id = p_person;
  delete from public.pastoral_notes where person_id = p_person;
  delete from public.one_to_ones where person_id = p_person;
  delete from public.recognitions where person_id = p_person;   -- ASHLIE: free text about the person
  delete from public.holidays where person_id = p_person;
  delete from public.checkin_flags where person_id = p_person;
  delete from public.email_link_tokens where person_id = p_person;
  update public.community_support_roles set person_id = null where person_id = p_person;
  update public.app_users set person_id = null where person_id = p_person;
  -- Decision of 23 Oct 2026: an anonymised person leaves every unit, so "Former member" no
  -- longer appears on any team list. Serving history (assignments) stays as anonymous counts.
  -- SECURITY REVIEW FIX N02: date the end to when the person left (set just above), not to
  -- today. The nightly job (R8) anonymises people a year or more after they left; ending their
  -- membership "today" would record them as serving long after they had gone (accuracy).
  -- greatest() keeps the end on or after the joining date for oddly entered records.
  update public.unit_memberships m
     set status = 'ended',
         ended_on = greatest(m.joined_on, coalesce((select p.date_left from public.people p where p.id = p_person), current_date))
   where m.person_id = p_person and m.status <> 'ended';
  -- SECURITY REVIEW FIX F14: the free-text override reason can describe the person's
  -- circumstances; wipe it with the rest of their personal details.
  update public.assignments set override_reason = null where person_id = p_person and override_reason is not null;
  perform set_config('gsquad.anonymising', 'off', true);
end $$;
revoke all on function app.anonymise(uuid) from public, anon, authenticated;
grant execute on function app.anonymise(uuid) to service_role;
