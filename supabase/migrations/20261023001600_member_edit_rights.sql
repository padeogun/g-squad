-- =====================================================================================
-- G-Squad Planner: 16. Who edits member records, and who sees them (decisions of 23 Oct 2026)
--   1. Member records are edited only by the person's Team Lead (the Unit Lead of a unit they
--      are currently in) and the G-Squad Coordinator. The Resident Pastor, Operations Lead and
--      others keep READ access as before, but no longer edit. Faith fields follow the same
--      rule for edits; who may READ them is unchanged.
--      The TECi Coordinator keeps one narrow right: setting a person's TECi stage.
--   2. A Unit Lead sees only people in a unit they currently lead. The "people I entered"
--      exception (created_by) is removed, so someone who moves to another unit drops out
--      of the old Unit Lead's view.
-- Adding new members is unchanged: Unit Leads (to their own unit) and the Operations Lead,
-- through public.create_member() (migration 15).
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- Decision 1: edit rights.
-- -------------------------------------------------------------------------------------
create or replace function app.can_edit_person(p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.people p
    where p.id = p_person
      and p.church_id = app.current_church_id()
      and (
        app.has_role('gsquad_coordinator')
        -- Their Team Lead: Unit Lead of a unit they are in now (not ended).
        or exists (
          select 1 from public.unit_memberships m
          where m.person_id = p.id and m.status <> 'ended' and app.is_unit_lead_of(m.unit_id)
        )
      )
  )
$$;

-- The TECi Coordinator may update a record only to set the TECi stage; people_guard below
-- refuses any other change from someone who is not an editor.
drop policy people_update on public.people;
create policy people_update on public.people for update to authenticated
  using (church_id = (select app.current_church_id())
         and (app.can_edit_person(id) or (select app.has_role('teci_coordinator'))))
  with check (church_id = (select app.current_church_id())
         and (app.can_edit_person(id) or (select app.has_role('teci_coordinator'))));

-- people_guard, re-created whole from migration 15 with two changes:
--   * a TECi stage is changed on an existing record by the TECi Coordinator only (the
--     Operations Lead may still set one when ADDING a member);
--   * "TECi stage only" now applies to anyone who is not an editor of THIS person, rather
--     than to anyone without certain roles (a TECi Coordinator who also leads some other unit
--     no longer gets full edit rights through the TECi route).
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
       or new.status <> 'left' or new.birth_day is not null or new.anniversary_day is not null then
      raise exception 'The anonymising marker may only be used to anonymise' using errcode = '42501';
    end if;
    return new;
  end if;
  if new.anonymised_at is distinct from old.anonymised_at then
    raise exception 'Use public.anonymise_person() to anonymise a record' using errcode = '42501';
  end if;
  -- Decision 1: the TECi stage of an existing member is the TECi Coordinator's alone.
  if new.teci_stage_id is distinct from old.teci_stage_id and not app.has_role('teci_coordinator') then
    raise exception 'Only the TECi Coordinator can change a TECi stage' using errcode = '42501';
  end if;
  -- Someone who is not this person's editor (the TECi Coordinator route) changes the stage only.
  if not app.can_edit_person(old.id)
     and (to_jsonb(new) - 'teci_stage_id' - 'updated_at') <> (to_jsonb(old) - 'teci_stage_id' - 'updated_at') then
    raise exception 'Only their Team Lead or the G-Squad Coordinator can edit this record' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app.people_guard() from public, anon, authenticated;
grant execute on function app.people_guard() to service_role;

-- Faith fields: READ as before (app.can_see_faith: Resident Pastor, G-Squad Coordinator,
-- TECi Coordinator, their Unit Lead). WRITE: G-Squad Coordinator and their Team Lead only,
-- and only for someone in an ACTIVE membership of the lead's unit (as F07 for reading).
create or replace function app.can_edit_faith(p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.people p
    where p.id = p_person
      and p.church_id = app.current_church_id()
      and (
        app.has_role('gsquad_coordinator')
        or exists (
          select 1 from public.unit_memberships m
          where m.person_id = p.id and m.status = 'active' and app.is_unit_lead_of(m.unit_id)
        )
      )
  )
$$;
revoke all on function app.can_edit_faith(uuid) from public, anon;
grant execute on function app.can_edit_faith(uuid) to authenticated, service_role;

-- set_person_faith, re-created whole from migration 8 with the new edit check.
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
  if not app.can_edit_faith(p_person) then
    raise exception 'Only their Team Lead or the G-Squad Coordinator can record faith fields' using errcode = '42501';
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
revoke all on function public.set_person_faith(uuid, date, boolean, date, boolean, date, boolean, date) from public, anon;
grant execute on function public.set_person_faith(uuid, date, boolean, date, boolean, date, boolean, date) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- Decision 2: Unit Leads see their current units' people only.
-- can_read_person re-created whole from migration 4 without the created_by clause.
-- -------------------------------------------------------------------------------------
create or replace function app.can_read_person(p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.people p
    where p.id = p_person
      and p.church_id = app.current_church_id()
      and (
        app.is_church_wide_reader()
        or exists (
          select 1 from public.unit_memberships m
          where m.person_id = p.id and m.status <> 'ended'
            and (app.is_unit_lead_of(m.unit_id) or app.is_purpose_head_of_unit(m.unit_id))
        )
        or exists (
          select 1 from public.assignments a
          join public.projects pr on pr.id = a.project_id
          where a.person_id = p.id and a.status in ('planned', 'served')
            and pr.owner_user_id = (select auth.uid())
        )
      )
  )
$$;

-- Adding a membership: a Unit Lead may still add the person they have JUST entered (inside
-- create_member, before any membership exists). The old check read people through RLS,
-- which no longer shows that row, so it moves into a definer helper with a tighter test:
-- entered by the caller AND not yet in any unit. Anyone already in a unit goes through the
-- Operations Lead, as before (F05).
create or replace function app.is_new_entry_of_caller(p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.people p
    where p.id = p_person
      and p.church_id = app.current_church_id()
      and p.created_by = (select auth.uid())
      and not exists (select 1 from public.unit_memberships m where m.person_id = p.id)
  )
$$;
revoke all on function app.is_new_entry_of_caller(uuid) from public, anon;
grant execute on function app.is_new_entry_of_caller(uuid) to authenticated, service_role;

drop policy memberships_write on public.unit_memberships;
create policy memberships_write on public.unit_memberships for insert to authenticated
  with check (church_id = (select app.current_church_id())
              and ((app.is_unit_lead_of(unit_id) and app.is_new_entry_of_caller(person_id))
                   or (select app.has_role('operations_lead'))));
