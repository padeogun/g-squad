-- =====================================================================================
-- G-Squad Planner: 23. Bulk upload of G-Squad members (decision of 23 Oct 2026)
--   * public.import_members(rows, skip_existing): adds many members in ONE transaction. Every
--     row goes through public.create_member as the caller, so row-level security, every guard
--     and the logged faith function apply exactly as for one member. If any row fails, nothing
--     is saved and the error lists each failing row and why.
--   * Who: the G-Squad Coordinator and Operations Lead into any team; a Team Lead into their
--     own team only (create_member's existing rules). At most 500 rows per upload.
--   * The G-Squad Coordinator may now add members (people and memberships), in line with the
--     Coordinator's "all access" (decision of 23 Oct 2026, migration 18). Before, only Team
--     Leads and the Operations Lead could.
-- =====================================================================================

-- Coordinator adds members: people_insert and memberships_write gain gsquad_coordinator.
drop policy people_insert on public.people;
create policy people_insert on public.people for insert to authenticated
  with check (church_id = (select app.current_church_id())
              and created_by = (select auth.uid())
              and (select app.has_any_role(array['unit_lead','operations_lead','teci_coordinator','gsquad_coordinator']::public.app_role[])));

drop policy memberships_write on public.unit_memberships;
create policy memberships_write on public.unit_memberships for insert to authenticated
  with check (church_id = (select app.current_church_id())
              and ((app.is_unit_lead_of(unit_id) and app.is_new_entry_of_caller(person_id))
                   or (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[]))));

-- people_guard, re-created whole from migration 22 with one change: the G-Squad Coordinator
-- adds full member records (like the Operations Lead), so the "TECi route" limits (stage
-- required; name, email and stage only) no longer apply to them, and they may give a TECi
-- stage when adding someone.
create or replace function app.people_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return new; end if;

  if tg_op = 'INSERT' then
    -- The TECi stage is set by the TECi Coordinator (or the Ops Lead), not on entry.
    if new.teci_stage_id is not null
       and not app.has_any_role(array['teci_coordinator','operations_lead','gsquad_coordinator']::public.app_role[]) then
      raise exception 'Only the TECi Coordinator can set a TECi stage' using errcode = '42501';
    end if;
    -- The TECi Coordinator adds members who have completed a TECi level.
    if new.teci_stage_id is null and not app.has_any_role(array['unit_lead','operations_lead','gsquad_coordinator']::public.app_role[]) then
      raise exception 'Choose the TECi stage they have completed' using errcode = '22023';
    end if;
    -- SECURITY REVIEW 13 (S04): the TECi route records the minimum: name, email and the stage.
    -- create_member (and a direct insert) accepted birthdays, marital status, anniversaries,
    -- area, availability and so on from the TECi Coordinator, who cannot edit or correct the
    -- record afterwards (only the G-Squad Coordinator can until they join a team). The rest is
    -- added once the Operations Lead has put them in a team and their Team Lead can edit them.
    if not app.has_any_role(array['unit_lead','operations_lead','gsquad_coordinator']::public.app_role[])
       and (new.birth_day is not null or new.birth_month is not null or new.marital_status is not null
            or new.anniversary_day is not null or new.anniversary_month is not null or new.area is not null
            or new.greatness_community_id is not null or new.available_hours_month is not null
            or coalesce(cardinality(new.preferred_times), 0) > 0 or new.date_left is not null
            or new.status <> 'active' or new.celebration_opt_in
            or new.consent_notice_version is not null or new.consent_at is not null) then
      raise exception 'The TECi Coordinator records only a name, email address and TECi stage; the rest is added when they join a team'
        using errcode = '42501';
    end if;
    if new.teci_verified_at is not null and new.teci_stage_id is not null and app.has_role('teci_coordinator') then
      new.teci_verified_at := now();
      new.teci_verified_by := (select auth.uid());
    else
      new.teci_verified_at := null;
      new.teci_verified_by := null;
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
  -- Decision 1 (migration 16): the TECi stage of an existing member is the TECi Coordinator's alone.
  if new.teci_stage_id is distinct from old.teci_stage_id and not app.has_role('teci_coordinator') then
    raise exception 'Only the TECi Coordinator can change a TECi stage' using errcode = '42501';
  end if;
  -- Verification: only the TECi Coordinator, always as themselves and now.
  if new.teci_verified_at is distinct from old.teci_verified_at or new.teci_verified_by is distinct from old.teci_verified_by then
    if not app.has_role('teci_coordinator') then
      raise exception 'Only the TECi Coordinator can verify a TECi stage' using errcode = '42501';
    end if;
    if new.teci_verified_at is not null then
      if new.teci_stage_id is null then
        raise exception 'Set a TECi stage before verifying it' using errcode = '22023';
      end if;
      new.teci_verified_at := now();
      new.teci_verified_by := (select auth.uid());
    else
      new.teci_verified_by := null;
    end if;
  elsif new.teci_stage_id is distinct from old.teci_stage_id then
    -- A changed stage is unverified until it is confirmed again.
    new.teci_verified_at := null;
    new.teci_verified_by := null;
  end if;
  -- Someone who is not this person's editor (the TECi Coordinator route) changes TECi only.
  if not app.can_edit_person(old.id)
     and (to_jsonb(new) - 'teci_stage_id' - 'teci_verified_at' - 'teci_verified_by' - 'updated_at')
         <> (to_jsonb(old) - 'teci_stage_id' - 'teci_verified_at' - 'teci_verified_by' - 'updated_at') then
    raise exception 'Only their Team Lead or the G-Squad Coordinator can edit this record' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app.people_guard() from public, anon, authenticated;
grant execute on function app.people_guard() to service_role;

-- -------------------------------------------------------------------------------------
-- Bulk upload. Each element of p_rows:
--   { "row": <spreadsheet row number, for messages>,
--     "person": { ...member columns as create_member takes them... },
--     "unit_id": uuid, "church_role_id": uuid|null, "leadership_stage_id": uuid|null,
--     "faith": { ...as create_member's p_faith... } | null }
-- SECURITY INVOKER: grants nothing; create_member and set_person_faith decide every row.
-- Returns { "added": n, "skipped": n }; on any failure raises with the row list (as JSON)
-- in DETAIL, and the whole upload is undone.
-- -------------------------------------------------------------------------------------
create or replace function public.import_members(p_rows jsonb, p_skip_existing boolean default false)
returns jsonb
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  r jsonb;
  i int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_added int := 0;
  v_skipped int := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'There are no members to import' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception 'Upload at most 500 members at a time' using errcode = '22023';
  end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    i := i + 1;
    begin
      if jsonb_typeof(r) <> 'object' or nullif(r->>'unit_id', '') is null then
        raise exception 'Choose the unit they are joining' using errcode = '22023';
      end if;
      perform public.create_member(
        r->'person',
        (r->>'unit_id')::uuid,
        nullif(r->>'church_role_id', '')::uuid,
        false,
        nullif(r->>'leadership_stage_id', '')::uuid,
        case when jsonb_typeof(r->'faith') = 'object' then r->'faith' end);
      v_added := v_added + 1;
    exception when others then
      -- "Already recorded" (same email) is skipped when asked; create_member raises it without
      -- saying who, so this tells the caller nothing a single add wouldn't.
      if p_skip_existing and sqlstate = 'P0001' and sqlerrm = 'A member with that email address is already recorded' then
        v_skipped := v_skipped + 1;
      else
        v_errors := v_errors || jsonb_build_object(
          'row', coalesce(case when jsonb_typeof(r->'row') = 'number' then (r->>'row')::int end, i),
          'message', left(sqlerrm, 300));
      end if;
    end;
  end loop;

  if jsonb_array_length(v_errors) > 0 then
    -- Raising undoes every row already added in this call: all or nothing.
    raise exception 'Nothing was imported: % row(s) need fixing', jsonb_array_length(v_errors)
      using errcode = '22023', detail = v_errors::text, hint = 'import_rows';
  end if;
  return jsonb_build_object('added', v_added, 'skipped', v_skipped);
end $$;
revoke all on function public.import_members(jsonb, boolean) from public, anon;
grant execute on function public.import_members(jsonb, boolean) to authenticated, service_role;
