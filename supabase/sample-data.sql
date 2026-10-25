-- =====================================================================================
-- G-Squad Planner: made-up sample data for trying every function before go-live.
--
-- Why this file exists: until the DPIA is signed the database may hold fictional data only
-- (CLAUDE.md), yet most screens are empty without members, Sundays and projects. This fills
-- them with invented people so each role's screens have something to work on.
--
-- How it runs: by hand only, from GitHub > Actions > "Sample data" > Run workflow (never by
-- the normal deploy). Safe to run twice: it stops if the sample people are already there.
-- Removed again by supabase/sample-data-remove.sql before real data goes in (slice 7).
--
-- How sample rows are recognised (so removal touches nothing else):
--   people        email ends in @g-squad.example (".example" is reserved: no mail can reach it)
--   projects      description starts with 'Sample data'
--   church roles  description starts with 'Sample data'
--
-- Runs as the database owner, so the triggers treat it as a system change (app.is_system()):
-- the guards and audit triggers still run, and the hours columns are filled by the database.
-- All names are invented. Nothing here describes a real person.
--
-- SECURITY REVIEW 21 (K03): one transaction, so a failure part-way (say in the roles step)
-- leaves nothing half loaded.
-- =====================================================================================

begin;

do $$
declare
  v_church uuid := (select id from public.churches where slug = 'tec-manchester');
  v_purpose uuid;
  v_unit uuid;
  v_role uuid;
  v_person uuid;
  v_project uuid;
  v_grid uuid;
  v_sunday date;
  v_owner uuid;   -- the leader shown as owner of the sample projects
  i int;
  -- 30 invented people: first name, surname, area.
  v_names text[][] := array[
    ['Amara','Okafor','Salford'], ['Ben','Hartley','Eccles'], ['Chidi','Nwosu','Pendleton'],
    ['Dara','Whitfield','Swinton'], ['Efe','Adeyemi','Salford'], ['Femi','Lawson','Worsley'],
    ['Grace','Mensah','Eccles'], ['Hannah','Brook','Salford'], ['Ife','Balogun','Ordsall'],
    ['Joel','Pritchard','Swinton'], ['Kemi','Ajayi','Salford'], ['Liam','Forde','Walkden'],
    ['Maya','Osei','Pendleton'], ['Nadia','Clarke','Eccles'], ['Ola','Bankole','Salford'],
    ['Priya','Shah','Ordsall'], ['Quinn','Harper','Worsley'], ['Ruth','Asante','Salford'],
    ['Sam','Ellison','Swinton'], ['Tobi','Akande','Eccles'], ['Uche','Eze','Salford'],
    ['Vera','Lindqvist','Walkden'], ['Wale','Ogun','Pendleton'], ['Xena','Moreau','Salford'],
    ['Yemi','Coker','Ordsall'], ['Zara','Patel','Eccles'], ['Ade','Martins','Salford'],
    ['Bisi','Johnson','Swinton'], ['Caleb','Reid','Worsley'], ['Dami','Ilori','Salford']];
  -- Six teams and two rota roles each. Matches the units already in the live database; on an
  -- empty database (the local check) the teams are created first.
  v_units text[][] := array[
    ['Ushers','Ministry','Usher','Head usher'],
    ['Hospitality','Ministry','Host','Kitchen'],
    ['Elevation Priests of Praise (EPOP)','Worship','Vocalist','Instrumentalist'],
    ['Missions','Missions','Outreach team','Prayer partner'],
    ['412 Nation','Membership','Welcome team','Follow-up caller'],
    ['Maturity','Maturity','Class helper','Small group host']];
  v_unit_ids uuid[] := '{}';
  v_people uuid[] := '{}';
  v_sundays date[] := '{}';
begin
  if v_church is null then
    raise exception 'Run supabase/seed.sql first: the church is missing';
  end if;
  -- SECURITY REVIEW 21 (K03): once the Resident Pastor has switched on sending to members
  -- (after the DPIA), this is a live church: invented people must never be mixed in again.
  if exists (select 1 from public.church_settings where church_id = v_church and newsletter_live) then
    raise exception 'Sending to members is switched on, so this church is live: sample data is not loaded';
  end if;
  if exists (select 1 from public.people where email like '%@g-squad.example') then
    raise notice 'Sample data is already loaded; nothing changed';
    return;
  end if;
  -- Projects need an owner: the Operations Lead, else the G-Squad Coordinator, else any leader.
  select a.id into v_owner from public.app_users a
  left join public.role_assignments r on r.user_id = a.id and r.is_active
  where a.church_id = v_church and a.is_active
  order by (r.role = 'operations_lead') desc nulls last, (r.role = 'gsquad_coordinator') desc nulls last, a.created_at
  limit 1;
  if v_owner is null then
    raise exception 'Invite at least one leader before loading sample data';
  end if;

  -- 1. Teams and their rota roles ------------------------------------------------------
  for i in 1 .. array_length(v_units, 1) loop
    select id into v_unit from public.units where church_id = v_church and name = v_units[i][1];
    if v_unit is null then
      select id into v_purpose from public.purposes where church_id = v_church and name = v_units[i][2];
      if v_purpose is null then
        insert into public.purposes (church_id, name) values (v_church, v_units[i][2]) returning id into v_purpose;
      end if;
      insert into public.units (church_id, purpose_id, name, target_headcount)
      values (v_church, v_purpose, v_units[i][1], 8) returning id into v_unit;
    end if;
    v_unit_ids := v_unit_ids || v_unit;
    insert into public.church_roles (church_id, unit_id, name, description, is_rota_role)
    select v_church, v_unit, r, 'Sample data', true
    from unnest(array[v_units[i][3], v_units[i][4]]) r
    where not exists (select 1 from public.church_roles c where c.unit_id = v_unit and c.name = r);
  end loop;

  -- 2. People (fictional; undeliverable .example addresses) ---------------------------
  for i in 1 .. array_length(v_names, 1) loop
    insert into public.people (church_id, first_name, surname, email, area, date_joined,
                               birth_day, birth_month, celebration_opt_in, newsletter_subscribed,
                               available_hours_month)
    values (v_church, v_names[i][1], v_names[i][2],
            lower(v_names[i][1] || '.' || v_names[i][2]) || '@g-squad.example', v_names[i][3],
            -- Most joined over a year ago; the last three are new (shows the 90-day flag).
            case when i > 27 then current_date - 30 else current_date - (200 + i * 20) end,
            1 + (i * 7) % 28, 1 + (i % 12), i % 3 <> 0, true,
            case when i % 5 = 0 then 6 else 12 end)
    returning id into v_person;
    v_people := v_people || v_person;
  end loop;

  -- 3. Team memberships: five per team, the first of each five is its Team Leader.
  --    Six people also join a second team, so "serving in several teams" shows.
  for i in 1 .. 30 loop
    v_unit := v_unit_ids[1 + ((i - 1) / 5)];
    select id into v_role from public.church_roles where unit_id = v_unit and description = 'Sample data'
      order by name limit 1 offset ((i - 1) % 2);
    insert into public.unit_memberships (church_id, person_id, unit_id, church_role_id, is_team_leader, joined_on)
    values (v_church, v_people[i], v_unit, v_role, (i - 1) % 5 = 0,
            case when i > 27 then current_date - 20 else current_date - 180 end);
  end loop;
  for i in 2 .. 30 by 5 loop
    v_unit := v_unit_ids[1 + (i / 5 + 1) % 6];
    select id into v_role from public.church_roles where unit_id = v_unit and description = 'Sample data'
      order by name limit 1;
    insert into public.unit_memberships (church_id, person_id, unit_id, church_role_id, joined_on)
    values (v_church, v_people[i], v_unit, v_role, current_date - 120)
    on conflict do nothing;
  end loop;

  -- 4. Sunday services: the next four Sundays, each with a short draft grid.
  v_sunday := current_date + (7 - extract(isodow from current_date)::int);
  if v_sunday = current_date then v_sunday := v_sunday + 7; end if;
  for i in 0 .. 3 loop
    insert into public.projects (church_id, owner_user_id, name, description, level, is_sunday_service, status, starts_at, ends_at)
    values (v_church, v_owner, 'Sunday service ' || to_char(v_sunday + i * 7, 'FMDD Mon YYYY'), 'Sample data',
            'church', true, 'approved',
            ((v_sunday + i * 7) + time '10:00') at time zone 'Europe/London',
            ((v_sunday + i * 7) + time '12:40') at time zone 'Europe/London')
    returning id into v_project;
    insert into public.service_grids (church_id, project_id, service_date, theme)
    values (v_church, v_project, v_sunday + i * 7, case i when 0 then 'BUILD: Ministers, not just volunteers' end)
    returning id into v_grid;
    insert into public.service_segments (church_id, grid_id, position, title, starts_at, duration_minutes, led_by_unit_id, led_by_text)
    values (v_church, v_grid, 1, 'Praise and worship', '10:00', 30, v_unit_ids[3], null),
           (v_church, v_grid, 2, 'Welcome and notices', '10:30', 10, v_unit_ids[5], null),
           (v_church, v_grid, 3, 'The Word', '10:40', 60, null, 'Resident Pastor'),
           (v_church, v_grid, 4, 'Response and prayer', '11:40', 20, v_unit_ids[4], null);
    v_sundays := v_sundays || (v_sunday + i * 7);

    -- Serving on this Sunday: an uneven spread on purpose, so Fair share has a story to tell.
    -- People 1, 6, 11 (Team Leaders) serve three of the four Sundays (the busiest fifth);
    -- most others serve once; a few are not asked at all.
    insert into public.assignments (church_id, project_id, person_id, unit_id, church_role_id, serve_date)
    select v_church, v_project, m.person_id, m.unit_id, m.church_role_id, v_sunday + i * 7
    from public.unit_memberships m
    join unnest(v_people) with ordinality p(id, n) on p.id = m.person_id
    where m.status = 'active' and m.unit_id = v_unit_ids[1 + ((p.n::int - 1) / 5)]
      and ((p.n in (1, 6, 11) and i < 3)
           or (p.n not in (1, 6, 11) and p.n % 4 = i and p.n % 7 <> 0)
           -- People 2, 3, 16 and 17 serve a second Sunday as well.
           or (p.n in (2, 3, 16, 17) and (p.n + 1) % 4 = i));
  end loop;

  -- 5. A church event and a team activity, each asking teams for people (Volunteers needed).
  insert into public.projects (church_id, owner_user_id, name, description, level, status, starts_at, ends_at)
  values (v_church, v_owner, 'Community fun day', 'Sample data: an outreach day in the park', 'church', 'approved',
          ((v_sunday + 13) + time '11:00') at time zone 'Europe/London',
          ((v_sunday + 13) + time '15:00') at time zone 'Europe/London')
  returning id into v_project;
  insert into public.team_demand (church_id, project_id, unit_id, church_role_id, on_date, slots_needed, hours)
  select v_church, v_project, u, null, v_sunday + 13, 3, 4 from unnest(array[v_unit_ids[2], v_unit_ids[4]]) u;
  -- One Hospitality member is named already; the rest are left for the Team Lead to fill.
  -- (People 1, 6 and 11 are at the 9-hour limit, so the rota shows them as full.)
  insert into public.assignments (church_id, project_id, person_id, unit_id, serve_date)
  values (v_church, v_project, v_people[7], v_unit_ids[2], v_sunday + 13);

  insert into public.projects (church_id, owner_user_id, name, description, level, unit_id, status, starts_at, ends_at)
  values (v_church, v_owner, 'Ushers training evening', 'Sample data: a team activity waiting for its Purpose Head',
          'unit', v_unit_ids[1], 'submitted',
          ((v_sunday + 3) + time '19:00') at time zone 'Europe/London',
          ((v_sunday + 3) + time '21:00') at time zone 'Europe/London');

  insert into public.projects (church_id, owner_user_id, name, description, level, status, starts_at, ends_at)
  values (v_church, v_owner, 'Christmas carol service', 'Sample data: a church event waiting for a decision',
          'church', 'submitted',
          (make_date(extract(year from current_date)::int, 12, 20) + time '18:00') at time zone 'Europe/London',
          (make_date(extract(year from current_date)::int, 12, 20) + time '20:00') at time zone 'Europe/London');

  -- 6. Holidays: two people away on the second Sunday (the rota shows them as away).
  insert into public.holidays (church_id, person_id, starts_on, ends_on)
  values (v_church, v_people[8], v_sundays[2] - 3, v_sundays[2] + 3),
         (v_church, v_people[19], v_sundays[2] - 1, v_sundays[2] + 6);

  -- 7. One-to-ones this quarter for half the members (recorded by the owning leader).
  for i in 1 .. 30 by 2 loop
    insert into public.one_to_ones (church_id, lead_user_id, person_id, unit_id, quarter_start, held_on, feeling, support_needed,
                                    development_goal, value_lived_id)
    values (v_church, v_owner, v_people[i], v_unit_ids[1 + ((i - 1) / 5)], date_trunc('quarter', current_date)::date,
            greatest(date_trunc('quarter', current_date)::date, current_date - (i % 20)),
            (array['thriving','doing_well','doing_well','finding_it_hard','overstretched']::public.serving_feeling[])[1 + i % 5],
            (array['none','training','none','fewer_slots','pastoral_check_in']::public.support_need[])[1 + i % 5],
            'Grow in leading others',
            (select id from public.core_values where church_id = v_church and is_active order by sort_order limit 1 offset (i % 6)));
  end loop;

  -- 8. Values in action: three recognitions (one agreed for the newsletter).
  insert into public.recognitions (church_id, recognised_by, person_id, unit_id, value_id, description, recognised_on,
                                   offered_to_newsletter, person_agreed)
  values
    (v_church, v_owner, v_people[2], v_unit_ids[1], (select id from public.core_values where church_id = v_church and name = 'Service' limit 1),
     'Stayed after the service to reset the hall without being asked.', current_date - 5, true, true),
    (v_church, v_owner, v_people[7], v_unit_ids[2], (select id from public.core_values where church_id = v_church and name = 'Love' limit 1),
     'Made sure every new guest had someone to sit with.', current_date - 9, false, false),
    (v_church, v_owner, v_people[13], v_unit_ids[3], (select id from public.core_values where church_id = v_church and name = 'Excellence' limit 1),
     'Prepared the new song arrangement a week early.', current_date - 12, false, false);

  raise notice 'Sample data loaded: % people, % Sundays', array_length(v_people, 1), array_length(v_sundays, 1);
end $$;

-- 9. The tester's sign-in gets the leader roles (scoped roles take a sample team).
-- __TEST_EMAIL__ is replaced by scripts/sample-data-prepare.sh after it checks the address is
-- a plain email (letters, digits and . _ % + - only), so no quote can reach this SQL. Left as
-- is, nothing matches and no role is given.
--
-- SECURITY REVIEW 21:
--   K02  The Resident Pastor role is given only when the workflow's "Also give the tester the
--        Resident Pastor role" box is ticked (__GIVE_RESIDENT_PASTOR__ becomes 'yes'). In the
--        app only the Resident Pastor gives that role; here the database owner does, so it is
--        opt-in, and the workflow is off unless an admin switches it on.
--   K05  The audit trigger logs these grants with no actor (the database owner made them), so
--        nobody could tell who gave them. Each role given also writes an audit row naming the
--        GitHub user and run. sample-data-remove.sql uses those rows to take the roles back.
--   Paul's decision (25 Oct 2026): one test sign-in per role is needed too (admin@ as the
--        Resident Pastor, operations@ as a Team Lead), so the workflow chooses a set of roles:
--        __ROLE_SET__ becomes 'all', 'resident_pastor' or 'team_lead'. "Resident Pastor only"
--        still needs the K02 box ticked.
--   K06  The Team Lead role went to Ushers even when Ushers already had a Team Lead, and the
--        one-Team-Lead rule then stopped the whole load. It now goes to the first sample team
--        without one (or is skipped).
do $$
declare
  v_church uuid := (select id from public.churches where slug = 'tec-manchester');
  v_user uuid := (select u.id from auth.users u join public.app_users a on a.id = u.id
                  where lower(u.email) = lower('__TEST_EMAIL__') and a.church_id = v_church);
  v_give_rp boolean := '__GIVE_RESIDENT_PASTOR__' = 'yes';
  -- Which roles: every role, or just one so a single role's view can be checked. Left as
  -- the placeholder (or anything unexpected), it means every role, as before.
  v_set text := case when '__ROLE_SET__' in ('resident_pastor', 'team_lead') then '__ROLE_SET__' else 'all' end;
  v_unit uuid;
  v_purpose uuid := (select purpose_id from public.units where church_id = v_church and name = 'Ushers');
  v_given int;
begin
  if v_user is null then
    raise notice 'No signed-up leader with that email yet: invite them in the app first, then run this again';
    return;
  end if;
  if exists (select 1 from public.church_settings where church_id = v_church and newsletter_live) then
    raise exception 'Sending to members is switched on, so this church is live: no test roles are given';
  end if;
  -- The first sample team (in the order sample-data.sql lists them) with no other Team Lead.
  select u.id into v_unit
  from unnest(array['Ushers','Hospitality','Elevation Priests of Praise (EPOP)','Missions','412 Nation','Maturity'])
       with ordinality t(name, n)
  join public.units u on u.church_id = v_church and u.name = t.name
  where not exists (select 1 from public.role_assignments ra
                    where ra.unit_id = u.id and ra.role = 'unit_lead' and ra.is_active and ra.user_id <> v_user)
  order by t.n limit 1;

  with wanted as (
    select x.r::public.app_role as role, x.p as purpose_id, x.u as unit_id
    from (values ('resident_pastor', null::uuid, null::uuid), ('gsquad_coordinator', null, null),
                 ('operations_lead', null, null), ('teci_coordinator', null, null),
                 ('pastoral_lead', null, null), ('newsletter_editor', null, null), ('finance', null, null),
                 ('purpose_head', v_purpose, null), ('unit_lead', null, v_unit)) as x(r, p, u)
    where (v_set = 'all' or (v_set = 'resident_pastor' and x.r = 'resident_pastor')
                         or (v_set = 'team_lead' and x.r = 'unit_lead'))
      and (x.r <> 'resident_pastor' or v_give_rp)
      and (x.r <> 'unit_lead' or v_unit is not null)
      and (x.r <> 'purpose_head' or v_purpose is not null)
  ), given as (
    insert into public.role_assignments (church_id, user_id, role, purpose_id, unit_id)
    select v_church, v_user, w.role, w.purpose_id, w.unit_id
    from wanted w
    where not exists (select 1 from public.role_assignments ra
                      where ra.user_id = v_user and ra.role = w.role and ra.is_active)
    returning id, role
  ), logged as (
    -- Ids and labels only (audit_log never holds personal free text).
    insert into public.audit_log (church_id, actor_id, action, table_name, record_id, detail)
    select v_church, null, 'sample_data_grant', 'role_assignments', g.id,
           jsonb_build_object('role', g.role, 'source', 'supabase/sample-data.sql',
                              'github_user', '__RUN_BY__', 'github_run', '__RUN_ID__')
    from given g
    returning 1
  )
  select count(*) into v_given from logged;
  raise notice 'Gave the test sign-in % leader role(s)%', v_given,
    case when v_give_rp then ', including Resident Pastor' else ' (not Resident Pastor)' end;
  if v_unit is null then
    raise notice 'Every sample team already has a Team Lead, so the Team Lead role was not given';
  end if;
end $$;

commit;

-- What the workflow log shows (notices from the blocks above may not reach it).
select (select count(*) from public.people where email like '%@g-squad.example') as sample_people,
       (select count(*) from public.projects where description like 'Sample data%') as sample_projects,
       (select count(distinct ra.role) from public.role_assignments ra
          join auth.users u on u.id = ra.user_id
         where lower(u.email) = lower('__TEST_EMAIL__') and ra.is_active) as tester_roles;
