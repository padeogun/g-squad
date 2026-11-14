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
--   Greatness Communities and leadership questions   name ends with '(sample)'
-- Everything else (faith fields, notes, flags, plans, inputs, serving, the newsletter issue)
-- belongs to a sample person or a sample project and goes when that does.
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
  v_community uuid;
  v_row uuid;
  v_prompt uuid;
  v_issue uuid;
  v_day date;
  v_month date;
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
  -- Every event has a run of show (migration 32): a draft one for the fun day, to finalise
  -- and approve when testing.
  insert into public.service_grids (church_id, project_id, service_date, theme)
  values (v_church, v_project, v_sunday + 13, 'Love your neighbour') returning id into v_grid;
  insert into public.service_segments (church_id, grid_id, position, title, starts_at, duration_minutes, led_by_unit_id, led_by_text)
  values (v_church, v_grid, 1, 'Set up the gazebos and stalls', '10:00', 60, v_unit_ids[2], null),
         (v_church, v_grid, 2, 'Welcome and opening prayer', '11:00', 15, null, 'Resident Pastor'),
         (v_church, v_grid, 3, 'Games, food and face painting', '11:15', 180, v_unit_ids[4], null),
         (v_church, v_grid, 4, 'Pack down', '14:15', 45, v_unit_ids[2], null);

  insert into public.projects (church_id, owner_user_id, name, description, level, unit_id, status, starts_at, ends_at)
  values (v_church, v_owner, 'Ushers training evening', 'Sample data: a team event waiting for its Purpose Head (start its run of show first)',
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

  -- ===================================================================================
  -- Sections 9 to 20 (13 Nov 2026, Paul: "a test version to test all the functions").
  -- Sections 1 to 8 left whole screens empty (faith fields, TECi, communities, pastoral
  -- notes, event plans, inputs, safeguarding, serving approvals, the newsletter, history).
  -- Everything below hangs off a sample person or a sample project, or carries "(sample)" in
  -- its name, so sample-data-remove.sql can find it.
  -- ===================================================================================

  -- 9. Member details: phones, a second email, marriage and anniversary, TECi stage.
  --    Phones are in 07700 900xxx, the range Ofcom keeps for drama: no real phone can ring.
  for i in 1 .. 30 loop
    update public.people set
      phones = case when i % 3 = 1 then array['07700 900' || lpad((100 + i)::text, 3, '0')] else phones end,
      other_emails = case when i in (4, 9) then array[lower(v_names[i][1] || '.' || v_names[i][2]) || '.work@g-squad.example'] else other_emails end,
      marital_status = case when i % 4 = 0 then 'married' when i % 4 = 1 then 'single' end::public.marital_status,
      anniversary_day = case when i % 4 = 0 then 1 + (i * 3) % 28 end,
      anniversary_month = case when i % 4 = 0 then 1 + ((i + extract(month from current_date)::int) % 12) end,
      -- One name with Yoruba tone marks, to check the service grid PDF prints it properly.
      other_names = case i when 9 then 'Ọláolúwa' when 4 then 'Rose' end,
      -- Stages 1 to 5 across the members. Two in three are verified by the TECi Coordinator;
      -- the rest, and the three new members (stage 1), wait on the TECi page to be verified.
      teci_stage_id = (select t.id from public.teci_stages t where t.church_id = v_church
                       and t.stage_no = case when i > 27 then 1 else 1 + (i % 5) end),
      teci_verified_at = case when i <= 27 and i % 3 <> 0 then now() - interval '30 days' end
    where id = v_people[i];
  end loop;

  -- 10. Faith fields for 24 of the 30 (the rest are blank, as a new entry would be). Written
  --     here by the database owner because public.set_person_faith needs a signed-in leader;
  --     in the app these are still read and written only through the logged functions.
  --     Two water baptisms fall in the last month, so the monthly report and the newsletter
  --     have a baptism count to show.
  insert into public.person_faith (church_id, person_id, salvation_date, water_baptism, water_baptism_date,
                                   holy_spirit_baptism, holy_spirit_baptism_date, speaks_in_tongues)
  select v_church, p.id, current_date - (400 + p.n::int * 45), p.n % 2 = 0,
         case when p.n in (2, 4) then current_date - 10 when p.n % 2 = 0 then current_date - (300 + p.n::int * 20) end,
         p.n % 3 = 0, case when p.n % 3 = 0 then current_date - (200 + p.n::int * 15) end, p.n % 6 = 0
  from unnest(v_people) with ordinality p(id, n)
  where p.n <= 24
  on conflict (person_id) do update set
    salvation_date = excluded.salvation_date, water_baptism = excluded.water_baptism,
    water_baptism_date = excluded.water_baptism_date, holy_spirit_baptism = excluded.holy_spirit_baptism,
    holy_spirit_baptism_date = excluded.holy_spirit_baptism_date, speaks_in_tongues = excluded.speaks_in_tongues;

  -- 11. Team roles and leadership stages: a Deputy Team Lead in three teams, a Welfare and
  --     Pastoral Coordinator in two (the church's default roles, migration 22), and a
  --     leadership stage for eight people.
  update public.unit_memberships m set church_role_id = r.id
    from public.church_roles r, unnest(v_people) with ordinality p(id, n)
   where r.church_id = v_church and m.person_id = p.id and m.unit_id = v_unit_ids[1 + ((p.n::int - 1) / 5)]
     and ((p.n in (3, 8, 13) and r.default_key = 'deputy_team_lead')
          or (p.n in (4, 18) and r.default_key = 'welfare_pastoral'));
  update public.unit_memberships m set leadership_stage_id = s.id
    from public.leadership_stages s, unnest(v_people) with ordinality p(id, n)
   where s.church_id = v_church and m.person_id = p.id and m.unit_id = v_unit_ids[1 + ((p.n::int - 1) / 5)]
     and p.n % 4 = 3 and s.sort_order = 1 + (p.n::int / 4) % 4;

  -- 12. Greatness Communities (named "(sample)" so removal finds them), their support roles
  --     and a few members in each. One support role is left unfilled.
  for i in 1 .. 3 loop
    insert into public.greatness_communities (church_id, type_id, name)
    select v_church, t.id, (array['Founders Table (sample)', 'Creatives Collective (sample)', 'Eccles Neighbours (sample)'])[i]
    from public.community_types t
    where t.church_id = v_church
      and t.name = (array['Business and Career', 'Art and Media', 'Geography or Location Based'])[i]
    returning id into v_community;
    if v_community is not null then
      insert into public.community_support_roles (church_id, community_id, role_name, person_id)
      values (v_church, v_community, 'Community Lead', v_people[i * 4]),
             (v_church, v_community, 'Host', v_people[i * 4 + 1]),
             (v_church, v_community, 'Prayer Lead', null);
      update public.people set greatness_community_id = v_community
       where id = any (v_people[i * 4 : i * 4 + 4]);
    end if;
    v_community := null;
  end loop;

  -- 13. Someone who has left and someone taking a break (neither has serving booked: 14 and 28
  --     are never on the Sunday rota above), so the status filters and "left" rules show.
  update public.unit_memberships set status = 'ended', ended_on = current_date - 14 where person_id = v_people[14];
  update public.people set status = 'left', date_left = current_date - 14 where id = v_people[14];
  update public.people set status = 'paused' where id = v_people[28];

  -- 14. Pastoral care: two notes (one with a follow-up date) and three check-in flags (one
  --     raised by a leader, one for a new member, one already closed).
  insert into public.pastoral_notes (church_id, person_id, author_id, note, follow_up_on)
  values (v_church, v_people[5], v_owner, 'Sample data: asked for prayer about a house move. Offered a lighter rota for a month.', current_date + 14),
         (v_church, v_people[15], v_owner, 'Sample data: back after a long break and glad to be serving again.', null);
  insert into public.checkin_flags (church_id, person_id, source, status, raised_by, raised_at, closed_by, closed_at)
  values (v_church, v_people[5], 'manual', 'open', v_owner, now() - interval '3 days', null, null),
         (v_church, v_people[29], 'new_90_days', 'open', null, now() - interval '1 day', null, null),
         (v_church, v_people[10], 'manual', 'closed', v_owner, now() - interval '40 days', v_owner, now() - interval '30 days');

  -- 15. Eight past Sundays, so "active / inactive", Fair share, the monthly report and the
  --     dashboards have history. Each was served, then closed (a booking cannot be added to a
  --     closed project, so the Sunday is marked done after its serving is recorded).
  --     The spread keeps everyone inside the 9-hour limit together with section 4: most
  --     people served one Sunday in four; the three busy Team Leads served only the two
  --     oldest odd weeks; people 7, 14, 21 and 28 were never asked (they show as inactive).
  --     Checked for any start date: no one passes their monthly hours in any calendar month.
  for i in 1 .. 8 loop
    insert into public.projects (church_id, owner_user_id, name, description, level, is_sunday_service, status, starts_at, ends_at)
    values (v_church, v_owner, 'Sunday service ' || to_char(v_sunday - i * 7, 'FMDD Mon YYYY'), 'Sample data',
            'church', true, 'approved',
            ((v_sunday - i * 7) + time '10:00') at time zone 'Europe/London',
            ((v_sunday - i * 7) + time '12:40') at time zone 'Europe/London')
    returning id into v_project;
    insert into public.service_grids (church_id, project_id, service_date, theme)
    values (v_church, v_project, v_sunday - i * 7, 'BUILD (sample week ' || i || ')')
    returning id into v_grid;
    insert into public.service_segments (church_id, grid_id, position, title, starts_at, duration_minutes, led_by_unit_id, led_by_text)
    values (v_church, v_grid, 1, 'Praise and worship', '10:00', 30, v_unit_ids[3], null),
           (v_church, v_grid, 2, 'Welcome and notices', '10:30', 10, v_unit_ids[5], null),
           (v_church, v_grid, 3, 'The Word', '10:40', 60, null, 'Resident Pastor'),
           (v_church, v_grid, 4, 'Response and prayer', '11:40', 20, v_unit_ids[4], null);
    -- SECURITY REVIEW 24 (A03): approved after its parts are in. Adding a part to an approved
    -- grid withdraws the approval (the database's own rule), which left these past Sundays
    -- waiting for the Resident Pastor.
    update public.service_grids set status = 'approved',
           finalised_at = ((v_sunday - i * 7 - 3) + time '18:00') at time zone 'Europe/London',
           approved_at = ((v_sunday - i * 7 - 2) + time '18:00') at time zone 'Europe/London'
     where id = v_grid;
    insert into public.assignments (church_id, project_id, person_id, unit_id, church_role_id, serve_date, status)
    select v_church, v_project, m.person_id, m.unit_id,
           (select c.id from public.church_roles c where c.unit_id = m.unit_id and c.description = 'Sample data'
             order by c.name limit 1 offset ((p.n::int - 1) % 2)),
           v_sunday - i * 7,
           -- One no-show, so that status has an example.
           case when p.n = 9 and i = 5 then 'no_show' else 'served' end::public.assignment_status
    from public.unit_memberships m
    join unnest(v_people) with ordinality p(id, n) on p.id = m.person_id
    where m.status = 'active' and m.unit_id = v_unit_ids[1 + ((p.n::int - 1) / 5)]
      and ((p.n in (1, 6, 11) and i in (5, 7))
           -- Person 18 is left out: their hours are kept for the three events of section 17e.
           or (p.n not in (1, 6, 11, 18) and p.n % 7 <> 0 and p.n % 4 = i % 4));
    update public.projects set status = 'done' where id = v_project;
  end loop;

  -- 16. The Sundays ahead: the first keeps its draft grid (to finalise), now with sub-points,
  --     a named person leading and the reusable blocks; the second is finalised and waits for
  --     the Resident Pastor's approval.
  update public.service_segments s set sub_points = array['Call to worship', 'Two songs of praise', 'One song of worship']
    from public.service_grids g where g.id = s.grid_id and g.service_date = v_sundays[1] and g.is_sunday and s.position = 1
     and g.project_id in (select id from public.projects where description like 'Sample data%');
  update public.service_segments s set led_by_person_id = v_people[9], led_by_unit_id = null
    from public.service_grids g where g.id = s.grid_id and g.service_date = v_sundays[1] and g.is_sunday and s.position = 2
     and g.project_id in (select id from public.projects where description like 'Sample data%');
  insert into public.service_grid_blocks (church_id, grid_id, block_id, position)
  select v_church, g.id, b.id, row_number() over (order by b.name)
  from public.service_grids g, public.reusable_blocks b
  where g.service_date = v_sundays[1] and g.is_sunday and b.church_id = v_church
    and g.project_id in (select id from public.projects where description like 'Sample data%')
  on conflict do nothing;
  update public.service_grids g set status = 'finalised', finalised_at = now()
   where g.service_date = v_sundays[2] and g.is_sunday
     and g.project_id in (select id from public.projects where description like 'Sample data%');

  -- 17. Events at every stage, with the High-level Event Planning form, action points, inputs
  --     (requested, overdue, received), safeguarding notes and volunteers needed.
  --  a. Community fun day (approved in section 5): a full plan with the budget approved.
  select id into v_project from public.projects where church_id = v_church and name = 'Community fun day' and description like 'Sample data%';
  insert into public.event_plans (church_id, project_id, size, complexity, purpose_why, spiritual_outcome, alignment, target_audience,
                                  has_planning_committee, committee_members, calendar_check, venue_kind, venue_name,
                                  budget_estimate_gbp, budget_status, budget_decided_by, budget_decided_at, funding,
                                  required_resources, resource_gaps, setup_minutes, packdown_minutes, main_attraction, engagement,
                                  side_activities, media_plan, logistics_plan, childcare_needed, risk_assessment_needed,
                                  comms_plan_done, comms_strategy, assets_status, signup_method, followup_plan, guest_journey,
                                  hospitality, decor, on_day_lead_person_id, qc_checklist)
  values (v_church, v_project, 'medium', 'moderate', 'Meet our neighbours and serve families near the church.',
          'Guests hear the gospel simply and are invited to Sunday.', 'BUILD: ministers, not just volunteers.', 'Families within a mile of the venue',
          true, 'Missions and Hospitality Team Leads (sample)', 'confirmed', 'external', 'Peel Park (sample)',
          450, 'approved', v_owner, now() - interval '5 days', 'ministry_budget',
          'Gazebos, tables, PA, games kit, food for 150', 'Second gazebo still to borrow', 60, 45, 'Family games and a free barbecue',
          'Welcome desk and prayer corner', 'Face painting, bouncy castle', 'Two photographers; short film for the Brief',
          'Van from 9am; set up by 10.30', true, true, true, 'Flyers door to door, social posts two weeks ahead', 'in_progress',
          'No sign-up: open invitation', 'Follow-up callers ring every guest who leaves a number within 3 days',
          'Welcome desk, games, food, prayer corner, invitation card', 'Barbecue and soft drinks; halal and vegetarian options',
          'TEC banners and bunting', v_people[16], 'Risk assessment signed; first aid kit; lost child point briefed');
  insert into public.event_plan_actions (church_id, project_id, section_no, description, owner_user_id, due_on, status)
  values (v_church, v_project, 6, 'Borrow a second gazebo', v_owner, v_sunday + 6, 'open'),
         (v_church, v_project, 9, 'Print 500 flyers', v_owner, v_sunday - 2, 'done'),
         (v_church, v_project, 8, 'Brief the lost child point team', v_owner, v_sunday + 12, 'open');
  insert into public.project_inputs (church_id, project_id, title, requested_from_user_id, unit_id, due_on, is_required, status, body, received_at, requested_by)
  values (v_church, v_project, 'Risk assessment', v_owner, null, current_date - 6, true, 'requested', null, null, v_owner),
         (v_church, v_project, 'First aid cover confirmed', v_owner, null, current_date - 2, true, 'requested', null, null, v_owner),
         (v_church, v_project, 'Food order for 150', v_owner, v_unit_ids[2], v_sunday + 8, false, 'requested', null, null, v_owner);
  -- SECURITY REVIEW 24 (A04): every input starts as requested (the database's own rule), so the
  -- received one is marked received afterwards, as the person asked would do.
  update public.project_inputs set status = 'received', body = 'Sample data: risk assessment completed and filed.',
         received_at = now() - interval '7 days'
   where project_id = v_project and title = 'Risk assessment';
  insert into public.event_safeguarding (church_id, project_id, notes, updated_by)
  values (v_church, v_project, 'Sample data: children stay with their own adults; two DBS-checked leaders at the lost child point.', v_owner);
  -- Missions' three places: one filled (person 18), two open (a shortfall on My Unit).
  insert into public.assignments (church_id, project_id, person_id, unit_id, serve_date)
  values (v_church, v_project, v_people[18], v_unit_ids[4], v_sunday + 13);

  --  b. Christmas carol service (waiting for a decision): a large event with the budget still
  --     to decide (R16) and more people asked for than two teams have (shortfall, R6).
  select id, (starts_at at time zone 'Europe/London')::date into v_project, v_day
  from public.projects where church_id = v_church and name = 'Christmas carol service' and description like 'Sample data%';
  insert into public.event_plans (church_id, project_id, size, complexity, purpose_why, target_audience, has_planning_committee,
                                  calendar_check, venue_kind, venue_name, budget_estimate_gbp, budget_status, funding,
                                  childcare_needed, risk_assessment_needed)
  values (v_church, v_project, 'large', 'high', 'Invite the city to hear the Christmas story.', 'Members, friends and families',
          true, 'not_checked', 'internal', 'Main hall', 1200, 'pending', 'ministry_budget', true, true);
  insert into public.team_demand (church_id, project_id, unit_id, church_role_id, on_date, slots_needed, hours)
  values (v_church, v_project, v_unit_ids[3], null, v_day, 12, 3),
         (v_church, v_project, v_unit_ids[1], null, v_day, 8, 3);
  insert into public.event_safeguarding (church_id, project_id, notes, updated_by)
  values (v_church, v_project, 'Sample data: creche in the side room, sign-in and sign-out sheet.', v_owner);

  --  c. Ushers training evening (waiting for its Purpose Head): a small team event.
  select id into v_project from public.projects where church_id = v_church and name = 'Ushers training evening' and description like 'Sample data%';
  insert into public.event_plans (church_id, project_id, size, complexity, purpose_why, calendar_check, venue_kind, budget_status, funding)
  values (v_church, v_project, 'small', 'low', 'Refresh the welcome and seating routine before Christmas.', 'confirmed', 'internal', 'not_needed', 'free');

  --  d. A draft, to take through submit and approval from the start.
  insert into public.projects (church_id, owner_user_id, name, description, level, status, starts_at, ends_at)
  values (v_church, v_owner, 'Youth worship night', 'Sample data: a draft to complete and submit', 'church', 'draft',
          ((v_sunday + 40) + time '18:30') at time zone 'Europe/London',
          ((v_sunday + 40) + time '21:00') at time zone 'Europe/London');

  --  e. Winter coat drive (approved, two weeks) and a Missions prayer walk on the morning of
  --     the fun day. Person 18 is on the fun day and the coat drive already, so the prayer
  --     walk booking waits for the G-Squad Coordinator (more than 2 events at the same time).
  --     Hours are short (1 hour each) so approving it keeps person 18 inside the 9 hours.
  insert into public.projects (church_id, owner_user_id, name, description, level, status, starts_at, ends_at, approved_at)
  values (v_church, v_owner, 'Winter coat drive', 'Sample data: collecting and sorting coats for local families', 'church', 'approved',
          ((v_sunday + 8) + time '09:00') at time zone 'Europe/London',
          ((v_sunday + 20) + time '17:00') at time zone 'Europe/London', now() - interval '4 days')
  returning id into v_project;
  insert into public.team_demand (church_id, project_id, unit_id, church_role_id, on_date, slots_needed, hours)
  values (v_church, v_project, v_unit_ids[4], null, v_sunday + 10, 3, 1);
  insert into public.assignments (church_id, project_id, person_id, unit_id, serve_date)
  values (v_church, v_project, v_people[18], v_unit_ids[4], v_sunday + 10);
  insert into public.service_grids (church_id, project_id, service_date, theme)
  values (v_church, v_project, v_sunday + 8, 'Warm this winter') returning id into v_grid;
  insert into public.service_segments (church_id, grid_id, position, title, starts_at, duration_minutes, led_by_unit_id, led_by_text)
  values (v_church, v_grid, 1, 'Collection point opens', '09:00', 180, v_unit_ids[4], null),
         (v_church, v_grid, 2, 'Sorting and bagging', '12:00', 120, v_unit_ids[4], null);

  insert into public.projects (church_id, owner_user_id, name, description, level, unit_id, status, starts_at, ends_at, approved_at)
  values (v_church, v_owner, 'Missions prayer walk', 'Sample data: a team event before the fun day', 'unit', v_unit_ids[4], 'approved',
          ((v_sunday + 13) + time '09:00') at time zone 'Europe/London',
          ((v_sunday + 13) + time '11:30') at time zone 'Europe/London', now() - interval '2 days')
  returning id into v_project;
  insert into public.team_demand (church_id, project_id, unit_id, church_role_id, on_date, slots_needed, hours)
  values (v_church, v_project, v_unit_ids[4], null, v_sunday + 13, 4, 1);
  insert into public.assignments (church_id, project_id, person_id, unit_id, serve_date, status)
  values (v_church, v_project, v_people[18], v_unit_ids[4], v_sunday + 13, 'pending_approval')
  returning id into v_row;
  -- SECURITY REVIEW 24 (A05): the request row the booking guard writes for a signed-in Team
  -- Lead, so the Coordinator's list shows when it was asked and how many events overlap.
  insert into public.audit_log (church_id, actor_id, action, table_name, record_id, detail)
  values (v_church, v_owner, 'serving_approval_requested', 'assignments', v_row,
          jsonb_build_object('kind', 'project', 'person_id', v_people[18], 'project_id', v_project,
                             'unit_id', v_unit_ids[4], 'overlapping', 2));

  --  f. A finished event with its review, a cancelled one, and one from the network (for
  --     information only).
  insert into public.projects (church_id, owner_user_id, name, description, level, status, starts_at, ends_at, approved_at)
  values (v_church, v_owner, 'Prayer breakfast', 'Sample data: a finished event with its review', 'church', 'approved',
          ((v_sunday - 36) + time '08:00') at time zone 'Europe/London',
          ((v_sunday - 36) + time '10:00') at time zone 'Europe/London', now() - interval '60 days')
  returning id into v_project;
  insert into public.event_plans (church_id, project_id, size, complexity, purpose_why, calendar_check, venue_kind, budget_estimate_gbp,
                                  budget_status, budget_decided_by, budget_decided_at, funding, review_impact, review_accounts_done,
                                  review_operational, review_feedback, review_completed_at)
  values (v_church, v_project, 'small', 'low', 'Pray for the term ahead.', 'confirmed', 'internal', 80, 'approved', v_owner,
          now() - interval '50 days', 'ministry_budget', '42 people came; six first-time guests.', true,
          'Set-up took longer than planned; start 30 minutes earlier next time.', 'Guests asked for it to be termly.', now() - interval '30 days');
  insert into public.team_demand (church_id, project_id, unit_id, church_role_id, on_date, slots_needed, hours)
  values (v_church, v_project, v_unit_ids[2], null, v_sunday - 36, 2, 2);
  insert into public.assignments (church_id, project_id, person_id, unit_id, serve_date, status)
  values (v_church, v_project, v_people[8], v_unit_ids[2], v_sunday - 36, 'served'),
         (v_church, v_project, v_people[9], v_unit_ids[2], v_sunday - 36, 'served');
  update public.projects set status = 'done' where id = v_project;

  insert into public.projects (church_id, owner_user_id, name, description, level, unit_id, status, starts_at, ends_at, decision_note)
  values (v_church, v_owner, 'Autumn hike', 'Sample data: a cancelled team event', 'unit', v_unit_ids[5], 'cancelled',
          ((v_sunday - 15) + time '10:00') at time zone 'Europe/London',
          ((v_sunday - 15) + time '15:00') at time zone 'Europe/London', 'Cancelled: weather warning.');
  insert into public.projects (church_id, owner_user_id, name, description, level, status, origin, origin_note, starts_at, ends_at)
  values (v_church, v_owner, 'Network leaders'' day', 'Sample data: from the network, shown for information', 'church', 'draft',
          'network', 'Dates set by the network (sample).',
          ((v_sunday + 27) + time '09:30') at time zone 'Europe/London',
          ((v_sunday + 27) + time '16:00') at time zone 'Europe/London');

  --  g. A routine team activity (not an event, so no run of show): weekly rehearsal for four
  --     weeks, two hours each, with two people named for the first week.
  insert into public.projects (church_id, owner_user_id, name, description, level, unit_id, status, is_event, starts_at, ends_at, approved_at)
  values (v_church, v_owner, 'EPOP weekly rehearsal', 'Sample data: a routine team activity', 'unit', v_unit_ids[3], 'approved', false,
          ((v_sunday + 4) + time '19:00') at time zone 'Europe/London',
          ((v_sunday + 25) + time '21:00') at time zone 'Europe/London', now() - interval '6 days')
  returning id into v_project;
  insert into public.team_demand (church_id, project_id, unit_id, church_role_id, on_date, slots_needed, hours)
  select v_church, v_project, v_unit_ids[3], null, v_sunday + 4 + w * 7, 4, 2 from generate_series(0, 3) w;
  insert into public.assignments (church_id, project_id, person_id, unit_id, serve_date)
  values (v_church, v_project, v_people[12], v_unit_ids[3], v_sunday + 4),
         (v_church, v_project, v_people[13], v_unit_ids[3], v_sunday + 4);

  -- 18. A request to join a third team, waiting for the G-Squad Coordinator. Person 2 is in
  --     Ushers and Hospitality already (section 3).
  insert into public.unit_memberships (church_id, person_id, unit_id, status, joined_on)
  values (v_church, v_people[2], v_unit_ids[6], 'pending_approval', current_date)
  returning id into v_row;
  insert into public.audit_log (church_id, actor_id, action, table_name, record_id, detail)   -- A05, as above
  values (v_church, v_owner, 'serving_approval_requested', 'unit_memberships', v_row,
          jsonb_build_object('kind', 'team', 'person_id', v_people[2], 'unit_id', v_unit_ids[6]));

  -- 19. One-to-ones in full: every focus area on this quarter's records, the restricted
  --     "walk with God" note on five of them, two leadership questions with answers, and last
  --     quarter's records for six people (history).
  update public.one_to_ones o set
    sense_of_family = 'Feels at home in the team; would like more time together outside Sundays.',
    competence = 'Confident in the role; ready to train a new member.',
    value_lived_note = 'Seen in how they covered for a teammate at short notice.',
    value_to_grow_id = (select c.id from public.core_values c where c.church_id = v_church and c.is_active
                         and c.id is distinct from o.value_lived_id order by c.sort_order desc limit 1),
    value_to_grow_note = 'Agreed one small step to practise before we next meet.',
    notes = 'Sample data'
  where o.person_id = any (v_people);
  insert into public.one_to_one_walk (church_id, one_to_one_id, notes, updated_by)
  select v_church, o.id, 'Sample data: reading through the Gospels; asked for a prayer partner.', v_owner
  from public.one_to_ones o join unnest(v_people) with ordinality p(id, n) on p.id = o.person_id
  where p.n in (1, 5, 9, 13, 17);
  for i in 1 .. 2 loop
    insert into public.one_to_one_prompts (church_id, question, starts_on, ends_on, created_by)
    values (v_church, (array['What would help you invite one person to church this quarter? (sample)',
                             'Which part of BUILD speaks to you most? (sample)'])[i],
            date_trunc('quarter', current_date)::date,
            (date_trunc('quarter', current_date) + interval '3 months - 1 day')::date, v_owner)
    returning id into v_prompt;
    insert into public.one_to_one_answers (church_id, one_to_one_id, prompt_id, answer)
    select v_church, o.id, v_prompt, (array['A simple invitation card to hand over.', 'Being a minister, not just a volunteer.'])[i]
    from public.one_to_ones o join unnest(v_people) with ordinality p(id, n) on p.id = o.person_id
    where p.n % 4 = 1;
  end loop;
  insert into public.one_to_ones (church_id, lead_user_id, person_id, unit_id, quarter_start, held_on, feeling, support_needed,
                                  development_goal, notes)
  select v_church, v_owner, p.id, v_unit_ids[1 + ((p.n::int - 1) / 5)],
         (date_trunc('quarter', current_date) - interval '3 months')::date,
         (date_trunc('quarter', current_date) - interval '20 days')::date,
         'doing_well', 'none', 'Shadow the Team Lead once a month', 'Sample data'
  from unnest(v_people) with ordinality p(id, n)
  where p.n in (1, 2, 6, 7, 11, 12);
  -- A fourth recognition, agreed for sharing at a G-Squad meeting.
  insert into public.recognitions (church_id, recognised_by, person_id, unit_id, value_id, description, recognised_on,
                                   offered_to_meeting, person_agreed)
  values (v_church, v_owner, v_people[17], v_unit_ids[4], (select id from public.core_values where church_id = v_church and name = 'Humility' limit 1),
          'Took the least visible job at the outreach and did it gladly.', current_date - 3, true, true);

  -- 20. Next month's issue of The Greatness Brief, as start_newsletter_issue would make it
  --     (that function needs a signed-in editor): the issue's own project, a draft with the
  --     editors' words, a win (agreed) and a notice, and a team update asked of each Team Lead
  --     who has signed in. Skipped if that month already has an issue. This month is left
  --     free, so "Start an issue" can be tried as well.
  v_month := (date_trunc('month', current_date) + interval '1 month')::date;
  if not exists (select 1 from public.newsletter_issues where church_id = v_church and issue_month = v_month) then
    insert into public.projects (church_id, owner_user_id, level, name, description, starts_at, ends_at)
    values (v_church, v_owner, 'church', 'The Greatness Brief: ' || trim(to_char(v_month, 'FMMonth YYYY')),
            'Sample data: the newsletter for ' || trim(to_char(v_month, 'FMMonth YYYY')) || '. Team updates for it are requested here.',
            (v_month::timestamp) at time zone 'Europe/London',
            ((v_month + interval '1 month')::timestamp at time zone 'Europe/London') - interval '1 second')
    returning id into v_project;
    insert into public.newsletter_issues (church_id, project_id, issue_month, send_on, headline, standfirst, pastor_word, pastor_name)
    values (v_church, v_project, v_month, v_month, 'Built to serve (sample issue)',
            'A made-up issue for testing: gatherings, new members, birthdays and wins.',
            'This season we are building people, not just filling rotas. Thank you for serving.', 'Resident Pastor (sample)')
    returning id into v_issue;
    insert into public.newsletter_items (church_id, issue_id, kind, position, title, body, names_a_person, agreement_ticked, created_by)
    values (v_church, v_issue, 'win', 1, 'A warm welcome', 'Ben stayed after the service to reset the hall without being asked.', true, true, v_owner),
           (v_church, v_issue, 'notice', 2, 'Rota requests', 'Holiday dates for January go to your Team Lead by the 20th.', false, false, v_owner);
    insert into public.project_inputs (church_id, project_id, title, requested_from_user_id, unit_id, due_on, is_required, requested_by)
    select v_church, v_project, 'Team update for The Greatness Brief, ' || trim(to_char(v_month, 'FMMonth YYYY')),
           ra.user_id, u.id, current_date + 7, false, v_owner
    from public.units u
    join public.role_assignments ra on ra.unit_id = u.id and ra.role = 'unit_lead' and ra.is_active and ra.church_id = v_church
    where u.church_id = v_church and u.is_active;
  end if;

  raise notice 'Sample data loaded: % people, % Sundays ahead, 8 Sundays past', array_length(v_people, 1), array_length(v_sundays, 1);
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
--   Paul's decision (13 Nov 2026): a test sign-in for every role, so the choice is now any
--        one role (see v_roles below). Still a fixed list checked by the script.
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
  v_set text := case when '__ROLE_SET__' in ('resident_pastor', 'purpose_head', 'gsquad_coordinator', 'operations_lead',
                                             'teci_coordinator', 'team_lead', 'deputy_team_lead', 'pastoral_lead',
                                             'newsletter_editor', 'finance') then '__ROLE_SET__' else 'all' end;
  -- The access roles each choice gives (13 Nov 2026: a test sign-in for every role). The
  -- Coordinator and Operations Lead functions are held by a Purpose Head (migration 22), so
  -- those two choices give Purpose Head as well. "all" leaves out Deputy Team Lead: one
  -- sign-in holding every role would see nothing a Deputy alone sees differently.
  v_roles text[] := case v_set
    when 'all' then array['resident_pastor', 'gsquad_coordinator', 'operations_lead', 'teci_coordinator', 'pastoral_lead',
                          'newsletter_editor', 'finance', 'purpose_head', 'unit_lead']
    when 'team_lead' then array['unit_lead']
    when 'deputy_team_lead' then array['deputy_unit_lead']
    when 'gsquad_coordinator' then array['purpose_head', 'gsquad_coordinator']
    when 'operations_lead' then array['purpose_head', 'operations_lead']
    else array[v_set] end;
  v_unit uuid;
  v_deputy_unit uuid;
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
    -- SECURITY REVIEW 24 (A02): nor a team this sign-in is already Deputy of (nobody is both).
    and not exists (select 1 from public.role_assignments ra
                    where ra.unit_id = u.id and ra.role = 'deputy_unit_lead' and ra.is_active and ra.user_id = v_user)
  order by t.n limit 1;
  -- A Deputy Team Lead's team: the first sample team this sign-in does not lead (nobody is
  -- both Team Lead and Deputy of one team). Ushers, unless they lead it.
  select u.id into v_deputy_unit
  from unnest(array['Ushers','Hospitality','Elevation Priests of Praise (EPOP)','Missions','412 Nation','Maturity'])
       with ordinality t(name, n)
  join public.units u on u.church_id = v_church and u.name = t.name
  where not exists (select 1 from public.role_assignments ra
                    where ra.unit_id = u.id and ra.role = 'unit_lead' and ra.is_active and ra.user_id = v_user)
  order by t.n limit 1;

  with wanted as (
    select x.r::public.app_role as role, x.p as purpose_id, x.u as unit_id
    from (values ('resident_pastor', null::uuid, null::uuid), ('gsquad_coordinator', null, null),
                 ('operations_lead', null, null), ('teci_coordinator', null, null),
                 ('pastoral_lead', null, null), ('newsletter_editor', null, null), ('finance', null, null),
                 ('purpose_head', v_purpose, null), ('unit_lead', null, v_unit),
                 ('deputy_unit_lead', null, v_deputy_unit)) as x(r, p, u)
    where x.r = any (v_roles)
      and (x.r <> 'resident_pastor' or v_give_rp)
      and (x.r <> 'unit_lead' or v_unit is not null)
      and (x.r <> 'deputy_unit_lead' or v_deputy_unit is not null)
      and (x.r <> 'purpose_head' or v_purpose is not null)
  ), given as (
    insert into public.role_assignments (church_id, user_id, role, purpose_id, unit_id)
    select v_church, v_user, w.role, w.purpose_id, w.unit_id
    from wanted w
    -- Purpose Head first: the Coordinator and Operations Lead functions need it to be there.
    where not exists (select 1 from public.role_assignments ra
                      where ra.user_id = v_user and ra.role = w.role and ra.is_active)
    order by (w.role = 'purpose_head') desc
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
