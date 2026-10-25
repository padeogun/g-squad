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
-- the database's own "on delete cascade" links. The tester's leader roles are NOT removed:
-- take those away in the app (Leaders), so the change is logged against a person.
-- Anything testers typed in by hand (new members, projects) stays and is listed at the end
-- for a person to check.
-- =====================================================================================

do $$
declare
  v_church uuid := (select id from public.churches where slug = 'tec-manchester');
  v_people int;
  v_projects int;
  v_roles int;
begin
  -- Serving and requests that use a sample rota role block that role's deletion ("restrict"),
  -- so they go first, whoever created them.
  delete from public.assignments a using public.church_roles r
   where a.church_role_id = r.id and r.church_id = v_church and r.description like 'Sample data%';
  delete from public.team_demand d using public.church_roles r
   where d.church_role_id = r.id and r.church_id = v_church and r.description like 'Sample data%';

  delete from public.projects where church_id = v_church and description like 'Sample data%';
  get diagnostics v_projects = row_count;

  delete from public.people where church_id = v_church and email like '%@g-squad.example';
  get diagnostics v_people = row_count;

  -- Memberships keep their person but lose a sample role ("set null"), then the roles go.
  delete from public.church_roles where church_id = v_church and description like 'Sample data%';
  get diagnostics v_roles = row_count;

  raise notice 'Removed % sample people, % sample projects, % sample roles', v_people, v_projects, v_roles;
  raise notice 'Left for a person to check: % other people, % other projects',
    (select count(*) from public.people where church_id = v_church),
    (select count(*) from public.projects where church_id = v_church);
end $$;

-- What the workflow log shows (notices may not reach it).
select (select count(*) from public.people where email like '%@g-squad.example') as sample_people_left,
       (select count(*) from public.projects where description like 'Sample data%') as sample_projects_left;
