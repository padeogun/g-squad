-- =====================================================================================
-- Automated checks for the schema: church isolation, role scopes, restricted data, and the
-- business rules. Runs on a throwaway local database (see run_tests.sh). Each check records
-- PASS or FAIL in test.results; the script ends by failing if any check failed.
-- Fixture data is fictional.
-- =====================================================================================
\set ON_ERROR_STOP 1
set client_min_messages = warning;

-- ---------- test helpers -------------------------------------------------------------
create schema test;
create table test.results (n serial, name text, ok boolean, detail text);
create table test.ids (name text primary key, id uuid not null);
grant usage on schema test to authenticated, service_role, anon;
grant select, insert on test.results to authenticated, service_role, anon;
grant usage on sequence test.results_n_seq to authenticated, service_role, anon;
grant select on test.ids to authenticated, service_role, anon;

create function test.id(p text) returns uuid language sql stable as $$ select id from test.ids where name = p $$;
create function test.ok(cond boolean, name text) returns void language sql as
  $$ insert into test.results (name, ok) values (name, coalesce(cond, false)) $$;
-- Passes when the statement raises an error.
create function test.throws(stmt text, name text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    insert into test.results (name, ok, detail) values (name, true, sqlerrm);
    return;
  end;
  insert into test.results (name, ok, detail) values (name, false, 'no error raised');
end $$;
-- Passes when the statement runs without error.
create function test.lives(stmt text, name text) returns void language plpgsql as $$
begin
  execute stmt;
  insert into test.results (name, ok) values (name, true);
exception when others then
  insert into test.results (name, ok, detail) values (name, false, sqlerrm);
end $$;
grant execute on all functions in schema test to authenticated, service_role, anon;

-- Sign in as a fixture user (sets the JWT "sub" claim used by auth.uid()).
create function test.login(p text) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', coalesce(test.id(p)::text, ''), false) $$;
-- (Some checks switch user inside a block that already runs as authenticated.)
grant execute on function test.login(text) to authenticated;

-- ---------- fixture (as the database owner: triggers treat this as a system change) ----
do $$
declare
  a uuid := (select id from public.churches where slug = 'tec-manchester');
  b uuid;
begin
  insert into test.ids values ('churchA', a);
  insert into public.churches (name, slug) values ('Other Church', 'other-church') returning id into b;
  insert into public.church_settings (church_id) values (b) on conflict do nothing;   -- created automatically since migration 12
  insert into test.ids values ('churchB', b);
end $$;

do $$
declare
  a uuid := test.id('churchA');
  b uuid := test.id('churchB');
  u text;
  v uuid;
begin
  -- Leader accounts.
  foreach u in array array['rp','ops','coord','teci','ul_a','ul_b','ph','editor','pastoral','finance','b_ops'] loop
    v := gen_random_uuid();
    insert into auth.users (id, email) values (v, u || '@example.org');
    insert into public.app_users (id, church_id, display_name)
    values (v, case when u = 'b_ops' then b else a end, initcap(u));
    insert into test.ids values (u, v);
  end loop;

  -- Purposes and units.
  insert into public.purposes (church_id, name) values (a, 'Purpose One') returning id into v;  insert into test.ids values ('P1', v);
  insert into public.purposes (church_id, name) values (a, 'Purpose Two') returning id into v;  insert into test.ids values ('P2', v);
  insert into public.units (church_id, purpose_id, name, regular_monthly_need) values (a, test.id('P1'), 'Production', 0) returning id into v; insert into test.ids values ('A1', v);
  insert into public.units (church_id, purpose_id, name, regular_monthly_need) values (a, test.id('P2'), 'Ushering', 0)   returning id into v; insert into test.ids values ('A2', v);
  insert into public.units (church_id, purpose_id, name) values (a, test.id('P2'), 'Hospitality') returning id into v; insert into test.ids values ('A3', v);
  insert into public.purposes (church_id, name) values (b, 'B Purpose') returning id into v; insert into test.ids values ('PB', v);
  insert into public.units (church_id, purpose_id, name) values (b, test.id('PB'), 'B Unit') returning id into v; insert into test.ids values ('B1', v);

end $$;

-- Roles.
insert into public.role_assignments (church_id, user_id, role, purpose_id, unit_id)
select test.id('churchA'), test.id(x.u), x.r::public.app_role, x.p, x.un
from (values
  ('rp','resident_pastor', null::uuid, null::uuid),
  ('ops','operations_lead', null, null),
  ('coord','gsquad_coordinator', null, null),
  ('teci','teci_coordinator', null, null),
  ('ul_a','unit_lead', null, test.id('A1')),
  ('ul_b','unit_lead', null, test.id('A2')),
  ('ph','purpose_head', test.id('P1'), null),
  ('editor','newsletter_editor', null, null),
  ('pastoral','pastoral_lead', null, null),
  ('finance','finance', null, null)
) as x(u, r, p, un)
on conflict do nothing;
insert into public.role_assignments (church_id, user_id, role)
values (test.id('churchB'), test.id('b_ops'), 'operations_lead') on conflict do nothing;

-- People: p1 in A1, p2 in A2, p3 in A1 and A2. Fictional names and example.org emails.
do $$
declare a uuid := test.id('churchA'); v uuid;
begin
  insert into public.people (church_id, first_name, surname, email, birth_day, birth_month, celebration_opt_in, date_joined)
  values (a, 'Ada', 'Test', 'ada@example.org', 12, extract(month from current_date + interval '1 month')::int, true, current_date - 400) returning id into v;
  insert into test.ids values ('p1', v);
  insert into public.people (church_id, first_name, surname, email, birth_day, birth_month, celebration_opt_in, date_joined)
  values (a, 'Ben', 'Sample', 'ben@example.org', 3, extract(month from current_date + interval '1 month')::int, false, current_date - 400) returning id into v;
  insert into test.ids values ('p2', v);
  insert into public.people (church_id, first_name, surname, email, date_joined)
  values (a, 'Cy', 'Example', 'cy@example.org', current_date - 400) returning id into v;
  insert into test.ids values ('p3', v);
  insert into public.people (church_id, first_name, surname)
  values (test.id('churchB'), 'Bea', 'Elsewhere') returning id into v;
  insert into test.ids values ('pB', v);

  insert into public.unit_memberships (church_id, person_id, unit_id) values
    (a, test.id('p1'), test.id('A1')), (a, test.id('p2'), test.id('A2')),
    (a, test.id('p3'), test.id('A1')), (a, test.id('p3'), test.id('A2'));
  insert into public.unit_memberships (church_id, person_id, unit_id)
  values (test.id('churchB'), test.id('pB'), test.id('B1'));

  insert into public.person_faith (person_id, church_id, water_baptism, water_baptism_date)
  values (test.id('p1'), a, true, date_trunc('month', current_date)::date + 2);
end $$;

-- A month-long Sunday rota project three months ahead, already approved (system change).
insert into public.projects (church_id, level, name, starts_at, ends_at, status, is_sunday_service, owner_user_id)
values (test.id('churchA'), 'church', 'Sunday rota',
        date_trunc('month', current_date) + interval '3 months',
        date_trunc('month', current_date) + interval '4 months' - interval '1 second',
        'approved', true, test.id('ops'));
insert into test.ids select 'rota', id from public.projects where name = 'Sunday rota';

-- =====================================================================================
-- 1. Church isolation and anonymous access
-- =====================================================================================
select test.login('b_ops');
set role authenticated;
select test.ok((select count(*) from public.people) = 1, 'Other church sees only its own person');
select test.ok((select count(*) from public.units) = 1, 'Other church sees only its own unit');
select test.ok((select count(*) from public.projects) = 0, 'Other church sees no TEC projects');
select test.throws(format('insert into public.people (church_id, first_name, surname, created_by) values (%L, %L, %L, %L)',
                          test.id('churchA'), 'X', 'Y', test.id('b_ops')),
                   'Other church cannot insert a person into TEC');
select test.throws(format('insert into public.unit_memberships (person_id, unit_id) values (%L, %L)', test.id('pB'), test.id('A1')),
                   'Composite foreign key stops linking a person to another church''s unit');
reset role;

select test.login('');
set role anon;
select test.throws('select count(*) from public.people', 'Anonymous visitor cannot read people');
select test.throws('select count(*) from public.projects', 'Anonymous visitor cannot read projects');
reset role;

-- =====================================================================================
-- 2. Who sees which people
-- =====================================================================================
select test.login('ul_a'); set role authenticated;
select test.ok((select count(*) from public.people) = 2, 'Unit Lead sees only own unit members (p1, p3)');
select test.ok(not exists (select 1 from public.people where id = test.id('p2')), 'Unit Lead cannot see another unit''s member');
reset role;

select test.login('ph'); set role authenticated;
select test.ok((select count(*) from public.people) = 2, 'Purpose Head sees people in units of their purpose');
reset role;

select test.login('editor'); set role authenticated;
select test.ok((select count(*) from public.people) = 0, 'Newsletter editor sees no contact details');
reset role;

select test.login('ops'); set role authenticated;
select test.ok((select count(*) from public.people) = 3, 'Operations Lead sees every TEC member');
reset role;

-- =====================================================================================
-- 3. Faith fields
-- =====================================================================================
select test.login('ul_a'); set role authenticated;
select test.ok((select water_baptism from public.get_person_faith(test.id('p1'))), 'Unit Lead reads faith fields of own member');
select test.throws(format('select * from public.get_person_faith(%L)', test.id('p2')), 'Unit Lead cannot read faith fields outside own unit');
reset role;

select test.login('ops'); set role authenticated;
select test.throws(format('select * from public.get_person_faith(%L)', test.id('p1')), 'Operations Lead cannot read faith fields');
select test.throws(format('select public.set_person_faith(%L, null, true, null, false, null, false, null)', test.id('p2')),
                   'Operations Lead cannot write faith fields');
reset role;

select test.login('rp'); set role authenticated;
select test.throws('select count(*) from public.person_faith', 'No one reads the faith table directly');
reset role;

-- Decision of 23 Oct 2026 (migration 16): faith fields are recorded by the G-Squad Coordinator
-- and the person's Team Lead only; the TECi Coordinator and Resident Pastor read them.
select test.login('teci'); set role authenticated;
select test.throws(format('select public.set_person_faith(%L, null, true, null, false, null, false, null)', test.id('p2')),
                   'M16: TECi Coordinator cannot record faith fields');
reset role;
select test.login('coord'); set role authenticated;
select test.lives(format('select public.set_person_faith(%L, %L, false, null, true, %L, false, null)',
                         test.id('p2'), current_date - 30, date_trunc('month', current_date)::date + 1),
                  'G-Squad Coordinator records faith fields');
reset role;

select test.ok(exists (select 1 from public.audit_log where action = 'view_faith' and record_id = test.id('p1')),
               'Every faith-field read is in the audit log');

select test.login('editor'); set role authenticated;
select test.ok((select water_baptisms from public.baptism_counts(current_date)) = 1, 'Editors get baptism counts, never names');
reset role;

-- =====================================================================================
-- 4. Pastoral notes and one-to-ones
-- =====================================================================================
select test.login('pastoral'); set role authenticated;
select test.lives(format('insert into public.pastoral_notes (person_id, note) values (%L, %L)', test.id('p1'), 'Check-in held.'),
                  'Pastoral lead writes a note');
select test.ok((select count(*) from public.get_pastoral_notes(test.id('p1'))) = 1, 'Pastoral lead reads notes through the logged function');
select test.throws('select count(*) from public.pastoral_notes', 'Pastoral notes cannot be read directly');
reset role;

select test.login('ul_a'); set role authenticated;
select test.throws(format('select * from public.get_pastoral_notes(%L)', test.id('p1')), 'Unit Lead cannot read pastoral notes');
select test.lives(format('insert into public.one_to_ones (person_id, unit_id, quarter_start, held_on, feeling) values (%L, %L, %L, %L, %L)',
                         test.id('p1'), test.id('A1'), date_trunc('quarter', current_date)::date, current_date, 'doing_well'),
                  'Unit Lead records a one-to-one for own member');
select test.throws(format('insert into public.one_to_ones (person_id, unit_id, quarter_start, held_on, feeling) values (%L, %L, %L, %L, %L)',
                          test.id('p2'), test.id('A1'), date_trunc('quarter', current_date)::date, current_date, 'doing_well'),
                   'Unit Lead cannot record a one-to-one for someone outside the unit');
reset role;

select test.login('coord'); set role authenticated;
select test.ok((select count(*) from public.one_to_ones) = 1, 'G-Squad Coordinator reads one-to-ones');
reset role;
select test.login('ph'); set role authenticated;
select test.ok((select count(*) from public.one_to_ones) = 1, 'Purpose Head reads one-to-ones for their units');
reset role;
select test.login('ops'); set role authenticated;
select test.ok((select count(*) from public.one_to_ones) = 0, 'Operations Lead cannot read one-to-ones');
reset role;
select test.login('ul_b'); set role authenticated;
select test.ok((select count(*) from public.one_to_ones) = 0, 'Another Unit Lead cannot read them');
reset role;

-- =====================================================================================
-- 5. Assignments: R1 / R2 limit with override, R10 holidays, own-unit rule
-- =====================================================================================
select test.login('ul_a'); set role authenticated;
do $$
declare d date := (date_trunc('month', current_date) + interval '3 months')::date; s date;
begin
  s := d + ((7 - extract(isodow from d)::int) % 7);   -- first Sunday of that month
  perform test.lives(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values (%L,%L,%L,%L)',
                            test.id('rota'), test.id('p1'), test.id('A1'), s), 'Slot 1 of 3');
  perform test.lives(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values (%L,%L,%L,%L)',
                            test.id('rota'), test.id('p1'), test.id('A1'), s + 7), 'Slot 2 of 3');
  perform test.lives(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values (%L,%L,%L,%L)',
                            test.id('rota'), test.id('p1'), test.id('A1'), s + 14), 'Slot 3 of 3');
  perform test.throws(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values (%L,%L,%L,%L)',
                             test.id('rota'), test.id('p1'), test.id('A1'), s + 21), 'R2: a fourth slot is refused for a Unit Lead');
  perform test.throws(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values (%L,%L,%L,%L)',
                             test.id('rota'), test.id('p2'), test.id('A1'), s), 'Unit Lead cannot assign someone outside the unit');
end $$;
reset role;

select test.login('ops'); set role authenticated;
do $$
declare d date := (date_trunc('month', current_date) + interval '3 months')::date; s date;
begin
  s := d + ((7 - extract(isodow from d)::int) % 7);
  perform test.throws(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values (%L,%L,%L,%L)',
                             test.id('rota'), test.id('p1'), test.id('A1'), s + 21), 'R2: Ops Lead needs a written reason to override');
  perform test.lives(format('insert into public.assignments (project_id, person_id, unit_id, serve_date, override_reason) values (%L,%L,%L,%L,%L)',
                            test.id('rota'), test.id('p1'), test.id('A1'), s + 21, 'Covering a sudden absence'), 'R2: Ops Lead override with reason');
  -- R10 holiday. Holidays are recorded by the Team Lead (migration 16: the Operations Lead no
  -- longer edits member records), so switch to p3's Unit Lead for this one insert.
  perform test.login('ul_a');
  perform test.lives(format('insert into public.holidays (person_id, starts_on, ends_on) values (%L,%L,%L)', test.id('p3'), s, s + 1),
                     'Holiday recorded');
  perform test.login('ops');
  perform test.throws(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values (%L,%L,%L,%L)',
                             test.id('rota'), test.id('p3'), test.id('A1'), s), 'R10: no slot while on holiday');
end $$;
reset role;
select test.ok(exists (select 1 from public.audit_log where action = 'override_limit'), 'R2: override is logged');

-- Personal limit from available hours: 6 hours at 3 hours a slot = 2.
-- (A fixture change as the database owner: sign out first so the guards treat it as system.)
select test.login('nobody');
update public.people set available_hours_month = 6 where id = test.id('p2');
select test.ok(app.personal_limit(test.id('p2')) = 2, 'R10: available hours lower the personal limit');

-- =====================================================================================
-- 6. R3: a third unit needs the Resident Pastor
-- =====================================================================================
select test.login('ops'); set role authenticated;
insert into public.unit_memberships (person_id, unit_id) values (test.id('p3'), test.id('A3'));
select test.ok((select status from public.unit_memberships where person_id = test.id('p3') and unit_id = test.id('A3')) = 'pending_approval',
               'R3: third unit starts pending approval');
select test.throws(format('update public.unit_memberships set status = %L where person_id = %L and unit_id = %L',
                          'active', test.id('p3'), test.id('A3')), 'R3: Ops Lead cannot approve the third unit');
reset role;
select test.login('rp'); set role authenticated;
update public.unit_memberships set status = 'active' where person_id = test.id('p3') and unit_id = test.id('A3');
select test.ok((select status from public.unit_memberships where person_id = test.id('p3') and unit_id = test.id('A3')) = 'active',
               'R3: Resident Pastor approves the third unit');
reset role;

-- =====================================================================================
-- 7. Projects: approval rules R6, R9, R14, R15, R16
-- =====================================================================================
select test.login('ul_a'); set role authenticated;
insert into public.projects (level, unit_id, name, starts_at, ends_at, status)
values ('unit', test.id('A1'), 'Production training', now() + interval '70 days', now() + interval '70 days 3 hours', 'approved');
select test.ok((select status from public.projects where name = 'Production training') = 'draft', 'A new project is always a draft');
update public.projects set status = 'submitted' where name = 'Production training';
select test.throws($q$update public.projects set status = 'approved' where name = 'Production training'$q$,
                   'Unit Lead cannot approve their own project');
reset role;
-- Demand far beyond capacity (R6).
insert into public.team_demand (church_id, project_id, unit_id, on_date, slots_needed)
select church_id, id, test.id('A1'), (now() + interval '70 days')::date, 50 from public.projects where name = 'Production training';
select test.login('ph'); set role authenticated;
select test.throws($q$update public.projects set status = 'approved' where name = 'Production training'$q$,
                   'R6: shortfall blocks approval without an action');
update public.projects set status = 'approved', shortfall_action = 'recruit' where name = 'Production training';
select test.ok((select status from public.projects where name = 'Production training') = 'approved',
               'R6: Purpose Head approves once an action is recorded');
select test.ok((select approved_by from public.projects where name = 'Production training') = test.id('ph'), 'Approver recorded automatically');
reset role;

-- An event with the High-level Event Planning form.
select test.login('ops'); set role authenticated;
insert into public.projects (level, name, starts_at, ends_at)
values ('church', 'Harvest outreach', now() + interval '70 days', now() + interval '70 days 4 hours');
insert into public.event_plans (project_id, size, complexity)
select id, 'large', 'high' from public.projects where name = 'Harvest outreach';
select test.throws($q$update public.projects set status = 'submitted' where name = 'Harvest outreach'$q$,
                   'R15: High complexity needs a planning committee');
update public.event_plans set has_planning_committee = true where project_id = (select id from public.projects where name = 'Harvest outreach');
update public.projects set status = 'submitted' where name = 'Harvest outreach';
select test.throws($q$update public.event_plans set budget_status = 'approved' where project_id = (select id from public.projects where name = 'Harvest outreach')$q$,
                   'R16: the event owner cannot approve their own budget');
reset role;
select test.login('rp'); set role authenticated;
select test.throws($q$update public.projects set status = 'approved' where name = 'Harvest outreach'$q$,
                   'R16: approval waits for the budget');
reset role;
select test.login('finance'); set role authenticated;
update public.event_plans set budget_status = 'approved' where project_id = (select id from public.projects where name = 'Harvest outreach');
select test.ok((select budget_decided_by from public.event_plans e join public.projects p on p.id = e.project_id where p.name = 'Harvest outreach') = test.id('finance'),
               'R16: Finance approves the budget, recorded automatically');
select test.throws($q$update public.event_plans set main_attraction = 'x' where project_id = (select id from public.projects where name = 'Harvest outreach')$q$,
                   'Finance can only change the budget');
reset role;
-- R14: move the event to 20 days away; a Large event needs 8 weeks.
select test.login('ops'); set role authenticated;
update public.projects set starts_at = now() + interval '20 days', ends_at = now() + interval '20 days 4 hours' where name = 'Harvest outreach';
reset role;
select test.login('rp'); set role authenticated;
select test.throws($q$update public.projects set status = 'approved' where name = 'Harvest outreach'$q$,
                   'R14: a Large event needs 8 weeks lead time');
reset role;
select test.login('ops'); set role authenticated;
update public.projects set starts_at = now() + interval '70 days', ends_at = now() + interval '70 days 4 hours' where name = 'Harvest outreach';
reset role;
select test.login('rp'); set role authenticated;
select test.lives($q$update public.projects set status = 'approved' where name = 'Harvest outreach'$q$, 'Resident Pastor approves the rescheduled event');
reset role;

-- R9 inputs and the review.
select test.login('ops'); set role authenticated;
insert into public.project_inputs (project_id, title, requested_from_user_id, unit_id, due_on)
select id, 'Volunteer plan', test.id('ul_a'), test.id('A1'), current_date - 1 from public.projects where name = 'Harvest outreach';
select test.ok((select display_status from public.v_project_inputs where title = 'Volunteer plan') = 'overdue', 'R9: overdue the day after the due date');
update public.projects set status = 'in_progress' where name = 'Harvest outreach';
select test.throws($q$update public.projects set status = 'done' where name = 'Harvest outreach'$q$, 'R9: cannot close with a required input outstanding');
reset role;
select test.login('ul_a'); set role authenticated;
select test.throws($q$update public.project_inputs set title = 'Changed' where title = 'Volunteer plan'$q$,
                   'The person asked cannot change the request itself');
update public.project_inputs set body = '6 volunteers confirmed', status = 'received' where title = 'Volunteer plan';
reset role;
select test.login('ops'); set role authenticated;
select test.throws($q$update public.projects set status = 'done' where name = 'Harvest outreach'$q$, 'Event cannot close before its review');
update public.event_plans set review_completed_at = now() where project_id = (select id from public.projects where name = 'Harvest outreach');
select test.lives($q$update public.projects set status = 'done' where name = 'Harvest outreach'$q$, 'Event closes once inputs and review are done');
reset role;

-- =====================================================================================
-- 8. R11: Sunday Service Grid
-- =====================================================================================
select test.login('ops'); set role authenticated;
do $$
declare d date := (date_trunc('month', current_date) + interval '3 months')::date; s date;
begin
  s := d + ((7 - extract(isodow from d)::int) % 7);
  insert into public.service_grids (project_id, service_date, theme) values (test.id('rota'), s, 'Relevance');
end $$;
insert into public.service_segments (grid_id, position, title, starts_at, duration_minutes, led_by_unit_id)
select id, 1, 'Pre-service prayer', '10:00', 25, test.id('A1') from public.service_grids;
update public.service_grids set status = 'finalised';
select test.throws($q$update public.service_grids set status = 'approved'$q$, 'R11: Ops Lead cannot approve the grid');
reset role;
select test.login('rp'); set role authenticated;
update public.service_grids set status = 'approved';
select test.ok((select status from public.service_grids) = 'approved', 'R11: Resident Pastor approves the grid');
reset role;
select test.login('ops'); set role authenticated;
insert into public.service_segments (grid_id, position, title, starts_at, duration_minutes, led_by_text)
select id, 2, 'Welcome', '10:27', 10, 'Guest host' from public.service_grids;
select test.ok((select version from public.service_grids) = 2 and (select status from public.service_grids) = 'finalised',
               'R11: a later change raises the version and needs re-approval');
select test.ok((select ends_at from public.v_service_segments where position = 1) = '10:25'::time, 'End time worked out from start and duration');
reset role;

-- =====================================================================================
-- 9. Newsletter: R17 approval order, R18 named items, counts only
-- =====================================================================================
select test.login('editor'); set role authenticated;
select test.throws($q$insert into public.projects (level, name, starts_at, ends_at) values ('church', 'x', now(), now())$q$,
                   'Editors cannot create projects');
reset role;
select test.login('ops'); set role authenticated;
insert into public.projects (level, name, starts_at, ends_at)
values ('church', 'The Greatness Brief', date_trunc('month', now()) + interval '1 month', date_trunc('month', now()) + interval '2 months' - interval '1 second');
reset role;
select test.login('editor'); set role authenticated;
insert into public.newsletter_issues (project_id, issue_month, headline, status)
select id, (date_trunc('month', now()) + interval '1 month')::date, 'Your finance and the Ministry', 'approved'
from public.projects where name = 'The Greatness Brief';
select test.ok((select status from public.newsletter_issues) = 'draft', 'A new issue is always a draft');
insert into public.newsletter_items (issue_id, kind, body, names_a_person)
select id, 'win', 'We welcomed twins to a family in the church.', true from public.newsletter_issues;
select test.throws($q$update public.newsletter_issues set status = 'awaiting_coordinator'$q$, 'R18: a named item needs agreement first');
update public.newsletter_items set agreement_ticked = true;
update public.newsletter_issues set status = 'awaiting_coordinator';
select test.throws($q$update public.newsletter_issues set status = 'awaiting_pastor'$q$, 'R17: editors cannot approve');
reset role;
select test.login('rp'); set role authenticated;
select test.throws($q$update public.newsletter_issues set status = 'approved'$q$, 'R17: the Resident Pastor cannot approve before the Coordinator');
reset role;
select test.login('coord'); set role authenticated;
update public.newsletter_issues set status = 'awaiting_pastor';
reset role;
select test.login('rp'); set role authenticated;
update public.newsletter_issues set status = 'approved';
select test.ok((select status from public.newsletter_issues) = 'approved', 'R17: Coordinator then Resident Pastor approve');
reset role;
select test.login('editor'); set role authenticated;
update public.newsletter_issues set headline = 'A new headline';
select test.ok((select status from public.newsletter_issues) = 'awaiting_coordinator' and
               (select pastor_approved_by from public.newsletter_issues) is null,
               'R17: an edit after approval restarts approval');
select test.throws($q$update public.newsletter_issues set status = 'sent'$q$, 'Only the email job sends');
select test.ok((select count(*) from public.newsletter_celebrations((date_trunc('month', now()) + interval '1 month')::date)
                where kind = 'birthday') = 1, 'R18: only opted-in birthdays appear');
select test.ok(public.newsletter_recipient_count() = 3, 'Editors see a recipient count only');
select test.throws('select count(*) from public.newsletter_rsvps', 'Editors cannot read who RSVPed');
select test.throws($q$select public.redeem_email_link('x')$q$, 'Signed-in users cannot redeem email links');
reset role;

-- Email links, as the Edge Function (service role).
insert into public.email_link_tokens (token_hash, church_id, person_id, issue_id, purpose, target_project, expires_at)
select sha256(convert_to('valid-token-0123456789abcdef0123456789', 'UTF8')), test.id('churchA'), test.id('p1'), i.id, 'rsvp', test.id('rota'), now() + interval '30 days'
from public.newsletter_issues i;
insert into public.email_link_tokens (token_hash, church_id, person_id, issue_id, purpose, expires_at)
select sha256(convert_to('expired-token-0123456789abcdef012345678', 'UTF8')), test.id('churchA'), test.id('p1'), i.id, 'unsubscribe', now() - interval '1 day'
from public.newsletter_issues i;
select test.login(''); set role service_role;
select test.ok(public.redeem_email_link('valid-token-0123456789abcdef0123456789') = 'rsvp', 'A valid RSVP link records the RSVP');
select test.ok(public.redeem_email_link('expired-token-0123456789abcdef012345678') = 'invalid', 'An expired link does nothing');
select test.ok(public.redeem_email_link('made-up-token-0123456789abcdef01234567') = 'invalid', 'An unknown link does nothing');
reset role;
select test.ok((select newsletter_subscribed from public.people where id = test.id('p1')), 'Expired unsubscribe link left the subscription alone');

-- =====================================================================================
-- 10. Admin, audit, people's rights
-- =====================================================================================
select test.login('ul_a'); set role authenticated;
select test.throws(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('ul_a'), 'operations_lead'),
                   'A Unit Lead cannot give themselves a role');
update public.church_settings set serving_limit_per_month = 9;
select test.ok((select count(*) from public.audit_log) = 0, 'A Unit Lead cannot read the audit log');
select test.throws(format('update public.people set teci_stage_id = (select id from public.teci_stages where stage_no = 2) where id = %L', test.id('p1')),
                   'Only the TECi Coordinator sets a TECi stage');
reset role;
select test.ok((select serving_limit_per_month from public.church_settings where church_id = test.id('churchA')) = 3,
               'A Unit Lead cannot change church settings');

select test.login('teci'); set role authenticated;
select test.lives(format('update public.people set teci_stage_id = (select id from public.teci_stages where stage_no = 2) where id = %L', test.id('p1')),
                  'TECi Coordinator sets a TECi stage');
select test.throws(format('update public.people set surname = %L where id = %L', 'Changed', test.id('p1')),
                   'TECi Coordinator cannot edit other member details');
reset role;

select test.login('ops'); set role authenticated;
select test.ok((select count(*) from public.audit_log) > 0, 'Operations Lead reads the audit log');
select test.throws('delete from public.audit_log', 'No one can delete audit entries');
select test.ok(public.export_person(test.id('p1')) -> 'faith' = 'null'::jsonb, 'Export by the Ops Lead leaves faith fields out');
select test.lives(format('select public.anonymise_person(%L)', test.id('p2')), 'Ops Lead anonymises on request');
reset role;
select test.ok((select first_name = 'Former' and email is null and anonymised_at is not null from public.people where id = test.id('p2')),
               'Anonymised record keeps no personal details');
select test.ok(not exists (select 1 from public.person_faith where person_id = test.id('p2')), 'Anonymising removes faith fields');

select test.login('rp'); set role authenticated;
select test.ok(public.export_person(test.id('p1')) -> 'faith' <> 'null'::jsonb, 'Export by the Resident Pastor includes faith fields');
select test.ok((select count(*) from public.capacity_calendar(extract(year from current_date)::int)) = 36, 'Capacity calendar: 3 units x 12 months');
select test.ok((select count(*) from public.v_engagement) = 3, 'Engagement view works under RLS');
reset role;

select test.ok(app.raise_automatic_flags() >= 0, 'Nightly flag job runs');
select test.ok(app.anonymise_expired_people() >= 0, 'Nightly anonymisation job runs');

-- =====================================================================================
-- 11. Security review fixes (23 Oct 2026). Fnn refers to SECURITY_LOG.md.
-- =====================================================================================

-- F01: role assignments.
select test.login('ops'); set role authenticated;
select test.throws(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('ops'), 'resident_pastor'),
                   'F01: Ops Lead cannot grant themselves Resident Pastor');
select test.throws(format('insert into public.role_assignments (user_id, role, unit_id) values (%L, %L, %L)', test.id('ops'), 'unit_lead', test.id('A2')),
                   'F01: Ops Lead cannot give themselves a Unit Lead role');
select test.throws(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('editor'), 'gsquad_coordinator'),
                   'F01: Ops Lead cannot grant a faith-reading role to someone else');
select test.throws(format('update public.role_assignments set role = %L where user_id = %L', 'resident_pastor', test.id('finance')),
                   'F01: Ops Lead cannot turn an existing role into Resident Pastor');
select test.lives(format('insert into public.role_assignments (user_id, role, unit_id) values (%L, %L, %L)', test.id('finance'), 'unit_lead', test.id('A3')),
                  'F01: Ops Lead still assigns Unit Leads to other people');
reset role;
select test.login('rp'); set role authenticated;
select test.lives(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('editor'), 'teci_coordinator'),
                  'F01: Resident Pastor grants a faith-reading role');
select test.lives(format('update public.role_assignments set is_active = false where user_id = %L and role = %L', test.id('editor'), 'teci_coordinator'),
                  'F01: Resident Pastor removes it again');
select test.throws(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('rp'), 'pastoral_lead'),
                   'F01: Resident Pastor cannot change their own roles either');
reset role;

-- F02: only the Resident Pastor lets Purpose Heads read pastoral notes.
select test.login('ops'); set role authenticated;
select test.throws('update public.church_settings set purpose_heads_read_pastoral = true',
                   'F02: Ops Lead cannot let Purpose Heads read pastoral notes');
reset role;
select test.login('rp'); set role authenticated;
select test.lives('update public.church_settings set purpose_heads_read_pastoral = true', 'F02: Resident Pastor can change that setting');
select test.throws('update public.church_settings set serving_limit_per_month = 5', 'F02: Resident Pastor cannot change the other settings');
select test.lives('update public.church_settings set purpose_heads_read_pastoral = false', 'F02: Resident Pastor switches it off again');
reset role;

-- F03: the logged reads must run in a read-write transaction on PostgREST.
select test.ok((select bool_and(provolatile = 'v') from pg_proc
                where oid in ('public.get_person_faith(uuid)'::regprocedure, 'public.get_pastoral_notes(uuid)'::regprocedure)),
               'F03: logged faith and pastoral reads are VOLATILE');

-- F04: audit log never names changed faith columns, and the Ops Lead cannot see faith audit rows.
select test.login('coord'); set role authenticated;
select public.set_person_faith(test.id('p1'), current_date - 400, true, date_trunc('month', current_date)::date + 2, true, current_date - 10, false, null);
reset role;
select test.ok((select detail from public.audit_log where table_name = 'person_faith' and action = 'update' order by id desc limit 1) = '{}'::jsonb,
               'F04: a faith-field change is logged without column names');
select test.login('ops'); set role authenticated;
select test.ok((select count(*) from public.audit_log where table_name in ('person_faith', 'pastoral_notes') or action in ('view_faith', 'view_pastoral')) = 0,
               'F04: Ops Lead cannot see faith or pastoral audit entries');
reset role;
select test.login('rp'); set role authenticated;
select test.ok((select count(*) from public.audit_log where action = 'view_faith') > 0, 'F04: Resident Pastor sees faith audit entries');
reset role;

-- F05: a Unit Lead cannot pull an arbitrary person into their unit.
select test.login('ul_b'); set role authenticated;
select test.throws(format('insert into public.unit_memberships (person_id, unit_id) values (%L, %L)', test.id('p1'), test.id('A2')),
                   'F05: Unit Lead cannot add someone else''s member to their unit');
reset role;
select test.login('ul_a'); set role authenticated;
insert into public.people (first_name, surname) values ('Dee', 'Newcomer');
select test.lives(format('insert into public.unit_memberships (person_id, unit_id) select id, %L from public.people where first_name = %L',
                         test.id('A1'), 'Dee'), 'F05: Unit Lead adds a person they entered');
reset role;

-- F06 / F10: R18 re-checked at every approval step; approval stamps cannot be pre-filled.
select test.login('editor'); set role authenticated;
insert into public.newsletter_items (issue_id, kind, body, names_a_person)
select id, 'win', 'A late named item.', true from public.newsletter_issues;
reset role;
select test.login('coord'); set role authenticated;
select test.throws($q$update public.newsletter_issues set status = 'awaiting_pastor'$q$,
                   'F06: an unagreed named item added after submission blocks approval');
reset role;
select test.login('editor'); set role authenticated;
delete from public.newsletter_items where body = 'A late named item.';
reset role;
select test.login('coord'); set role authenticated;
update public.newsletter_issues set status = 'awaiting_pastor', pastor_approved_by = test.id('coord');
select test.ok((select pastor_approved_by from public.newsletter_issues) is null, 'F10: Coordinator cannot pre-fill the pastor''s approval');
reset role;

-- F07: a membership pending the Resident Pastor's approval does not open faith fields.
select test.login('');   -- fixture set-up below is a system change
do $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (v, 'ul_c@example.org');
  insert into public.app_users (id, church_id, display_name) values (v, test.id('churchA'), 'Ul_c');
  insert into test.ids values ('ul_c', v);
  insert into public.role_assignments (church_id, user_id, role, unit_id) values (test.id('churchA'), v, 'unit_lead', test.id('A3'));
  insert into public.unit_memberships (church_id, person_id, unit_id, status)
  values (test.id('churchA'), test.id('p1'), test.id('A3'), 'pending_approval');
end $$;
select test.login('ul_c'); set role authenticated;
select test.throws(format('select * from public.get_person_faith(%L)', test.id('p1')),
                   'F07: Unit Lead of a pending membership cannot read faith fields');
select test.lives(format('select * from public.get_person_faith(%L)', test.id('p3')),
                  'F07: Unit Lead of an active membership still can');
reset role;

-- F08: anonymous callers are never treated as system changes.
create function test.sys() returns boolean language sql security definer as $$ select app.is_system() $$;
grant execute on function test.sys() to anon, authenticated, service_role;
select test.login(''); set role anon;
select test.ok(not test.sys(), 'F08: an anonymous caller is not a system change');
reset role;
set role service_role;
select test.ok(test.sys(), 'F08: the service role is a system change');
reset role;

-- F09: the anonymising marker cannot be used for ordinary edits.
select test.login('ul_a'); set role authenticated;
select set_config('gsquad.anonymising', 'on', false);
select test.throws(format('update public.people set surname = %L where id = %L', 'Changed', test.id('p1')),
                   'F09: the anonymising marker only allows anonymising');
select set_config('gsquad.anonymising', 'off', false);
reset role;

-- F10: approval records cannot be forged.
select test.login('ops'); set role authenticated;
update public.projects set status = 'in_progress', approved_by = test.id('ops') where id = test.id('rota');
select test.ok((select approved_by from public.projects where id = test.id('rota')) is null,
               'F10: moving a project on keeps the original approval record');
update public.service_grids set approved_by = test.id('ops'), approved_at = now();
select test.ok((select approved_by from public.service_grids) is null, 'F10: Ops Lead cannot write a grid approver');
reset role;

-- F11: R16, "not needed" with a budget estimate is a budget decision.
select test.login('ops'); set role authenticated;
insert into public.projects (level, name, starts_at, ends_at)
values ('church', 'Budget check', now() + interval '90 days', now() + interval '90 days 2 hours');
select test.throws($q$insert into public.event_plans (project_id, size, complexity, budget_estimate_gbp, budget_status)
                      select id, 'small', 'low', 500, 'not_needed' from public.projects where name = 'Budget check'$q$,
                   'F11: owner cannot mark a costed budget as not needed');
reset role;

-- F12: export log scope is a code, never free text.
select test.login('ops'); set role authenticated;
select test.throws($q$select public.log_export('Export of Ada Test''s record', 1)$q$, 'F12: free-text export scope is refused');
select test.lives($q$select public.log_export('people_unit', 5)$q$, 'F12: a short export code is logged');
reset role;

-- F13: the email-link redeemer refuses any signed-in identity, whatever the grants.
select test.login('ops');
select test.throws($q$select public.redeem_email_link('valid-token-0123456789abcdef0123456789')$q$,
                   'F13: redeem_email_link refuses a signed-in caller even with EXECUTE');
select test.login('');
set role service_role;
select test.ok(public.redeem_email_link('bad token with spaces 0123456789abcdef') = 'invalid', 'F13: malformed tokens are rejected');
reset role;

-- F15: event plan actions are added by the project's manager only.
select test.login('editor'); set role authenticated;
select test.throws(format($q$insert into public.event_plan_actions (project_id, section_no, description, owner_user_id)
                             select id, 1, 'x', %L from public.projects where name = 'Harvest outreach'$q$, test.id('editor')),
                   'F15: anyone else cannot add action points to a project');
reset role;
select test.login('ops'); set role authenticated;
select test.lives($q$insert into public.event_plan_actions (project_id, section_no, description)
                    select id, 1, 'Book venue' from public.projects where name = 'Harvest outreach'$q$,
                  'F15: the project manager adds action points');
reset role;

-- F16: a one-to-one cannot move to another unit.
select test.login('');
insert into public.role_assignments (church_id, user_id, role, unit_id) values (test.id('churchA'), test.id('ul_a'), 'unit_lead', test.id('A3'));
select test.login('ul_a'); set role authenticated;
select test.throws(format('update public.one_to_ones set unit_id = %L', test.id('A3')), 'F16: a one-to-one cannot move to another unit');
reset role;

-- F17: input bounds (as the G-Squad Coordinator, who may edit member records).
select test.login('coord'); set role authenticated;
select test.throws(format('update public.people set preferred_times = array_fill(%L::text, array[11]) where id = %L', 'Sunday', test.id('p1')),
                   'F17: preferred_times is bounded');
reset role;
-- Project inputs and service segments are the Operations Lead's to edit.
select test.login('ops'); set role authenticated;
select test.throws($q$update public.project_inputs set link_url = 'https://example.org/a b' where title = 'Volunteer plan'$q$,
                   'F17: link URLs cannot contain spaces');
select test.throws($q$update public.service_segments set sub_points = array_fill('x'::text, array[21])$q$,
                   'F17: sub_points is bounded');
reset role;

-- F18: functions created by later migrations are not executable by anon or PUBLIC by default.
create function public.zz_probe() returns integer language sql as 'select 1';
select test.ok(not has_function_privilege('anon', 'public.zz_probe()', 'execute'), 'F18: a new public function is not open to anon');
drop function public.zz_probe();

-- F14: export holds everything; anonymising wipes free-text override reasons.
select test.login('rp'); set role authenticated;
select test.ok(public.export_person(test.id('p1')) ? 'checkin_flags', 'F14: subject access export includes check-in flags');
reset role;
select test.login('ops'); set role authenticated;
select public.anonymise_person(test.id('p1'));
reset role;
select test.ok(not exists (select 1 from public.assignments where person_id = test.id('p1') and override_reason is not null),
               'F14: anonymising wipes override reasons');

-- =====================================================================================
-- 11. Core values (ASHLIE): reference form, one-to-one reflection, Values in Action (R19, R20)
-- =====================================================================================
select test.login('editor'); set role authenticated;
select test.ok((select count(*) from public.core_values) = 6, 'ASHLIE: the six core values are seeded and readable');
select test.ok((select string_agg(letter, '' order by sort_order) from public.core_values) = 'ASHLIE', 'ASHLIE: values are in order');
reset role;

select test.login('ops'); set role authenticated;
update public.core_values set name = 'Changed' where letter = 'A';
reset role;
select test.ok((select name from public.core_values where letter = 'A') = 'Accountability', 'ASHLIE: only the Resident Pastor edits core values');

-- One-to-one reflection: a value lived out and a value to grow in. (p1 was anonymised by an
-- earlier check, so these use p3, an active member of A1.)
select test.login('ul_a'); set role authenticated;
select test.lives(format('insert into public.one_to_ones (person_id, unit_id, quarter_start, held_on, feeling) values (%L, %L, %L, %L, %L)',
                         test.id('p3'), test.id('A1'), date_trunc('quarter', current_date)::date, current_date, 'thriving'),
                  'ASHLIE: one-to-one for p3');
select test.lives(format('update public.one_to_ones set value_lived_id = (select id from public.core_values where letter = %L), value_lived_note = %L, value_to_grow_id = (select id from public.core_values where letter = %L) where person_id = %L',
                         'S', 'Covered three Sundays at short notice', 'E', test.id('p3')),
                  'ASHLIE: one-to-one records a value lived and a value to grow in');
select test.throws(format('update public.one_to_ones set value_lived_id = null, value_lived_note = %L where person_id = %L', 'A note with no value', test.id('p3')),
                   'ASHLIE: a reflection note needs its value');
reset role;

-- Values in Action recognitions.
select test.login('ul_a'); set role authenticated;
select test.lives(format('insert into public.recognitions (person_id, unit_id, value_id, description, recognised_on, offered_to_newsletter, person_agreed) values (%L, %L, (select id from public.core_values where letter = %L), %L, %L, true, true)',
                         test.id('p3'), test.id('A1'), 'L', 'Stayed after service to help a first-time guest find the reception.', (date_trunc('month', current_date) - interval '10 days')::date),
                  'R19: a Unit Lead recognises a member of their unit');
select test.lives(format('insert into public.recognitions (person_id, unit_id, value_id, description, recognised_on) values (%L, %L, (select id from public.core_values where letter = %L), %L, %L)',
                         test.id('p3'), test.id('A1'), 'A', 'Owned the sound desk checklist every week.', (date_trunc('month', current_date) - interval '12 days')::date),
                  'R19: a recognition can stay private');
select test.ok((select recognised_by from public.recognitions where value_id = (select id from public.core_values where letter = 'L')) = test.id('ul_a'),
               'R19: the author is recorded automatically');
select test.throws(format('insert into public.recognitions (person_id, unit_id, value_id, description) values (%L, %L, (select id from public.core_values where letter = %L), %L)',
                          test.id('p3'), test.id('A2'), 'S', 'Served well.'),
                   'R19: a Unit Lead cannot recognise in another unit');
select test.throws(format('insert into public.recognitions (person_id, unit_id, value_id, description) values (%L, %L, (select id from public.core_values where letter = %L), %L)',
                          test.id('pB'), test.id('A1'), 'S', 'Served well.'),
                   'R19: cannot recognise someone who is not in the unit');
select test.throws(format('insert into public.recognitions (person_id, unit_id, value_id, description, offered_to_newsletter) values (%L, %L, (select id from public.core_values where letter = %L), %L, true)',
                          test.id('p3'), test.id('A1'), 'H', 'Served quietly behind the scenes.'),
                   'R19: cannot offer to the newsletter without the member''s agreement');
select test.throws(format('insert into public.recognitions (person_id, unit_id, value_id, description, recognised_on) values (%L, %L, (select id from public.core_values where letter = %L), %L, %L)',
                          test.id('p3'), test.id('A1'), 'H', 'Not yet happened.', current_date + 7),
                   'R19: recognitions are for service already given');
select test.throws(format('update public.recognitions set person_id = %L', test.id('p1')),
                   'R19: the person on a recognition cannot change');
reset role;

select test.login('ul_b'); set role authenticated;
select test.ok((select count(*) from public.recognitions) = 0, 'R19: another Unit Lead does not see the recognitions');
reset role;
select test.login('ph'); set role authenticated;
select test.ok((select count(*) from public.recognitions) = 2, 'R19: the unit''s Purpose Head sees them');
reset role;
select test.login('editor'); set role authenticated;
select test.ok((select count(*) from public.recognitions) = 0, 'R19: editors cannot read recognitions directly');
select test.ok((select count(*) from public.newsletter_recognitions(current_date)) = 1, 'R19: editors get only agreed, offered recognitions');
select test.ok((select display_name from public.newsletter_recognitions(current_date)) = 'Cy E.', 'R19: newsletter shows first name and initial only');
select test.throws($q$select * from public.values_in_action_counts(current_date - 365, current_date)$q$, 'R20: editors cannot run value counts');
reset role;

select test.login('coord'); set role authenticated;
select test.ok((select count(*) from public.values_in_action_counts(current_date - 365, current_date)) = 6, 'R20: counts come back per value, all six');
select test.ok((select sum(recognitions) from public.values_in_action_counts(current_date - 365, current_date)) = 2, 'R20: counts total the recognitions');
reset role;
select test.login('ul_a'); set role authenticated;
select test.throws($q$select * from public.values_in_action_counts(current_date - 365, current_date)$q$, 'R20: a Unit Lead cannot count church-wide');
select test.lives(format('select * from public.values_in_action_counts(%L, %L, %L)', current_date - 365, current_date, test.id('A1')), 'R20: a Unit Lead counts their own unit');
reset role;
select test.login('ul_b'); set role authenticated;
select test.throws(format('select * from public.values_in_action_counts(%L, %L, %L)', current_date - 365, current_date, test.id('A1')), 'R20: a Unit Lead cannot count another unit');
reset role;
select test.ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and column_name ilike '%score%'),
               'R20: no score or rating column anywhere');

-- People's rights.
select test.login('ops'); set role authenticated;
select test.ok(jsonb_array_length(public.export_person(test.id('p3')) -> 'recognitions') = 2, 'Export includes recognitions');
select test.lives(format('select public.anonymise_person(%L)', test.id('p3')), 'Anonymise a recognised member');
reset role;
select test.ok(not exists (select 1 from public.recognitions where person_id = test.id('p3')), 'Anonymising removes recognitions');

-- Security review 2 (G01 to G05, see SECURITY_LOG.md). p1 to p3 are anonymised by now, so add
-- p4, an active member of A1 (as the database owner: a system change).
select test.login('');
do $$
declare v uuid;
begin
  insert into public.people (church_id, first_name, surname, email, date_joined)
  values (test.id('churchA'), 'Dee', 'Fixture', 'dee@example.org', current_date - 200) returning id into v;
  insert into test.ids values ('p4', v);
  insert into public.unit_memberships (church_id, person_id, unit_id) values (test.id('churchA'), v, test.id('A1'));
end $$;

-- G02: a leader cannot recognise themselves (link ul_a's account to p4 for this check only).
select test.login('');
update public.app_users set person_id = test.id('p4') where id = test.id('ul_a');
select test.login('ul_a'); set role authenticated;
select test.throws(format('insert into public.recognitions (person_id, unit_id, value_id, description, recognised_on) values (%L, %L, (select id from public.core_values where letter = %L), %L, %L)',
                          test.id('p4'), test.id('A1'), 'S', 'Recognising myself.', current_date - 1),
                   'G02: a leader cannot recognise themselves');
reset role; select test.login('');
update public.app_users set person_id = null where id = test.id('ul_a');

-- G03: a retired value cannot be used for a new recognition.
update public.core_values set is_active = false where letter = 'H';
select test.login('ul_a'); set role authenticated;
select test.throws(format('insert into public.recognitions (person_id, unit_id, value_id, description, recognised_on) values (%L, %L, (select id from public.core_values where letter = %L), %L, %L)',
                          test.id('p4'), test.id('A1'), 'H', 'Tagged with a retired value.', current_date - 1),
                   'G03: a recognition needs a current core value');
reset role; select test.login('');
update public.core_values set is_active = true where letter = 'H';

-- G01: withdrawing agreement does not depend on the author still holding a unit role.
select test.login('ul_a'); set role authenticated;
select test.lives(format('insert into public.recognitions (person_id, unit_id, value_id, description, recognised_on, offered_to_newsletter, offered_to_meeting, person_agreed) values (%L, %L, (select id from public.core_values where letter = %L), %L, %L, true, true, true)',
                         test.id('p4'), test.id('A1'), 'S', 'Set up the stage in the rain.', (date_trunc('month', current_date) - interval '5 days')::date),
                  'G01: recognition for p4, offered with agreement');
reset role; select test.login('');
insert into test.ids select 'rec4', id from public.recognitions where person_id = test.id('p4') and description = 'Set up the stage in the rain.';
select test.login('editor'); set role authenticated;
select test.ok((select count(*) from public.newsletter_recognitions(current_date)) = 1, 'G01: offered recognition reaches the newsletter feed');
select test.throws(format('select public.withdraw_recognition_sharing(%L)', test.id('rec4')), 'G01: an editor cannot withdraw sharing');
reset role;
select test.login('ul_b'); set role authenticated;
select test.throws(format('select public.withdraw_recognition_sharing(%L)', test.id('rec4')), 'G01: a lead of another unit cannot withdraw sharing');
reset role;
select test.login('b_ops'); set role authenticated;
select test.throws(format('select public.withdraw_recognition_sharing(%L)', test.id('rec4')), 'G01: another church cannot withdraw sharing');
reset role;
-- The author loses the Unit Lead role, so can no longer edit, but can still withdraw sharing.
select test.login('');
update public.role_assignments set is_active = false where user_id = test.id('ul_a') and role = 'unit_lead';
select test.login('ul_a'); set role authenticated;
select test.throws(format('update public.recognitions set description = %L where id = %L', 'Edited after leaving the role.', test.id('rec4')),
                   'G01: a former Unit Lead cannot edit their recognition');
select test.lives(format('select public.withdraw_recognition_sharing(%L)', test.id('rec4')), 'G01: a former Unit Lead can still withdraw sharing');
reset role; select test.login('');
update public.role_assignments set is_active = true where user_id = test.id('ul_a') and role = 'unit_lead';
select test.ok((select not (offered_to_newsletter or offered_to_meeting or person_agreed) from public.recognitions where id = test.id('rec4')),
               'G01: withdrawing clears agreement and both offers');
select test.login('editor'); set role authenticated;
select test.ok((select count(*) from public.newsletter_recognitions(current_date)) = 0, 'G01: a withdrawn recognition leaves the newsletter feed');
reset role;
-- The unit's Purpose Head (not the author) can also withdraw.
select test.login('');
update public.recognitions set offered_to_meeting = true, person_agreed = true where id = test.id('rec4');
select test.login('ph'); set role authenticated;
select test.lives(format('select public.withdraw_recognition_sharing(%L)', test.id('rec4')), 'G01: the unit''s Purpose Head can withdraw sharing');
reset role;
select test.ok((select not person_agreed from public.recognitions where id = test.id('rec4')), 'G01: Purpose Head withdrawal took effect');

-- G04: changes to recognitions (including the agreement tick) are audited, without values.
select test.ok(exists (select 1 from public.audit_log where table_name = 'recognitions' and record_id = test.id('rec4')
                       and action = 'update' and detail -> 'columns' ? 'person_agreed'),
               'G04: changes to agreement are audited by column name');
select test.ok(not exists (select 1 from public.audit_log where table_name = 'recognitions' and detail::text ilike '%stage in the rain%'),
               'G04: the audit log never holds recognition text');

-- G05: only the editable columns can be updated through the API.
select test.login('ul_a'); set role authenticated;
select test.throws(format('update public.recognitions set created_at = now() - interval %L where id = %L', '1 year', test.id('rec4')),
                   'G05: created_at cannot be rewritten');
select test.lives(format('update public.recognitions set description = %L where id = %L', 'Set up the stage in heavy rain.', test.id('rec4')),
                  'G05: the author can still edit the wording');
reset role;

-- =====================================================================================
-- 12. Recognition retention (12 months, decision of 23 Oct 2026)
-- =====================================================================================
insert into public.recognitions (church_id, person_id, unit_id, value_id, description, recognised_on, recognised_by)
select test.id('churchA'), test.id('p4'), test.id('A1'), v.id, 'Old recognition, past retention.', current_date - interval '13 months', test.id('ul_a')
from public.core_values v where v.letter = 'I';
insert into public.recognitions (church_id, person_id, unit_id, value_id, description, recognised_on, recognised_by)
select test.id('churchA'), test.id('p4'), test.id('A1'), v.id, 'Recent recognition, within retention.', current_date - interval '11 months', test.id('ul_a')
from public.core_values v where v.letter = 'I';
select test.ok((select recognition_retention_months from public.church_settings where church_id = test.id('churchA')) = 12,
               'Retention: recognitions are kept 12 months by default');
select app.housekeeping();
select test.ok(not exists (select 1 from public.recognitions where description = 'Old recognition, past retention.'),
               'Retention: housekeeping deletes recognitions older than 12 months');
select test.ok(exists (select 1 from public.recognitions where description = 'Recent recognition, within retention.'),
               'Retention: housekeeping keeps recognitions within 12 months');
select test.login('ul_a'); set role authenticated;
select test.throws('select app.housekeeping()', 'Retention: signed-in users cannot run the housekeeping job');
reset role;

-- Security review 3 (H01 to H03, see SECURITY_LOG.md).
select test.ok(not has_function_privilege('anon', 'app.housekeeping()', 'execute')
               and not has_function_privilege('authenticated', 'app.housekeeping()', 'execute')
               and has_function_privilege('service_role', 'app.housekeeping()', 'execute'),
               'Retention: only the service role (and the owner, for pg_cron) can run housekeeping');

-- Who can change the period. Only the Operations Lead, within 6 to 36 months (H02), audited.
select test.login('ops'); set role authenticated;
select test.throws(format('update public.church_settings set recognition_retention_months = 5 where church_id = %L', test.id('churchA')),
                   'H02: retention below 6 months is refused');
select test.throws(format('update public.church_settings set recognition_retention_months = 37 where church_id = %L', test.id('churchA')),
                   'H02: retention above 36 months is refused');
select test.lives(format('update public.church_settings set recognition_retention_months = 24 where church_id = %L', test.id('churchA')),
                  'Retention: the Operations Lead can change the period');
reset role;
select test.ok((select recognition_retention_months from public.church_settings where church_id = test.id('churchA')) = 24,
               'Retention: the Operations Lead''s change took effect');
select test.ok(exists (select 1 from public.audit_log where table_name = 'church_settings' and actor_id = test.id('ops')
                       and detail -> 'columns' ? 'recognition_retention_months'),
               'Retention: a change to the period is audited with who made it');
select test.login('rp'); set role authenticated;
select test.throws(format('update public.church_settings set recognition_retention_months = 6 where church_id = %L', test.id('churchA')),
                   'Retention: the Resident Pastor cannot change the period');
reset role;
select test.login('ul_a'); set role authenticated;
update public.church_settings set recognition_retention_months = 6 where church_id = test.id('churchA');
reset role;
select test.login('b_ops'); set role authenticated;
update public.church_settings set recognition_retention_months = 6 where church_id = test.id('churchA');
reset role;
select test.ok((select recognition_retention_months from public.church_settings where church_id = test.id('churchA')) = 24,
               'Retention: a Unit Lead or another church''s Operations Lead cannot change the period');
select test.login('ops'); set role authenticated;
update public.church_settings set recognition_retention_months = 12 where church_id = test.id('churchA');
reset role;

-- H01: the date of service cannot be moved after the day the recognition was written.
select test.login('');
do $$
declare v uuid;
begin
  insert into public.recognitions (church_id, person_id, unit_id, value_id, description, recognised_on, recognised_by, created_at)
  select test.id('churchA'), test.id('p4'), test.id('A1'), cv.id, 'Written long ago.', current_date - 400, test.id('ul_a'), now() - interval '400 days'
  from public.core_values cv where cv.letter = 'L' returning id into v;
  insert into test.ids values ('rec_old', v);
end $$;
select test.login('ul_a'); set role authenticated;
select test.throws(format('update public.recognitions set recognised_on = current_date where id = %L', test.id('rec_old')),
                   'H01: an author cannot move the date of service forward to keep a recognition');
select test.lives(format('update public.recognitions set recognised_on = current_date - 401 where id = %L', test.id('rec_old')),
                  'H01: an author can still correct the date to an earlier day');
reset role;

-- Boundary: exactly 12 months old is kept until the next night; one day more is deleted, and
-- the job's delete is audited with no actor and no text.
select test.login('');
do $$
declare v uuid;
begin
  insert into public.recognitions (church_id, person_id, unit_id, value_id, description, recognised_on, recognised_by)
  select test.id('churchA'), test.id('p4'), test.id('A1'), cv.id, 'Exactly twelve months.', (current_date - interval '12 months')::date, test.id('ul_a')
  from public.core_values cv where cv.letter = 'L';
  insert into public.recognitions (church_id, person_id, unit_id, value_id, description, recognised_on, recognised_by)
  select test.id('churchA'), test.id('p4'), test.id('A1'), cv.id, 'Twelve months and a day.', (current_date - interval '12 months')::date - 1, test.id('ul_a')
  from public.core_values cv where cv.letter = 'L' returning id into v;
  insert into test.ids values ('rec_boundary', v);
end $$;

-- H03: a church with no settings row still has its recognitions purged (12-month default).
do $$
declare b uuid := test.id('churchB'); v uuid;
begin
  -- Unit B1 exists from the fixture; church B has no core values yet.
  insert into public.core_values (church_id, letter, name, behaviour, sort_order) values (b, 'S', 'Service', 'We serve.', 1) returning id into v;
  insert into test.ids values ('Bval', v);
  insert into public.people (church_id, first_name, surname, date_joined) values (b, 'Bea', 'Fixture', current_date - 800) returning id into v;
  insert into test.ids values ('pB_ret', v);
  insert into public.recognitions (church_id, person_id, unit_id, value_id, description, recognised_on, recognised_by)
  values (b, test.id('pB_ret'), test.id('B1'), test.id('Bval'), 'Other church, past retention.', current_date - 500, test.id('b_ops'));
  -- Simulates a church left without a row (before migration 12, or removed by hand); the
  -- church_settings_keep guard (I01) now refuses this, so it is switched off just for the setup.
  alter table public.church_settings disable trigger church_settings_keep;
  delete from public.church_settings where church_id = b;
  alter table public.church_settings enable trigger church_settings_keep;
end $$;

select app.housekeeping();
select test.ok(not exists (select 1 from public.recognitions where id = test.id('rec_old')),
               'H01: the corrected recognition is deleted when its time is up');
select test.ok(exists (select 1 from public.recognitions where description = 'Exactly twelve months.'),
               'Retention: a recognition exactly 12 months old is kept until the next night');
select test.ok(not exists (select 1 from public.recognitions where id = test.id('rec_boundary')),
               'Retention: a recognition 12 months and a day old is deleted');
select test.ok(exists (select 1 from public.audit_log where table_name = 'recognitions' and record_id = test.id('rec_boundary')
                       and action = 'delete' and actor_id is null),
               'Retention: the job''s deletions are audited (no actor)');
select test.ok(not exists (select 1 from public.audit_log where table_name = 'recognitions' and detail::text ilike '%twelve months%'),
               'Retention: the deletion audit holds no recognition text');
select test.ok(not exists (select 1 from public.recognitions where description = 'Other church, past retention.'),
               'H03: recognitions are purged even when a church has no settings row');
insert into public.church_settings (church_id) values (test.id('churchB'));

select test.ok((select labels ->> 'g_squad' from public.church_settings where church_id = test.id('churchA')) = 'G-Squad',
               'Seed sets the church''s labels on its settings row');
insert into public.churches (name, slug) values ('Third Church', 'third-church');
select test.ok(exists (select 1 from public.church_settings s join public.churches c on c.id = s.church_id where c.slug = 'third-church'),
               'A new church gets its settings row automatically, so nightly jobs cover it');

-- Security review 4 (I01 to I03, see SECURITY_LOG.md).
select test.ok(exists (select 1 from public.audit_log a join public.churches c on c.id = a.church_id
                       where c.slug = 'third-church' and a.table_name = 'church_settings' and a.action = 'insert' and a.actor_id is null),
               'Settings: the automatic settings row is audited (no actor)');
select test.ok(not has_function_privilege('anon', 'app.church_settings_default()', 'execute')
               and not has_function_privilege('authenticated', 'app.church_settings_default()', 'execute')
               and not has_function_privilege('anon', 'app.church_settings_keep()', 'execute')
               and not has_function_privilege('authenticated', 'app.church_settings_keep()', 'execute'),
               'Settings: API roles cannot call the settings trigger functions');
select test.login('ops'); set role authenticated;
select test.throws($q$insert into public.churches (name, slug) values ('Rogue Church', 'rogue-church')$q$,
                   'Settings: signed-in users cannot create churches (so cannot fire the settings trigger)');
delete from public.church_settings where church_id = test.id('churchA');
reset role;
select test.ok(exists (select 1 from public.church_settings where church_id = test.id('churchA')),
               'I01: the Operations Lead cannot delete the settings row');
select test.throws(format('delete from public.church_settings where church_id = %L', test.id('churchA')),
                   'I01: even the service role cannot delete a church''s settings row');
select test.lives($q$delete from public.churches where slug = 'third-church'$q$,
                  'I01/I04: a church can still be deleted, and its settings row goes with it (cascade)');
select test.ok(not exists (select 1 from public.church_settings s where not exists (select 1 from public.churches c where c.id = s.church_id)),
               'I01: no settings row is left without its church');
select test.ok(not exists (select 1 from public.churches c where not exists (select 1 from public.church_settings s where s.church_id = c.id)),
               'I01: every church has a settings row');

-- I02: a leaver in a church with no settings row is still anonymised (12-month default).
do $$
declare c uuid; v uuid;
begin
  insert into public.churches (name, slug) values ('Fourth Church', 'fourth-church') returning id into c;
  alter table public.church_settings disable trigger church_settings_keep;
  delete from public.church_settings where church_id = c;
  alter table public.church_settings enable trigger church_settings_keep;
  insert into public.people (church_id, first_name, surname, date_joined, status, date_left)
  values (c, 'Dee', 'Leaver', current_date - 900, 'left', current_date - 400) returning id into v;
  insert into test.ids values ('pD_left', v);
  insert into public.people (church_id, first_name, surname, date_joined, status, date_left)
  values (c, 'Eve', 'Recent', current_date - 900, 'left', current_date - 300) returning id into v;
  insert into test.ids values ('pD_recent', v);
end $$;
select app.anonymise_expired_people();
select test.ok((select anonymised_at is not null and surname = 'member' from public.people where id = test.id('pD_left')),
               'I02: anonymisation covers a church with no settings row (left over 12 months ago)');
select test.ok((select anonymised_at is null from public.people where id = test.id('pD_recent')),
               'I02: the 12-month default keeps a leaver of 10 months');
select test.ok(not has_function_privilege('anon', 'app.anonymise_expired_people()', 'execute')
               and not has_function_privilege('authenticated', 'app.anonymise_expired_people()', 'execute')
               and has_function_privilege('service_role', 'app.anonymise_expired_people()', 'execute'),
               'I02: only the service role (and the owner, for pg_cron) can run anonymisation');

-- I03: re-running the seed keeps labels the church has changed.
update public.church_settings set labels = '{"g_squad":"Our Team"}' where church_id = test.id('churchA');
insert into public.church_settings (church_id, labels)
values (test.id('churchA'), '{"g_squad":"G-Squad","unit":"unit","service":"service"}')
on conflict (church_id) do update set labels = excluded.labels
  where public.church_settings.labels = '{}'::jsonb;
select test.ok((select labels ->> 'g_squad' from public.church_settings where church_id = test.id('churchA')) = 'Our Team',
               'I03: re-running the seed does not overwrite the church''s own labels');

-- =====================================================================================
-- Slice 1 (migration 13): the G-Squad Coordinator invites leaders, within the F01 limits
-- =====================================================================================
-- A newly invited leader: Supabase Auth creates the auth.users row (the Edge Function does this
-- with the service role); the inviter then adds the app account and roles as themselves.
do $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (v, 'new.lead@example.org');
  insert into test.ids values ('newlead', v);
end $$;

select test.login('coord'); set role authenticated;
select test.lives(format('insert into public.app_users (id, display_name) values (%L, %L)', test.id('newlead'), 'New Lead'),
                  'S1: Coordinator adds an invited leader''s account');
select test.ok((select church_id from public.app_users where id = test.id('newlead')) = test.id('churchA'),
               'S1: the new account joins the inviter''s church automatically');
select test.lives(format('insert into public.role_assignments (user_id, role, unit_id) values (%L, %L, %L)',
                         test.id('newlead'), 'unit_lead', test.id('A3')),
                  'S1: Coordinator makes the new leader a Unit Lead');
-- Migration 18: the Coordinator now gives and removes senior roles, except the Resident Pastor role.
select test.lives(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('newlead'), 'teci_coordinator'),
                  'M18: Coordinator gives a senior role');
select test.lives(format('delete from public.role_assignments where user_id = %L and role = %L', test.id('newlead'), 'teci_coordinator'),
                  'M18: Coordinator removes a senior role');
select test.lives(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('newlead'), 'operations_lead'),
                  'M18: Coordinator gives the Operations Lead role');
select test.lives(format('delete from public.role_assignments where user_id = %L and role = %L', test.id('newlead'), 'operations_lead'),
                  'M18: Coordinator removes the Operations Lead role');
select test.throws(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('newlead'), 'resident_pastor'),
                   'M18: Coordinator cannot give the Resident Pastor role');
select test.throws(format('delete from public.role_assignments where user_id = %L and role = %L', test.id('rp'), 'resident_pastor'),
                   'M18: Coordinator cannot remove the Resident Pastor role');
select test.throws(format('delete from public.role_assignments where user_id = %L', test.id('coord')),
                   'S1: Coordinator cannot change their own roles');
select test.ok((select count(distinct user_id) from public.role_assignments) >= 10,
               'S1: Coordinator sees every leader''s roles in their church');
select test.ok(not exists (select 1 from public.role_assignments where user_id = test.id('b_ops')),
               'S1: Coordinator sees no roles from another church');
select test.throws(format('update public.app_users set is_active = false where id = %L', test.id('rp')),
                   'M18: Coordinator cannot switch off the Resident Pastor''s account');
select test.throws(format('update public.app_users set church_id = %L where id = %L', test.id('churchB'), test.id('newlead')),
                   'S1: an account cannot be moved to another church');
select test.lives(format('update public.app_users set display_name = %L where id = %L', 'New Lead (Hospitality)', test.id('newlead')),
                  'S1: Coordinator can rename a leader''s account');
select test.ok((select display_name from public.app_users where id = test.id('newlead')) = 'New Lead (Hospitality)',
               'S1: ... and the new name is saved');
reset role;

select test.login('ops'); set role authenticated;
select test.throws(format('update public.app_users set is_active = false where id = %L', test.id('ops')),
                   'S1: Operations Lead cannot switch off their own account');
select test.throws(format('update public.app_users set is_active = false where id = %L', test.id('coord')),
                   'S1: Operations Lead cannot switch off a senior leader''s account');
select test.lives(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('newlead'), 'operations_lead'),
                  'S1: an Operations Lead can give the Operations Lead role');
select test.lives(format('delete from public.role_assignments where user_id = %L and role = %L', test.id('newlead'), 'operations_lead'),
                  'S1: an Operations Lead can remove the Operations Lead role from someone else');
reset role;

select test.login('coord'); set role authenticated;
select test.lives(format('update public.app_users set is_active = false where id = %L', test.id('newlead')),
                  'S1: Coordinator can switch off a Unit Lead''s account');
select test.ok(not (select is_active from public.app_users where id = test.id('newlead')),
               'S1: ... and the account is really switched off');
reset role;

select test.login('ul_a'); set role authenticated;
select test.throws(format('insert into public.role_assignments (user_id, role, unit_id) values (%L, %L, %L)',
                          test.id('ul_b'), 'unit_lead', test.id('A1')),
                   'S1: a Unit Lead cannot give roles');
reset role;

select test.login('rp'); set role authenticated;
select test.lives(format('update public.app_users set is_active = true where id = %L', test.id('newlead')),
                  'S1: Resident Pastor can switch an account back on');
select test.ok((select is_active from public.app_users where id = test.id('newlead')),
               'S1: ... and the account is really back on');
reset role;

-- =====================================================================================
-- Security review 6 (migration 14): account guard and role-row updates
-- =====================================================================================
-- K02: the Resident Pastor switches off the Pastoral Lead; nobody else may switch them back on
-- (that would hand the Pastoral Lead role back).
select test.login('rp'); set role authenticated;
select test.lives(format('update public.app_users set is_active = false where id = %L', test.id('pastoral')),
                  'K02: Resident Pastor switches off a senior leader''s account');
reset role;
-- (Migration 18: the Coordinator may now do this too, so only the Operations Lead is checked here.)
select test.login('ops'); set role authenticated;
select test.throws(format('update public.app_users set is_active = true where id = %L', test.id('pastoral')),
                   'K02: Operations Lead cannot switch a senior leader''s account back on');
reset role;
select test.ok(not (select is_active from public.app_users where id = test.id('pastoral')),
               'K02: ... and the account stays switched off');
select test.login('rp'); set role authenticated;
select test.lives(format('update public.app_users set is_active = true where id = %L', test.id('pastoral')),
                  'K02: Resident Pastor switches the senior leader''s account back on');
reset role;

-- K03: a Purpose Head is protected while Purpose Heads read pastoral notes.
select test.login('');
update public.church_settings set purpose_heads_read_pastoral = true where church_id = test.id('churchA');
select test.login('ops'); set role authenticated;
select test.throws(format('update public.app_users set is_active = false where id = %L', test.id('ph')),
                   'K03: Operations Lead cannot switch off a Purpose Head who reads pastoral notes');
select test.throws(format('delete from public.app_users where id = %L', test.id('ph')),
                   'K03: ... nor delete that account');
reset role;
select test.login('');
update public.church_settings set purpose_heads_read_pastoral = false where church_id = test.id('churchA');
select test.ok((select is_active from public.app_users where id = test.id('ph')), 'K03: ... and the Purpose Head is still active');

-- K04: nobody re-links their own account to a G-Squad record (G02 self-recognition check).
select test.login('coord'); set role authenticated;
select test.throws(format('update public.app_users set person_id = %L where id = %L', test.id('p1'), test.id('coord')),
                   'K04: Coordinator cannot change the record linked to their own account');
select test.lives(format('update public.app_users set display_name = %L where id = %L', 'Coord', test.id('coord')),
                  'K04: ... but can still rename their own account');
reset role;
select test.login('ops'); set role authenticated;
select test.throws(format('update public.app_users set person_id = %L where id = %L', test.id('p2'), test.id('ops')),
                   'K04: Operations Lead cannot change the link on their own account');
reset role;

-- Role rows: an UPDATE is checked like a removal plus a grant.
select test.login('coord'); set role authenticated;
select test.throws(format('update public.role_assignments set role = %L, unit_id = null where user_id = %L and role = %L',
                          'resident_pastor', test.id('ul_b'), 'unit_lead'),
                   'K/M18: Coordinator cannot turn a Unit Lead row into the Resident Pastor role');
select test.throws(format('update public.role_assignments set user_id = %L where user_id = %L and role = %L',
                          test.id('coord'), test.id('finance'), 'finance'),
                   'K: Coordinator cannot move someone''s role row to themselves');
select test.throws(format('update public.role_assignments set is_active = false where user_id = %L and role = %L',
                          test.id('rp'), 'resident_pastor'),
                   'K/M18: Coordinator cannot switch off the Resident Pastor role row');
select test.throws(format('update public.role_assignments set church_id = %L where user_id = %L',
                          test.id('churchB'), test.id('finance')),
                   'K: a role row cannot be moved to another church');
select test.throws(format('insert into public.role_assignments (user_id, role, unit_id) values (%L, %L, %L)',
                          test.id('ul_b'), 'unit_lead', test.id('B1')),
                   'K: a role cannot point at another church''s unit');
reset role;

-- =====================================================================================
-- Slice 1b/1c (migration 15, Review 7): what the member screens do, end to end.
-- =====================================================================================
-- L01: the old app path (INSERT ... RETURNING on people) is refused by people_read.
select test.login('ul_a'); set role authenticated;
select test.throws($q$insert into public.people (first_name, surname) values ('Ret', 'Urning') returning id$q$,
                   'L01: INSERT ... RETURNING on people is refused (why the app uses create_member)');
-- A Unit Lead adds a member to their own unit, with faith fields, in one call.
select test.lives(format($q$select public.create_member(
    jsonb_build_object('first_name', 'Lia', 'surname', 'Newmember', 'email', '  Lia@Example.ORG ',
                       'birth_day', 5, 'birth_month', 6, 'marital_status', 'single',
                       'anniversary_day', 1, 'anniversary_month', 1,
                       'id', %L, 'church_id', %L, 'created_by', %L, 'anonymised_at', now()),
    %L, null, false, null, jsonb_build_object('water_baptism', true, 'water_baptism_date', '2026-01-04'))$q$,
    test.id('p1'), test.id('churchB'), test.id('ops'), test.id('A1')),
  'L01: Unit Lead adds a member, their membership and faith fields to their own unit');
select test.ok((select water_baptism from public.get_person_faith(
                  (select id from public.people where surname = 'Newmember'))),
               'L01: ... and reads back the faith fields (active membership in their unit)');
reset role;
select test.ok((select p.created_by = test.id('ul_a') and p.church_id = test.id('churchA') and p.anonymised_at is null
                       and p.id <> test.id('p1') and p.email = 'lia@example.org'
                       and p.anniversary_day is null and p.status = 'active'
                from public.people p where p.surname = 'Newmember'),
               'L01: id, church, creator and anonymised_at in the payload are ignored; email lower-cased; no anniversary unless married');
select test.ok((select m.status = 'active' and m.unit_id = test.id('A1') from public.unit_memberships m
                join public.people p on p.id = m.person_id where p.surname = 'Newmember'),
               'L01: the membership is in the chosen unit and active');

select test.login('ul_a'); set role authenticated;
select test.throws(format($q$select public.create_member('{"first_name":"Dup","surname":"Email","email":"LIA@example.org"}', %L)$q$, test.id('A1')),
                   'L01: an email already recorded (any case) is refused');
select test.throws(format($q$select public.create_member('{"first_name":"Ota","surname":"Atomic"}', %L)$q$, test.id('A2')),
                   'L01: Unit Lead cannot add a member to another unit');
select test.throws(format($q$select public.create_member(jsonb_build_object('first_name','Teci','surname','Atomic','teci_stage_id',%L), %L)$q$,
                          (select id from public.teci_stages where church_id = test.id('churchA') limit 1), test.id('A1')),
                   'L01: Unit Lead cannot set a TECi stage on a new member');
select test.throws(format('update public.people set teci_stage_id = %L where surname = %L',
                          (select id from public.teci_stages where church_id = test.id('churchA') limit 1), 'Newmember'),
                   'L01: Unit Lead cannot set a TECi stage on an existing member');
reset role;
select test.login('ops'); set role authenticated;
select test.throws(format($q$select public.create_member('{"first_name":"Fai","surname":"Atomic"}', %L, null, false, null, '{"water_baptism":true}')$q$, test.id('A2')),
                   'L01: Operations Lead cannot record faith fields while adding a member');
select test.lives(format($q$select public.create_member('{"first_name":"Opa","surname":"Added"}', %L)$q$, test.id('A2')),
                  'L01: Operations Lead adds a member to any unit (no faith fields)');
reset role;
select test.login('b_ops'); set role authenticated;
select test.throws(format($q$select public.create_member('{"first_name":"Cross","surname":"Atomic"}', %L)$q$, test.id('A1')),
                   'L01: another church''s Operations Lead cannot add a member to this church''s unit');
reset role;
select test.ok(not exists (select 1 from public.people where surname in ('Atomic', 'Email')),
               'L01: a refused create_member leaves no person behind (one transaction)');

-- My Unit: a Unit Lead changes team role, stage and leader flag in their unit only.
select test.login('ul_a'); set role authenticated;
do $$
declare n int;
begin
  update public.unit_memberships
     set church_role_id = null, is_team_leader = true,
         leadership_stage_id = (select id from public.leadership_stages order by sort_order limit 1)
   where unit_id = test.id('A1') and person_id = (select id from public.people where surname = 'Newmember');
  get diagnostics n = row_count;
  perform test.ok(n = 1, 'My Unit: Unit Lead changes role, stage and leader flag in their own unit');
  update public.unit_memberships set is_team_leader = true where unit_id = test.id('A2');
  get diagnostics n = row_count;
  perform test.ok(n = 0, 'My Unit: Unit Lead cannot change a membership of another unit');
end $$;
select test.ok(not exists (select 1 from public.people where id = test.id('p2')),
               'Members: Unit Lead does not see a member of another unit');
reset role;

-- L02: anonymised records stay closed.
select app.anonymise((select id from public.people where surname = 'Added'));
select test.login('coord'); set role authenticated;
select test.throws(format($q$update public.people set first_name = 'Opa', email = 'opa@example.org' where id = %L$q$,
                          (select id from public.people where anonymised_at is not null and first_name = 'Former' limit 1)),
                   'L02: an anonymised record cannot be filled in again');
select test.throws(format('insert into public.unit_memberships (person_id, unit_id) values (%L, %L)',
                          (select id from public.people where anonymised_at is not null and first_name = 'Former' limit 1), test.id('A3')),
                   'L02: an anonymised person cannot be added to a unit');
reset role;

-- =====================================================================================
-- Migration 16 (decisions of 23 Oct 2026): who edits member records; Unit Leads see their
-- current units only.
-- =====================================================================================
select test.login('ul_a'); set role authenticated;
select test.lives(format($q$select public.create_member('{"first_name":"Mo","surname":"Mover"}', %L)$q$, test.id('A1')),
                  'M16: a Unit Lead still adds a new member to their own unit');
select test.lives(format($q$update public.people set area = 'M7' where surname = 'Mover'$q$), 'M16: their Team Lead edits the record');
select test.ok((select area from public.people where surname = 'Mover') = 'M7', 'M16: ... and the change is saved');
reset role;

select test.login('coord'); set role authenticated;
select test.lives($q$update public.people set area = 'M8' where surname = 'Mover'$q$, 'M16: the G-Squad Coordinator edits the record');
reset role;
select test.ok((select area from public.people where surname = 'Mover') = 'M8', 'M16: ... and the change is saved');

-- The Resident Pastor and Operations Lead can read the record but their edits change nothing.
select test.login('rp'); set role authenticated;
select test.ok(exists (select 1 from public.people where surname = 'Mover'), 'M16: Resident Pastor can still read the record');
update public.people set area = 'RP' where surname = 'Mover';
reset role;
select test.ok((select area from public.people where surname = 'Mover') = 'M8', 'M16: Resident Pastor cannot edit a member record');
select test.login('ops'); set role authenticated;
update public.people set area = 'OPS' where surname = 'Mover';
reset role;
select test.ok((select area from public.people where surname = 'Mover') = 'M8', 'M16: Operations Lead cannot edit a member record');

-- The TECi Coordinator sets the TECi stage only.
select test.login('teci'); set role authenticated;
select test.lives(format($q$update public.people set teci_stage_id = %L where surname = 'Mover'$q$,
                         (select id from public.teci_stages where church_id = test.id('churchA') and stage_no = 1)),
                  'M16: TECi Coordinator sets the TECi stage');
select test.throws($q$update public.people set area = 'TECI' where surname = 'Mover'$q$,
                   'M16: TECi Coordinator cannot change other fields');
reset role;
select test.login('coord'); set role authenticated;
select test.throws(format($q$update public.people set teci_stage_id = null where surname = 'Mover'$q$),
                   'M16: only the TECi Coordinator changes an existing TECi stage');
reset role;

-- Decision 2: once Mo moves from A1 to A2, A1's Unit Lead no longer sees or edits them.
select test.login('ops'); set role authenticated;
select test.lives($q$update public.unit_memberships set status = 'ended'
                    where person_id = (select id from public.people where surname = 'Mover')$q$,
                  'M16: Operations Lead ends the old membership');
select test.lives(format($q$insert into public.unit_memberships (person_id, unit_id)
                            select id, %L from public.people where surname = 'Mover'$q$, test.id('A2')),
                  'M16: Operations Lead adds them to another unit');
reset role;
select test.login('ul_a'); set role authenticated;
select test.ok(not exists (select 1 from public.people where surname = 'Mover'),
               'M16: the old Unit Lead no longer sees someone they entered after they move');
update public.people set area = 'OLD' where surname = 'Mover';
reset role;
select test.ok((select area from public.people where surname = 'Mover') = 'M8', 'M16: ... and cannot edit them');
select test.login('ul_b'); set role authenticated;
select test.ok(exists (select 1 from public.people where surname = 'Mover'), 'M16: the new Unit Lead sees them');
reset role;

-- A Unit Lead cannot pull an existing member of another unit into their own (F05 still holds),
-- even knowing their id (taken here as the owner, since the Unit Lead can no longer see them).
insert into test.ids select 'mover', id from public.people where surname = 'Mover';
select test.login('ul_a'); set role authenticated;
select test.throws(format($q$insert into public.unit_memberships (person_id, unit_id) values (%L, %L)$q$,
                          test.id('mover'), test.id('A1')),
                   'M16: a Unit Lead cannot add an existing member of another unit');
reset role;

-- =====================================================================================
-- Security review 8 (SECURITY REVIEW FIX Mnn in migration 16).
-- =====================================================================================
-- M01: the old Unit Lead cannot re-open Mo's ended membership of their unit to get them back.
select test.login('ul_a'); set role authenticated;
select test.throws(format($q$update public.unit_memberships set status = 'active' where person_id = %L and unit_id = %L$q$,
                          test.id('mover'), test.id('A1')),
                   'M01: a Unit Lead cannot re-open an ended membership');
select test.ok(not exists (select 1 from public.people where id = test.id('mover')), 'M01: ... and still cannot see them');
reset role;
-- Ending a membership and live-membership changes are still the Unit Lead's.
select test.login('ul_b'); set role authenticated;
select test.lives(format($q$update public.unit_memberships set is_team_leader = true where person_id = %L and unit_id = %L$q$,
                         test.id('mover'), test.id('A2')),
                  'M01: a Unit Lead still changes a live membership of their unit');
reset role;
-- The Operations Lead may bring someone back (as with adding to a unit, F05).
select test.login('ops'); set role authenticated;
select test.lives(format($q$update public.unit_memberships set status = 'active' where person_id = %L and unit_id = %L$q$,
                         test.id('mover'), test.id('A1')),
                  'M01: the Operations Lead can re-open an ended membership');
reset role;
-- ... but not for an anonymised person.
select test.login('nobody');
update public.unit_memberships set status = 'ended', ended_on = current_date
 where person_id = (select id from public.people where anonymised_at is not null and first_name = 'Former' limit 1)
   and status <> 'ended';
insert into test.ids select 'anon_person', id from public.people where anonymised_at is not null and first_name = 'Former' limit 1;
select test.login('ops'); set role authenticated;
select test.throws(format($q$update public.unit_memberships set status = 'active' where person_id = %L$q$, test.id('anon_person')),
                   'M01: an anonymised person''s membership cannot be re-opened');
reset role;

-- M02: no faith fields written onto an anonymised record, even by the G-Squad Coordinator.
select test.login('coord'); set role authenticated;
select test.throws(format('select public.set_person_faith(%L, null, true, null, false, null, false, null)', test.id('anon_person')),
                   'M02: faith fields cannot be recorded on an anonymised record');
reset role;
select test.ok(not exists (select 1 from public.person_faith where person_id = test.id('anon_person')),
               'M02: ... and nothing was written');

-- The TECi route gives no wider edit right to a TECi Coordinator who also leads some other unit.
select test.login('nobody');
insert into public.role_assignments (church_id, user_id, role, unit_id)
values (test.id('churchA'), test.id('teci'), 'unit_lead', test.id('A3'));
select test.login('teci'); set role authenticated;
select test.throws(format($q$update public.people set area = 'TECI2' where id = %L$q$, test.id('mover')),
                   'M16: TECi Coordinator who leads another unit still cannot edit this record');
reset role;
select test.login('nobody');
delete from public.role_assignments where user_id = test.id('teci') and role = 'unit_lead';

-- The Operations Lead adds members but does not record faith fields: the whole add is undone.
select test.login('ops'); set role authenticated;
select test.throws(format($q$select public.create_member('{"first_name":"Fa","surname":"Faithless"}', %L, null, false, null, '{"water_baptism":true}')$q$,
                          test.id('A3')),
                   'M16: the Operations Lead cannot record faith fields when adding a member');
reset role;
select test.ok(not exists (select 1 from public.people where surname = 'Faithless'), 'M16: ... and no half-added member is left');

-- is_new_entry_of_caller: only the caller's OWN entry with no membership ever.
select test.login('ul_a'); set role authenticated;
select test.ok(not app.is_new_entry_of_caller(test.id('mover')), 'M16: someone entered long ago and placed in a unit is not a new entry');
reset role;
select test.login('ul_b'); set role authenticated;
select test.lives(format($q$insert into public.people (id, church_id, first_name, surname) values (%L, %L, 'Or', 'Phan')$q$,
                         '00000000-0000-4000-8000-0000000000f1', test.id('churchA')),
                  'M16: a Unit Lead enters a person directly');
reset role;
select test.login('ul_a'); set role authenticated;
select test.throws(format($q$insert into public.unit_memberships (person_id, unit_id) values (%L, %L)$q$,
                          '00000000-0000-4000-8000-0000000000f1', test.id('A1')),
                   'M16: another Unit Lead cannot claim that entry');
reset role;

-- Migration 17 (decision of 23 Oct 2026): anonymising ends every unit membership, so a
-- "Former member" no longer appears on the team list.
do $$
declare v uuid;
begin
  insert into public.people (church_id, first_name, surname) values (test.id('churchA'), 'Leaving', 'Soon') returning id into v;
  insert into public.unit_memberships (church_id, person_id, unit_id) values (test.id('churchA'), v, test.id('A1'));
  insert into test.ids values ('leaver', v);
end $$;
select test.login('nobody');
select app.anonymise(test.id('leaver'));
select test.ok(not exists (select 1 from public.unit_memberships where person_id = test.id('leaver') and status <> 'ended'),
               'M17: anonymising ends the person''s unit memberships');
select test.ok(not exists (select 1 from public.unit_memberships m join public.people p on p.id = m.person_id
                           where p.anonymised_at is not null and m.status <> 'ended'),
               'M17: no anonymised person has a live unit membership');
select test.login('ul_a'); set role authenticated;
select test.ok(not exists (select 1 from public.unit_memberships where unit_id = test.id('A1') and status <> 'ended'
                           and person_id = test.id('leaver')),
               'M17: the Former member is not on the Unit Lead''s team list');
reset role;

-- Security review 9: the same through the paths used for real, where the triggers on
-- unit_memberships run in full (not the owner/system shortcut above).
do $$
declare v uuid; w uuid;
begin
  insert into public.people (church_id, first_name, surname) values (test.id('churchA'), 'Erasure', 'Request') returning id into v;
  insert into public.unit_memberships (church_id, person_id, unit_id, joined_on) values (test.id('churchA'), v, test.id('A1'), current_date - 30);
  insert into public.unit_memberships (church_id, person_id, unit_id, status) values (test.id('churchA'), v, test.id('A2'), 'pending_approval');
  insert into test.ids values ('erasure', v);
  insert into public.people (church_id, first_name, surname, status, date_joined, date_left)
    values (test.id('churchA'), 'Long', 'Gone', 'left', current_date - 2000, current_date - 800) returning id into w;
  insert into public.unit_memberships (church_id, person_id, unit_id, joined_on) values (test.id('churchA'), w, test.id('A1'), current_date - 2000);
  insert into test.ids values ('longgone', w);
end $$;
select test.ok(not has_function_privilege('authenticated', 'app.anonymise(uuid)', 'execute')
               and not has_function_privilege('anon', 'app.anonymise(uuid)', 'execute'),
               'N01: app.anonymise is not callable by anon or signed-in users');
select test.ok(has_function_privilege('authenticated', 'public.anonymise_person(uuid)', 'execute')
               and not has_function_privilege('anon', 'public.anonymise_person(uuid)', 'execute'),
               'N01: anonymise_person stays open to signed-in users only (it checks the role itself)');
select test.login('ops'); set role authenticated;
select test.throws(format('select app.anonymise(%L)', test.id('erasure')), 'N01: the Ops Lead cannot call app.anonymise directly');
select test.lives(format('select public.anonymise_person(%L)', test.id('erasure')),
                  'N01: the Ops Lead anonymises a member with live and pending memberships');
reset role;
select test.ok((select count(*) = 2 and bool_and(status = 'ended' and ended_on = current_date)
                from public.unit_memberships where person_id = test.id('erasure')),
               'N01: anonymise_person ends active and pending memberships');
select test.ok(exists (select 1 from public.audit_log where action = 'anonymise_request' and record_id = test.id('erasure')),
               'N01: the erasure request is logged');
select test.login('ul_a'); set role authenticated;
select test.ok(not exists (select 1 from public.people where id = test.id('erasure')),
               'N01: the Unit Lead no longer sees the Former member at all');
reset role;
select test.login('nobody');
select app.anonymise_expired_people();
select test.ok((select status = 'ended' and ended_on = current_date - 800
                from public.unit_memberships where person_id = test.id('longgone')),
               'N02: the nightly job ends the membership, dated when the person left');

-- =====================================================================================
-- Migration 18 (decision of 23 Oct 2026): the G-Squad Coordinator has full access, except
-- the Resident Pastor role and account.
-- =====================================================================================
select test.login('coord'); set role authenticated;
select test.lives(format('select * from public.get_pastoral_notes(%L)', test.id('p1')), 'M18: Coordinator reads pastoral notes');
select test.lives(format('insert into public.pastoral_notes (person_id, note) values (%L, %L)', test.id('p1'), 'Checked in after the service.'),
                  'M18: Coordinator adds a pastoral note');
select test.lives($q$update public.units set regular_monthly_need = 3 where name = 'Hospitality'$q$, 'M18: Coordinator edits a unit');
select test.ok((select regular_monthly_need from public.units where name = 'Hospitality' and church_id = test.id('churchA')) = 3,
               'M18: ... and the change is saved');
select test.lives($q$insert into public.purposes (name) values ('Coordinator purpose')$q$, 'M18: Coordinator adds a purpose');
select test.lives($q$update public.teci_stages set description = 'Foundations' where stage_no = 1$q$, 'M18: Coordinator edits a TECi stage');
select test.lives($q$insert into public.project_types (name) values ('Coordinator type')$q$, 'M18: Coordinator adds a project type');
select test.lives('update public.church_settings set serving_limit_per_month = 3', 'M18: Coordinator changes a church setting');
select test.lives('update public.church_settings set purpose_heads_read_pastoral = false', 'M18: Coordinator sets who reads pastoral notes');
select test.lives(format('update public.app_users set is_active = false where id = %L', test.id('pastoral')),
                  'M18: Coordinator switches off a senior leader''s account');
select test.lives(format('update public.app_users set is_active = true where id = %L', test.id('pastoral')),
                  'M18: ... and back on');
select test.throws(format('update public.app_users set is_active = false where id = %L', test.id('coord')),
                   'M18: Coordinator still cannot switch off their own account');
select test.throws(format('delete from public.role_assignments where user_id = %L', test.id('coord')),
                   'M18: Coordinator still cannot change their own roles');
reset role;

-- The Operations Lead's limits are unchanged: no pastoral notes, no senior roles.
select test.login('ops'); set role authenticated;
select test.throws(format('select * from public.get_pastoral_notes(%L)', test.id('p1')), 'M18: Operations Lead still cannot read pastoral notes');
select test.throws(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('finance'), 'pastoral_lead'),
                   'M18: Operations Lead still cannot give a senior role');
reset role;

-- =====================================================================================
-- Security review 10 (migration 18), SECURITY REVIEW FIX P03: the Resident Pastor safeguard
-- against every route tried in the review, the other new rights, the limits that stay, and
-- two Coordinators acting against each other.
-- =====================================================================================
-- Fixture (as the system): a former Resident Pastor whose role row was switched off; a
-- switched-off account that still holds an active Resident Pastor row; a second Coordinator;
-- an open check-in flag.
select test.login('');
do $$
declare v uuid; u text;
begin
  foreach u in array array['oldrp','coord2'] loop
    v := gen_random_uuid();
    insert into auth.users (id, email) values (v, u || '@example.org');
    insert into public.app_users (id, church_id, display_name) values (v, test.id('churchA'), initcap(u));
    insert into test.ids values (u, v);
  end loop;
  insert into public.role_assignments (church_id, user_id, role, is_active)
  values (test.id('churchA'), test.id('finance'), 'resident_pastor', false);
  insert into public.role_assignments (church_id, user_id, role) values (test.id('churchA'), test.id('oldrp'), 'resident_pastor');
  update public.app_users set is_active = false where id = test.id('oldrp');
  insert into public.role_assignments (church_id, user_id, role) values (test.id('churchA'), test.id('coord2'), 'gsquad_coordinator');
  insert into public.checkin_flags (church_id, person_id, source, raised_by) values (test.id('churchA'), test.id('p1'), 'manual', test.id('ops'))
  returning id into v;
  insert into test.ids values ('flag1', v);
end $$;

select test.login('coord'); set role authenticated;
-- The Resident Pastor role and account: every route is refused.
select test.throws(format('update public.role_assignments set is_active = true where user_id = %L and role = %L', test.id('finance'), 'resident_pastor'),
                   'P03: Coordinator cannot switch a former Resident Pastor''s role row back on');
select test.throws(format('update public.app_users set is_active = true where id = %L', test.id('oldrp')),
                   'P03: Coordinator cannot switch on an account that holds the Resident Pastor role');
select test.throws(format('delete from public.app_users where id = %L', test.id('rp')),
                   'P03: Coordinator cannot delete the Resident Pastor''s account');
select test.throws(format('update public.role_assignments set user_id = %L where user_id = %L and role = %L', test.id('teci'), test.id('rp'), 'resident_pastor'),
                   'P03: Coordinator cannot move the Resident Pastor role row to someone else');
select test.throws(format('update public.role_assignments set role = %L where user_id = %L and role = %L', 'resident_pastor', test.id('coord2'), 'gsquad_coordinator'),
                   'P03: Coordinator cannot turn another senior role into the Resident Pastor role');
-- What stays outside the Coordinator's access.
select test.ok((select count(*) from public.audit_log) = 0, 'P03: Coordinator still cannot read the audit log');
with u as (update public.core_values set name = 'Changed' where letter = 'A' returning 1)
select test.ok(count(*) = 0, 'P03: Coordinator cannot change the ASHLIE core values (Resident Pastor only)') from u;
select test.throws(format('select public.export_person(%L)', test.id('p1')), 'P03: export_person stays with the Operations Lead and Resident Pastor');
select test.throws(format('select public.anonymise_person(%L)', test.id('p1')), 'P03: anonymise_person stays with the Operations Lead');
-- The other new rights.
with u as (update public.checkin_flags set status = 'closed' where id = test.id('flag1') returning closed_by)
select test.ok(count(*) = 1 and bool_and(closed_by = test.id('coord')), 'P03: Coordinator closes a check-in flag (recorded as closer)') from u;
select test.lives($q$insert into public.church_roles (name) values ('Coordinator role')$q$, 'P03: Coordinator adds a team role');
select test.lives($q$insert into public.leadership_stages (sort_order, name) values (49, 'Coordinator stage')$q$, 'P03: Coordinator adds a leadership stage');
select test.lives($q$insert into public.reusable_blocks (name, body) values ('Coordinator block', 'Text')$q$, 'P03: Coordinator adds a reusable block');
reset role;

-- Other roles' limits are unchanged.
select test.login('ops'); set role authenticated;
with u as (update public.checkin_flags set status = 'open' where id = test.id('flag1') returning 1)
select test.ok(count(*) = 0, 'P03: Operations Lead still cannot re-open or close check-in flags') from u;
with u as (update public.teci_stages set description = 'Ops' where stage_no = 1 returning 1)
select test.ok(count(*) = 0, 'P03: Operations Lead still cannot edit TECi stages') from u;
select test.throws(format('update public.app_users set is_active = false where id = %L', test.id('coord2')),
                   'P03: Operations Lead still cannot switch off a Coordinator''s account');
reset role;
select test.login('pastoral'); set role authenticated;
with u as (update public.checkin_flags set status = 'open' where id = test.id('flag1') returning 1)
select test.ok(count(*) = 1, 'P03: Pastoral Lead still re-opens and closes check-in flags') from u;
reset role;

-- Two Coordinators: one can switch the other off (accepted by the decision), neither can touch
-- the Resident Pastor, and the Resident Pastor can always put things right.
select test.login('coord2'); set role authenticated;
select test.lives(format('update public.app_users set is_active = false where id = %L', test.id('coord')),
                  'P03: a Coordinator can switch off another Coordinator''s account');
select test.throws(format('update public.app_users set is_active = false where id = %L', test.id('rp')),
                   'P03: ... but not the Resident Pastor''s');
reset role;
select test.login('coord'); set role authenticated;
select test.throws(format('select * from public.get_pastoral_notes(%L)', test.id('p1')),
                   'P03: a switched-off Coordinator loses pastoral notes at once');
with u as (delete from public.role_assignments where user_id = test.id('coord2') returning 1)
select test.ok(count(*) = 0, 'P03: a switched-off Coordinator cannot strike back') from u;
reset role;
select test.login('rp'); set role authenticated;
select test.lives(format('update public.app_users set is_active = true where id = %L', test.id('coord')),
                  'P03: the Resident Pastor switches the Coordinator back on');
select test.lives(format('delete from public.role_assignments where user_id = %L', test.id('coord2')),
                  'P03: ... and removes the other Coordinator''s role');
reset role;

-- =====================================================================================
-- Migration 19 (slice 2): setting up a Sunday, and who can serve.
-- =====================================================================================
do $$
declare d date := (date_trunc('month', current_date) + interval '6 months')::date;
begin
  -- First Sunday six months ahead (well away from the R2 checks earlier in this file).
  perform set_config('test.sun6', (d + ((7 - extract(isodow from d)::int) % 7))::text, false);
end $$;

select test.login('ops'); set role authenticated;
select test.lives(format('select public.create_sunday_service(%L)', current_setting('test.sun6')),
                  'S2: Operations Lead sets up a Sunday (project and grid together)');
select test.ok((select p.is_sunday_service and p.level = 'church' and p.status = 'draft'
                  and (p.starts_at at time zone 'Europe/London')::time = '10:00'
                from public.service_grids g join public.projects p on p.id = g.project_id
                where g.service_date = current_setting('test.sun6')::date),
               'S2: the Sunday is a church-level draft starting at 10:00 local time');
select test.throws(format('select public.create_sunday_service(%L)', current_setting('test.sun6')),
                   'S2: only one service grid per Sunday');
select test.throws(format('select public.create_sunday_service(%L)', current_setting('test.sun6')::date + 1),
                   'S2: a service grid must be on a Sunday');
reset role;

select test.login('ul_a'); set role authenticated;
select test.throws(format('select public.create_sunday_service(%L)', current_setting('test.sun6')::date + 7),
                   'S2: a Unit Lead cannot set up a Sunday');
select test.ok((select count(*) from public.rota_candidates(test.id('A1'), current_setting('test.sun6')::date)) >= 1,
               'S2: a Unit Lead sees who can serve in their unit');
select test.ok(not exists (select 1 from public.rota_candidates(test.id('A1'), current_setting('test.sun6')::date) c
                           where c.slot_limit is null or c.slots_used is null),
               'S2: every candidate has slots used and a limit');
select test.throws(format('select * from public.rota_candidates(%L, %L)', test.id('A2'), current_setting('test.sun6')),
                   'S2: a Unit Lead cannot list another unit''s candidates');
select test.throws(format('select * from public.rota_candidates(%L, %L)', test.id('B1'), current_setting('test.sun6')),
                   'S2: no one lists another church''s unit');
reset role;
select test.login('editor'); set role authenticated;
select test.throws(format('select * from public.rota_candidates(%L, %L)', test.id('A1'), current_setting('test.sun6')),
                   'S2: a newsletter editor cannot list candidates');
reset role;
select test.login('coord'); set role authenticated;
select test.lives(format('select * from public.rota_candidates(%L, %L)', test.id('A1'), current_setting('test.sun6')),
                  'S2: the G-Squad Coordinator can list candidates');
reset role;
select test.ok(not has_function_privilege('anon', 'public.rota_candidates(uuid, date)', 'execute')
               and not has_function_privilege('anon', 'public.create_sunday_service(date, time, time, text, uuid)', 'execute'),
               'S2: neither Sunday function is open to anon');

-- Reordering and versions (migration 19).
select test.login('ops'); set role authenticated;
do $$
declare g uuid := (select id from public.service_grids where service_date = current_setting('test.sun6')::date);
begin
  insert into public.service_segments (grid_id, position, title, starts_at, duration_minutes, led_by_text) values
    (g, 1, 'Welcome', '10:00', 25, 'Hosts'), (g, 2, 'Worship', '10:25', 20, 'EPOP'), (g, 3, 'Sermon', '10:45', 60, 'Pastor');
  update public.service_grids set status = 'finalised' where id = g;
  perform set_config('test.g6', g::text, false);
end $$;
select test.lives(format('select public.reorder_segments(%L, array(select id from public.service_segments where grid_id = %L order by position desc))',
                         current_setting('test.g6'), current_setting('test.g6')),
                  'S2: Operations Lead reorders segments in one step');
select test.ok((select title from public.service_segments where grid_id = current_setting('test.g6')::uuid and position = 1) = 'Sermon',
               'S2: ... and the new order is saved');
select test.ok((select version from public.service_grids where id = current_setting('test.g6')::uuid) = 2,
               'S2: reordering a finalised grid raises the version once, not once per segment');
select test.throws(format('select public.reorder_segments(%L, array(select id from public.service_segments where grid_id = %L limit 2))',
                          current_setting('test.g6'), current_setting('test.g6')),
                   'S2: a reorder must list every segment');
reset role;
select test.login('ul_a'); set role authenticated;
select public.reorder_segments(current_setting('test.g6')::uuid,
                               array(select id from public.service_segments where grid_id = current_setting('test.g6')::uuid order by position desc));
reset role;
select test.ok((select title from public.service_segments where grid_id = current_setting('test.g6')::uuid and position = 1) = 'Sermon',
               'S2: a Unit Lead cannot reorder the grid');

-- Rota and check-in on a Sunday set up with create_sunday_service (slice 2 screens).
-- A fresh member of A1, so earlier checks (moves, anonymising) don't affect this one.
select test.login('ul_a'); set role authenticated;
select public.create_member('{"first_name":"Rota","surname":"Tester"}', test.id('A1'));
reset role;
insert into test.ids select 'rt1', id from public.people where surname = 'Tester' and first_name = 'Rota';
select test.login('ul_a'); set role authenticated;
select test.lives(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values ((select project_id from public.service_grids where id = %L), %L, %L, %L)',
                         current_setting('test.g6'), test.id('rt1'), test.id('A1'), current_setting('test.sun6')),
                  'S2: a Unit Lead fills a slot on the new Sunday from their own unit');
select test.ok(exists (select 1 from public.rota_candidates(test.id('A1'), current_setting('test.sun6')::date) c
                       where c.person_id = test.id('rt1') and c.serving_that_day and c.slots_used >= 1),
               'S2: who-can-serve shows them as serving that day');
select test.throws(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values ((select project_id from public.service_grids where id = %L), %L, %L, %L)',
                          current_setting('test.g6'), test.id('p2'), test.id('A1'), current_setting('test.sun6')),
                   'S2: a Unit Lead cannot rota someone outside their unit');
select test.lives(format($q$update public.assignments set status = 'served' where person_id = %L and serve_date = %L$q$,
                         test.id('rt1'), current_setting('test.sun6')),
                  'S2: the Unit Lead checks them in as served');
select test.lives(format($q$update public.assignments set status = 'planned' where person_id = %L and serve_date = %L$q$,
                         test.id('rt1'), current_setting('test.sun6')),
                  'S2: ... and can undo the check-in');
reset role;
select test.login('ul_b'); set role authenticated;
update public.assignments set status = 'no_show' where person_id = test.id('rt1') and serve_date = current_setting('test.sun6')::date;
reset role;
select test.ok((select status from public.assignments where person_id = test.id('rt1') and serve_date = current_setting('test.sun6')::date) = 'planned',
               'S2: another unit''s lead cannot check in this unit''s slots');

-- ---------- report ---------------------------------------------------------------------
select n, case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail
from test.results order by n;

do $$
declare f int; t int;
begin
  select count(*) filter (where not ok), count(*) into f, t from test.results;
  raise warning '% of % checks passed', t - f, t;
  if f > 0 then raise exception '% check(s) failed', f; end if;
end $$;
