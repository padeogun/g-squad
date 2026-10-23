-- =====================================================================================
-- G-Squad Planner: 10. Security review fixes (independent review, 23 Oct 2026)
-- Fixes that cut across earlier migrations. Smaller fixes are made in place in the earlier
-- files and marked "SECURITY REVIEW FIX Fnn"; see SECURITY_LOG.md for the full list.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- F01: role assignments. Before, the Operations Lead could give themselves (or change a row to)
-- resident_pastor, gsquad_coordinator, teci_coordinator or pastoral_lead, and so read faith
-- fields, pastoral notes and one-to-ones; and anyone with write rights could grant themselves
-- unit_lead / purpose_head / finance to reach a unit's faith fields or approve their own budget.
-- Now:
--   * nobody can create, change or remove their OWN role assignments (ask another admin);
--   * roles that read faith fields or pastoral notes are granted, changed and removed only by
--     the Resident Pastor (purpose_head too, while the church lets Purpose Heads read
--     pastoral notes);
--   * the service role / SQL editor (no signed-in caller) is not limited, for bootstrapping.
-- -------------------------------------------------------------------------------------
create or replace function app.role_assignment_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_restricted public.app_role[] := array['resident_pastor','gsquad_coordinator','teci_coordinator','pastoral_lead']::public.app_role[];
begin
  if app.is_system() then return coalesce(new, old); end if;

  if exists (select 1 from public.church_settings s
             where s.church_id = coalesce(new.church_id, old.church_id) and s.purpose_heads_read_pastoral) then
    v_restricted := v_restricted || 'purpose_head'::public.app_role;
  end if;

  if (tg_op <> 'DELETE' and new.user_id = v_me) or (tg_op <> 'INSERT' and old.user_id = v_me) then
    raise exception 'You cannot change your own role assignments' using errcode = '42501';
  end if;

  if ((tg_op <> 'DELETE' and new.role = any (v_restricted)) or (tg_op <> 'INSERT' and old.role = any (v_restricted)))
     and not app.has_role('resident_pastor') then
    raise exception 'Only the Resident Pastor can assign or remove this role' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;

create trigger role_assignment_guard before insert or update or delete on public.role_assignments
  for each row execute function app.role_assignment_guard();

-- -------------------------------------------------------------------------------------
-- F02: church settings. purpose_heads_read_pastoral widens who reads pastoral notes, so only
-- the Resident Pastor may change it (before, the Operations Lead could switch it on and, with a
-- purpose_head role, read pastoral notes). The Resident Pastor may change only that setting.
-- -------------------------------------------------------------------------------------
create or replace function app.church_settings_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return new; end if;
  if new.church_id <> old.church_id then
    raise exception 'Church cannot be changed' using errcode = '42501';
  end if;
  if new.purpose_heads_read_pastoral is distinct from old.purpose_heads_read_pastoral
     and not app.has_role('resident_pastor') then
    raise exception 'Only the Resident Pastor decides whether Purpose Heads read pastoral notes' using errcode = '42501';
  end if;
  if not app.has_role('operations_lead')
     and (to_jsonb(new) - array['purpose_heads_read_pastoral','updated_at'])
         <> (to_jsonb(old) - array['purpose_heads_read_pastoral','updated_at']) then
    raise exception 'Only the Operations Lead changes the other settings' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger church_settings_guard before update on public.church_settings
  for each row execute function app.church_settings_guard();

-- -------------------------------------------------------------------------------------
-- F18: grants for objects created by FUTURE migrations. Postgres gives EXECUTE on new
-- functions to PUBLIC, and Supabase's default privileges give anon table and function rights in
-- "public". Earlier migrations revoked these for existing objects only, so every later function
-- had to remember its own revoke. Remove the defaults for objects this role creates from now on.
-- -------------------------------------------------------------------------------------
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from anon;
alter default privileges revoke execute on functions from public;   -- PUBLIC can only be revoked globally

-- -------------------------------------------------------------------------------------
-- F19: indexes used by RLS helpers, the logged reads and the anonymisation job.
-- -------------------------------------------------------------------------------------
create index if not exists pastoral_notes_person      on public.pastoral_notes (person_id);
create index if not exists checkin_flags_person       on public.checkin_flags (person_id);
create index if not exists email_link_tokens_person   on public.email_link_tokens (person_id);
create index if not exists projects_owner             on public.projects (owner_user_id);
create index if not exists one_to_ones_unit           on public.one_to_ones (unit_id);
create index if not exists newsletter_rsvps_person    on public.newsletter_rsvps (person_id);
create index if not exists newsletter_reactions_person on public.newsletter_reactions (person_id);
create index if not exists assignments_project        on public.assignments (project_id);

-- New trigger functions: not callable by API roles (triggers do not need EXECUTE grants).
revoke all on function app.role_assignment_guard(), app.church_settings_guard() from public, anon, authenticated;
grant execute on function app.role_assignment_guard(), app.church_settings_guard() to service_role;
