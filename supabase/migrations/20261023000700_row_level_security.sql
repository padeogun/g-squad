-- =====================================================================================
-- G-Squad Planner: 7. Row-level security
-- Access is enforced in the database, not only by hiding parts of the screen.
-- Rules of thumb used below:
--   * every policy first checks the row belongs to the caller's church (CC)
--   * "anon" (not signed in) gets nothing at all
--   * faith fields, pastoral notes, RSVPs, reactions and email tokens have NO select policy:
--     they are read only through the logged functions in migration 6
--   * nothing is ever deleted through the API except where a policy below says so;
--     people are anonymised (migration 9), not deleted
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Defaults and grants
-- -------------------------------------------------------------------------------------

-- church_id fills itself from the signed-in user's account, so the app never has to send it
-- (and a policy still rejects any other value the app might send).
do $$
declare t text;
begin
  for t in
    select c.table_name from information_schema.columns c
    join information_schema.tables tb on tb.table_schema = c.table_schema and tb.table_name = c.table_name
    where c.table_schema = 'public' and c.column_name = 'church_id' and tb.table_type = 'BASE TABLE'
      and c.table_name not in ('church_settings', 'audit_log')
  loop
    execute format('alter table public.%I alter column church_id set default app.current_church_id()', t);
  end loop;
end $$;

-- Turn RLS on for every table. (Not FORCE: the SECURITY DEFINER helper functions run as the
-- table owner and must read app_users / role_assignments without re-entering these policies.)
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Not-signed-in visitors get no table or function access at all.
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated, service_role;
-- The email-link redeemer is for the Edge Function (service role) only.
revoke execute on function public.redeem_email_link(text) from authenticated;
-- Signed-in users may never touch the audit log, email tokens, RSVPs or reactions directly.
revoke insert, update, delete, truncate on public.audit_log from authenticated;
revoke all on public.email_link_tokens, public.newsletter_rsvps, public.newsletter_reactions from authenticated;
revoke truncate, references, trigger on all tables in schema public from authenticated;

-- -------------------------------------------------------------------------------------
-- 2. Foundation
-- -------------------------------------------------------------------------------------

create policy churches_read on public.churches for select to authenticated
  using (id = (select app.current_church_id()));

create policy sites_read on public.sites for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy sites_write on public.sites for all to authenticated
  using (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')))
  with check (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')));

create policy settings_read on public.church_settings for select to authenticated
  using (church_id = (select app.current_church_id()));
-- SECURITY REVIEW FIX F02: the Resident Pastor may also update settings, because only they may
-- switch on Purpose Heads reading pastoral notes (column rule in migration 20261023001000).
create policy settings_update on public.church_settings for update to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','resident_pastor']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','resident_pastor']::public.app_role[])));

-- Leaders' display names are visible across the church (owners, requesters, approvers).
create policy app_users_read on public.app_users for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy app_users_admin on public.app_users for all to authenticated
  using (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')))
  with check (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')));

create policy purposes_read on public.purposes for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy purposes_write on public.purposes for all to authenticated
  using (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')))
  with check (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')));

create policy units_read on public.units for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy units_write on public.units for all to authenticated
  using (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')))
  with check (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')));

-- Users see their own roles; the Operations Lead and Resident Pastor see everyone's.
create policy roles_read on public.role_assignments for select to authenticated
  using (church_id = (select app.current_church_id())
         and (user_id = (select auth.uid())
              or (select app.has_any_role(array['operations_lead','resident_pastor']::public.app_role[]))));
-- SECURITY REVIEW FIX F01: the Resident Pastor may also write role assignments; the trigger
-- app.role_assignment_guard (migration 20261023001000) stops anyone changing their own roles and
-- reserves the roles that can read faith fields or pastoral notes for the Resident Pastor.
create policy roles_write on public.role_assignments for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','resident_pastor']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','resident_pastor']::public.app_role[])));

-- SECURITY REVIEW FIX F04: entries about faith fields, pastoral notes and one-to-ones (who
-- viewed or changed whose record) are themselves sensitive: Resident Pastor only.
create policy audit_read on public.audit_log for select to authenticated
  using (church_id = (select app.current_church_id())
         and ((select app.has_role('resident_pastor'))
              or ((select app.has_role('operations_lead'))
                  and coalesce(table_name, '') not in ('person_faith', 'pastoral_notes', 'one_to_ones')
                  and action not in ('view_faith', 'view_pastoral'))));

-- -------------------------------------------------------------------------------------
-- 3. Reference forms: everyone in the church reads them; named roles maintain them.
-- -------------------------------------------------------------------------------------

create policy church_roles_read on public.church_roles for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy church_roles_write on public.church_roles for all to authenticated
  using (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')))
  with check (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')));

-- TECi Stages: managed by the TECi Coordinator.
create policy teci_read on public.teci_stages for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy teci_write on public.teci_stages for all to authenticated
  using (church_id = (select app.current_church_id()) and (select app.has_role('teci_coordinator')))
  with check (church_id = (select app.current_church_id()) and (select app.has_role('teci_coordinator')));

create policy leadership_stages_read on public.leadership_stages for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy leadership_stages_write on public.leadership_stages for all to authenticated
  using (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')))
  with check (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')));

-- Greatness Communities and types: Operations Lead or G-Squad Coordinator (owner still to be
-- confirmed in the spec; narrow this policy once it is).
create policy community_types_read on public.community_types for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy community_types_write on public.community_types for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])));

create policy communities_read on public.greatness_communities for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy communities_write on public.greatness_communities for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])));

create policy support_roles_read on public.community_support_roles for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy support_roles_write on public.community_support_roles for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])));

create policy project_types_read on public.project_types for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy project_types_write on public.project_types for all to authenticated
  using (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')))
  with check (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')));

create policy blocks_read on public.reusable_blocks for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy blocks_write on public.reusable_blocks for all to authenticated
  using (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')))
  with check (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')));

-- -------------------------------------------------------------------------------------
-- 4. People and Teams
-- -------------------------------------------------------------------------------------

-- Contact and member details: scope from app.can_read_person() (migrations 3 and 4).
create policy people_read on public.people for select to authenticated
  using (church_id = (select app.current_church_id()) and app.can_read_person(id));
-- Unit Leads and the Operations Lead add members; created_by must be the caller.
create policy people_insert on public.people for insert to authenticated
  with check (church_id = (select app.current_church_id())
              and created_by = (select auth.uid())
              and (select app.has_any_role(array['unit_lead','operations_lead']::public.app_role[])));
create policy people_update on public.people for update to authenticated
  using (church_id = (select app.current_church_id()) and app.can_edit_person(id))
  with check (church_id = (select app.current_church_id()) and app.can_edit_person(id));
-- No delete policy: leaving members are anonymised instead (R8).

-- person_faith: no policies at all for authenticated. Reads: public.get_person_faith().
-- Writes: public.set_person_faith() (migration 8).
revoke all on public.person_faith from authenticated;

-- Memberships: visible with the person; added and changed by the unit's lead or the Ops Lead.
create policy memberships_read on public.unit_memberships for select to authenticated
  using (church_id = (select app.current_church_id())
         and (app.can_read_person(person_id) or app.is_unit_lead_of(unit_id) or app.is_purpose_head_of_unit(unit_id)));
-- SECURITY REVIEW FIX F05: a Unit Lead may add only a person they entered themselves. Before,
-- a Unit Lead could add ANY person id (ids are visible in app_users, event plans, grids) to their
-- unit and so gain that person's contact details and faith fields. Adding an existing member
-- of another unit goes through the Operations Lead.
create policy memberships_write on public.unit_memberships for insert to authenticated
  with check (church_id = (select app.current_church_id())
              and ((app.is_unit_lead_of(unit_id)
                    and exists (select 1 from public.people p
                                where p.id = unit_memberships.person_id and p.created_by = (select auth.uid())))
                   or (select app.has_role('operations_lead'))));
create policy memberships_update on public.unit_memberships for update to authenticated
  using (church_id = (select app.current_church_id())
         and (app.is_unit_lead_of(unit_id) or (select app.has_any_role(array['operations_lead','resident_pastor']::public.app_role[]))))
  with check (church_id = (select app.current_church_id())
         and (app.is_unit_lead_of(unit_id) or (select app.has_any_role(array['operations_lead','resident_pastor']::public.app_role[]))));

create policy holidays_read on public.holidays for select to authenticated
  using (church_id = (select app.current_church_id()) and app.can_read_person(person_id));
create policy holidays_write on public.holidays for all to authenticated
  using (church_id = (select app.current_church_id()) and app.can_edit_person(person_id))
  with check (church_id = (select app.current_church_id()) and app.can_edit_person(person_id));

-- Check-in flags: seen by anyone who can see the person; raised by hand only as "manual";
-- closed by the pastoral lead or Resident Pastor.
create policy flags_read on public.checkin_flags for select to authenticated
  using (church_id = (select app.current_church_id()) and app.can_read_person(person_id));
create policy flags_insert on public.checkin_flags for insert to authenticated
  with check (church_id = (select app.current_church_id()) and app.can_read_person(person_id)
              and source = 'manual' and status = 'open' and raised_by = (select auth.uid()));
create policy flags_close on public.checkin_flags for update to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['pastoral_lead','resident_pastor']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['pastoral_lead','resident_pastor']::public.app_role[])));

-- Pastoral notes: write-only through the table (the author must be the caller); reads go
-- through public.get_pastoral_notes(), which logs every view. Authors may correct their own.
create policy pastoral_insert on public.pastoral_notes for insert to authenticated
  with check (church_id = (select app.current_church_id()) and author_id = (select auth.uid())
              and app.can_see_pastoral(person_id));
revoke select, update, delete on public.pastoral_notes from authenticated;

-- One-to-ones: written by the unit's lead about a member of that unit; read by the writer,
-- the unit's Purpose Head, the G-Squad Coordinator and the Resident Pastor.
create policy one_to_ones_read on public.one_to_ones for select to authenticated
  using (church_id = (select app.current_church_id()) and app.can_read_one_to_one(unit_id, lead_user_id));
create policy one_to_ones_insert on public.one_to_ones for insert to authenticated
  with check (church_id = (select app.current_church_id())
              and lead_user_id = (select auth.uid()) and app.is_unit_lead_of(unit_id)
              and exists (select 1 from public.unit_memberships m
                          where m.person_id = one_to_ones.person_id and m.unit_id = one_to_ones.unit_id
                            and m.status <> 'ended'));
create policy one_to_ones_update on public.one_to_ones for update to authenticated
  using (church_id = (select app.current_church_id()) and lead_user_id = (select auth.uid()) and app.is_unit_lead_of(unit_id))
  with check (church_id = (select app.current_church_id()) and lead_user_id = (select auth.uid()) and app.is_unit_lead_of(unit_id));

-- -------------------------------------------------------------------------------------
-- 5. Projects
-- -------------------------------------------------------------------------------------

-- Projects are visible across the church (annual calendar, dashboards).
create policy projects_read on public.projects for select to authenticated
  using (church_id = (select app.current_church_id()));
-- Creating: church projects by the Resident Pastor, a Purpose Head, the Coordinator or the
-- Operations Lead; unit projects by that unit's lead or Purpose Head, the Coordinator or Ops Lead.
create policy projects_insert on public.projects for insert to authenticated
  with check (
    church_id = (select app.current_church_id())
    and owner_user_id = (select auth.uid())
    and (
      (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[]))
      or (level = 'church' and (select app.has_any_role(array['resident_pastor','purpose_head']::public.app_role[])))
      or (level = 'unit' and (app.is_unit_lead_of(unit_id) or app.is_purpose_head_of_unit(unit_id)))
    ));
-- Updating: the owner, the Ops Lead, or a would-be approver (status rules in migration 8).
create policy projects_update on public.projects for update to authenticated
  using (church_id = (select app.current_church_id())
         and (owner_user_id = (select auth.uid())
              or (select app.has_any_role(array['operations_lead','resident_pastor']::public.app_role[]))
              or (level = 'unit' and app.is_purpose_head_of_unit(unit_id))))
  with check (church_id = (select app.current_church_id()));
-- Only drafts can be deleted, by their owner or the Ops Lead.
create policy projects_delete on public.projects for delete to authenticated
  using (church_id = (select app.current_church_id()) and status = 'draft'
         and (owner_user_id = (select auth.uid()) or (select app.has_role('operations_lead'))));

create policy demand_read on public.team_demand for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy demand_write on public.team_demand for all to authenticated
  using (church_id = (select app.current_church_id()) and app.can_manage_project(project_id))
  with check (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));

-- Assignments: visible to the unit's lead and Purpose Head, the project owner, and
-- church-wide leaders; made by the unit's lead or the Ops Lead (limits in migration 8).
create policy assignments_read on public.assignments for select to authenticated
  using (church_id = (select app.current_church_id())
         and (app.is_unit_lead_of(unit_id) or app.is_purpose_head_of_unit(unit_id)
              or app.owns_project(project_id)
              or (select app.has_any_role(array['operations_lead','resident_pastor','gsquad_coordinator']::public.app_role[]))));
create policy assignments_write on public.assignments for insert to authenticated
  with check (church_id = (select app.current_church_id())
              and (app.is_unit_lead_of(unit_id) or (select app.has_role('operations_lead'))));
create policy assignments_update on public.assignments for update to authenticated
  using (church_id = (select app.current_church_id())
         and (app.is_unit_lead_of(unit_id) or (select app.has_role('operations_lead'))))
  with check (church_id = (select app.current_church_id())
         and (app.is_unit_lead_of(unit_id) or (select app.has_role('operations_lead'))));

-- Inputs: visible across the church (outstanding inputs on the Church Dashboard). Requested by
-- the project's manager; the person asked can fill in their own input (columns limited in migration 8).
create policy inputs_read on public.project_inputs for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy inputs_insert on public.project_inputs for insert to authenticated
  with check (church_id = (select app.current_church_id()) and app.can_manage_project(project_id)
              and requested_by = (select auth.uid()));
create policy inputs_update on public.project_inputs for update to authenticated
  using (church_id = (select app.current_church_id())
         and (app.can_manage_project(project_id) or requested_from_user_id = (select auth.uid())))
  with check (church_id = (select app.current_church_id())
         and (app.can_manage_project(project_id) or requested_from_user_id = (select auth.uid())));
create policy inputs_delete on public.project_inputs for delete to authenticated
  using (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));

-- Event plans: the project's manager edits; Finance and the Resident Pastor may update the
-- budget decision (which columns each may change is checked in migration 8).
create policy event_plans_read on public.event_plans for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy event_plans_insert on public.event_plans for insert to authenticated
  with check (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));
create policy event_plans_update on public.event_plans for update to authenticated
  using (church_id = (select app.current_church_id())
         and (app.can_manage_project(project_id) or (select app.has_any_role(array['finance','resident_pastor']::public.app_role[]))))
  with check (church_id = (select app.current_church_id()));

create policy actions_read on public.event_plan_actions for select to authenticated
  using (church_id = (select app.current_church_id()));
-- SECURITY REVIEW FIX F15: before, anyone could add action points to any project by naming
-- themselves as owner. Now only the project's manager adds or deletes them; the action owner
-- may update their own (e.g. mark done).
create policy actions_insert on public.event_plan_actions for insert to authenticated
  with check (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));
create policy actions_update on public.event_plan_actions for update to authenticated
  using (church_id = (select app.current_church_id())
         and (app.can_manage_project(project_id) or owner_user_id = (select auth.uid())))
  with check (church_id = (select app.current_church_id())
         and (app.can_manage_project(project_id) or owner_user_id = (select auth.uid())));
create policy actions_delete on public.event_plan_actions for delete to authenticated
  using (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));

-- Sunday Service Grid: everyone reads; the Ops Lead builds; the Resident Pastor approves.
create policy grids_read on public.service_grids for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy grids_insert on public.service_grids for insert to authenticated
  with check (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')));
create policy grids_update on public.service_grids for update to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','resident_pastor']::public.app_role[])))
  with check (church_id = (select app.current_church_id()));
create policy grids_delete on public.service_grids for delete to authenticated
  using (church_id = (select app.current_church_id()) and status = 'draft' and (select app.has_role('operations_lead')));

create policy segments_read on public.service_segments for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy segments_write on public.service_segments for all to authenticated
  using (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')))
  with check (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')));

create policy grid_blocks_read on public.service_grid_blocks for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy grid_blocks_write on public.service_grid_blocks for all to authenticated
  using (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')))
  with check (church_id = (select app.current_church_id()) and (select app.has_role('operations_lead')));

-- -------------------------------------------------------------------------------------
-- 6. Reports and newsletter
-- -------------------------------------------------------------------------------------

create policy reports_read on public.monthly_reports for select to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['resident_pastor','gsquad_coordinator','purpose_head',
                                            'operations_lead','pastoral_lead']::public.app_role[])));
create policy reports_write on public.monthly_reports for insert to authenticated
  with check (church_id = (select app.current_church_id()) and (select app.has_role('gsquad_coordinator')));
create policy reports_update on public.monthly_reports for update to authenticated
  using (church_id = (select app.current_church_id()) and (select app.has_role('gsquad_coordinator')))
  with check (church_id = (select app.current_church_id()) and (select app.has_role('gsquad_coordinator')));

create policy issues_read on public.newsletter_issues for select to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['newsletter_editor','gsquad_coordinator','resident_pastor','operations_lead']::public.app_role[])));
create policy issues_insert on public.newsletter_issues for insert to authenticated
  with check (church_id = (select app.current_church_id())
              and (select app.has_any_role(array['newsletter_editor','operations_lead']::public.app_role[])));
create policy issues_update on public.newsletter_issues for update to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['newsletter_editor','gsquad_coordinator','resident_pastor','operations_lead']::public.app_role[])))
  with check (church_id = (select app.current_church_id()));

create policy items_read on public.newsletter_items for select to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['newsletter_editor','gsquad_coordinator','resident_pastor','operations_lead']::public.app_role[])));
create policy items_write on public.newsletter_items for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['newsletter_editor','operations_lead']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['newsletter_editor','operations_lead']::public.app_role[])));

-- newsletter_rsvps, newsletter_reactions, email_link_tokens: RLS on, no policies, privileges
-- revoked above. Only the service role (Edge Function) touches them.
