-- =====================================================================================
-- Migration 37: goal-based projects, special Sundays, team programmes and monthly programme
-- reports (decisions of 27 Nov 2026, Paul).
--
-- 1. Goal-based projects (projects.is_goal). Not every project is an event: a committee may
--    work for months towards a plan or output (a building project, say). A goal-based project
--    has milestones and outputs (project_milestones) instead of a run of show, may stay open
--    for months, and sits at church, purpose (projects.purpose_id) or team level. Every one is
--    decided by the Resident Pastor with the leadership, usually in the year plan; events keep
--    their approvers (Purpose Head for team events, Operations Lead for church events). It is
--    approved once it names at least one milestone and closed once every milestone is met. It
--    may have a planning committee, whose seats count in leaders' load as for events.
-- 2. Church level: the owner chooses the level and the approver checks it (no new rule).
-- 3. Special Sundays (projects.is_special_sunday): a Sunday with special guests or
--    non-routine activities, as the Resident Pastor or the Operations Lead decides. Only a
--    special Sunday may have a planning committee (the Sunday grid stays its run of show).
-- 4. Team programmes (unit_programmes): a team's core routine functions. A programme that
--    coordinates a core deliverable for the church reports monthly in one area (maturity,
--    evangelism or assimilation); one geared to presentation does not report. Events and
--    routine activities can be linked to a programme (projects.programme_id).
-- 5. Monthly programme reports (programme_reports): written by the team's Team Lead (or the
--    Coordinator) and submitted to the Coordinator; read by the monthly-report roles and the
--    team's own Lead and Deputy. Counts the app holds come from linked projects
--    (programme_report_figures); the Team Lead types the rest. Counts only, no names.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Projects: goal-based, purpose level, special Sundays, programme link
-- -------------------------------------------------------------------------------------
create type public.programme_area as enum ('maturity', 'evangelism', 'assimilation');

create table public.unit_programmes (
  id           uuid primary key default gen_random_uuid(),
  church_id    uuid not null default app.current_church_id() references public.churches(id) on delete restrict,
  unit_id      uuid not null,
  name         text not null check (length(btrim(name)) between 1 and 120),
  description  text check (length(description) <= 1000),
  -- The area it reports on monthly; null = a programme geared to presentation (no report).
  report_area  public.programme_area,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  unique (church_id, id),
  unique (unit_id, name),
  foreign key (church_id, unit_id) references public.units(church_id, id) on delete cascade
);
comment on table public.unit_programmes is
  'A team''s core routine functions (migration 37). report_area set = reports monthly in that area.';

alter table public.projects
  add column is_goal boolean not null default false,
  add column purpose_id uuid,
  add column is_special_sunday boolean not null default false,
  add column programme_id uuid,
  add constraint projects_purpose_fk foreign key (church_id, purpose_id)
    references public.purposes(church_id, id) on delete restrict,
  -- A programme removed leaves its projects unlinked (only programme_id is cleared).
  add constraint projects_programme_fk foreign key (church_id, programme_id)
    references public.unit_programmes(church_id, id) on delete set null (programme_id),
  -- A goal-based project is not an event and not a Sunday.
  add constraint projects_goal_not_event check (not is_goal or (not is_event and not is_sunday_service)),
  -- The purpose level: a church-wide goal-based project led for one purpose.
  add constraint projects_purpose_level check (purpose_id is null or (is_goal and level = 'church')),
  add constraint projects_special_sunday check (not is_special_sunday or is_sunday_service);
create index projects_programme on public.projects (programme_id) where programme_id is not null;
comment on column public.projects.is_goal is
  'A goal-based project: milestones and outputs instead of a run of show; decided by the Resident Pastor (migration 37).';
comment on column public.projects.purpose_id is
  'For a church-level goal-based project led for one purpose: the purpose level (migration 37).';
comment on column public.projects.is_special_sunday is
  'A Sunday with special guests or non-routine activities, as the Resident Pastor or Operations Lead decides; may have a planning committee (migration 37).';

-- Is the signed-in user the Purpose Head of this purpose?
create or replace function app.is_purpose_head_of(p_purpose uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.role_assignments ra
                 join public.app_users u on u.id = ra.user_id and u.is_active
                 where ra.user_id = (select auth.uid()) and ra.role = 'purpose_head'
                   and ra.purpose_id = p_purpose and ra.is_active)
$$;
revoke all on function app.is_purpose_head_of(uuid) from public, anon;
grant execute on function app.is_purpose_head_of(uuid) to authenticated, service_role;

-- Re-created from migration 32 with the goal-based kind, the purpose level, special Sundays
-- and the programme link. What a project is (event, routine activity, goal-based) and where it
-- sits are decided while it is a draft; they shape who approves it and what it needs.
create or replace function app.project_kind_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_prog record;
begin
  if app.is_system() then return new; end if;
  if tg_op = 'INSERT' then
    -- Only the Operations Lead sets up Sundays (create_sunday_service runs as the caller).
    if new.is_sunday_service and not app.has_role('operations_lead') then
      raise exception 'Only the Operations Lead sets up a Sunday service' using errcode = '42501';
    end if;
    if new.is_sunday_service then new.is_event := true; end if;
    -- A goal-based project has milestones, not a run of show.
    if new.is_goal then new.is_event := false; end if;
    if new.is_special_sunday and not app.has_any_role(array['resident_pastor','operations_lead']::public.app_role[]) then
      raise exception 'The Resident Pastor or the Operations Lead decides a special Sunday' using errcode = '42501';
    end if;
  else
    -- Never changed afterwards: the Sunday rules (hours, rest, bookings, leaders' load) rest on it.
    if new.is_sunday_service is distinct from old.is_sunday_service then
      raise exception 'A project cannot become or stop being a Sunday service' using errcode = '42501';
    end if;
    if new.is_event is distinct from old.is_event or new.is_goal is distinct from old.is_goal then
      -- The Brief's own project is marked by the newsletter trigger (migration 32).
      if not new.is_event and not new.is_goal and new.is_goal is not distinct from old.is_goal
         and exists (select 1 from public.newsletter_issues i where i.project_id = new.id) then
        return new;
      end if;
      if old.status <> 'draft' then
        raise exception 'Whether this is an event, a routine activity or a goal-based project is decided before it is submitted'
          using errcode = '23514';
      end if;
      if new.is_sunday_service then
        raise exception 'A Sunday service is an event' using errcode = '23514';
      end if;
      if new.is_goal and new.is_event then
        new.is_event := false;
      end if;
      -- Neither a routine activity nor a goal-based project has a run of show; a started one
      -- would be left behind. Milestones likewise belong to goal-based projects only.
      if not new.is_event and exists (select 1 from public.service_grids g where g.project_id = new.id) then
        raise exception 'Delete its run of show first' using errcode = '23514';
      end if;
      if not new.is_goal and exists (select 1 from public.project_milestones m where m.project_id = new.id) then
        raise exception 'Delete its milestones first' using errcode = '23514';
      end if;
    end if;
    -- The purpose level is chosen while a draft, like the kind (it decides who sees it as theirs).
    if new.purpose_id is distinct from old.purpose_id and old.status <> 'draft' then
      raise exception 'The purpose is chosen before the project is submitted' using errcode = '23514';
    end if;
    -- A special Sunday is the Resident Pastor's or the Operations Lead's call, while it is to come.
    if new.is_special_sunday is distinct from old.is_special_sunday then
      if not app.has_any_role(array['resident_pastor','operations_lead']::public.app_role[]) then
        raise exception 'The Resident Pastor or the Operations Lead decides a special Sunday' using errcode = '42501';
      end if;
      if old.status in ('done', 'cancelled') then
        raise exception 'This Sunday has finished' using errcode = '23514';
      end if;
      -- Its planning committee goes when it stops being special (only special Sundays have one).
      if not new.is_special_sunday and exists (select 1 from public.project_committee_members c where c.project_id = new.id) then
        raise exception 'Remove its planning committee first' using errcode = '23514';
      end if;
    end if;
  end if;

  -- Only a team project can be a routine team activity; a church or purpose project that is
  -- not an event is goal-based (or the Brief's own project).
  if not new.is_event and not new.is_goal and new.level <> 'unit'
     and (tg_op = 'INSERT' or not exists (select 1 from public.newsletter_issues i where i.project_id = new.id)) then
    raise exception 'A church project is an event or a goal-based project; only a team project can be a routine team activity'
      using errcode = '23514';
  end if;
  -- The purpose level is set by the purpose's own head, the Operations Lead or the Coordinator.
  if new.purpose_id is not null and (tg_op = 'INSERT' or new.purpose_id is distinct from old.purpose_id)
     and not (app.is_purpose_head_of(new.purpose_id)
              or app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])) then
    raise exception 'Only the purpose''s head, the Operations Lead or the Coordinator sets a project at that purpose''s level'
      using errcode = '42501';
  end if;
  -- A project linked to a programme: a team project to its own team's programme; an active one.
  if new.programme_id is not null and (tg_op = 'INSERT' or new.programme_id is distinct from old.programme_id
                                       or new.unit_id is distinct from old.unit_id) then
    select up.unit_id, up.is_active into v_prog from public.unit_programmes up
     where up.id = new.programme_id and up.church_id = new.church_id;
    if not found or not v_prog.is_active then
      raise exception 'Choose one of the team''s current programmes' using errcode = '23514';
    end if;
    if new.level = 'unit' and new.unit_id <> v_prog.unit_id then
      raise exception 'A team project is linked to one of its own team''s programmes' using errcode = '23514';
    end if;
    if new.is_sunday_service then
      raise exception 'Sundays are not linked to a programme' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
revoke all on function app.project_kind_guard() from public, anon, authenticated;
grant execute on function app.project_kind_guard() to service_role;

-- Re-created whole from migration 25 (the last full version), with the goal-based approver,
-- the purpose level and the special Sunday flag (marked "Migration 37" inline).
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
  -- Migration 37 (decision of 27 Nov 2026): a goal-based project at any level is decided by
  -- the Resident Pastor, with the leadership, usually in the year plan.
  v_is_approver := case when old.is_goal then app.has_role('resident_pastor')
                        else app.is_project_approver(old.level, old.unit_id) end;

  -- Non-managers (approvers) may only change the status, the shortfall action and their note.
  -- Migration 37: is_special_sunday too; app.project_kind_guard lets only the Resident Pastor
  -- or the Operations Lead change it.
  if not v_is_manager and
     (to_jsonb(new) - array['status','approved_by','approved_at','updated_at','shortfall_action','shortfall_action_note','decision_note','is_special_sunday'])
     <> (to_jsonb(old) - array['status','approved_by','approved_at','updated_at','shortfall_action','shortfall_action_note','decision_note','is_special_sunday']) then
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
      or new.unit_id is distinct from old.unit_id or new.purpose_id is distinct from old.purpose_id) then
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
    -- SECURITY REVIEW 16 (V02): the approver was worked out from the NEW level and unit, so a
    -- manager could change them in the approving request: the Operations Lead turning a
    -- submitted unit project into a church project and approving it at once, or an owner who
    -- heads another unit's purpose moving it there. The approval is now for the project as it
    -- was submitted: level and unit cannot change in the same request.
    if new.level <> old.level or new.unit_id is distinct from old.unit_id
       or new.is_goal <> old.is_goal or new.purpose_id is distinct from old.purpose_id then
      raise exception 'Change the level or unit on its own first; the new approver then decides' using errcode = '42501';
    end if;
    -- Migration 37: goal-based projects by the Resident Pastor; others as before.
    if not (case when new.is_goal then app.has_role('resident_pastor')
                 else app.is_project_approver(new.level, new.unit_id) end) then
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
revoke all on function app.project_guard() from public, anon, authenticated;
grant execute on function app.project_guard() to service_role;

-- -------------------------------------------------------------------------------------
-- 2. Milestones and outputs of goal-based projects
-- -------------------------------------------------------------------------------------
create table public.project_milestones (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null default app.current_church_id() references public.churches(id) on delete restrict,
  project_id  uuid not null,
  title       text not null check (length(btrim(title)) between 1 and 200),
  output      text check (length(output) <= 1000),     -- what is delivered when it is met
  due_on      date not null,
  done_on     date,
  sort_order  smallint not null default 0,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (church_id, id),
  foreign key (church_id, project_id) references public.projects(church_id, id) on delete cascade
);
create index project_milestones_project on public.project_milestones (project_id, due_on);
comment on table public.project_milestones is
  'Milestones and outputs of a goal-based project (migration 37); it closes when every one is met.';

-- Changed by the project's managers while the project is open; a milestone is met on a day
-- that has come. A milestone stays with its project.
create or replace function app.milestone_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Europe/London')::date;
  v_project uuid := case when tg_op = 'DELETE' then old.project_id else new.project_id end;
  p public.projects;
begin
  if app.is_system() then return coalesce(new, old); end if;
  select * into p from public.projects x where x.id = v_project and x.church_id = (select app.current_church_id());
  if not found then
    -- The project is being deleted (a draft), and its milestones go with it.
    if tg_op = 'DELETE' and not exists (select 1 from public.projects x where x.id = v_project) then
      return old;
    end if;
    raise exception 'Milestones belong to a goal-based project' using errcode = '23514';
  end if;
  if not p.is_goal then
    raise exception 'Milestones belong to a goal-based project' using errcode = '23514';
  end if;
  if not app.can_manage_project(p.id) then
    raise exception 'Only the project''s owner or the Operations Lead changes its milestones' using errcode = '42501';
  end if;
  if p.status in ('done', 'cancelled') then
    raise exception 'This project has closed' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if new.done_on is not null and new.done_on > v_today then
    raise exception 'A milestone is met on a day that has come' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' then
    if new.project_id <> old.project_id or new.church_id <> old.church_id then
      raise exception 'A milestone stays with its project' using errcode = '42501';
    end if;
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  else
    new.created_by := (select auth.uid());
    new.created_at := now();
  end if;
  new.church_id := p.church_id;
  new.updated_at := now();
  return new;
end $$;
revoke all on function app.milestone_guard() from public, anon, authenticated;
grant execute on function app.milestone_guard() to service_role;
create trigger project_milestones_guard before insert or update or delete on public.project_milestones
  for each row execute function app.milestone_guard();

alter table public.project_milestones enable row level security;
revoke all on public.project_milestones from public, anon, authenticated;
grant select, insert, update, delete on public.project_milestones to authenticated;
-- Read across the church, as projects are; changed by the project's managers.
create policy project_milestones_read on public.project_milestones for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy project_milestones_insert on public.project_milestones for insert to authenticated
  with check (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));
create policy project_milestones_update on public.project_milestones for update to authenticated
  using (church_id = (select app.current_church_id()) and app.can_manage_project(project_id))
  with check (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));
create policy project_milestones_delete on public.project_milestones for delete to authenticated
  using (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));

-- A goal-based project is submitted and approved with at least one milestone, and closes when
-- every milestone is met. Named so it fires after app.project_guard (name order), which may
-- still send a project back.
create or replace function app.project_milestone_rules() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() or not new.is_goal or new.status = old.status then return new; end if;
  if new.status in ('submitted', 'approved')
     and not exists (select 1 from public.project_milestones m where m.project_id = new.id) then
    raise exception 'Name at least one milestone, with its output, before the project goes for approval' using errcode = '23514';
  end if;
  if new.status = 'done'
     and exists (select 1 from public.project_milestones m where m.project_id = new.id and m.done_on is null) then
    raise exception 'Every milestone must be met before the project closes' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function app.project_milestone_rules() from public, anon, authenticated;
grant execute on function app.project_milestone_rules() to service_role;
create trigger project_milestone_rules before update on public.projects
  for each row execute function app.project_milestone_rules();

-- -------------------------------------------------------------------------------------
-- 3. Planning committees: events still to happen (not ordinary Sundays), special Sundays and
--    goal-based projects. Re-created from migration 36.
-- -------------------------------------------------------------------------------------
create or replace function app.committee_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' then
    if not exists (select 1 from public.projects p where p.id = old.project_id) or app.person_gone(old.person_id) then
      return old;
    end if;
    if not app.can_manage_project(old.project_id) then
      raise exception 'Only the project''s owner or the Operations Lead changes its committee' using errcode = '42501';
    end if;
    return old;
  end if;
  if not app.can_manage_project(new.project_id) or not app.can_read_person(new.person_id) then
    raise exception 'Only the project''s owner or the Operations Lead changes its committee' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and (new.project_id <> old.project_id or new.person_id <> old.person_id or new.id <> old.id) then
    raise exception 'Only the role on the committee can change' using errcode = '23514';
  end if;
  if tg_op = 'INSERT' then
    -- Migration 37: an event (a Sunday only when it is special) or a goal-based project, still open.
    if exists (select 1 from public.projects p where p.id = new.project_id
               and (p.status in ('done', 'cancelled')
                    or not (p.is_goal or (p.is_event and (not p.is_sunday_service or p.is_special_sunday))))) then
      raise exception 'A committee is named for an event, a special Sunday or a goal-based project that is still open' using errcode = '23514';
    end if;
    if not exists (select 1 from public.people x where x.id = new.person_id and x.status = 'active' and x.anonymised_at is null) then
      raise exception 'Committee members are current G-Squad members' using errcode = '23514';
    end if;
    new.added_by := (select auth.uid());
    new.created_at := now();
  else
    new.added_by := old.added_by;
    new.created_at := old.created_at;
    new.church_id := old.church_id;
  end if;
  return new;
end $$;
revoke all on function app.committee_guard() from public, anon, authenticated;
grant execute on function app.committee_guard() to service_role;

-- -------------------------------------------------------------------------------------
-- 4. Team programmes
-- -------------------------------------------------------------------------------------
-- Who keeps a team's programmes: its Team Lead, the Coordinator or the Operations Lead.
create or replace function app.can_keep_programmes(p_unit uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select app.is_unit_lead_of(p_unit) or app.has_any_role(array['gsquad_coordinator','operations_lead']::public.app_role[])
$$;
revoke all on function app.can_keep_programmes(uuid) from public, anon;
grant execute on function app.can_keep_programmes(uuid) to authenticated, service_role;

create or replace function app.programme_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and (new.unit_id <> old.unit_id or new.church_id <> old.church_id) then
    raise exception 'A programme stays with its team' using errcode = '42501';
  end if;
  -- A programme that has reported keeps its area, so its reports still make sense.
  if tg_op = 'UPDATE' and new.report_area is distinct from old.report_area and old.report_area is not null
     and exists (select 1 from public.programme_reports r where r.unit_id = old.unit_id and r.area = old.report_area)
     and not exists (select 1 from public.unit_programmes up where up.unit_id = old.unit_id
                       and up.report_area = old.report_area and up.id <> old.id and up.is_active) then
    raise exception 'This team has reported on that area: keep it, or stop the programme and start a new one' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then
    if exists (select 1 from public.projects p where p.programme_id = old.id) then
      raise exception 'Projects are linked to this programme: stop it instead of deleting it' using errcode = '23514';
    end if;
    return old;
  end if;
  if tg_op = 'UPDATE' then new.created_at := old.created_at; else new.created_at := now(); end if;
  return new;
end $$;
revoke all on function app.programme_guard() from public, anon, authenticated;
grant execute on function app.programme_guard() to service_role;
create trigger unit_programmes_guard before insert or update or delete on public.unit_programmes
  for each row execute function app.programme_guard();

alter table public.unit_programmes enable row level security;
revoke all on public.unit_programmes from public, anon, authenticated;
grant select, insert, update, delete on public.unit_programmes to authenticated;
-- Read across the church (what each team does is not sensitive); kept by the team's leaders.
create policy unit_programmes_read on public.unit_programmes for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy unit_programmes_insert on public.unit_programmes for insert to authenticated
  with check (church_id = (select app.current_church_id()) and app.can_keep_programmes(unit_id));
create policy unit_programmes_update on public.unit_programmes for update to authenticated
  using (church_id = (select app.current_church_id()) and app.can_keep_programmes(unit_id))
  with check (church_id = (select app.current_church_id()) and app.can_keep_programmes(unit_id));
create policy unit_programmes_delete on public.unit_programmes for delete to authenticated
  using (church_id = (select app.current_church_id()) and app.can_keep_programmes(unit_id));

-- -------------------------------------------------------------------------------------
-- 5. Monthly programme reports
-- -------------------------------------------------------------------------------------
create table public.programme_reports (
  id            uuid primary key default gen_random_uuid(),
  church_id     uuid not null default app.current_church_id() references public.churches(id) on delete restrict,
  unit_id       uuid not null,
  area          public.programme_area not null,
  report_month  date not null check (extract(day from report_month) = 1),
  figures       jsonb not null default '{}'::jsonb,     -- the typed counts (keys by area, below)
  commentary    text check (length(commentary) <= 4000),
  status        public.report_status not null default 'draft',
  submitted_by  uuid,
  submitted_at  timestamptz,
  updated_by    uuid,
  updated_at    timestamptz not null default now(),
  unique (church_id, id),
  unique (unit_id, area, report_month),
  check ((status = 'submitted') = (submitted_at is not null)),
  foreign key (church_id, unit_id) references public.units(church_id, id) on delete cascade
);
comment on table public.programme_reports is
  'A team''s monthly report on a programme area (migration 37): typed counts; the app''s own counts come from programme_report_figures.';

-- The typed counts each area asks for. Counts the app holds (G-Squad participation, decisions
-- for Christ at linked events, guests) are worked out, not typed.
create or replace function app.programme_typed_keys(p_area public.programme_area) returns text[]
language sql immutable set search_path = ''
as $$
  select case p_area
    when 'maturity'     then array['classes_held', 'people_completing', 'decisions_other']
    when 'evangelism'   then array['outreach_sessions', 'people_reached', 'decisions_other']
    when 'assimilation' then array['visitors_welcomed', 'onboarded_48h', 'connected_to_communities']
  end
$$;

-- Who writes a team's programme report: its Team Lead, or the Coordinator.
create or replace function app.can_write_programme_report(p_unit uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select app.is_unit_lead_of(p_unit) or app.has_role('gsquad_coordinator')
$$;
revoke all on function app.can_write_programme_report(uuid) from public, anon;
grant execute on function app.can_write_programme_report(uuid) to authenticated, service_role;

-- Who reads it: the monthly-report roles, and the team's own Lead and Deputy.
create or replace function app.can_read_programme_report(p_unit uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select app.has_any_role(array['gsquad_coordinator','resident_pastor','purpose_head',
                                'operations_lead','pastoral_lead']::public.app_role[])
      or app.sees_unit(p_unit)
$$;
revoke all on function app.can_read_programme_report(uuid) from public, anon;
grant execute on function app.can_read_programme_report(uuid) to authenticated, service_role;

create or replace function app.programme_report_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_this_month date := date_trunc('month', (now() at time zone 'Europe/London'))::date;
  k text;
  v jsonb;
begin
  if app.is_system() then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    if old.status <> 'draft' then
      raise exception 'A submitted report is kept' using errcode = '23514';
    end if;
    if not app.can_write_programme_report(old.unit_id) then
      raise exception 'Only the team''s Team Lead or the Coordinator changes this report' using errcode = '42501';
    end if;
    return old;
  end if;
  if not app.can_write_programme_report(new.unit_id) then
    raise exception 'Only the team''s Team Lead or the Coordinator writes this report' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' then
    if new.unit_id <> old.unit_id or new.area <> old.area or new.report_month <> old.report_month
       or new.church_id <> old.church_id then
      raise exception 'A report stays with its team, area and month' using errcode = '42501';
    end if;
    -- Once submitted it is the Coordinator's: only they return it to draft for changes.
    if old.status = 'submitted' then
      if not (app.has_role('gsquad_coordinator') and new.status = 'draft'
              and new.figures = old.figures and new.commentary is not distinct from old.commentary) then
        raise exception 'This report has been submitted: ask the Coordinator to return it for changes' using errcode = '23514';
      end if;
    end if;
  else
    -- A team reports on an area it has a current reporting programme for, for a month that has come.
    if not exists (select 1 from public.unit_programmes up where up.unit_id = new.unit_id
                     and up.report_area = new.area and up.is_active) then
      raise exception 'This team has no programme reporting on that area' using errcode = '23514';
    end if;
    if new.report_month > v_this_month then
      raise exception 'Report on a month that has come' using errcode = '23514';
    end if;
  end if;
  -- The typed counts: only this area's keys, each a whole number from 0 to 100000.
  if jsonb_typeof(new.figures) <> 'object' then
    raise exception 'Figures are a set of counts' using errcode = '22023';
  end if;
  for k, v in select * from jsonb_each(new.figures) loop
    if not k = any (app.programme_typed_keys(new.area)) then
      raise exception 'Unknown figure for this area: %', k using errcode = '22023';
    end if;
    if jsonb_typeof(v) = 'null' then continue; end if;
    if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric <> trunc((v #>> '{}')::numeric)
       or (v #>> '{}')::numeric < 0 or (v #>> '{}')::numeric > 100000 then
      raise exception 'Each figure is a whole number from 0 to 100000' using errcode = '22023';
    end if;
  end loop;
  -- Who submitted and when are recorded by the database.
  if new.status = 'submitted' and (tg_op = 'INSERT' or old.status <> 'submitted') then
    new.submitted_by := (select auth.uid());
    new.submitted_at := now();
  elsif new.status = 'draft' then
    new.submitted_by := null;
    new.submitted_at := null;
  else
    new.submitted_by := old.submitted_by;
    new.submitted_at := old.submitted_at;
  end if;
  new.church_id := (select app.current_church_id());
  new.updated_by := (select auth.uid());
  new.updated_at := now();
  return new;
end $$;
revoke all on function app.programme_report_guard() from public, anon, authenticated;
grant execute on function app.programme_report_guard() to service_role;
create trigger programme_reports_guard before insert or update or delete on public.programme_reports
  for each row execute function app.programme_report_guard();

alter table public.programme_reports enable row level security;
revoke all on public.programme_reports from public, anon, authenticated;
grant select, insert, update, delete on public.programme_reports to authenticated;
create policy programme_reports_read on public.programme_reports for select to authenticated
  using (church_id = (select app.current_church_id()) and app.can_read_programme_report(unit_id));
create policy programme_reports_insert on public.programme_reports for insert to authenticated
  with check (church_id = (select app.current_church_id()) and app.can_write_programme_report(unit_id));
create policy programme_reports_update on public.programme_reports for update to authenticated
  using (church_id = (select app.current_church_id()) and app.can_write_programme_report(unit_id))
  with check (church_id = (select app.current_church_id()) and app.can_write_programme_report(unit_id));
create policy programme_reports_delete on public.programme_reports for delete to authenticated
  using (church_id = (select app.current_church_id()) and app.can_write_programme_report(unit_id));

-- The counts the app holds for a team's area in a month, from projects linked to the team's
-- programmes in that area (approved, under way or done, starting in the month). Counts only.
-- G-Squad participation counts members serving and members attending; attendance at maturity
-- events is left out, because per team it would show a member's faith practice to readers who
-- may not see it (review 28, A01).
create or replace function public.programme_report_figures(p_unit uuid, p_area public.programme_area, p_month date)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_m date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month')::date;
  v jsonb;
begin
  if not exists (select 1 from public.units u where u.id = p_unit and u.church_id = app.current_church_id())
     or not app.can_read_programme_report(p_unit) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  with linked as (
    select p.id
    from public.projects p join public.unit_programmes up on up.id = p.programme_id
    where up.unit_id = p_unit and up.report_area = p_area and p.church_id = app.current_church_id()
      and p.status in ('approved', 'in_progress', 'done')
      and (p.starts_at at time zone 'Europe/London')::date >= v_m
      and (p.starts_at at time zone 'Europe/London')::date < v_end
  ), people_in as (
    select a.person_id from public.assignments a join linked l on l.id = a.project_id
     where a.status in ('planned', 'served') and a.serve_date >= v_m and a.serve_date < v_end
    union
    select ea.person_id from public.event_attendance ea join linked l on l.id = ea.project_id
     where ea.attended_on >= v_m and ea.attended_on < v_end and not app.is_maturity_event(ea.project_id)
  )
  select jsonb_build_object(
           'month', v_m,
           'linked_activities', (select count(*) from linked),
           'gsquad_participation', (select count(distinct person_id) from people_in),
           'decisions_for_christ', (select coalesce(sum(o.decisions_for_christ), 0) from public.project_outcomes o join linked l on l.id = o.project_id),
           'first_time_guests', (select coalesce(sum(o.first_time_guests), 0) from public.project_outcomes o join linked l on l.id = o.project_id),
           'guests_contacted_48h', (select coalesce(sum(o.guests_contacted_48h), 0) from public.project_outcomes o join linked l on l.id = o.project_id),
           'connected_to_community', (select coalesce(sum(o.connected_to_community), 0) from public.project_outcomes o join linked l on l.id = o.project_id))
    into v;
  return v;
end $$;
revoke all on function public.programme_report_figures(uuid, public.programme_area, date) from public, anon;
grant execute on function public.programme_report_figures(uuid, public.programme_area, date) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 6. Readiness: re-created from migration 33 with milestones and the goal-based approver.
-- -------------------------------------------------------------------------------------
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
    -- Migration 37: milestones of a goal-based project (needed to submit; all met to close).
    'milestones', case when p.is_goal then jsonb_build_object(
        'named', (select count(*) from public.project_milestones m where m.project_id = p.id),
        'open', (select count(*) from public.project_milestones m where m.project_id = p.id and m.done_on is null)) end,
    -- Migration 37: a goal-based project is decided by the Resident Pastor.
    'can_approve', case when p.is_goal then app.has_role('resident_pastor') else app.is_project_approver(p.level, p.unit_id) end,
    'self_approval', case when p.is_goal then false
                          else app.is_project_approver(p.level, p.unit_id) and p.owner_user_id = (select auth.uid()) end
  );
end $$;
revoke all on function public.project_readiness(uuid) from public, anon;
grant execute on function public.project_readiness(uuid) to authenticated, service_role;
