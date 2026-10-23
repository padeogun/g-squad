-- =====================================================================================
-- G-Squad Planner: 13. Leader invitations by the G-Squad Coordinator (slice 1)
-- Decision of 23 Oct 2026: the Operations Lead AND the G-Squad Coordinator invite leaders and
-- give them roles in the app. The limits from security review 1 (F01) still apply to both:
--   * nobody changes their own roles;
--   * the senior roles (Resident Pastor, G-Squad Coordinator, TECi Coordinator, Pastoral Lead,
--     and Purpose Head while Purpose Heads may read pastoral notes) are given and removed only
--     by the Resident Pastor.
-- New in this migration:
--   * the Operations Lead role itself is given and removed only by the Resident Pastor or an
--     Operations Lead, so the Coordinator cannot create a second Operations Lead (the "second
--     account" risk recorded in the spec) or remove the current one;
--   * an account that holds a senior or Operations Lead role can be switched off (is_active) or
--     deleted only by the Resident Pastor, and nobody can switch off their own account, so one
--     admin cannot lock the others out.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Policies: add the G-Squad Coordinator alongside the Operations Lead.
-- -------------------------------------------------------------------------------------

-- Leaders' accounts (app_users): the Coordinator can now add and update them too. The Resident
-- Pastor is added as well: the account guard below lets only the Resident Pastor switch off a
-- senior leader or Operations Lead, so they need write access to do it.
drop policy app_users_admin on public.app_users;
create policy app_users_admin on public.app_users for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator','resident_pastor']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator','resident_pastor']::public.app_role[])));

-- Role assignments: the Coordinator sees everyone's roles (needed to manage them) ...
drop policy roles_read on public.role_assignments;
create policy roles_read on public.role_assignments for select to authenticated
  using (church_id = (select app.current_church_id())
         and (user_id = (select auth.uid())
              or (select app.has_any_role(array['operations_lead','resident_pastor','gsquad_coordinator']::public.app_role[]))));

-- ... and may write them, within the limits of app.role_assignment_guard below.
drop policy roles_write on public.role_assignments;
create policy roles_write on public.role_assignments for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','resident_pastor','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','resident_pastor','gsquad_coordinator']::public.app_role[])));

-- -------------------------------------------------------------------------------------
-- 2. Role-grant guard (re-created whole from migration 10, with the Operations Lead rule added).
-- -------------------------------------------------------------------------------------
create or replace function app.role_assignment_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_restricted public.app_role[] := array['resident_pastor','gsquad_coordinator','teci_coordinator','pastoral_lead']::public.app_role[];
begin
  -- Service role / SQL editor / scheduled jobs: not limited (bootstrapping the first admin).
  if app.is_system() then return coalesce(new, old); end if;

  -- Purpose Heads count as senior while they may read pastoral notes (church setting).
  if exists (select 1 from public.church_settings s
             where s.church_id = coalesce(new.church_id, old.church_id) and s.purpose_heads_read_pastoral) then
    v_restricted := v_restricted || 'purpose_head'::public.app_role;
  end if;

  -- Nobody creates, changes or removes their own role assignments.
  if (tg_op <> 'DELETE' and new.user_id = v_me) or (tg_op <> 'INSERT' and old.user_id = v_me) then
    raise exception 'You cannot change your own role assignments' using errcode = '42501';
  end if;

  -- Senior roles: Resident Pastor only (unchanged from migration 10).
  if ((tg_op <> 'DELETE' and new.role = any (v_restricted)) or (tg_op <> 'INSERT' and old.role = any (v_restricted)))
     and not app.has_role('resident_pastor') then
    raise exception 'Only the Resident Pastor can assign or remove this role' using errcode = '42501';
  end if;

  -- NEW: the Operations Lead role: Resident Pastor or an Operations Lead only (not the Coordinator).
  if ((tg_op <> 'DELETE' and new.role = 'operations_lead') or (tg_op <> 'INSERT' and old.role = 'operations_lead'))
     and not app.has_any_role(array['resident_pastor','operations_lead']::public.app_role[]) then
    raise exception 'Only the Resident Pastor or an Operations Lead can assign or remove the Operations Lead role'
      using errcode = '42501';
  end if;

  return coalesce(new, old);
end $$;
-- (The trigger role_assignment_guard from migration 10 already calls this function.)
revoke all on function app.role_assignment_guard() from public, anon, authenticated;
grant execute on function app.role_assignment_guard() to service_role;

-- -------------------------------------------------------------------------------------
-- 3. Account guard: protects admins and senior leaders from being switched off by a peer.
-- -------------------------------------------------------------------------------------
create or replace function app.app_user_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_protected boolean;
begin
  if app.is_system() then return coalesce(new, old); end if;

  -- The account's church and id never change (they tie it to Supabase Auth and its data).
  if tg_op = 'UPDATE' and (new.id <> old.id or new.church_id <> old.church_id) then
    raise exception 'An account''s id and church cannot be changed' using errcode = '42501';
  end if;

  -- Only switching off (is_active true -> false) and deleting are protected; renames are not.
  if tg_op = 'UPDATE' and not (old.is_active and not new.is_active) then
    return new;
  end if;

  -- Nobody switches off or deletes their own account (ask another admin).
  if old.id = v_me then
    raise exception 'You cannot switch off your own account' using errcode = '42501';
  end if;

  -- Does the account hold a senior or Operations Lead role?
  select exists (
    select 1 from public.role_assignments ra
    where ra.user_id = old.id and ra.is_active
      and ra.role = any (array['resident_pastor','gsquad_coordinator','teci_coordinator',
                               'pastoral_lead','operations_lead']::public.app_role[])
  ) into v_protected;

  if v_protected and not app.has_role('resident_pastor') then
    raise exception 'Only the Resident Pastor can switch off this account' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;

create trigger app_user_guard before update or delete on public.app_users
  for each row execute function app.app_user_guard();

revoke all on function app.app_user_guard() from public, anon, authenticated;
grant execute on function app.app_user_guard() to service_role;
