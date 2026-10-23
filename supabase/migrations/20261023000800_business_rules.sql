-- =====================================================================================
-- G-Squad Planner: 8. Business rules
-- Triggers that enforce the spec's rules in the database, so the app cannot bypass them:
--   R2 serving limit with logged override, R3 third unit needs pastor approval,
--   R6 shortfall action before approval, R9 inputs before Done, R10 holidays,
--   R11 grid versioning and approval, R14 lead time, R15 owner and committee,
--   R16 budget approval, R17 newsletter approval order, R18 named items need agreement,
--   plus column guards (who may change which fields).
-- Convention: when auth.uid() is null the change comes from the service role or a scheduled
-- job (no API caller), and the role checks are skipped; anon has no write rights at all.
-- =====================================================================================

-- Small helper: true when the change has no signed-in caller (service role / cron).
-- SECURITY REVIEW FIX F08: "no auth.uid()" alone also matched the anon role (and any API
-- request without a "sub" claim), so a route for anon would have skipped every guard. The
-- request's role (the "role" setting PostgREST sets per request; SECURITY DEFINER does not
-- change it) must also not be one of the API's end-user roles.
create or replace function app.is_system() returns boolean
language sql stable set search_path = ''
as $$
  select (select auth.uid()) is null
     and coalesce(current_setting('role', true), 'none') not in ('anon', 'authenticated')
$$;

-- -------------------------------------------------------------------------------------
-- People: column guards
-- -------------------------------------------------------------------------------------
create or replace function app.people_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return new; end if;

  if tg_op = 'INSERT' then
    -- The TECi stage is set by the TECi Coordinator (or the Ops Lead), not on entry.
    if new.teci_stage_id is not null
       and not app.has_any_role(array['teci_coordinator','operations_lead']::public.app_role[]) then
      raise exception 'Only the TECi Coordinator can set a TECi stage' using errcode = '42501';
    end if;
    new.anonymised_at := null;
    return new;
  end if;

  -- UPDATE: identity columns never change through the API.
  if new.id <> old.id or new.church_id <> old.church_id or new.created_by is distinct from old.created_by then
    raise exception 'id, church and creator cannot be changed' using errcode = '42501';
  end if;
  -- Anonymising goes through app.anonymise(), which sets a transaction-local marker first.
  -- (API callers cannot set server settings, so they cannot fake the marker.)
  -- SECURITY REVIEW FIX F09: the marker can only be used to anonymise. Even if a caller ever
  -- managed to set it, the row must come out wiped (no contact details, status 'left').
  if current_setting('gsquad.anonymising', true) = 'on' then
    if new.anonymised_at is null or new.email is not null or new.area is not null
       or new.status <> 'left' or new.birth_day is not null or new.anniversary_day is not null then
      raise exception 'The anonymising marker may only be used to anonymise' using errcode = '42501';
    end if;
    return new;
  end if;
  if new.anonymised_at is distinct from old.anonymised_at then
    raise exception 'Use public.anonymise_person() to anonymise a record' using errcode = '42501';
  end if;
  if new.teci_stage_id is distinct from old.teci_stage_id
     and not app.has_any_role(array['teci_coordinator','operations_lead']::public.app_role[]) then
    raise exception 'Only the TECi Coordinator can change a TECi stage' using errcode = '42501';
  end if;
  -- The TECi Coordinator's own edit right covers the TECi stage only.
  if app.has_role('teci_coordinator')
     and not app.has_any_role(array['operations_lead','gsquad_coordinator','unit_lead']::public.app_role[])
     and (to_jsonb(new) - 'teci_stage_id' - 'updated_at') <> (to_jsonb(old) - 'teci_stage_id' - 'updated_at') then
    raise exception 'The TECi Coordinator can change the TECi stage only' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger people_guard before insert or update on public.people
  for each row execute function app.people_guard();

-- Faith fields: written only through this function, which checks access (Resident Pastor,
-- G-Squad Coordinator, TECi Coordinator, the person's Unit Lead) and audits the write.
create or replace function public.set_person_faith(
  p_person uuid,
  p_salvation_date date,
  p_water_baptism boolean, p_water_baptism_date date,
  p_holy_spirit_baptism boolean, p_holy_spirit_baptism_date date,
  p_speaks_in_tongues boolean, p_speaks_in_tongues_date date)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not app.can_see_faith(p_person) then
    raise exception 'Not allowed to record faith fields for this person' using errcode = '42501';
  end if;
  insert into public.person_faith as f (person_id, church_id, salvation_date,
      water_baptism, water_baptism_date, holy_spirit_baptism, holy_spirit_baptism_date,
      speaks_in_tongues, speaks_in_tongues_date, updated_by)
  values (p_person, app.current_church_id(), p_salvation_date,
      coalesce(p_water_baptism, false), p_water_baptism_date,
      coalesce(p_holy_spirit_baptism, false), p_holy_spirit_baptism_date,
      coalesce(p_speaks_in_tongues, false), p_speaks_in_tongues_date, (select auth.uid()))
  on conflict (person_id) do update set
      salvation_date = excluded.salvation_date,
      water_baptism = excluded.water_baptism, water_baptism_date = excluded.water_baptism_date,
      holy_spirit_baptism = excluded.holy_spirit_baptism, holy_spirit_baptism_date = excluded.holy_spirit_baptism_date,
      speaks_in_tongues = excluded.speaks_in_tongues, speaks_in_tongues_date = excluded.speaks_in_tongues_date,
      updated_by = excluded.updated_by;
end $$;

-- -------------------------------------------------------------------------------------
-- R3: joining more units than the church allows (default 2) needs the Resident Pastor.
-- -------------------------------------------------------------------------------------
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
      if app.has_role('resident_pastor') then
        new.status := 'active';
        new.approved_by := (select auth.uid());
      else
        new.status := 'pending_approval';     -- waits for the Resident Pastor
      end if;
    elsif new.status = 'pending_approval' then
      new.status := 'active';
    end if;
    return new;
  end if;

  -- UPDATE: approving a pending membership is for the Resident Pastor only.
  if old.status = 'pending_approval' and new.status = 'active' then
    if not app.has_role('resident_pastor') then
      raise exception 'A Resident Pastor must approve joining another unit' using errcode = '42501';
    end if;
    new.approved_by := (select auth.uid());
  elsif new.approved_by is distinct from old.approved_by then
    raise exception 'approved_by is set automatically' using errcode = '42501';
  end if;
  -- Re-activating an ended membership counts as joining again.
  if old.status = 'ended' and new.status = 'active' and v_live >= v_max and not app.has_role('resident_pastor') then
    new.status := 'pending_approval';
  end if;
  -- ended_on follows status.
  if new.status = 'ended' and new.ended_on is null then new.ended_on := current_date; end if;
  if new.status <> 'ended' then new.ended_on := null; end if;
  return new;
end $$;

create trigger membership_guard before insert or update on public.unit_memberships
  for each row execute function app.membership_guard();

-- -------------------------------------------------------------------------------------
-- R2 / R10: assignments respect the monthly limit and holidays.
-- -------------------------------------------------------------------------------------
create or replace function app.assignment_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_limit int;
  v_used int;
  v_proj record;
begin
  if tg_op = 'UPDATE' and (new.person_id <> old.person_id or new.church_id <> old.church_id) then
    raise exception 'Reassign by cancelling this slot and adding a new one' using errcode = '42501';
  end if;
  -- Only live slots are checked; marking served / no-show / cancelled is always allowed.
  if new.status not in ('planned', 'served') then return new; end if;
  if tg_op = 'UPDATE' and new.serve_date = old.serve_date and new.unit_id = old.unit_id
     and old.status in ('planned', 'served') then
    return new;
  end if;

  -- The serve date must fall within the project's dates.
  select p.starts_at, p.ends_at, p.status into v_proj from public.projects p where p.id = new.project_id;
  if new.serve_date < v_proj.starts_at::date or new.serve_date > v_proj.ends_at::date then
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

  -- R1 / R2: one monthly limit across all units; the Ops Lead may override with a reason.
  v_limit := app.personal_limit(new.person_id);
  v_used  := app.slots_in_month(new.person_id, new.serve_date, new.id);
  if v_used >= v_limit then
    if app.has_role('operations_lead') and coalesce(length(trim(new.override_reason)), 0) >= 5 then
      perform app.audit('override_limit', 'assignments', new.id,
                        jsonb_build_object('person_id', new.person_id, 'month', date_trunc('month', new.serve_date)::date,
                                           'limit', v_limit, 'slots_before', v_used));
    else
      raise exception 'This person already has % of % slots this month', v_used, v_limit
        using errcode = '23514', hint = 'The Operations Lead can override with a written reason.';
    end if;
  end if;
  return new;
end $$;

create trigger assignment_guard before insert or update on public.assignments
  for each row execute function app.assignment_guard();

-- -------------------------------------------------------------------------------------
-- Projects: approval and closing rules (R6, R9, R14, R15, R16) and who may move status.
-- -------------------------------------------------------------------------------------

-- Returns the first unit-month where this project's demand exceeds spare capacity, or null.
create or replace function app.project_shortfall(p_project uuid) returns text
language sql stable security definer set search_path = ''
as $$
  select u.name || ' in ' || to_char(d.m, 'Mon YYYY')
  from (
    select td.unit_id, date_trunc('month', td.on_date)::date as m, sum(td.slots_needed) as need
    from public.team_demand td where td.project_id = p_project
    group by 1, 2
  ) d
  join public.units u on u.id = d.unit_id
  where app.unit_capacity(d.unit_id, d.m, p_project) < d.need
  order by d.m, u.name
  limit 1
$$;

create or replace function app.project_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_plan public.event_plans%rowtype;
  v_has_plan boolean;
  v_short text;
  v_weeks int;
  v_is_manager boolean;
begin
  if tg_op = 'INSERT' then
    -- Every project starts as a draft with no approval, whatever the app sends.
    if not app.is_system() then
      new.status := 'draft';
      new.approved_by := null;
      new.approved_at := null;
    end if;
    return new;
  end if;

  if app.is_system() then return new; end if;

  if new.church_id <> old.church_id then
    raise exception 'Church cannot be changed' using errcode = '42501';
  end if;
  if new.owner_user_id <> old.owner_user_id and not app.has_role('operations_lead') then
    raise exception 'Only the Operations Lead can change a project owner' using errcode = '42501';
  end if;
  if new.approved_by is distinct from old.approved_by or new.approved_at is distinct from old.approved_at then
    if new.status = old.status then
      raise exception 'Approval is recorded automatically' using errcode = '42501';
    end if;
  end if;

  v_is_manager := old.owner_user_id = (select auth.uid()) or app.has_role('operations_lead');

  -- Non-managers (approvers) may only change the status and the shortfall action.
  if not v_is_manager and
     (to_jsonb(new) - array['status','approved_by','approved_at','updated_at','shortfall_action','shortfall_action_note'])
     <> (to_jsonb(old) - array['status','approved_by','approved_at','updated_at','shortfall_action','shortfall_action_note']) then
    raise exception 'Only the project owner or the Operations Lead can edit the project' using errcode = '42501';
  end if;

  -- Changing dates, level or unit of an approved project sends it back for approval.
  if old.status in ('approved', 'in_progress') and new.status = old.status and
     (new.starts_at <> old.starts_at or new.ends_at <> old.ends_at or new.level <> old.level
      or new.unit_id is distinct from old.unit_id) then
    new.status := 'submitted';
    new.approved_by := null;
    new.approved_at := null;
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
    if v_has_plan and v_plan.complexity = 'high' and not v_plan.has_planning_committee then
      raise exception 'A High complexity event needs a planning committee (R15)' using errcode = '23514';
    end if;
    new.approved_by := null; new.approved_at := null;
    return new;
  end if;

  -- submitted -> approved: unit projects by the unit's Purpose Head, church projects by the
  -- Resident Pastor. Checks R6, R14, R16.
  if new.status = 'approved' then
    if old.status <> 'submitted' then
      raise exception 'Only a submitted project can be approved' using errcode = '23514';
    end if;
    if not ((new.level = 'church' and app.has_role('resident_pastor'))
            or (new.level = 'unit' and app.is_purpose_head_of_unit(new.unit_id))) then
      raise exception 'You cannot approve this project' using errcode = '42501';
    end if;
    -- R6: shortfall needs a recorded action.
    v_short := app.project_shortfall(new.id);
    if v_short is not null and new.shortfall_action is null then
      raise exception 'Shortfall in %: record the action taken (move, scale down, borrow, recruit) (R6)', v_short
        using errcode = '23514';
    end if;
    if v_has_plan then
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

  -- Back to draft (rework) or cancelled: owner, Ops Lead, or Resident Pastor.
  if new.status in ('draft', 'cancelled') then
    if not (v_is_manager or app.has_role('resident_pastor')) then
      raise exception 'You cannot change this project''s status' using errcode = '42501';
    end if;
    if old.status = 'done' then
      raise exception 'A finished project cannot be reopened' using errcode = '23514';
    end if;
    new.approved_by := null; new.approved_at := null;
    return new;
  end if;

  return new;
end $$;

create trigger project_guard before insert or update on public.projects
  for each row execute function app.project_guard();

-- -------------------------------------------------------------------------------------
-- Inputs: the person asked may fill in their own input only; received_at follows status.
-- -------------------------------------------------------------------------------------
create or replace function app.input_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.status := 'requested';
    new.received_at := null;
    return new;
  end if;
  if not app.is_system() and not app.can_manage_project(old.project_id) then
    -- The person asked: body, link and marking it received only.
    if (to_jsonb(new) - array['body','link_url','status','received_at'])
       <> (to_jsonb(old) - array['body','link_url','status','received_at']) then
      raise exception 'You can only provide your own input' using errcode = '42501';
    end if;
  end if;
  if new.project_id <> old.project_id or new.church_id <> old.church_id then
    raise exception 'An input cannot move to another project' using errcode = '42501';
  end if;
  if new.status = 'received' and old.status <> 'received' then new.received_at := now(); end if;
  if new.status = 'requested' then new.received_at := null; end if;
  return new;
end $$;

create trigger input_guard before insert or update on public.project_inputs
  for each row execute function app.input_guard();

-- -------------------------------------------------------------------------------------
-- Event plans: budget decisions by Finance or the Resident Pastor only (R16).
-- -------------------------------------------------------------------------------------
create or replace function app.event_plan_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_budget_cols text[] := array['budget_status','budget_decided_by','budget_decided_at','updated_at'];
  v_approver boolean;
begin
  if app.is_system() then return new; end if;
  v_approver := app.has_any_role(array['finance','resident_pastor']::public.app_role[]);

  -- SECURITY REVIEW FIX F11 (R16): "not needed" with a budget estimate above zero is a budget
  -- decision, so only Finance or the Resident Pastor may make it.
  if new.budget_status = 'not_needed' and coalesce(new.budget_estimate_gbp, 0) > 0 and not v_approver then
    raise exception 'A plan with a budget estimate needs Finance or the Resident Pastor (R16)' using errcode = '42501';
  end if;

  if tg_op = 'INSERT' then
    -- A new plan starts with the budget pending, or not needed.
    if new.budget_status not in ('pending', 'not_needed') then new.budget_status := 'pending'; end if;
    new.budget_decided_by := null; new.budget_decided_at := null;
    new.review_completed_at := null;
    return new;
  end if;

  if new.project_id <> old.project_id or new.church_id <> old.church_id then
    raise exception 'A plan cannot move to another project' using errcode = '42501';
  end if;

  -- Budget approve / reject: Finance or Resident Pastor only.
  if new.budget_status is distinct from old.budget_status then
    if new.budget_status in ('approved', 'rejected') and not v_approver then
      raise exception 'Only Finance or the Resident Pastor can approve a budget' using errcode = '42501';
    end if;
    new.budget_decided_by := case when new.budget_status in ('approved','rejected') then (select auth.uid()) end;
    new.budget_decided_at := case when new.budget_status in ('approved','rejected') then now() end;
  elsif new.budget_decided_by is distinct from old.budget_decided_by or new.budget_decided_at is distinct from old.budget_decided_at then
    raise exception 'Budget decisions are recorded automatically' using errcode = '42501';
  end if;

  -- A changed estimate after approval needs a fresh decision.
  if old.budget_status = 'approved' and new.budget_estimate_gbp is distinct from old.budget_estimate_gbp
     and new.budget_status = 'approved' then
    new.budget_status := 'pending'; new.budget_decided_by := null; new.budget_decided_at := null;
  end if;

  -- Finance / Resident Pastor who are not managers of the project may change the budget only.
  if not app.can_manage_project(old.project_id)
     and (to_jsonb(new) - v_budget_cols) <> (to_jsonb(old) - v_budget_cols) then
    raise exception 'You can only decide the budget on this plan' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger event_plan_guard before insert or update on public.event_plans
  for each row execute function app.event_plan_guard();

-- -------------------------------------------------------------------------------------
-- R11: Sunday Service Grid finalising, approval and versioning.
-- -------------------------------------------------------------------------------------
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

  -- Approval: Resident Pastor only, from a finalised grid.
  if new.status = 'approved' and old.status <> 'approved' then
    if not app.has_role('resident_pastor') then
      raise exception 'Only the Resident Pastor approves the service grid' using errcode = '42501';
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
  if not app.has_role('operations_lead') then
    raise exception 'Only the Operations Lead edits the service grid' using errcode = '42501';
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
  end if;
  return new;
end $$;

create trigger grid_guard before insert or update on public.service_grids
  for each row execute function app.grid_guard();

-- Any change to a finalised or approved grid's segments or blocks raises the version.
create or replace function app.grid_content_changed() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_grid uuid := coalesce(new.grid_id, old.grid_id);
begin
  update public.service_grids g
     set version = g.version + 1, status = 'finalised', approved_by = null, approved_at = null
   where g.id = v_grid and g.status in ('finalised', 'approved');
  return null;
end $$;

create trigger segments_version after insert or update or delete on public.service_segments
  for each row execute function app.grid_content_changed();
create trigger grid_blocks_version after insert or update or delete on public.service_grid_blocks
  for each row execute function app.grid_content_changed();

-- -------------------------------------------------------------------------------------
-- R13: the monthly report is frozen once submitted.
-- -------------------------------------------------------------------------------------
create or replace function app.report_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.status := 'draft'; new.submitted_by := null; new.submitted_at := null;
    return new;
  end if;
  if app.is_system() then return new; end if;
  if old.status = 'submitted' then
    raise exception 'A submitted report cannot be changed' using errcode = '23514';
  end if;
  if new.status = 'submitted' then
    new.submitted_by := (select auth.uid()); new.submitted_at := now();
  end if;
  return new;
end $$;

create trigger report_guard before insert or update on public.monthly_reports
  for each row execute function app.report_guard();

-- -------------------------------------------------------------------------------------
-- R17 / R18: newsletter approval order and named items.
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
  if (new.coordinator_approved_by, new.coordinator_approved_at, new.pastor_approved_by, new.pastor_approved_at, new.sent_at)
     is distinct from (old.coordinator_approved_by, old.coordinator_approved_at, old.pastor_approved_by, old.pastor_approved_at, old.sent_at)
     and new.status = old.status then
    raise exception 'Approvals are recorded automatically' using errcode = '42501';
  end if;

  v_editor := app.has_any_role(array['newsletter_editor','operations_lead']::public.app_role[]);
  v_content_changed := (new.headline, new.standfirst, new.pastor_word, new.pastor_name, new.send_on)
                       is distinct from (old.headline, old.standfirst, old.pastor_word, old.pastor_name, old.send_on);

  if v_content_changed and not v_editor then
    raise exception 'Only newsletter editors change the content' using errcode = '42501';
  end if;

  -- An edit after any approval sends the issue back to the Coordinator.
  if v_content_changed and old.status in ('awaiting_pastor', 'approved') then
    new.status := 'awaiting_coordinator';
    new.coordinator_approved_by := null; new.coordinator_approved_at := null;
    new.pastor_approved_by := null; new.pastor_approved_at := null;
    return new;
  end if;

  if new.status = old.status then return new; end if;

  -- SECURITY REVIEW FIX F06 (R18): an item added or changed after submission (or while the
  -- issue was sent back by an item change) was never re-checked, so an unagreed named item could
  -- be approved. Every forward step now re-checks it.
  if new.status in ('awaiting_coordinator', 'awaiting_pastor', 'approved')
     and exists (select 1 from public.newsletter_items i
                 where i.issue_id = new.id and i.names_a_person and not i.agreement_ticked) then
    raise exception 'A named item is missing the person''s agreement (R18)' using errcode = '23514';
  end if;

  if new.status = 'awaiting_coordinator' then
    if not v_editor then
      raise exception 'Only newsletter editors submit an issue' using errcode = '42501';
    end if;
    -- R18: every named personal item needs the person's agreement ticked.
    if exists (select 1 from public.newsletter_items i
               where i.issue_id = new.id and i.names_a_person and not i.agreement_ticked) then
      raise exception 'A named item is missing the person''s agreement (R18)' using errcode = '23514';
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
  return new;
end $$;

create trigger issue_guard before insert or update on public.newsletter_issues
  for each row execute function app.issue_guard();

-- Items: no changes once sent; a change after any approval sends the issue back.
create or replace function app.issue_item_changed() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_issue uuid := coalesce(new.issue_id, old.issue_id);
  v_status public.issue_status;
begin
  select i.status into v_status from public.newsletter_issues i where i.id = v_issue;
  if v_status = 'sent' then
    raise exception 'A sent issue cannot be changed' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and new.issue_id <> old.issue_id then
    raise exception 'An item cannot move to another issue' using errcode = '42501';
  end if;
  if v_status in ('awaiting_pastor', 'approved') then
    update public.newsletter_issues
       set status = 'awaiting_coordinator',
           coordinator_approved_by = null, coordinator_approved_at = null,
           pastor_approved_by = null, pastor_approved_at = null
     where id = v_issue;
  end if;
  return coalesce(new, old);
end $$;

create trigger issue_item_changed before insert or update or delete on public.newsletter_items
  for each row execute function app.issue_item_changed();

-- -------------------------------------------------------------------------------------
-- Check-in flags: closing records who and when.
-- -------------------------------------------------------------------------------------
create or replace function app.flag_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.person_id <> old.person_id or new.source <> old.source or new.church_id <> old.church_id
     or new.raised_by is distinct from old.raised_by or new.raised_at <> old.raised_at then
    raise exception 'Only the status of a flag can change' using errcode = '42501';
  end if;
  if new.status = 'closed' and old.status = 'open' then
    new.closed_by := (select auth.uid()); new.closed_at := now();
  elsif new.status = 'open' then
    new.closed_by := null; new.closed_at := null;
  end if;
  return new;
end $$;

create trigger flag_guard before update on public.checkin_flags
  for each row execute function app.flag_guard();

-- One-to-ones and pastoral notes: the author cannot be reassigned.
-- SECURITY REVIEW FIX F16: nor can a one-to-one move to another unit (where the person may not
-- serve, changing which Purpose Head can read it).
create or replace function app.author_fixed() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if (to_jsonb(new) ->> 'person_id') <> (to_jsonb(old) ->> 'person_id')
     or (to_jsonb(new) ->> 'church_id') <> (to_jsonb(old) ->> 'church_id')
     or (to_jsonb(new) ->> 'unit_id') is distinct from (to_jsonb(old) ->> 'unit_id')
     or coalesce(to_jsonb(new) ->> 'lead_user_id', to_jsonb(new) ->> 'author_id')
        is distinct from coalesce(to_jsonb(old) ->> 'lead_user_id', to_jsonb(old) ->> 'author_id') then
    raise exception 'Person and author cannot be changed' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger one_to_ones_author before update on public.one_to_ones
  for each row execute function app.author_fixed();

revoke all on all functions in schema app from public;
grant execute on all functions in schema app to authenticated, service_role;
revoke execute on function public.set_person_faith(uuid, date, boolean, date, boolean, date, boolean, date) from anon, public;
grant execute on function public.set_person_faith(uuid, date, boolean, date, boolean, date, boolean, date) to authenticated;
