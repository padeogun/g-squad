-- =====================================================================================
-- G-Squad Planner: 15. Security review 7 (reference forms, members and My Unit)
-- Fixes marked SECURITY REVIEW FIX Lnn; see SECURITY_LOG.md, Review 7.
--   L01  public.create_member(): adds a new member, their unit membership and (optionally)
--        their faith fields in ONE transaction, as the caller (row-level security and every
--        guard still apply). Before, the app made three separate calls: the first could never
--        work (INSERT ... RETURNING on people is refused by people_read, because
--        app.can_read_person cannot see a row the same statement is inserting), and a failure
--        after the first call left a person with no unit behind, which the Unit Lead could not
--        fix or remove.
--   L02  An anonymised person (R8) can no longer be changed through the API, and no one can
--        be added to a unit, so a record cannot be filled in again after anonymising.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- L01: add a member in one transaction.
-- SECURITY INVOKER on purpose: it runs as the caller, so people_insert, memberships_write,
-- app.people_guard (TECi stage), app.membership_guard (R3) and set_person_faith's own check
-- (app.can_see_faith) decide, exactly as for direct calls. It grants nothing new.
-- Only the listed member columns are taken from p_person: id, church_id, created_by,
-- anonymised_at and consent columns in the payload are ignored (defaults and guards set them).
-- -------------------------------------------------------------------------------------
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
  if p_unit is null then
    raise exception 'Choose the unit they are joining' using errcode = '22023';
  end if;
  r := jsonb_populate_record(null::public.people, coalesce(p_person, '{}'::jsonb));

  begin
    insert into public.people (id, first_name, other_names, surname, email, area,
        birth_day, birth_month, marital_status, anniversary_day, anniversary_month,
        date_joined, date_left, status, teci_stage_id, greatness_community_id,
        newsletter_subscribed, celebration_opt_in)
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
        r.teci_stage_id, r.greatness_community_id,
        coalesce(r.newsletter_subscribed, true), coalesce(r.celebration_opt_in, false));
  exception when unique_violation then
    raise exception 'A member with that email address is already recorded' using errcode = 'P0001';
  end;

  insert into public.unit_memberships (person_id, unit_id, church_role_id, is_team_leader, leadership_stage_id)
  values (v_id, p_unit, p_church_role, coalesce(p_is_team_leader, false), p_leadership_stage);

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

revoke all on function public.create_member(jsonb, uuid, uuid, boolean, uuid, jsonb) from public, anon;
grant execute on function public.create_member(jsonb, uuid, uuid, boolean, uuid, jsonb) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- L02: anonymised records are closed. app.people_guard is re-created whole (as in
-- migration 8) with one new check after the system bypass.
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

  -- SECURITY REVIEW FIX L02: an anonymised record stays anonymised. Without this, anyone
  -- who could edit it (the Operations Lead, or the Unit Lead who entered it) could type the
  -- name and email back in, undoing R8 and the person's erasure request.
  if old.anonymised_at is not null then
    raise exception 'This record has been anonymised and cannot be changed' using errcode = '42501';
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

-- SECURITY REVIEW FIX L02: no one joins a unit as an anonymised person (a membership would
-- make the record live again for a Unit Lead and the rotas).
create or replace function app.membership_not_anonymised() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return new; end if;
  if exists (select 1 from public.people p where p.id = new.person_id and p.anonymised_at is not null) then
    raise exception 'This record has been anonymised and cannot join a unit' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app.membership_not_anonymised() from public;

create trigger membership_not_anonymised before insert on public.unit_memberships
  for each row execute function app.membership_not_anonymised();
