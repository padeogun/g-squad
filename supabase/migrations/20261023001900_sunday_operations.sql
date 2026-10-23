-- =====================================================================================
-- G-Squad Planner: 19. Sunday operations (slice 2)
--   1. One service each Sunday: at most one service grid per church per date.
--   2. public.create_sunday_service(): sets up a Sunday in one step (its project and its
--      grid), as the caller, so every existing rule still applies.
--   3. public.rota_candidates(): for one unit and one Sunday, who can serve, with their slots
--      used this month, their personal limit (R1/R10), holidays (R10) and whether they are
--      already serving that day. The rota screen offers people from this list; the
--      assignment guard (migration 8) still has the final say on every slot.
--   4. Grid versions go up once per change (statement-level triggers).
--   5. public.reorder_segments(): reorder a grid in one call.
--   6. Security review 11 fixes (Q01 to Q09; see SECURITY_LOG.md).
-- =====================================================================================

-- 1. TEC runs one service each Sunday (spec): one grid per Sunday.
create unique index service_grids_one_per_sunday on public.service_grids (church_id, service_date);

-- 2. A Sunday: a church-level project marked as a Sunday service, plus its grid.
-- SECURITY INVOKER on purpose: projects_insert and grids_insert decide who may do this (the
-- Operations Lead builds grids), and the project and grid guards set status and versions.
-- Times are local (Europe/London), so a 10:00 start stays 10:00 across clock changes.
create or replace function public.create_sunday_service(
  p_date date,
  p_starts time default '10:00',
  p_ends time default '12:40',
  p_theme text default null,
  p_site uuid default null)
returns uuid
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_project uuid;
  v_grid uuid;
begin
  if p_date is null or extract(isodow from p_date) <> 7 then
    raise exception 'Choose a Sunday' using errcode = '22023';
  end if;
  if p_ends <= p_starts then
    raise exception 'The service must end after it starts' using errcode = '22023';
  end if;
  if exists (select 1 from public.service_grids g where g.service_date = p_date and g.church_id = app.current_church_id()) then
    raise exception 'There is already a service grid for that Sunday' using errcode = '23505';
  end if;

  insert into public.projects (name, level, is_sunday_service, site_id, starts_at, ends_at)
  values ('Sunday service ' || to_char(p_date, 'FMDD Mon YYYY'), 'church', true, p_site,
          (p_date + p_starts) at time zone 'Europe/London',
          (p_date + p_ends) at time zone 'Europe/London')
  returning id into v_project;

  insert into public.service_grids (project_id, service_date, theme)
  values (v_project, p_date, nullif(btrim(p_theme), ''))
  returning id into v_grid;

  return v_grid;
end $$;
revoke all on function public.create_sunday_service(date, time, time, text, uuid) from public, anon;
grant execute on function public.create_sunday_service(date, time, time, text, uuid) to authenticated, service_role;

-- 3. Who can serve in one unit on one Sunday.
-- SECURITY DEFINER because it needs other units' slots (the limit is one across all units),
-- which the caller may not see row by row. It returns counts only, never which other units,
-- and only to those who rota this unit: its Unit Lead, its Purpose Head, the Operations Lead
-- and the G-Squad Coordinator.
create or replace function public.rota_candidates(p_unit uuid, p_date date)
returns table (
  person_id uuid,
  first_name text,
  surname text,
  church_role_id uuid,
  slots_used integer,
  slot_limit integer,
  on_holiday boolean,
  serving_that_day boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.units u where u.id = p_unit and u.church_id = app.current_church_id())
     or not (app.is_unit_lead_of(p_unit) or app.is_purpose_head_of_unit(p_unit)
             or app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])) then
    raise exception 'Not allowed to rota this unit' using errcode = '42501';
  end if;
  return query
    select p.id, p.first_name, p.surname, m.church_role_id,
           app.slots_in_month(p.id, p_date),
           app.personal_limit(p.id),
           app.on_holiday(p.id, p_date),
           exists (select 1 from public.assignments a
                   where a.person_id = p.id and a.serve_date = p_date and a.status in ('planned', 'served'))
    from public.unit_memberships m
    join public.people p on p.id = m.person_id
    where m.unit_id = p_unit and m.status = 'active'
      and p.status = 'active' and p.anonymised_at is null
    order by 5, p.surname, p.first_name;   -- fewest slots this month first
end $$;
revoke all on function public.rota_candidates(uuid, date) from public, anon;
grant execute on function public.rota_candidates(uuid, date) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 4. Grid versions go up once per change, not once per row.
-- Migration 8 raised the version in a row-level trigger, so reordering ten segments of a
-- finalised grid in one go raised it by ten. These statement-level triggers (one per event,
-- as Postgres requires for transition tables) raise it once per statement for each grid touched.
-- -------------------------------------------------------------------------------------
create or replace function app.grid_content_changed_stmt() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.service_grids g
       set version = g.version + 1, status = 'finalised', approved_by = null, approved_at = null
     where g.status in ('finalised', 'approved') and g.id in (select n.grid_id from new_rows n);
  elsif tg_op = 'DELETE' then
    update public.service_grids g
       set version = g.version + 1, status = 'finalised', approved_by = null, approved_at = null
     where g.status in ('finalised', 'approved') and g.id in (select o.grid_id from old_rows o);
  else
    -- SECURITY REVIEW FIX Q01: an update can move a segment or block to another grid (grid_id
    -- changes), so the grid it LEFT has changed too. Before, only the new grid was looked at,
    -- so taking a segment out of an approved grid left that grid "approved".
    -- SECURITY REVIEW FIX Q02: only rows that really changed count. Before, saving a segment
    -- without changing anything sent an approved grid back for approval. Rows identical
    -- before and after cancel out in the two EXCEPTs.
    update public.service_grids g
       set version = g.version + 1, status = 'finalised', approved_by = null, approved_at = null
     where g.status in ('finalised', 'approved')
       and g.id in (select c.grid_id from (select * from new_rows except select * from old_rows) c
                    union
                    select c.grid_id from (select * from old_rows except select * from new_rows) c);
  end if;
  return null;
end $$;
revoke all on function app.grid_content_changed_stmt() from public, anon, authenticated;
grant execute on function app.grid_content_changed_stmt() to service_role;

drop trigger segments_version on public.service_segments;
drop trigger grid_blocks_version on public.service_grid_blocks;

create trigger segments_version_ins after insert on public.service_segments
  referencing new table as new_rows for each statement execute function app.grid_content_changed_stmt();
create trigger segments_version_upd after update on public.service_segments
  referencing old table as old_rows new table as new_rows for each statement execute function app.grid_content_changed_stmt();
create trigger segments_version_del after delete on public.service_segments
  referencing old table as old_rows for each statement execute function app.grid_content_changed_stmt();
create trigger grid_blocks_version_ins after insert on public.service_grid_blocks
  referencing new table as new_rows for each statement execute function app.grid_content_changed_stmt();
create trigger grid_blocks_version_upd after update on public.service_grid_blocks
  referencing old table as old_rows new table as new_rows for each statement execute function app.grid_content_changed_stmt();
create trigger grid_blocks_version_del after delete on public.service_grid_blocks
  referencing old table as old_rows for each statement execute function app.grid_content_changed_stmt();

-- -------------------------------------------------------------------------------------
-- 5. Reorder a grid's segments in one statement (positions are unique per grid, checked at
-- the end of the transaction). SECURITY INVOKER: segments_write decides who may (the
-- Operations Lead). Every segment of the grid must be listed exactly once.
-- -------------------------------------------------------------------------------------
create or replace function public.reorder_segments(p_grid uuid, p_segments uuid[])
returns void
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_count int;
  v_to_move int;
  v_moved int;
begin
  select count(*) into v_count from public.service_segments s where s.grid_id = p_grid;
  if v_count <> coalesce(cardinality(p_segments), 0)
     or v_count <> (select count(distinct x) from unnest(p_segments) x)
     or exists (select 1 from unnest(p_segments) x
                where not exists (select 1 from public.service_segments s where s.id = x and s.grid_id = p_grid)) then
    raise exception 'List every segment of this grid exactly once' using errcode = '22023';
  end if;
  -- SECURITY REVIEW FIX Q06: everyone can read segments, but segments_write lets only the
  -- Operations Lead change them, so for anyone else the update below quietly matched no rows
  -- and the call "succeeded". Count what should move, and refuse if row-level security
  -- stopped any of it.
  select count(*) into v_to_move
    from public.service_segments s
    join unnest(p_segments) with ordinality as o(id, ord) on o.id = s.id
   where s.grid_id = p_grid and s.position <> o.ord;
  update public.service_segments s
     set position = o.ord
    from unnest(p_segments) with ordinality as o(id, ord)
   where s.id = o.id and s.grid_id = p_grid and s.position <> o.ord;
  get diagnostics v_moved = row_count;
  if v_moved < v_to_move then
    raise exception 'Only the Operations Lead can reorder the service grid' using errcode = '42501';
  end if;
end $$;
revoke all on function public.reorder_segments(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_segments(uuid, uuid[]) to authenticated, service_role;

-- =====================================================================================
-- 6. Security review 11 (slice 2). Each change is marked SECURITY REVIEW FIX Qnn.
-- app.grid_guard and app.assignment_guard are re-created whole from migration 8 (no later
-- migration changed them); everything not marked is unchanged.
-- =====================================================================================

-- R11: Sunday Service Grid finalising, approval and versioning.
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

  -- SECURITY REVIEW FIX Q05: "new version, approval withdrawn" is always allowed, whoever's
  -- change caused it. The content triggers (segments, blocks, reusable block text) make exactly
  -- this change; before, it was refused unless the caller was the Operations Lead, so any other
  -- path that touched a finalised grid (a Coordinator editing a block's text, a cascade) either
  -- failed or had to skip re-approval. It only ever takes approval away, so it is safe for
  -- anyone who can reach it (row-level security still limits direct updates to the Operations
  -- Lead and Resident Pastor).
  if old.status in ('finalised', 'approved') and new.status = 'finalised'
     and new.version = old.version + 1 and new.approved_by is null and new.approved_at is null
     and (to_jsonb(new) - array['status', 'version', 'approved_by', 'approved_at', 'updated_at'])
         = (to_jsonb(old) - array['status', 'version', 'approved_by', 'approved_at', 'updated_at']) then
    return new;
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
    -- SECURITY REVIEW FIX Q04: back to draft starts the next version. Before, approved v3 ->
    -- draft -> edits -> finalised came back as v3 again, so two different grids (and PDFs named
    -- "...-v3.pdf") carried the same number and the Resident Pastor could not tell them apart.
    if old.status <> 'draft' then
      new.version := greatest(new.version, old.version + 1);
    end if;
  end if;
  return new;
end $$;

-- SECURITY REVIEW FIX Q03: a finalised or approved grid cannot be deleted, including by a
-- cascade. Sunday projects stay "draft" (they are never submitted for approval), and drafts may be
-- deleted by their owner, so deleting the Sunday's project removed its approved grid.
create or replace function app.grid_delete_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.status <> 'draft' and not app.is_system() then
    raise exception 'A finalised or approved service grid cannot be deleted; put it back to draft first'
      using errcode = '42501';
  end if;
  return old;
end $$;
create trigger grid_delete_guard before delete on public.service_grids
  for each row execute function app.grid_delete_guard();

-- SECURITY REVIEW FIX Q03 (continued): the same cascade deleted every slot of the Sunday,
-- including who served and who didn't (engagement and monthly report history). A project with
-- served or no-show slots can no longer be deleted; cancel it instead. SECURITY DEFINER so the
-- answer does not depend on which slots the caller can see.
create or replace function app.project_has_history(p_project uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.assignments a
                 where a.project_id = p_project and a.status in ('served', 'no_show'))
$$;
drop policy projects_delete on public.projects;
create policy projects_delete on public.projects for delete to authenticated
  using (church_id = (select app.current_church_id()) and status = 'draft'
         and (owner_user_id = (select auth.uid()) or (select app.has_role('operations_lead')))
         and not app.project_has_history(id));

-- SECURITY REVIEW FIX Q05: a reusable block's text is printed in the grid PDF, so changing it
-- changes every finalised or approved grid it is attached to. Those grids (coming Sundays only;
-- past services are history) get a new version that the Resident Pastor approves again.
create or replace function app.block_text_changed() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.service_grids g
     set version = g.version + 1, status = 'finalised', approved_by = null, approved_at = null
   where g.status in ('finalised', 'approved')
     and g.service_date >= (now() at time zone 'Europe/London')::date
     and g.id in (select gb.grid_id
                  from public.service_grid_blocks gb
                  join new_rows n on n.id = gb.block_id
                  join old_rows o on o.id = n.id
                  where (n.name, n.body) is distinct from (o.name, o.body));
  return null;
end $$;
create trigger reusable_blocks_grid_version after update on public.reusable_blocks
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.block_text_changed();

-- R2 / R10: assignments respect the monthly limit and holidays.
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
  -- SECURITY REVIEW FIX Q09: "served" and "no-show" are recorded on or after the day (the
  -- table's own rule). Before, a slot months ahead could be marked served, which counts towards
  -- engagement (active / inactive) and the monthly report. Today is the UK date.
  if not app.is_system() and new.status in ('served', 'no_show')
     and (tg_op = 'INSERT' or new.status is distinct from old.status or new.serve_date <> old.serve_date)
     and new.serve_date > (now() at time zone 'Europe/London')::date then
    raise exception 'Mark served or no-show on or after the day' using errcode = '23514';
  end if;
  -- Only live slots are checked; marking served / no-show / cancelled is always allowed.
  if new.status not in ('planned', 'served') then return new; end if;
  -- SECURITY REVIEW FIX Q08: the shortcut for status-only changes also requires the same
  -- project. Before, a live slot could be moved to another project (a cancelled or finished
  -- one, or one whose dates do not include the serve date) with no checks at all.
  if tg_op = 'UPDATE' and new.serve_date = old.serve_date and new.unit_id = old.unit_id
     and new.project_id = old.project_id and old.status in ('planned', 'served') then
    return new;
  end if;

  -- The serve date must fall within the project's dates.
  select p.starts_at, p.ends_at, p.status into v_proj from public.projects p where p.id = new.project_id;
  -- SECURITY REVIEW FIX Q07: project times are compared as UK dates. A plain ::date uses the
  -- database's time zone (UTC on Supabase), so in summer anything starting before 01:00 UK
  -- time fell on the previous day and the allowed serve dates were off by one.
  if new.serve_date < (v_proj.starts_at at time zone 'Europe/London')::date
     or new.serve_date > (v_proj.ends_at at time zone 'Europe/London')::date then
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

-- Trigger functions are not called directly through the API.
revoke all on function app.grid_delete_guard(), app.block_text_changed() from public, anon, authenticated;
grant execute on function app.grid_delete_guard(), app.block_text_changed() to service_role;
-- project_has_history is used in a policy, so signed-in users need to be able to run it.
revoke all on function app.project_has_history(uuid) from public, anon;
grant execute on function app.project_has_history(uuid) to authenticated, service_role;
