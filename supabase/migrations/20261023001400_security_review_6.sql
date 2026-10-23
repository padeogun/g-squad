-- =====================================================================================
-- G-Squad Planner: 14. Security review 6 (leader invitations, slice 1a), 23 Oct 2026
-- Tightens the account guard from migration 13. See SECURITY_LOG.md, Review 6.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- SECURITY REVIEW FIX K02: switching an account back ON is protected like switching it off.
-- A switched-off account keeps its role rows, so turning it back on gives those roles back.
-- Before, the G-Squad Coordinator could switch on a former Resident Pastor, Pastoral Lead or
-- Operations Lead that the Resident Pastor had switched off, and so hand out a senior or
-- Operations Lead role, which only the Resident Pastor (or an Operations Lead) may give.
--
-- SECURITY REVIEW FIX K03: a Purpose Head counts as senior while Purpose Heads may read
-- pastoral notes (as in app.role_assignment_guard), so their account is protected too.
--
-- SECURITY REVIEW FIX K04: nobody changes the link from their own account to a G-Squad
-- record (person_id). Migration 13 gave the Coordinator and Resident Pastor write access to
-- app_users; they could clear their own link and then recognise themselves (bypassing G02).
-- -------------------------------------------------------------------------------------
create or replace function app.app_user_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_protected boolean;
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

  -- Does the account hold a senior or Operations Lead role (still on its role rows)?
  select exists (
    select 1 from public.role_assignments ra
    where ra.user_id = old.id and ra.is_active and ra.role = any (v_senior)
  ) into v_protected;

  if v_protected and not app.has_role('resident_pastor') then
    raise exception 'Only the Resident Pastor can switch this account off or on' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
-- (The trigger app_user_guard from migration 13 already calls this function.)
revoke all on function app.app_user_guard() from public, anon, authenticated;
grant execute on function app.app_user_guard() to service_role;
