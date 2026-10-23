-- =====================================================================================
-- G-Squad Planner: 18. The G-Squad Coordinator has full access (decision of 23 Oct 2026)
-- On top of what the Coordinator already had (member records and faith fields, inviting
-- leaders, one-to-ones, newsletter first approval), the Coordinator now also:
--   1. reads and adds pastoral notes, and closes check-in flags, like the Pastoral Lead;
--   2. keeps every reference form and the church settings, like the Operations Lead
--      (and like the TECi Coordinator for TECi stages);
--   3. gives and removes senior roles, and switches senior leaders' accounts off or on.
-- Safeguards that stay (agreed with Paul):
--   * the Resident Pastor role is given, removed and switched off by the Resident Pastor only,
--     so no one else can remove the Resident Pastor or appoint a second one;
--   * nobody changes their own roles or switches their own account off or on.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Pastoral notes and check-in flags.
-- can_see_pastoral re-created whole from migration 3 with the Coordinator added. It decides
-- both reading (public.get_pastoral_notes, logged) and adding (pastoral_insert policy).
-- -------------------------------------------------------------------------------------
create or replace function app.can_see_pastoral(p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.people p
    where p.id = p_person
      and p.church_id = app.current_church_id()
      and (
        app.has_any_role(array['resident_pastor','pastoral_lead','gsquad_coordinator']::public.app_role[])
        or (
          (select s.purpose_heads_read_pastoral from public.church_settings s where s.church_id = p.church_id)
          and exists (
            select 1 from public.unit_memberships m
            where m.person_id = p.id and m.status <> 'ended' and app.is_purpose_head_of_unit(m.unit_id)
          )
        )
      )
  )
$$;

drop policy flags_close on public.checkin_flags;
create policy flags_close on public.checkin_flags for update to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['pastoral_lead','resident_pastor','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['pastoral_lead','resident_pastor','gsquad_coordinator']::public.app_role[])));

-- -------------------------------------------------------------------------------------
-- 2. Reference forms and church settings.
-- Each write policy is replaced with the same rule plus the Coordinator.
-- (The app's form list, src/data/forms.ts, is checked against these by forms.test.ts.)
-- -------------------------------------------------------------------------------------
drop policy purposes_write on public.purposes;
create policy purposes_write on public.purposes for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])));

drop policy units_write on public.units;
create policy units_write on public.units for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])));

drop policy church_roles_write on public.church_roles;
create policy church_roles_write on public.church_roles for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])));

drop policy teci_write on public.teci_stages;
create policy teci_write on public.teci_stages for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['teci_coordinator','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['teci_coordinator','gsquad_coordinator']::public.app_role[])));

drop policy leadership_stages_write on public.leadership_stages;
create policy leadership_stages_write on public.leadership_stages for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])));

drop policy project_types_write on public.project_types;
create policy project_types_write on public.project_types for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])));

drop policy blocks_write on public.reusable_blocks;
create policy blocks_write on public.reusable_blocks for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])));

-- Church settings: the Coordinator may change them as the Operations Lead can, and (being
-- senior) may also switch Purpose Heads' reading of pastoral notes on or off.
drop policy settings_update on public.church_settings;
create policy settings_update on public.church_settings for update to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','resident_pastor','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','resident_pastor','gsquad_coordinator']::public.app_role[])));

-- church_settings_guard re-created whole from migration 10 with the Coordinator added to both rules.
create or replace function app.church_settings_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return new; end if;
  if new.church_id <> old.church_id then
    raise exception 'Church cannot be changed' using errcode = '42501';
  end if;
  if new.purpose_heads_read_pastoral is distinct from old.purpose_heads_read_pastoral
     and not app.has_any_role(array['resident_pastor','gsquad_coordinator']::public.app_role[]) then
    raise exception 'Only the Resident Pastor or G-Squad Coordinator decides whether Purpose Heads read pastoral notes'
      using errcode = '42501';
  end if;
  if not app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])
     and (to_jsonb(new) - array['purpose_heads_read_pastoral','updated_at'])
         <> (to_jsonb(old) - array['purpose_heads_read_pastoral','updated_at']) then
    raise exception 'Only the Operations Lead or G-Squad Coordinator changes the other settings' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app.church_settings_guard() from public, anon, authenticated;
grant execute on function app.church_settings_guard() to service_role;

-- -------------------------------------------------------------------------------------
-- 3. Senior roles and senior accounts.
-- role_assignment_guard re-created whole from migration 13:
--   * senior roles: Resident Pastor or G-Squad Coordinator (was Resident Pastor only);
--   * the Resident Pastor role itself: Resident Pastor only (safeguard);
--   * the Operations Lead role: Resident Pastor, Operations Lead or G-Squad Coordinator.
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

  -- Safeguard: the Resident Pastor role is the Resident Pastor's alone to give or remove.
  if ((tg_op <> 'DELETE' and new.role = 'resident_pastor') or (tg_op <> 'INSERT' and old.role = 'resident_pastor'))
     and not app.has_role('resident_pastor') then
    raise exception 'Only the Resident Pastor can assign or remove the Resident Pastor role' using errcode = '42501';
  end if;

  -- Other senior roles: Resident Pastor or G-Squad Coordinator.
  if ((tg_op <> 'DELETE' and new.role = any (v_restricted)) or (tg_op <> 'INSERT' and old.role = any (v_restricted)))
     and not app.has_any_role(array['resident_pastor','gsquad_coordinator']::public.app_role[]) then
    raise exception 'Only the Resident Pastor or G-Squad Coordinator can assign or remove this role' using errcode = '42501';
  end if;

  -- The Operations Lead role: Resident Pastor, an Operations Lead, or the G-Squad Coordinator.
  if ((tg_op <> 'DELETE' and new.role = 'operations_lead') or (tg_op <> 'INSERT' and old.role = 'operations_lead'))
     and not app.has_any_role(array['resident_pastor','operations_lead','gsquad_coordinator']::public.app_role[]) then
    raise exception 'Only the Resident Pastor, an Operations Lead or the G-Squad Coordinator can assign or remove the Operations Lead role'
      using errcode = '42501';
  end if;

  return coalesce(new, old);
end $$;
revoke all on function app.role_assignment_guard() from public, anon, authenticated;
grant execute on function app.role_assignment_guard() to service_role;

-- app_user_guard re-created whole from migration 14: senior accounts are switched off or on
-- by the Resident Pastor or the G-Squad Coordinator; an account holding the Resident Pastor
-- role by the Resident Pastor only (safeguard).
create or replace function app.app_user_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_protected boolean;
  v_is_rp boolean;
  v_senior public.app_role[] := array['resident_pastor','gsquad_coordinator','teci_coordinator',
                                      'pastoral_lead','operations_lead']::public.app_role[];
begin
  if app.is_system() then return coalesce(new, old); end if;

  -- The account's church and id never change (they tie it to Supabase Auth and its data).
  if tg_op = 'UPDATE' and (new.id <> old.id or new.church_id <> old.church_id) then
    raise exception 'An account''s id and church cannot be changed' using errcode = '42501';
  end if;

  -- K04: your own link to a G-Squad record is set by another admin.
  if tg_op = 'UPDATE' and old.id = v_me and new.person_id is distinct from old.person_id then
    raise exception 'You cannot change the G-Squad record linked to your own account' using errcode = '42501';
  end if;

  -- Only switching off, switching on (K02) and deleting are protected; renames are not.
  if tg_op = 'UPDATE' and new.is_active = old.is_active then
    return new;
  end if;

  -- Nobody switches their own account off or on, or deletes it (ask another admin).
  if old.id = v_me then
    raise exception 'You cannot switch your own account off or on' using errcode = '42501';
  end if;

  -- K03: Purpose Heads are senior while they may read pastoral notes.
  if exists (select 1 from public.church_settings s
             where s.church_id = old.church_id and s.purpose_heads_read_pastoral) then
    v_senior := v_senior || 'purpose_head'::public.app_role;
  end if;

  -- Does the account hold a senior role, and is it a Resident Pastor's (still on its role rows)?
  select exists (select 1 from public.role_assignments ra
                 where ra.user_id = old.id and ra.is_active and ra.role = any (v_senior)),
         exists (select 1 from public.role_assignments ra
                 where ra.user_id = old.id and ra.is_active and ra.role = 'resident_pastor')
    into v_protected, v_is_rp;

  if v_is_rp and not app.has_role('resident_pastor') then
    raise exception 'Only the Resident Pastor can switch this account off or on' using errcode = '42501';
  end if;
  if v_protected and not app.has_any_role(array['resident_pastor','gsquad_coordinator']::public.app_role[]) then
    raise exception 'Only the Resident Pastor or G-Squad Coordinator can switch this account off or on' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
revoke all on function app.app_user_guard() from public, anon, authenticated;
grant execute on function app.app_user_guard() to service_role;
