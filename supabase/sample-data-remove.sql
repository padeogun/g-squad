-- =====================================================================================
-- G-Squad Planner: removes the made-up sample data loaded by supabase/sample-data.sql.
--
-- Why: real member data may go in only after the DPIA is signed, and it must not sit beside
-- invented people. Run this before go-live (slice 7) from GitHub > Actions > "Sample data"
-- > Run workflow, choosing "remove".
--
-- It deletes only rows it can recognise as sample data (see sample-data.sql):
--   people        email ends in @g-squad.example
--   projects      description starts with 'Sample data'
--   church roles  description starts with 'Sample data'
-- Most related rows (memberships, serving, one-to-ones, holidays, grids) go with them through
-- the database's own "on delete cascade" links. Anything testers typed in by hand (new
-- members, projects) stays and is listed at the end for a person to check.
--
-- SECURITY REVIEW 21:
--   K07  The roles the load gave the tester used to stay. The app cannot take them away: nobody
--        changes their own roles, and only a Resident Pastor removes the Resident Pastor role,
--        so a tester who is the only Resident Pastor kept it for good. Now every role the load
--        gave (found by its 'sample_data_grant' audit row) is switched off here, and logged
--        with the GitHub user and run. Roles given in the app are not touched.
--   K08  Serving and requests that used a sample rota role were deleted whoever they belonged
--        to, and sample roles sit in real teams, so real serving history could go. Now only
--        sample people's and sample projects' rows go; anyone else's keep the row and just
--        lose the role name.
--   K03  One transaction: it removes everything or nothing.
-- =====================================================================================

begin;

do $$
declare
  v_church uuid := (select id from public.churches where slug = 'tec-manchester');
  v_people int;
  v_projects int;
  v_roles int;
  v_kept int;
  v_ended int;
begin
  -- Sample projects and people first: their serving, requests, memberships, grids, holidays,
  -- one-to-ones and recognitions go with them ("on delete cascade").
  delete from public.projects where church_id = v_church and description like 'Sample data%';
  get diagnostics v_projects = row_count;

  delete from public.people where church_id = v_church and email like '%@g-squad.example';
  get diagnostics v_people = row_count;

  -- Whatever still uses a sample rota role belongs to someone else (typed in by a tester, or
  -- real). It would block the role's deletion ("restrict"), so it keeps its row and loses only
  -- the role name, rather than being deleted.
  update public.assignments a set church_role_id = null
    from public.church_roles r
   where a.church_role_id = r.id and r.church_id = v_church and r.description like 'Sample data%';
  get diagnostics v_kept = row_count;
  update public.team_demand d set church_role_id = null
    from public.church_roles r
   where d.church_role_id = r.id and r.church_id = v_church and r.description like 'Sample data%';

  -- Memberships keep their person but lose a sample role ("set null"), then the roles go.
  delete from public.church_roles where church_id = v_church and description like 'Sample data%';
  get diagnostics v_roles = row_count;

  -- K07: switch off the roles the load gave, and log who did it. A Purpose Head or Resident
  -- Pastor role is kept while the same person still holds a Coordinator or Operations Lead
  -- role given in the app (the database requires one); the notice below says so.
  with sample_grants as (
    select ra.id, ra.user_id, ra.role from public.role_assignments ra
    where ra.church_id = v_church and ra.is_active
      and exists (select 1 from public.audit_log l
                  where l.action = 'sample_data_grant' and l.table_name = 'role_assignments'
                    and l.record_id = ra.id)
  ), ended as (
    update public.role_assignments ra set is_active = false
      from sample_grants g
     where ra.id = g.id
       and not (g.role in ('purpose_head', 'resident_pastor')
                and exists (select 1 from public.role_assignments f
                            where f.user_id = g.user_id and f.is_active
                              and f.role in ('gsquad_coordinator', 'operations_lead')
                              and f.id not in (select id from sample_grants))
                and not exists (select 1 from public.role_assignments h
                                where h.user_id = g.user_id and h.is_active
                                  and h.role in ('purpose_head', 'resident_pastor')
                                  and h.id not in (select id from sample_grants)))
    returning ra.id, ra.role
  ), logged as (
    insert into public.audit_log (church_id, actor_id, action, table_name, record_id, detail)
    select v_church, null, 'sample_data_revoke', 'role_assignments', e.id,
           jsonb_build_object('role', e.role, 'source', 'supabase/sample-data-remove.sql',
                              'github_user', '__RUN_BY__', 'github_run', '__RUN_ID__')
    from ended e
    returning 1
  )
  select count(*) into v_ended from logged;

  raise notice 'Removed % sample people, % sample projects, % sample roles; switched off % test role(s)',
    v_people, v_projects, v_roles, v_ended;
  if v_kept > 0 then
    raise notice '% serving row(s) of other people used a sample role: kept, without the role name', v_kept;
  end if;
  if exists (select 1 from public.role_assignments ra
             where ra.church_id = v_church and ra.is_active
               and exists (select 1 from public.audit_log l
                           where l.action = 'sample_data_grant' and l.record_id = ra.id)) then
    raise notice 'A test Purpose Head or Resident Pastor role was kept because the same person holds a Coordinator or Operations Lead role given in the app. Sort that out in Leaders.';
  end if;
  raise notice 'Left for a person to check: % other people, % other projects',
    (select count(*) from public.people where church_id = v_church),
    (select count(*) from public.projects where church_id = v_church);
end $$;

commit;

-- What the workflow log shows (notices may not reach it).
select (select count(*) from public.people where email like '%@g-squad.example') as sample_people_left,
       (select count(*) from public.projects where description like 'Sample data%') as sample_projects_left,
       (select count(*) from public.role_assignments ra
         where ra.is_active and exists (select 1 from public.audit_log l
                                        where l.action = 'sample_data_grant' and l.record_id = ra.id)) as test_roles_left;
