-- =====================================================================================
-- G-Squad Planner: 24. Projects and events (slice 4)
-- The schema, approvals (R6, R9, R14, R15, R16) and input tracker exist since migrations 4
-- and 8. This closes the gaps the project page needs:
--   1. The approver of a submitted project (the Resident Pastor for church projects, the
--      unit's Purpose Head for unit projects) may send it back to draft, with a note.
--      Before, a Purpose Head could approve a unit project but not return it for changes.
--   2. projects.decision_note: the approver's note on sending back or approving; only the
--      approver writes it.
--   3. The event review's completion time is stamped by the database.
--   4. Volunteers needed (team demand) must fall within the project's dates (London time).
--   5. public.project_readiness(project): the "before approval" checks as figures, so the
--      page shows Pass / Block / Action before anyone presses Submit or Approve. The same
--      rules still decide in app.project_guard; this only reports them.
-- Security review 15 (SECURITY_LOG.md) added: changed dates always send an approved project
-- back (U01); plan changes after approval do too, and R15 is checked again at approval (U02);
-- no reopening a finished project through "submitted" (U03); a column guard on action points
-- (U04); the decision note and the shortfall action only at the decision (U05, U06); input
-- receipt times that cannot be back-dated (U07); demand kept within changed dates (U08).
-- =====================================================================================

alter table public.projects
  add column decision_note text check (length(decision_note) <= 1000);

-- project_guard, re-created whole from migration 8 with the changes above (1 and 2), and the
-- fixes from security review 15 (U01 to U03, U05, U06, U08), each marked where it is made.
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
  if new.approved_by is distinct from old.approved_by or new.approved_at is distinct from old.approved_at then
    if new.status = old.status then
      raise exception 'Approval is recorded automatically' using errcode = '42501';
    end if;
  end if;

  v_is_manager := old.owner_user_id = (select auth.uid()) or app.has_role('operations_lead');
  -- The person who decides this project: the Resident Pastor for church projects, the unit's
  -- Purpose Head for unit projects (migration 24).
  v_is_approver := (old.level = 'church' and app.has_role('resident_pastor'))
                or (old.level = 'unit' and app.is_purpose_head_of_unit(old.unit_id));

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
  -- Resident Pastor. Checks R6, R14, R15, R16.
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

-- event_plan_guard, re-created whole from migration 8 with change 3.
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

  -- The review's completion time is the database's (migration 24): marking it complete records
  -- now, whatever time is sent; it can be cleared (reopened) but not back-dated.
  if new.review_completed_at is distinct from old.review_completed_at and new.review_completed_at is not null then
    new.review_completed_at := now();
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

-- -------------------------------------------------------------------------------------
-- 4. Team demand dates lie within the project (London dates of its start and end).
-- -------------------------------------------------------------------------------------
create or replace function app.demand_dates_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  p public.projects;
begin
  if app.is_system() then return new; end if;
  select * into p from public.projects where id = new.project_id;
  if new.on_date < (p.starts_at at time zone 'Europe/London')::date
     or new.on_date > (p.ends_at at time zone 'Europe/London')::date then
    raise exception 'Volunteers are needed on a day of the project (% to %)',
      to_char((p.starts_at at time zone 'Europe/London')::date, 'DD Mon YYYY'),
      to_char((p.ends_at at time zone 'Europe/London')::date, 'DD Mon YYYY')
      using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function app.demand_dates_guard() from public, anon, authenticated;
grant execute on function app.demand_dates_guard() to service_role;
create trigger team_demand_dates before insert or update on public.team_demand
  for each row execute function app.demand_dates_guard();

-- -------------------------------------------------------------------------------------
-- SECURITY REVIEW 15 (U02): a plan added or changed after approval in a way the approval
-- checked (R14 size, R15 complexity and committee, R16 budget) sends the project back for
-- approval. Before, an approved project could gain a Large, High complexity plan with no
-- budget decision, or lose its budget approval, and stay approved. AFTER the row is written,
-- so app.project_guard sees the new plan. The marker lets the status move whoever changed the
-- plan (Finance rejecting a budget is not a project manager); project_guard accepts only
-- "approved or in progress -> submitted" with no other column on that path.
-- -------------------------------------------------------------------------------------
create or replace function app.event_plan_resubmit() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return null; end if;
  if tg_op = 'UPDATE'
     and new.size = old.size and new.complexity = old.complexity
     and not (old.has_planning_committee and not new.has_planning_committee)
     and not (old.budget_status in ('approved', 'not_needed') and new.budget_status not in ('approved', 'not_needed')) then
    return null;
  end if;
  if exists (select 1 from public.projects p where p.id = new.project_id and p.status in ('approved', 'in_progress')) then
    perform set_config('gsquad.plan_resubmit', new.project_id::text, true);
    update public.projects set status = 'submitted' where id = new.project_id;
    perform set_config('gsquad.plan_resubmit', '', true);
  end if;
  return null;
end $$;
revoke all on function app.event_plan_resubmit() from public, anon, authenticated;
grant execute on function app.event_plan_resubmit() to service_role;
create trigger event_plan_resubmit after insert or update on public.event_plans
  for each row execute function app.event_plan_resubmit();

-- -------------------------------------------------------------------------------------
-- SECURITY REVIEW 15 (U04): action points had no column guard. The person an action is
-- given to (actions_update lets them update their own) could rewrite its text, section, due
-- date, or move it to any other project in the church. They may now only tick it done or
-- open; the project's managers edit the rest, and no one moves it to another project.
-- -------------------------------------------------------------------------------------
create or replace function app.action_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return new; end if;
  if new.project_id <> old.project_id or new.church_id <> old.church_id then
    raise exception 'An action point cannot move to another project' using errcode = '42501';
  end if;
  if not app.can_manage_project(old.project_id)
     and (to_jsonb(new) - 'status') <> (to_jsonb(old) - 'status') then
    raise exception 'You can only mark your action point done' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app.action_guard() from public, anon, authenticated;
grant execute on function app.action_guard() to service_role;
create trigger action_guard before update on public.event_plan_actions
  for each row execute function app.action_guard();

-- -------------------------------------------------------------------------------------
-- input_guard, re-created whole from migration 8. SECURITY REVIEW 15 (U07): received_at was
-- stamped only when the status changed, so the person asked (or a manager) could send any
-- date for an input already received and back-date it. It now always follows the status.
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
  if new.status = 'received' and old.status <> 'received' then new.received_at := now();
  elsif new.status = 'requested' then new.received_at := null;
  elsif not app.is_system() then new.received_at := old.received_at;
  end if;
  return new;
end $$;

-- -------------------------------------------------------------------------------------
-- 5. Readiness: the approval checks as figures. SECURITY DEFINER because the shortfall check
-- needs capacity across units (as app.project_guard does); it returns no names or personal
-- data, only the first short unit-month. Shown to the project's managers, its approver, and
-- the planning roles who already see the capacity calendar.
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
          or (p.level = 'church' and app.has_role('resident_pastor'))
          or (p.level = 'unit' and app.is_purpose_head_of_unit(p.unit_id))
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
    'can_approve', (p.level = 'church' and app.has_role('resident_pastor'))
                   or (p.level = 'unit' and app.is_purpose_head_of_unit(p.unit_id))
  );
end $$;
revoke all on function public.project_readiness(uuid) from public, anon;
grant execute on function public.project_readiness(uuid) to authenticated, service_role;
