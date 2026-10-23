-- =====================================================================================
-- G-Squad Planner: 19. Sunday operations (slice 2)
--   1. One service each Sunday: at most one service grid per church per date.
--   2. public.create_sunday_service(): sets up a Sunday in one step (its project and its
--      grid), as the caller, so every existing rule still applies.
--   3. public.rota_candidates(): for one unit and one Sunday, who can serve, with their slots
--      used this month, their personal limit (R1/R10), holidays (R10) and whether they are
--      already serving that day. The rota screen offers people from this list; the
--      assignment guard (migration 8) still has the final say on every slot.
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
  if tg_op = 'DELETE' then
    update public.service_grids g
       set version = g.version + 1, status = 'finalised', approved_by = null, approved_at = null
     where g.status in ('finalised', 'approved') and g.id in (select o.grid_id from old_rows o);
  else
    update public.service_grids g
       set version = g.version + 1, status = 'finalised', approved_by = null, approved_at = null
     where g.status in ('finalised', 'approved') and g.id in (select n.grid_id from new_rows n);
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
  referencing new table as new_rows for each statement execute function app.grid_content_changed_stmt();
create trigger segments_version_del after delete on public.service_segments
  referencing old table as old_rows for each statement execute function app.grid_content_changed_stmt();
create trigger grid_blocks_version_ins after insert on public.service_grid_blocks
  referencing new table as new_rows for each statement execute function app.grid_content_changed_stmt();
create trigger grid_blocks_version_upd after update on public.service_grid_blocks
  referencing new table as new_rows for each statement execute function app.grid_content_changed_stmt();
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
declare v_count int;
begin
  select count(*) into v_count from public.service_segments s where s.grid_id = p_grid;
  if v_count <> coalesce(cardinality(p_segments), 0)
     or v_count <> (select count(distinct x) from unnest(p_segments) x)
     or exists (select 1 from unnest(p_segments) x
                where not exists (select 1 from public.service_segments s where s.id = x and s.grid_id = p_grid)) then
    raise exception 'List every segment of this grid exactly once' using errcode = '22023';
  end if;
  update public.service_segments s
     set position = o.ord
    from unnest(p_segments) with ordinality as o(id, ord)
   where s.id = o.id and s.grid_id = p_grid and s.position <> o.ord;
end $$;
revoke all on function public.reorder_segments(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_segments(uuid, uuid[]) to authenticated, service_role;
