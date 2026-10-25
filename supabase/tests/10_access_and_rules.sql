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
  -- Spare units, each given its own Team Lead by a later check (one Team Lead per team).
  insert into public.units (church_id, purpose_id, name) values (a, test.id('P2'), 'Car park') returning id into v; insert into test.ids values ('A4', v);
  insert into public.units (church_id, purpose_id, name) values (a, test.id('P2'), 'Media')    returning id into v; insert into test.ids values ('A5', v);
  insert into public.units (church_id, purpose_id, name) values (a, test.id('P2'), 'Kids')     returning id into v; insert into test.ids values ('A6', v);
  insert into public.units (church_id, purpose_id, name) values (a, test.id('P2'), 'Prayer')   returning id into v; insert into test.ids values ('A7', v);
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
-- SECURITY REVIEW 19 (Z04): it has no service grid, so (like any event) a slot needs a place:
-- A1 is asked for one person, any role, on each day of the month.
insert into public.team_demand (church_id, project_id, unit_id, on_date, slots_needed)
select test.id('churchA'), test.id('rota'), test.id('A1'), d::date, 1
from generate_series(date_trunc('month', current_date) + interval '3 months',
                     date_trunc('month', current_date) + interval '4 months' - interval '1 day', interval '1 day') d;

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
select test.login('ops'); set role authenticated;   -- migration 25: church projects are approved by the Operations Lead
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
select test.login('ops'); set role authenticated;   -- migration 25: church projects are approved by the Operations Lead
select test.throws($q$update public.projects set status = 'approved' where name = 'Harvest outreach'$q$,
                   'R14: a Large event needs 8 weeks lead time');
reset role;
select test.login('ops'); set role authenticated;
update public.projects set starts_at = now() + interval '70 days', ends_at = now() + interval '70 days 4 hours' where name = 'Harvest outreach';
reset role;
select test.login('ops'); set role authenticated;   -- migration 25: church projects are approved by the Operations Lead
select test.lives($q$update public.projects set status = 'approved' where name = 'Harvest outreach'$q$, 'The Operations Lead approves the rescheduled church event (their own: allowed, flagged)');
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
-- SECURITY REVIEW 18 (Y06): issues are started only through start_newsletter_issue.
select test.throws($q$insert into public.newsletter_issues (project_id, issue_month, headline, status)
                      select id, (date_trunc('month', now()) + interval '1 month')::date, 'Your finance and the Ministry', 'approved'
                      from public.projects where name = 'The Greatness Brief'$q$,
                   'Y06: editors cannot attach an issue to an existing project');
reset role;
select test.login('');   -- the issue for the checks below (system change)
insert into public.newsletter_issues (church_id, project_id, issue_month, headline)
select church_id, id, (date_trunc('month', now()) + interval '1 month')::date, 'Your finance and the Ministry'
from public.projects where name = 'The Greatness Brief';
select test.ok((select status from public.newsletter_issues) = 'draft', 'A new issue is always a draft');
select test.login('editor'); set role authenticated;
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
-- SECURITY REVIEW 18 (Y01): an approval names the version of the content it approves.
select test.throws($q$update public.newsletter_issues set status = 'awaiting_pastor'$q$, 'Y01: an approval without the content version is refused');
select test.throws($q$update public.newsletter_issues set status = 'awaiting_pastor', approved_version = md5('stale')$q$,
                   'Y01: ... and one for an out-of-date version');
update public.newsletter_issues set status = 'awaiting_pastor', approved_version = public.newsletter_issue_content(id) ->> 'version';
reset role;
select test.login('rp'); set role authenticated;
update public.newsletter_issues set status = 'approved', approved_version = public.newsletter_issue_content(id) ->> 'version';
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
select test.ok((select count(*) from public.capacity_calendar(extract(year from current_date)::int)) = 84, 'Capacity calendar: 7 units x 12 months');
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
select test.lives(format('insert into public.role_assignments (user_id, role, unit_id) values (%L, %L, %L)', test.id('finance'), 'unit_lead', test.id('A4')),
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
update public.newsletter_issues set status = 'awaiting_pastor', pastor_approved_by = test.id('coord'),
                                   approved_version = public.newsletter_issue_content(id) ->> 'version';
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
insert into public.role_assignments (church_id, user_id, role, unit_id) values (test.id('churchA'), test.id('ul_a'), 'unit_lead', test.id('A5'));
select test.login('ul_a'); set role authenticated;
select test.throws(format('update public.one_to_ones set unit_id = %L', test.id('A5')), 'F16: a one-to-one cannot move to another unit');
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
-- Migration 22: a new church starts with its default team roles; removing a church is an
-- admin (service role) job that clears its reference lists first.
select test.login('nobody');
delete from public.church_roles where church_id = (select id from public.churches where slug = 'third-church');
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
                         test.id('newlead'), 'unit_lead', test.id('A6')),
                  'S1: Coordinator makes the new leader a Unit Lead');
-- Migration 18: the Coordinator now gives and removes senior roles, except the Resident Pastor role.
select test.lives(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('newlead'), 'teci_coordinator'),
                  'M18: Coordinator gives a senior role');
select test.lives(format('delete from public.role_assignments where user_id = %L and role = %L', test.id('newlead'), 'teci_coordinator'),
                  'M18: Coordinator removes a senior role');
-- Migration 22: the Operations Lead function is held by a Purpose Head or the Resident Pastor.
select test.throws(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('newlead'), 'operations_lead'),
                   'M22: Operations Lead cannot be given to someone who is not a Purpose Head');
select test.lives(format('insert into public.role_assignments (user_id, role, purpose_id) values (%L, %L, %L)', test.id('newlead'), 'purpose_head', test.id('P2')),
                  'M22: Coordinator makes them a Purpose Head first');
select test.lives(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('newlead'), 'operations_lead'),
                  'M18: Coordinator gives the Operations Lead role');
select test.throws(format('update public.role_assignments set is_active = false where user_id = %L and role = %L', test.id('newlead'), 'purpose_head'),
                   'M22: their last Purpose Head role cannot be removed while they hold the Operations Lead function');
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
values (test.id('churchA'), test.id('teci'), 'unit_lead', test.id('A7'));
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
-- SECURITY REVIEW FIX Q06: refused with an error, not a silent "success" that changed nothing.
select test.throws(format('select public.reorder_segments(%L, array(select id from public.service_segments where grid_id = %L order by position desc))',
                          current_setting('test.g6'), current_setting('test.g6')),
                   'Q06: a Unit Lead''s reorder is refused with an error');
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
-- SECURITY REVIEW FIX Q09: served / no-show only on or after the day.
select test.throws(format($q$update public.assignments set status = 'served' where person_id = %L and serve_date = %L$q$,
                          test.id('rt1'), current_setting('test.sun6')),
                   'Q09: a slot months ahead cannot be marked served');
reset role;

-- Check-in on the Sunday just gone (set up for the purpose, with rt1 on its rota).
do $$
begin
  perform set_config('test.sunpast', (current_date - extract(isodow from current_date)::int)::text, false);
end $$;
select test.login('ops'); set role authenticated;
select test.lives(format('select public.create_sunday_service(%L)', current_setting('test.sunpast')),
                  'S2: Operations Lead sets up last Sunday (for check-in)');
reset role;
select test.login('ul_a'); set role authenticated;
select test.lives(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values ((select project_id from public.service_grids where service_date = %L), %L, %L, %L)',
                         current_setting('test.sunpast'), test.id('rt1'), test.id('A1'), current_setting('test.sunpast')),
                  'S2: a Unit Lead puts a member on last Sunday''s rota');
select test.lives(format($q$update public.assignments set status = 'served' where person_id = %L and serve_date = %L$q$,
                         test.id('rt1'), current_setting('test.sunpast')),
                  'S2: the Unit Lead checks them in as served');
select test.lives(format($q$update public.assignments set status = 'planned' where person_id = %L and serve_date = %L$q$,
                         test.id('rt1'), current_setting('test.sunpast')),
                  'S2: ... and can undo the check-in');
reset role;
select test.login('ul_b'); set role authenticated;
update public.assignments set status = 'no_show' where person_id = test.id('rt1') and serve_date = current_setting('test.sunpast')::date;
reset role;
select test.ok((select status from public.assignments where person_id = test.id('rt1') and serve_date = current_setting('test.sunpast')::date) = 'planned',
               'S2: another unit''s lead cannot check in this unit''s slots');
select test.login('ul_a'); set role authenticated;
select test.lives(format($q$update public.assignments set status = 'no_show' where person_id = %L and serve_date = %L$q$,
                         test.id('rt1'), current_setting('test.sunpast')),
                  'S2: the Unit Lead records a no-show');
reset role;

-- =====================================================================================
-- Security review 11 (slice 2): grid versions (R11), deletes, slot rules.
-- =====================================================================================
-- A second Sunday (seven months ahead), finalised with one segment, then approved.
do $$
declare d date := (date_trunc('month', current_date) + interval '7 months')::date;
begin
  perform set_config('test.sun7', (d + ((7 - extract(isodow from d)::int) % 7))::text, false);
end $$;
select test.login('ops'); set role authenticated;
do $$
declare g uuid := public.create_sunday_service(current_setting('test.sun7')::date);
begin
  insert into public.service_segments (grid_id, position, title, starts_at, duration_minutes, led_by_text)
  values (g, 1, 'Welcome', '10:00', 10, 'Hosts');
  update public.service_grids set status = 'finalised' where id = g;
  perform set_config('test.g7', g::text, false);
end $$;
reset role;
-- Approves a grid as the Resident Pastor.
create function test.approve(g uuid) returns void language plpgsql as $$
begin
  perform test.login('rp');
  set local role authenticated;
  update public.service_grids set status = 'approved' where id = g;
  reset role;
end $$;
select test.approve(current_setting('test.g6')::uuid);
select test.approve(current_setting('test.g7')::uuid);
select set_config('test.v6', (select version from public.service_grids where id = current_setting('test.g6')::uuid)::text, false);
select set_config('test.v7', (select version from public.service_grids where id = current_setting('test.g7')::uuid)::text, false);

select test.login('ops'); set role authenticated;
-- Q02: saving a segment without changing it is not a change.
update public.service_segments set title = title, duration_minutes = duration_minutes where grid_id = current_setting('test.g6')::uuid;
select test.ok((select status = 'approved' and version = current_setting('test.v6')::int
                from public.service_grids where id = current_setting('test.g6')::uuid),
               'Q02: an update that changes nothing leaves an approved grid approved');
-- ... but a real change still makes one new version.
update public.service_segments set title = title || '!' where grid_id = current_setting('test.g6')::uuid;
select test.ok((select status = 'finalised' and version = current_setting('test.v6')::int + 1 and approved_by is null
                from public.service_grids where id = current_setting('test.g6')::uuid),
               'Q02: a real change to an approved grid still needs re-approval (one new version)');
reset role;
select test.approve(current_setting('test.g6')::uuid);
select set_config('test.v6', (select version from public.service_grids where id = current_setting('test.g6')::uuid)::text, false);

-- Q01: moving a segment from one approved grid to another changes BOTH grids.
select test.login('ops'); set role authenticated;
update public.service_segments set grid_id = current_setting('test.g7')::uuid, position = 2
 where grid_id = current_setting('test.g6')::uuid and position = 3;
reset role;
select test.ok((select status = 'finalised' and version = current_setting('test.v6')::int + 1
                from public.service_grids where id = current_setting('test.g6')::uuid),
               'Q01: taking a segment out of an approved grid needs re-approval of that grid');
select test.ok((select status = 'finalised' and version = current_setting('test.v7')::int + 1
                from public.service_grids where id = current_setting('test.g7')::uuid),
               'Q01: ... and of the grid it moved to');

-- Q04: back to draft starts the next version.
select set_config('test.v7', (select version from public.service_grids where id = current_setting('test.g7')::uuid)::text, false);
select test.login('ops'); set role authenticated;
update public.service_grids set status = 'draft' where id = current_setting('test.g7')::uuid;
update public.service_grids set status = 'finalised' where id = current_setting('test.g7')::uuid;
reset role;
select test.ok((select version = current_setting('test.v7')::int + 1 from public.service_grids where id = current_setting('test.g7')::uuid),
               'Q04: a grid sent back to draft and finalised again has a new version number');

-- Q05: changing a reusable block's text sends coming grids it is attached to back for approval,
-- even when the Coordinator makes the change.
select test.login('ops'); set role authenticated;
insert into public.service_grid_blocks (grid_id, block_id, position)
values (current_setting('test.g7')::uuid, (select id from public.reusable_blocks where name = 'Coordinator block'), 1);
reset role;
select test.approve(current_setting('test.g7')::uuid);
select set_config('test.v7', (select version from public.service_grids where id = current_setting('test.g7')::uuid)::text, false);
select test.login('coord'); set role authenticated;
select test.lives($q$update public.reusable_blocks set body = 'New wording' where name = 'Coordinator block'$q$,
                  'Q05: the Coordinator can still edit a block attached to an approved grid');
reset role;
select test.ok((select status = 'finalised' and version = current_setting('test.v7')::int + 1 and approved_by is null
                from public.service_grids where id = current_setting('test.g7')::uuid),
               'Q05: ... and the grid it prints in needs re-approval');
select test.login('coord'); set role authenticated;
update public.reusable_blocks set body = body where name = 'Coordinator block';
reset role;
select test.ok((select version = current_setting('test.v7')::int + 1 from public.service_grids where id = current_setting('test.g7')::uuid),
               'Q05: saving a block unchanged does not');
-- The bump route cannot be used to approve or to edit anything else.
select test.login('coord'); set role authenticated;
with u as (update public.service_grids set version = version + 1 where id = current_setting('test.g7')::uuid returning 1)
select test.ok(count(*) = 0, 'Q05: the Coordinator still cannot update a grid directly') from u;
reset role;
select test.login('rp'); set role authenticated;
select test.throws(format($q$update public.service_grids set status = 'finalised', version = version + 1, theme = 'Changed' where id = %L$q$,
                          current_setting('test.g7')),
                   'Q05: a "new version" update that also edits the grid is still the Operations Lead''s');
reset role;

-- Q03: an approved grid and served history cannot be deleted through the Sunday's project.
select test.approve(current_setting('test.g7')::uuid);
select test.login('ops'); set role authenticated;
select test.throws(format('delete from public.projects where id = (select project_id from public.service_grids where id = %L)',
                          current_setting('test.g7')),
                   'Q03: deleting a Sunday''s draft project cannot remove its approved grid');
with d as (delete from public.projects where id = (select project_id from public.service_grids where service_date = current_setting('test.sunpast')::date) returning 1)
select test.ok(count(*) = 0, 'Q03: a project with served or no-show slots cannot be deleted') from d;
reset role;
select test.ok(exists (select 1 from public.service_grids where id = current_setting('test.g7')::uuid)
               and exists (select 1 from public.assignments where person_id = test.id('rt1') and serve_date = current_setting('test.sunpast')::date),
               'Q03: ... both are still there');
select test.login('ops'); set role authenticated;
select test.lives(format('select public.create_sunday_service(%L)', current_setting('test.sun7')::date + 7),
                  'Q03: (a fresh Sunday)');
with d as (delete from public.projects where id = (select project_id from public.service_grids where service_date = current_setting('test.sun7')::date + 7) returning 1)
select test.ok(count(*) = 1, 'Q03: an unused draft Sunday can still be deleted') from d;
reset role;

-- Q07: project dates are UK dates. An event from 00:30 to 02:00 UK time on a summer Saturday
-- starts on Friday evening UTC.
set timezone = 'UTC';
select test.login('ops'); set role authenticated;
insert into public.projects (name, level, starts_at, ends_at)
values ('Night of worship', 'church', timestamptz '2027-06-12 00:30 Europe/London', timestamptz '2027-06-12 02:00 Europe/London');
-- SECURITY REVIEW 19 (Z04): a booking fills a place on an approved project, so the event is
-- approved and asks A1 for someone (system change).
reset role; select test.login('');
update public.projects set status = 'approved' where name = 'Night of worship';
insert into public.team_demand (church_id, project_id, unit_id, on_date, slots_needed)
select church_id, id, test.id('A1'), '2027-06-12', 1 from public.projects where name = 'Night of worship';
select test.login('ops'); set role authenticated;
select test.throws(format($q$insert into public.assignments (project_id, person_id, unit_id, serve_date) values ((select id from public.projects where name = 'Night of worship'), %L, %L, '2027-06-11')$q$,
                          test.id('rt1'), test.id('A1')),
                   'Q07: the day before (UK) is outside the event');
select test.lives(format($q$insert into public.assignments (project_id, person_id, unit_id, serve_date) values ((select id from public.projects where name = 'Night of worship'), %L, %L, '2027-06-12')$q$,
                         test.id('rt1'), test.id('A1')),
                  'Q07: the UK date of the event is inside it');
reset role;
reset timezone;

-- Q08: a Unit Lead cannot move a live slot to another project without the checks.
select test.login('ul_a'); set role authenticated;
select test.throws(format($q$update public.assignments set project_id = (select id from public.projects where name = 'Night of worship') where person_id = %L and serve_date = %L$q$,
                          test.id('rt1'), current_setting('test.sun6')),
                   'Q08: moving a slot to a project whose dates do not include it is refused');
reset role;

-- =====================================================================================
-- Migration 20 (slice 3): dashboards.
-- =====================================================================================
select test.login('ul_a'); set role authenticated;
select test.lives('select public.church_dashboard()', 'S3: a Unit Lead sees the church dashboard');
select test.ok((select (public.church_dashboard() ->> 'volunteers')::int) >= 1, 'S3: the church dashboard counts volunteers');
select test.ok(not (public.church_dashboard()::text ~* '(email|surname|first_name|salvation|baptism|note)'),
               'S3: the church dashboard carries no names or personal fields');
select test.lives(format('select public.unit_dashboard(%L)', test.id('A1')), 'S3: a Unit Lead sees their unit''s dashboard');
select test.throws(format('select public.unit_dashboard(%L)', test.id('A2')), 'S3: a Unit Lead cannot see another unit''s dashboard');
select test.ok(not (public.unit_dashboard(test.id('A1'))::text ~* '(email|surname|salvation|baptism|feeling|notes)'),
               'S3: the unit dashboard carries no names, faith fields or one-to-one content');
select test.ok(jsonb_array_length(public.unit_dashboard(test.id('A1')) -> 'members') >= 1, 'S3: the unit dashboard lists member figures');
reset role;
select test.login('editor'); set role authenticated;
select test.throws('select public.church_dashboard()', 'S3: a newsletter editor does not see the church dashboard');
select test.throws(format('select public.unit_dashboard(%L)', test.id('A1')), 'S3: ... nor a unit dashboard');
reset role;
select test.login('ops'); set role authenticated;
select test.throws(format('select public.unit_dashboard(%L)', test.id('B1')), 'S3: no one sees another church''s unit');
select test.lives(format('select public.unit_dashboard(%L)', test.id('A2')), 'S3: the Operations Lead sees any unit in their church');
reset role;
select test.ok(not has_function_privilege('anon', 'public.church_dashboard()', 'execute')
               and not has_function_privilege('anon', 'public.unit_dashboard(uuid)', 'execute'),
               'S3: neither dashboard is open to anon');

-- Security review 12.
-- R01: one-to-one dates and counts follow the one-to-ones read rule (writer, the unit's Purpose
-- Head, Coordinator, Resident Pastor). The Operations Lead cannot read one-to-ones, so the
-- dashboards must not tell them when (or whether) one was held.
-- (Earlier checks anonymised p1 and p3, which removed their one-to-ones, so ul_a writes a
-- fresh one for a current member of A1.)
insert into test.ids
select 's3_member', m.person_id from public.unit_memberships m join public.people p on p.id = m.person_id
where m.unit_id = test.id('A1') and m.status = 'active' and p.status = 'active' and p.anonymised_at is null
order by p.first_name limit 1;
select test.login('ul_a'); set role authenticated;
select test.lives(format('insert into public.one_to_ones (person_id, unit_id, quarter_start, held_on, feeling) values (%L, %L, %L, %L, %L)',
                         test.id('s3_member'), test.id('A1'), date_trunc('quarter', current_date)::date, current_date, 'doing_well'),
                  'S3/R01 fixture: the Unit Lead records a one-to-one');
reset role;
select test.login('ops'); set role authenticated;
select test.ok(not exists (select 1 from jsonb_array_elements(public.unit_dashboard(test.id('A1')) -> 'members') m
                           where m ->> 'last_one_to_one' is not null),
               'S3/R01: the Operations Lead sees no one-to-one dates on a unit dashboard');
select test.ok(public.unit_dashboard(test.id('A1')) -> 'one_to_ones_quarter' = 'null'::jsonb
               and public.unit_dashboard(test.id('A1')) -> 'one_to_ones_visible' = 'false'::jsonb,
               'S3/R01: ... nor a one-to-one count (null, and marked not visible, rather than a misleading 0)');
select test.ok(not exists (select 1 from jsonb_array_elements(public.church_dashboard() -> 'units_table') u
                           where u -> 'one_to_ones_quarter' <> 'null'::jsonb),
               'S3/R01: ... nor one-to-one counts per unit on the church dashboard');
reset role;
-- Migration 22 (no co-leads): a second Team Lead of A1 is refused, even as a system change.
-- The Deputy Team Lead of A1 sees the unit but no one-to-one dates or counts.
select test.login('nobody');   -- fixture changes below are system changes, not a user's
select test.throws(format('insert into public.role_assignments (church_id, user_id, role, unit_id) values (%L, %L, %L, %L)',
                          test.id('churchA'), test.id('ul_b'), 'unit_lead', test.id('A1')),
                   'M22: a team has one Team Lead (no co-leads)');
insert into public.role_assignments (church_id, user_id, role, unit_id) values (test.id('churchA'), test.id('ul_b'), 'deputy_unit_lead', test.id('A1'));
select test.login('ul_b'); set role authenticated;
select test.ok(not exists (select 1 from jsonb_array_elements(public.unit_dashboard(test.id('A1')) -> 'members') m
                           where m ->> 'last_one_to_one' is not null)
               and public.unit_dashboard(test.id('A1')) -> 'one_to_ones_quarter' = 'null'::jsonb
               and public.unit_dashboard(test.id('A1')) -> 'one_to_ones_visible' = 'false'::jsonb,
               'M22: the Deputy Team Lead opens the unit dashboard but sees no one-to-one dates or counts');
reset role;
select test.login('ul_a'); set role authenticated;
select test.ok(exists (select 1 from jsonb_array_elements(public.unit_dashboard(test.id('A1')) -> 'members') m
                       where m ->> 'person_id' = test.id('s3_member')::text and m ->> 'last_one_to_one' is not null)
               and (public.unit_dashboard(test.id('A1')) ->> 'one_to_ones_quarter')::int >= 1,
               'S3/R01: the writing Unit Lead still sees their one-to-one date and count');
reset role;
select test.login('coord'); set role authenticated;
select test.ok((select (u ->> 'one_to_ones_quarter')::int from jsonb_array_elements(public.church_dashboard() -> 'units_table') u
                where u ->> 'unit_id' = test.id('A1')::text) >= 1,
               'S3/R01: the G-Squad Coordinator still sees one-to-one counts per unit');
reset role;
select test.login('ph'); set role authenticated;
select test.ok((select u -> 'one_to_ones_quarter' from jsonb_array_elements(public.church_dashboard() -> 'units_table') u
                where u ->> 'unit_id' = test.id('A2')::text) = 'null'::jsonb
               and (select (u ->> 'one_to_ones_quarter')::int from jsonb_array_elements(public.church_dashboard() -> 'units_table') u
                    where u ->> 'unit_id' = test.id('A1')::text) >= 1,
               'S3/R01: a Purpose Head sees one-to-one counts for their own units only');
reset role;
-- R02: the new helpers bypass row-level security and take any id, so only the dashboards
-- (running as the owner) may call them.
select test.ok(not has_function_privilege('authenticated', 'app.engagement_of(uuid)', 'execute')
               and not has_function_privilege('authenticated', 'app.unit_open_slots(uuid, date, date)', 'execute'),
               'S3/R02: signed-in users cannot call the dashboard helpers directly');
select test.login('nobody');
-- R03: the church dashboard counts open check-ins only for current members (not anonymised
-- or left), the same people as every other figure on it.
insert into public.checkin_flags (church_id, person_id, source, raised_by)
select test.id('churchA'), p.id, 'manual', test.id('ops') from public.people p
where p.church_id = test.id('churchA') and p.status = 'left' and p.anonymised_at is null limit 1;
select test.login('ops'); set role authenticated;
select test.ok((public.church_dashboard() ->> 'checkins_open')::int
               = (select count(*) from public.checkin_flags f join public.people p on p.id = f.person_id
                  where p.church_id = test.id('churchA') and f.status = 'open' and p.status <> 'left' and p.anonymised_at is null)
               and exists (select 1 from public.checkin_flags f join public.people p on p.id = f.person_id
                           where f.status = 'open' and p.status = 'left'),
               'S3/R03: check-ins of people who have left are not counted');
reset role;

-- ---------- Migration 22: team roles, Deputy Team Lead, Purpose Head rule, TECi ----------
-- ul_b is the Deputy Team Lead of A1 (set above). s3_member is an active member of A1.
select test.login('nobody');
create temp table m22_expect as
  select (select count(*) from public.assignments where unit_id = test.id('A1')) as a1_assignments,
         (select area from public.people where id = test.id('s3_member')) as area;
grant select on m22_expect to authenticated;
select test.login('ul_b'); set role authenticated;
select test.ok(exists (select 1 from public.people where id = test.id('s3_member')),
               'M22: the Deputy sees the members of their team');
select test.ok(exists (select 1 from public.unit_memberships where unit_id = test.id('A1') and person_id = test.id('s3_member')),
               'M22: ... and their memberships');
select test.lives(format('select * from public.get_person_faith(%L)', test.id('s3_member')),
                  'M22: ... and their faith journey (logged)');
select test.ok((select count(*) from public.assignments where unit_id = test.id('A1')) = (select a1_assignments from m22_expect),
               'M22: ... and the team''s rota');
select test.ok(not exists (select 1 from public.one_to_ones where unit_id = test.id('A1')),
               'M22: ... but not its one-to-ones');
select test.lives('select public.church_dashboard()', 'M22: the Deputy sees the Church Dashboard, like the Team Lead');
select test.lives('select * from public.capacity_calendar(2027)', 'M22: ... and the capacity calendar');
-- View-only: updates find no rows, inserts are refused.
update public.people set area = 'DEPUTY' where id = test.id('s3_member');
update public.unit_memberships set leadership_stage_id = null where unit_id = test.id('A1');
reset role;
select test.login('nobody');
select test.ok((select area from public.people where id = test.id('s3_member')) is not distinct from (select area from m22_expect),
               'M22: the Deputy cannot edit a member record');
select test.ok(exists (select 1 from public.unit_memberships where unit_id = test.id('A1') and leadership_stage_id is not null)
               or not exists (select 1 from public.leadership_stages),
               'M22: ... nor change memberships');
select test.login('ul_b'); set role authenticated;
select test.throws(format($q$insert into public.checkin_flags (person_id, source, status, raised_by) values (%L, 'manual', 'open', %L)$q$,
                          test.id('s3_member'), test.id('ul_b')),
                   'M22: the Deputy does not raise check-in flags');
select test.throws(format($q$insert into public.one_to_ones (person_id, unit_id, lead_user_id, quarter_start, held_on, feeling) values (%L, %L, %L, date_trunc('quarter', current_date)::date, current_date, 'doing_well')$q$,
                          test.id('s3_member'), test.id('A1'), test.id('ul_b')),
                   'M22: ... nor write one-to-ones');
select test.throws(format('select public.set_person_faith(%L, null, false, null, false, null, false, null)', test.id('s3_member')),
                   'M22: ... nor record faith fields');
reset role;

-- Role rules, as the G-Squad Coordinator.
select test.login('coord'); set role authenticated;
select test.throws(format('insert into public.role_assignments (user_id, role, unit_id) values (%L, %L, %L)', test.id('ph'), 'unit_lead', test.id('A1')),
                   'M22: a team cannot be given a second Team Lead');
select test.throws(format('insert into public.role_assignments (user_id, role, unit_id) values (%L, %L, %L)', test.id('ul_a'), 'deputy_unit_lead', test.id('A1')),
                   'M22: the Team Lead is not also the Deputy of the same team');
select test.throws(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('pastoral'), 'gsquad_coordinator'),
                   'M22: the G-Squad Coordinator function needs a Purpose Head or the Resident Pastor');
select test.lives(format('insert into public.role_assignments (user_id, role) values (%L, %L)', test.id('ph'), 'operations_lead'),
                  'M22: a Purpose Head can be given the Operations Lead function');
select test.throws(format('delete from public.role_assignments where user_id = %L and role = %L', test.id('ph'), 'purpose_head'),
                   'M22: ... and keeps their Purpose Head role while they hold it');
select test.lives(format('delete from public.role_assignments where user_id = %L and role = %L', test.id('ph'), 'operations_lead'),
                  'M22: the function can be removed first');
reset role;

-- Default team roles.
select test.ok((select count(*) from public.church_roles where church_id = test.id('churchA') and default_key is not null) = 4
               and (select count(*) from public.church_roles where church_id = test.id('churchB') and default_key is not null) = 4,
               'M22: every church has the four default team roles');
select test.login('coord'); set role authenticated;
select test.throws($q$update public.church_roles set name = 'Captain' where default_key = 'team_lead'$q$,
                   'M22: a default role cannot be renamed');
select test.throws($q$update public.church_roles set is_active = false where default_key = 'member'$q$,
                   'M22: ... or switched off');
select test.throws($q$delete from public.church_roles where default_key = 'welfare_pastoral'$q$,
                   'M22: ... or deleted');
select test.throws($q$insert into public.church_roles (name, default_key) values ('Extra lead', 'team_lead')$q$,
                   'M22: no one makes their own default roles');
select test.lives($q$update public.church_roles set description = 'Leads and cares for the team' where default_key = 'team_lead'$q$,
                  'M22: a default role''s description can change');
select test.lives($q$insert into public.church_roles (name, permanence) values ('Harvest steward', 'project')$q$,
                  'M22: a project (temporary) role can be added');
reset role;
select test.login('ul_a'); set role authenticated;
select test.throws(format($q$update public.unit_memberships set church_role_id = (select id from public.church_roles where name = 'Harvest steward')
                             where unit_id = %L and person_id = %L$q$, test.id('A1'), test.id('s3_member')),
                   'M22: a project role is not a standing team role');
select test.lives(format($q$update public.unit_memberships set church_role_id = (select id from public.church_roles where default_key = 'team_lead')
                            where unit_id = %L and person_id = %L$q$, test.id('A1'), test.id('s3_member')),
                  'M22: the Team Lead label is given in the team');
select test.ok((select is_team_leader from public.unit_memberships where unit_id = test.id('A1') and person_id = test.id('s3_member')),
               'M22: ... and the team leader flag follows it');
select test.throws(format($q$update public.unit_memberships set church_role_id = (select id from public.church_roles where default_key = 'team_lead')
                             where unit_id = %L and person_id <> %L and status <> 'ended'$q$, test.id('A1'), test.id('s3_member')),
                   'M22: a second member cannot also be labelled Team Lead');
select test.lives(format($q$update public.unit_memberships set church_role_id = (select id from public.church_roles where default_key = 'member')
                            where unit_id = %L and person_id = %L$q$, test.id('A1'), test.id('s3_member')),
                  'M22: changing the label back to Member');
select test.ok(not (select is_team_leader from public.unit_memberships where unit_id = test.id('A1') and person_id = test.id('s3_member')),
               'M22: ... clears the team leader flag');
reset role;

-- TECi: verification and adding TECi graduates who are not in a team yet.
select test.login('teci'); set role authenticated;
select test.throws('select public.church_dashboard()', 'M22: the TECi Coordinator does not see the Church Dashboard');
select test.lives(format($q$update public.people set teci_stage_id = (select id from public.teci_stages where church_id = %L and stage_no = 1),
                            teci_verified_at = '2000-01-01' where id = %L$q$, test.id('churchA'), test.id('s3_member')),
                  'M22: the TECi Coordinator sets and verifies a stage');
select test.ok((select teci_verified_by = test.id('teci') and teci_verified_at > now() - interval '1 minute'
                from public.people where id = test.id('s3_member')),
               'M22: ... recorded as them, now (a supplied date is ignored)');
select test.lives(format($q$update public.people set teci_stage_id = (select id from public.teci_stages where church_id = %L and stage_no = 2)
                            where id = %L$q$, test.id('churchA'), test.id('s3_member')),
                  'M22: changing the stage without verifying');
select test.ok((select teci_verified_at is null and teci_verified_by is null from public.people where id = test.id('s3_member')),
               'M22: ... clears the old verification');
select test.lives(format($q$select public.create_member('{"first_name":"Tola","surname":"Graduate","teci_stage_id":"%s","teci_verified_at":"2000-01-01"}', null)$q$,
                         (select id from public.teci_stages where church_id = test.id('churchA') and stage_no = 1)),
                  'M22: the TECi Coordinator adds a TECi graduate who is not in a team yet');
select test.ok((select teci_verified_by = test.id('teci') from public.people where surname = 'Graduate'),
               'M22: ... verified by them');
select test.ok(not exists (select 1 from public.unit_memberships m join public.people p on p.id = m.person_id where p.surname = 'Graduate'),
               'M22: ... with no team');
select test.throws($q$select public.create_member('{"first_name":"No","surname":"Stage"}', null)$q$,
                   'M22: ... but only with the TECi stage they have completed');
select test.throws(format($q$select public.create_member('{"first_name":"In","surname":"Team","teci_stage_id":"%s"}', %L)$q$,
                          (select id from public.teci_stages where church_id = test.id('churchA') and stage_no = 1), test.id('A1')),
                   'M22: the TECi Coordinator does not add people to teams');
reset role;
select test.login('coord'); set role authenticated;   -- an editor of the record, but not the TECi Coordinator
select test.throws(format($q$update public.people set teci_verified_at = now() where id = %L$q$, test.id('s3_member')),
                   'M22: only the TECi Coordinator verifies a TECi stage');
reset role;
select test.login('ul_a'); set role authenticated;
select test.throws($q$select public.create_member('{"first_name":"No","surname":"Team"}', null)$q$,
                   'M22: a Team Lead still adds members to a team');
reset role;

-- ---------- Security review 13 ----------------------------------------------------------
-- S01: a Team Lead who becomes the Deputy of the same team stops reading the one-to-ones they
-- wrote (ul_a wrote one for s3_member above). Restored afterwards.
select test.login('nobody');
update public.role_assignments set is_active = false where user_id = test.id('ul_a') and role = 'unit_lead' and unit_id = test.id('A1');
insert into public.role_assignments (church_id, user_id, role, unit_id) values (test.id('churchA'), test.id('ul_a'), 'deputy_unit_lead', test.id('A1'));
select test.login('ul_a'); set role authenticated;
select test.ok(not exists (select 1 from public.one_to_ones where unit_id = test.id('A1')),
               'S13/S01: a former Team Lead who is now the Deputy no longer reads the one-to-ones they wrote');
select test.ok(not exists (select 1 from jsonb_array_elements(public.unit_dashboard(test.id('A1')) -> 'members') m
                           where m ->> 'last_one_to_one' is not null),
               'S13/S01: ... nor their dates on the unit dashboard');
reset role;
select test.login('nobody');
delete from public.role_assignments where user_id = test.id('ul_a') and role = 'deputy_unit_lead' and unit_id = test.id('A1');
update public.role_assignments set is_active = true where user_id = test.id('ul_a') and role = 'unit_lead' and unit_id = test.id('A1');
select test.login('ul_a'); set role authenticated;
select test.ok(exists (select 1 from public.one_to_ones where unit_id = test.id('A1')),
               'S13/S01: ... and reads them again as the Team Lead');
reset role;

-- S02: one Team Lead label per team even when the trigger's check is skipped or raced (a
-- system change skips it; two requests at once both pass it). The unique index decides.
select test.login('nobody');
select test.throws(format($q$update public.unit_memberships set church_role_id = (select id from public.church_roles where church_id = %L and default_key = 'team_lead')
                             where unit_id = %L and status <> 'ended'$q$, test.id('churchA'), test.id('A1')),
                   'S13/S02: two live memberships of a team cannot both carry the Team Lead label');
-- S05: no membership is flagged team leader without the Team Lead label.
select test.ok(not exists (select 1 from public.unit_memberships m
                           where m.is_team_leader and not exists (select 1 from public.church_roles r
                                                                  where r.id = m.church_role_id and r.default_key = 'team_lead')),
               'S13/S05: the team leader flag always matches the Team Lead label');
-- S03: the Purpose Head rule serialises changes per person (two sessions are needed to race
-- it, so this checks the lock is there; the race itself was reproduced by hand).
select test.ok((select prosrc ~ 'pg_advisory_xact_lock' from pg_proc where oid = 'app.role_rules()'::regprocedure),
               'S13/S03: role changes for one person are serialised');

-- S04: the TECi route records a name, email and stage only.
select test.login('teci'); set role authenticated;
select test.throws(format($q$select public.create_member('{"first_name":"Too","surname":"Much","birth_day":3,"birth_month":4,"marital_status":"married","teci_stage_id":"%s"}', null)$q$,
                          (select id from public.teci_stages where church_id = test.id('churchA') and stage_no = 1)),
                   'S13/S04: the TECi Coordinator cannot record birthdays or family details');
select test.throws(format($q$insert into public.people (first_name, surname, area, teci_stage_id) values ('Too', 'Much', 'Salford', %L)$q$,
                          (select id from public.teci_stages where church_id = test.id('churchA') and stage_no = 1)),
                   'S13/S04: ... nor other details by a direct insert');
select test.lives(format($q$select public.create_member('{"first_name":"Just","surname":"Enough","email":"just.enough@example.org","teci_stage_id":"%s"}', null)$q$,
                         (select id from public.teci_stages where church_id = test.id('churchA') and stage_no = 1)),
                  'S13/S04: ... but records a name, email and stage');
reset role;
select test.login('ops'); set role authenticated;
select test.lives(format($q$select public.create_member('{"first_name":"Ops","surname":"Graduate","area":"Rochdale","teci_stage_id":"%s"}', null)$q$,
                         (select id from public.teci_stages where church_id = test.id('churchA') and stage_no = 1)),
                  'S13/S04: the Operations Lead''s full member entry is unchanged');
reset role;

-- S07: the default role names are kept for the default roles.
select test.login('coord'); set role authenticated;
select test.throws(format($q$insert into public.church_roles (name, unit_id) values ('team lead', %L)$q$, test.id('A1')),
                   'S13/S07: a team''s own role cannot be called Team Lead');
select test.lives(format($q$insert into public.church_roles (name, unit_id) values ('Vision mixer', %L)$q$, test.id('A1')),
                  'S13/S07: a team''s own role with its own name is fine');
select test.throws($q$update public.church_roles set name = 'Deputy Team Lead' where name = 'Vision mixer'$q$,
                   'S13/S07: ... but it cannot be renamed to a default role''s name');
reset role;

-- ---------- Migration 23: bulk upload of members ----------
select test.login('coord'); set role authenticated;
select test.ok((public.import_members(format($j$[
    {"row": 2, "person": {"first_name": "Bulk", "surname": "One", "email": "bulk.one@example.org"}, "unit_id": "%s",
     "church_role_id": "%s"},
    {"row": 3, "person": {"first_name": "Bulk", "surname": "Two"}, "unit_id": "%s",
     "faith": {"water_baptism": true, "water_baptism_date": "2026-06-01"}}
  ]$j$, test.id('A1'), (select id from public.church_roles where church_id = test.id('churchA') and default_key = 'member'), test.id('A2'))::jsonb) ->> 'added')::int = 2,
  'M23: the G-Squad Coordinator uploads members into any team');
select test.ok((select count(*) from public.people where surname in ('One', 'Two') and first_name = 'Bulk') = 2
               and exists (select 1 from public.unit_memberships m join public.people p on p.id = m.person_id
                           where p.surname = 'One' and m.unit_id = test.id('A1')),
               'M23: ... each with their team membership');
select test.lives(format('select * from public.get_person_faith(%L)', (select id from public.people where first_name = 'Bulk' and surname = 'Two')),
                  'M23: ... and faith fields through the logged function');
-- All or nothing: one bad row and nothing is saved, with the row named.
select test.throws(format($q$select public.import_members('[
    {"row": 2, "person": {"first_name": "Good", "surname": "Row"}, "unit_id": "%s"},
    {"row": 3, "person": {"first_name": "", "surname": "Bad"}, "unit_id": "%s"}]'::jsonb)$q$, test.id('A1'), test.id('A1')),
  'M23: a bad row stops the whole upload');
select test.ok(not exists (select 1 from public.people where first_name = 'Good' and surname = 'Row'),
               'M23: ... and the good rows are not saved');
do $$
declare d text;
begin
  perform public.import_members(format('[{"row": 7, "person": {"first_name": "X"}, "unit_id": "%s"}]', test.id('A1'))::jsonb);
exception when others then
  get stacked diagnostics d = pg_exception_detail;
  perform test.ok((d::jsonb -> 0 ->> 'row')::int = 7, 'M23: the error lists the spreadsheet row that failed');
end $$;
select test.ok((public.import_members(format('[{"row": 2, "person": {"first_name": "Bulk", "surname": "Again", "email": "BULK.ONE@example.org"}, "unit_id": "%s"}]', test.id('A1'))::jsonb, true) ->> 'skipped')::int = 1,
               'M23: someone already recorded (same email) is skipped when asked');
select test.throws(format('select public.import_members(%L::jsonb)',
                          (select jsonb_agg(jsonb_build_object('person', jsonb_build_object('first_name', 'N', 'surname', 'S' || g), 'unit_id', test.id('A1'))) from generate_series(1, 501) g)),
                   'M23: at most 500 rows per upload');
reset role;

-- A Team Lead uploads into their own team only.
select test.login('ul_a'); set role authenticated;
select test.lives(format($q$select public.import_members('[{"row": 2, "person": {"first_name": "Lead", "surname": "Upload"}, "unit_id": "%s"}]'::jsonb)$q$, test.id('A1')),
                  'M23: a Team Lead uploads into their own team');
select test.throws(format($q$select public.import_members('[{"row": 2, "person": {"first_name": "Other", "surname": "Team"}, "unit_id": "%s"}]'::jsonb)$q$, test.id('A2')),
                   'M23: ... but not into another team');
reset role;

-- The Operations Lead uploads, but faith fields stay with the Coordinator and Team Lead.
select test.login('ops'); set role authenticated;
select test.throws(format($q$select public.import_members('[{"row": 2, "person": {"first_name": "Ops", "surname": "Faith"}, "unit_id": "%s", "faith": {"water_baptism": true}}]'::jsonb)$q$, test.id('A1')),
                   'M23: the Operations Lead cannot upload faith fields');
reset role;
select test.login('editor'); set role authenticated;
select test.throws(format($q$select public.import_members('[{"row": 2, "person": {"first_name": "No", "surname": "Right"}, "unit_id": "%s"}]'::jsonb)$q$, test.id('A1')),
                   'M23: a newsletter editor cannot upload members');
reset role;
set role anon;
select test.throws($q$select public.import_members('[]'::jsonb)$q$, 'M23: signed-out visitors cannot call the upload');
reset role;

-- ---------- Security review 14: bulk upload ----------
-- T01: every person added by an upload is in the audit log (who, record, unit; no personal data).
select test.login('coord'); set role authenticated;
select public.import_members(format('[{"row": 2, "person": {"first_name": "Audit", "surname": "One"}, "unit_id": "%s"},
                                      {"row": 3, "person": {"first_name": "Audit", "surname": "Two"}, "unit_id": "%s"}]',
                                    test.id('A1'), test.id('A2'))::jsonb);
reset role;
select test.ok((select count(*) from public.audit_log a join public.people p on p.id = a.record_id
                where a.action = 'import_member' and a.table_name = 'people' and p.first_name = 'Audit'
                  and a.actor_id = test.id('coord') and a.detail ? 'unit_id' and not a.detail ? 'first_name') = 2,
               'S14/T01: each person added by an upload is audited, without personal data');
-- T03: an odd "row" value still gives the row list, not a bare cast error.
select test.login('coord'); set role authenticated;
do $$
declare d text;
begin
  perform public.import_members(format('[{"row": 2.5, "person": {"first_name": "X"}, "unit_id": "%s"},
                                         {"row": 1e12, "person": {"first_name": "Y"}, "unit_id": "%s"},
                                         {"row": "7", "person": {"first_name": "Z"}, "unit_id": "%s"}]',
                                       test.id('A1'), test.id('A1'), test.id('A1'))::jsonb);
exception when others then
  get stacked diagnostics d = pg_exception_detail;
  perform test.ok(coalesce(d, '') like '[%' and (select array_agg((e->>'row')::int order by (e->>'row')::int) from jsonb_array_elements(d::jsonb) e) = array[1, 2, 3],
                  'S14/T03: a row number that is not a whole spreadsheet row falls back to its position');
end $$;
-- Skipping does not swallow a refusal: a Team Lead uploading into another team still fails.
reset role;
select test.login('ul_a'); set role authenticated;
select test.throws(format($q$select public.import_members('[{"row": 2, "person": {"first_name": "Skip", "surname": "Guard"}, "unit_id": "%s"}]'::jsonb, true)$q$, test.id('A2')),
                   'S14: skipping existing people does not skip a refusal');
reset role;
-- With skipping on, a failed upload names only the rows that need fixing, not the duplicates.
select test.login('coord'); set role authenticated;
do $$
declare d text;
begin
  perform public.import_members(format('[{"row": 2, "person": {"first_name": "Dup", "surname": "Probe", "email": "bulk.one@example.org"}, "unit_id": "%s"},
                                         {"row": 3, "person": {"first_name": "", "surname": "Bad"}, "unit_id": "%s"}]',
                                       test.id('A1'), test.id('A1'))::jsonb, true);
exception when others then
  get stacked diagnostics d = pg_exception_detail;
  perform test.ok(jsonb_array_length(d::jsonb) = 1 and (d::jsonb -> 0 ->> 'row')::int = 3,
                  'S14: with skipping on, a failed upload does not say which rows were already recorded');
end $$;
-- The Coordinator now adds memberships: R3 (third unit) and anonymised records still hold.
select public.import_members(format('[{"row": 2, "person": {"first_name": "Three", "surname": "Units"}, "unit_id": "%s"}]', test.id('A1'))::jsonb);
insert into public.unit_memberships (church_id, person_id, unit_id)
  select test.id('churchA'), id, test.id('A2') from public.people where first_name = 'Three' and surname = 'Units';
insert into public.unit_memberships (church_id, person_id, unit_id)
  select test.id('churchA'), id, test.id('A3') from public.people where first_name = 'Three' and surname = 'Units';
select test.ok((select m.status from public.unit_memberships m join public.people p on p.id = m.person_id
                where p.first_name = 'Three' and p.surname = 'Units' and m.unit_id = test.id('A3')) = 'pending_approval',
               'S14: a third unit added by the Coordinator waits for the Resident Pastor (R3)');
select test.throws(format($q$insert into public.unit_memberships (church_id, person_id, unit_id) values (%L, %L, %L)$q$,
                          test.id('churchA'), test.id('p2'), test.id('A4')),
                   'S14: the Coordinator cannot put an anonymised record in a unit');
reset role;

-- ---------- Migration 24: projects and events (slice 4) ----------
-- A unit project in A1 (purpose P1, Purpose Head 'ph'), owned by its Team Lead.
select test.login('ul_a'); set role authenticated;
insert into public.projects (level, unit_id, name, starts_at, ends_at)
values ('unit', test.id('A1'), 'M24 sound workshop', now() + interval '60 days', now() + interval '60 days 3 hours');
select test.ok((public.project_readiness((select id from public.projects where name = 'M24 sound workshop')) ->> 'can_manage')::boolean
               and not (public.project_readiness((select id from public.projects where name = 'M24 sound workshop')) ->> 'can_approve')::boolean,
               'M24: readiness tells the owner they manage the project but do not approve it');
select test.throws(format($q$insert into public.team_demand (project_id, unit_id, on_date, slots_needed)
                             values ((select id from public.projects where name = 'M24 sound workshop'), %L, current_date + 90, 2)$q$, test.id('A1')),
                   'M24: volunteers cannot be needed on a day outside the project');
select test.lives(format($q$insert into public.team_demand (project_id, unit_id, on_date, slots_needed)
                            values ((select id from public.projects where name = 'M24 sound workshop'), %L,
                                    ((now() + interval '60 days') at time zone 'Europe/London')::date, 1)$q$, test.id('A1')),
                  'M24: ... and can on a day of it');
update public.projects set status = 'submitted' where name = 'M24 sound workshop';
select test.throws($q$update public.projects set decision_note = 'Approve me' where name = 'M24 sound workshop'$q$,
                   'M24: the owner cannot write the decision note');
reset role;

select test.login('ph'); set role authenticated;
select test.ok((public.project_readiness((select id from public.projects where name = 'M24 sound workshop')) ->> 'can_approve')::boolean,
               'M24: readiness tells the Purpose Head they approve it');
select test.lives($q$update public.projects set status = 'draft', decision_note = 'Add the equipment list first' where name = 'M24 sound workshop'$q$,
                  'M24: the Purpose Head sends a submitted unit project back, with a note');
select test.ok((select status = 'draft' and decision_note = 'Add the equipment list first' from public.projects where name = 'M24 sound workshop'),
               'M24: ... it is a draft again and the note is kept');
select test.throws($q$update public.projects set status = 'cancelled' where name = 'M24 sound workshop'$q$,
                   'M24: ... but the Purpose Head does not cancel it');
reset role;
select test.login('ul_a'); set role authenticated;
update public.projects set status = 'submitted' where name = 'M24 sound workshop';
reset role;
select test.login('ph'); set role authenticated;
select test.lives($q$update public.projects set status = 'approved', decision_note = 'Approved' where name = 'M24 sound workshop'$q$,
                  'M24: the Purpose Head approves it after changes');
reset role;
select test.login('ul_b'); set role authenticated;   -- leads another unit, not P1's Purpose Head
update public.projects set status = 'draft' where name = 'Production training';   -- finds no row it may change
reset role;
select test.ok((select status from public.projects where name = 'Production training') = 'approved',
               'M24: someone else cannot send a project back');
select test.login('editor'); set role authenticated;
select test.throws($q$select public.project_readiness((select id from public.projects where name = 'M24 sound workshop'))$q$,
                   'M24: readiness is not shown to roles outside planning');
reset role;

-- The event review's completion time is the database's.
select test.login('ops'); set role authenticated;
update public.event_plans set review_completed_at = '2000-01-01'
where project_id = (select id from public.projects where name = 'Harvest outreach');
select test.ok((select review_completed_at > now() - interval '1 minute' from public.event_plans e
                join public.projects p on p.id = e.project_id where p.name = 'Harvest outreach'),
               'M24: marking the review complete records now, not the time sent');
select test.ok((public.project_readiness((select id from public.projects where name = 'Harvest outreach')) -> 'lead_time' ->> 'weeks_needed')::int = 8,
               'M24: readiness gives the lead time a Large event needs');
reset role;
set role anon;
select test.throws($q$select public.project_readiness(gen_random_uuid())$q$, 'M24: signed-out visitors cannot call readiness');
reset role;

-- ---------- Security review 15: projects and events ----------
-- 'M24 sound workshop' is approved by the Purpose Head ('ph'), owned by its Team Lead ('ul_a'),
-- with one volunteer slot on its first day.
select test.login('ul_a'); set role authenticated;
update public.projects set status = 'in_progress', ends_at = ends_at + interval '1 day' where name = 'M24 sound workshop';
select test.ok((select status = 'submitted' and approved_by is null from public.projects where name = 'M24 sound workshop'),
               'U01: changing the dates while moving an approved project on sends it back for approval');
select test.ok((select decision_note is null from public.projects where name = 'M24 sound workshop'),
               'U05: ... and the last approval note is not carried into the new submission');
reset role;
select test.login('rp'); set role authenticated;   -- not the approver of a unit project
select test.throws($q$update public.projects set shortfall_action = 'borrow' where name = 'M24 sound workshop'$q$,
                   'U06: the Resident Pastor cannot record the shortfall action on a unit project they do not approve');
reset role;
select test.login('ph'); set role authenticated;
select test.lives($q$update public.projects set status = 'approved' where name = 'M24 sound workshop'$q$,
                  'U01: ... and the Purpose Head approves the new dates');
reset role;
select test.login('ul_a'); set role authenticated;
select test.throws($q$update public.projects set ends_at = ends_at + interval '1 hour', decision_note = 'Approved by the Purpose Head'
                      where name = 'M24 sound workshop'$q$,
                   'U05: the owner cannot write the decision note alongside a date change');
reset role;
select test.login('ph'); set role authenticated;
select test.throws($q$update public.projects set decision_note = 'Rewritten later' where name = 'M24 sound workshop'$q$,
                   'U05: the approver cannot rewrite the note after approving');
select test.throws($q$update public.projects set shortfall_action = 'move' where name = 'M24 sound workshop'$q$,
                   'U06: the shortfall action cannot be changed after approval');
reset role;
select test.login('ops'); set role authenticated;
select test.throws($q$update public.projects set status = 'submitted' where name = 'Harvest outreach'$q$,
                   'U03: a finished project cannot be reopened by submitting it again');
reset role;

-- U02: the event plan after approval.
select test.login('ul_a'); set role authenticated;
insert into public.event_plans (project_id, size, complexity)
select id, 'small', 'low' from public.projects where name = 'M24 sound workshop';
select test.ok((select status = 'submitted' and approved_by is null from public.projects where name = 'M24 sound workshop'),
               'U02: adding the event plan to an approved project sends it back for approval');
update public.event_plans set budget_status = 'not_needed', complexity = 'high'
where project_id = (select id from public.projects where name = 'M24 sound workshop');
reset role;
select test.login('ph'); set role authenticated;
select test.throws($q$update public.projects set status = 'approved' where name = 'M24 sound workshop'$q$,
                   'U02: R15 is checked again at approval (High complexity, no committee)');
reset role;
select test.login('ul_a'); set role authenticated;
update public.event_plans set has_planning_committee = true
where project_id = (select id from public.projects where name = 'M24 sound workshop');
reset role;
select test.login('ph'); set role authenticated;
select test.lives($q$update public.projects set status = 'approved' where name = 'M24 sound workshop'$q$,
                  'U02: ... and approves once the committee is in place');
reset role;
select test.login('finance'); set role authenticated;
update public.event_plans set budget_status = 'rejected'
where project_id = (select id from public.projects where name = 'M24 sound workshop');
select test.ok((select status = 'submitted' from public.projects where name = 'M24 sound workshop'),
               'U02: Finance rejecting the budget of an approved event sends it back for approval');
update public.event_plans set budget_status = 'approved'
where project_id = (select id from public.projects where name = 'M24 sound workshop');
reset role;
select test.login('ph'); set role authenticated;
update public.projects set status = 'approved' where name = 'M24 sound workshop';
reset role;
select test.login('ul_a'); set role authenticated;
update public.event_plans set main_attraction = 'Live mixing demo'
where project_id = (select id from public.projects where name = 'M24 sound workshop');
select test.ok((select status = 'approved' from public.projects where name = 'M24 sound workshop'),
               'U02: other plan changes keep the approval');
reset role;

-- U04: action points.
select test.login('ul_a'); set role authenticated;
insert into public.event_plan_actions (project_id, section_no, description, owner_user_id)
select id, 6, 'Hire the mixing desk', test.id('ul_b') from public.projects where name = 'M24 sound workshop';
reset role;
select test.login('ul_b'); set role authenticated;
select test.throws($q$update public.event_plan_actions set description = 'Nothing to do' where description = 'Hire the mixing desk'$q$,
                   'U04: the person given an action point cannot rewrite it');
select test.throws($q$update public.event_plan_actions set project_id = (select id from public.projects where name = 'Harvest outreach')
                      where description = 'Hire the mixing desk'$q$,
                   'U04: ... or move it to another project');
select test.lives($q$update public.event_plan_actions set status = 'done' where description = 'Hire the mixing desk'$q$,
                  'U04: ... but can mark it done');
reset role;

-- U07: an input's receipt time follows its status.
select test.login('ul_a'); set role authenticated;
insert into public.project_inputs (project_id, title, requested_from_user_id, due_on)
select id, 'Equipment list', test.id('ul_b'), current_date + 7 from public.projects where name = 'M24 sound workshop';
reset role;
select test.login('ul_b'); set role authenticated;
update public.project_inputs set body = 'Desk, two monitors', status = 'received' where title = 'Equipment list';
update public.project_inputs set received_at = '2000-01-01' where title = 'Equipment list';
select test.ok((select received_at > now() - interval '1 minute' from public.project_inputs where title = 'Equipment list'),
               'U07: a received input cannot be back-dated');
reset role;

-- U08: volunteers needed stay within the project's dates.
select test.login('ul_a'); set role authenticated;
select test.throws($q$update public.projects set starts_at = starts_at + interval '30 days', ends_at = ends_at + interval '30 days'
                      where name = 'M24 sound workshop'$q$,
                   'U08: the dates cannot move away from the days volunteers are needed');
reset role;

-- ---------- Migration 25: approvals, safeguarding notes, shortfalls, phones and emails ----------
-- 1. Approvals: the Operations Lead approves church projects; the Resident Pastor owns none.
select test.login('rp'); set role authenticated;
select test.throws($q$insert into public.projects (level, name, starts_at, ends_at) values ('church', 'RP project', now() + interval '90 days', now() + interval '90 days 2 hours')$q$,
                   'M25: the Resident Pastor does not own projects');
reset role;
select test.login('ops'); set role authenticated;
select test.throws(format('update public.projects set owner_user_id = %L where name = %L', test.id('rp'), 'Harvest outreach'),
                   'M25: a project cannot be handed to the Resident Pastor');
insert into public.projects (level, name, starts_at, ends_at)
values ('church', 'M25 carol service', now() + interval '100 days', now() + interval '100 days 2 hours');
update public.projects set status = 'submitted' where name = 'M25 carol service';
select test.ok((public.project_readiness((select id from public.projects where name = 'M25 carol service')) ->> 'self_approval')::boolean,
               'M25: readiness flags that the Operations Lead would approve their own project');
reset role;
select test.login('ph'); set role authenticated;
update public.projects set status = 'approved' where name = 'M25 carol service';   -- finds no row it may change
reset role;
select test.ok((select status from public.projects where name = 'M25 carol service') = 'submitted',
               'M25: a Purpose Head does not approve church projects');
select test.login('ops'); set role authenticated;
select test.lives($q$update public.projects set status = 'approved' where name = 'M25 carol service'$q$,
                  'M25: the Operations Lead approves a church project, their own included');
select test.ok((select approved_by = owner_user_id from public.projects where name = 'M25 carol service'),
               'M25: ... recorded as self-approved (approver = owner)');
reset role;

-- 2. Safeguarding notes: restricted and logged.
select test.login('ops'); set role authenticated;
select test.lives(format('select public.set_event_safeguarding(%L, %L)', (select id from public.projects where name = 'Harvest outreach'), 'Two DBS-checked leaders at the children''s area'),
                  'M25: the event owner records safeguarding notes');
select test.throws('select * from public.event_safeguarding', 'M25: no one reads the safeguarding table directly');
select test.throws('select safeguarding_notes from public.event_plans', 'M25: the old open column is gone');
reset role;
select test.login('pastoral'); set role authenticated;
select test.ok(public.get_event_safeguarding((select id from public.projects where name = 'Harvest outreach')) like 'Two DBS%',
               'M25: the Pastoral Lead reads them');
reset role;
select test.login('rp'); set role authenticated;
select test.lives(format('select public.get_event_safeguarding(%L)', (select id from public.projects where name = 'Harvest outreach')),
                  'M25: ... and the Resident Pastor');
select test.throws(format('select public.set_event_safeguarding(%L, %L)', (select id from public.projects where name = 'Harvest outreach'), 'x'),
                   'M25: ... but neither writes them');
reset role;
select test.login('ul_b'); set role authenticated;
select test.throws(format('select public.get_event_safeguarding(%L)', (select id from public.projects where name = 'Harvest outreach')),
                   'M25: a leader outside the event cannot read them');
reset role;
select test.login('nobody');
select test.ok((select count(*) from public.audit_log where action = 'view_safeguarding') >= 2,
               'M25: every view of safeguarding notes is logged');

-- 3. Volunteer shortfalls on the dashboards.
select test.login('ops'); set role authenticated;
insert into public.team_demand (project_id, unit_id, on_date, slots_needed)
select id, test.id('A1'), (starts_at at time zone 'Europe/London')::date, 400 from public.projects where name = 'M25 carol service';
reset role;
select test.login('coord'); set role authenticated;
select test.ok(exists (select 1 from public.volunteer_shortfalls() where project_name = 'M25 carol service' and unit_id = test.id('A1')),
               'M25: the Church Dashboard lists a coming project that is short of volunteers');
reset role;
select test.login('ul_a'); set role authenticated;
select test.ok(exists (select 1 from public.volunteer_shortfalls(test.id('A1')) where project_name = 'M25 carol service'),
               'M25: ... and My Unit shows it to the Team Lead of the short unit');
select test.throws(format('select * from public.volunteer_shortfalls(%L)', test.id('A2')),
                   'M25: ... but not another unit''s shortfalls');
reset role;
select test.login('editor'); set role authenticated;
select test.throws('select * from public.volunteer_shortfalls()', 'M25: roles outside the dashboard audience cannot list shortfalls');
reset role;

-- 4. Phones and emails.
select test.login('ul_a'); set role authenticated;
select test.lives(format($q$update public.people set phones = '{"07700 900123","+44 161 496 0000"}', other_emails = '{"ada.work@example.org"}' where id = %L$q$, test.id('s3_member')),
                  'M25: a member has more phone numbers and email addresses');
select test.throws(format($q$update public.people set phones = '{"1111111","2222222","3333333","4444444"}' where id = %L$q$, test.id('s3_member')),
                   'M25: at most 3 phone numbers');
select test.throws(format($q$update public.people set phones = '{"call me"}' where id = %L$q$, test.id('s3_member')),
                   'M25: a phone number is digits (with +, spaces, brackets, dashes)');
select test.throws(format($q$update public.people set other_emails = '{"a@example.org","b@example.org","c@example.org"}' where id = %L$q$, test.id('s3_member')),
                   'M25: at most 3 email addresses in all');
select test.throws(format($q$update public.people set other_emails = '{"not-an-email"}' where id = %L$q$, test.id('s3_member')),
                   'M25: extra emails are checked like the main one');
select test.lives(format($q$select public.create_member('{"first_name":"Phone","surname":"Member","phones":[" 07700 900456 ",""],"other_emails":["Phone.Member@Example.org"]}', %L)$q$, test.id('A1')),
                  'M25: adding a member takes phones and extra emails');
select test.ok((select phones = '{"07700 900456"}' and other_emails = '{"phone.member@example.org"}' from public.people where surname = 'Member' and first_name = 'Phone'),
               'M25: ... trimmed, empty entries dropped, emails in lower case');
reset role;
select test.login('teci'); set role authenticated;
select test.throws(format($q$select public.create_member('{"first_name":"T","surname":"Phones","teci_stage_id":"%s","phones":["07700 900789"]}', null)$q$,
                          (select id from public.teci_stages where church_id = test.id('churchA') and stage_no = 1)),
                   'M25: the TECi route records no phone numbers (name, email and stage only)');
reset role;
select test.login('nobody');
select app.anonymise((select id from public.people where first_name = 'Phone' and surname = 'Member'));
select test.ok((select cardinality(phones) = 0 and cardinality(other_emails) = 0 from public.people where first_name = 'Former' and anonymised_at is not null
                and id = (select person_id from public.unit_memberships where person_id in (select id from public.people where anonymised_at is not null) order by joined_on desc limit 1)),
               'M25: anonymising wipes phone numbers and extra emails');

-- ---------- Security review 16 ----------
-- V01: the self-approval flag is recorded at approval, not worked out from today's owner.
-- (Read through to_jsonb so the checks report FAIL rather than stop if the column is missing.)
select test.login('ops'); set role authenticated;
update public.projects set owner_user_id = test.id('ph') where name = 'M25 carol service';
update public.projects set owner_user_id = test.id('ph') where name = 'M24 sound workshop';
reset role;
select test.ok(coalesce((select (to_jsonb(p) ->> 'self_approved')::boolean from public.projects p where name = 'M25 carol service'), false),
               'V01: a self-approved project stays flagged after its owner changes');
select test.ok(coalesce((select not (to_jsonb(p) ->> 'self_approved')::boolean and approved_by = owner_user_id
                         from public.projects p where name = 'M24 sound workshop'), false),
               'V01: ... and a project handed to its approver is not shown as self-approved');
select test.login('ph'); set role authenticated;
select test.throws($q$update public.projects set self_approved = false where name = 'M25 carol service'$q$,
                   'V01: the flag cannot be cleared by hand');
reset role;
select test.ok(coalesce((select (to_jsonb(p) ->> 'self_approved')::boolean from public.projects p where name = 'M25 carol service'), false),
               'V01: ... and is still set');

-- V02: no approval in the same request as a change of level or unit (the new level's approver
-- would decide a project the old level's approver never saw).
select test.login('ops'); set role authenticated;
insert into public.projects (level, unit_id, name, starts_at, ends_at)
values ('unit', test.id('A1'), 'V02 unit social', now() + interval '120 days', now() + interval '120 days 2 hours');
update public.projects set status = 'submitted' where name = 'V02 unit social';
select test.throws($q$update public.projects set level = 'church', unit_id = null, status = 'approved' where name = 'V02 unit social'$q$,
                   'V02: the Operations Lead cannot turn a submitted unit project into a church project and approve it in one step');
reset role;
select test.ok((select status = 'submitted' and approved_by is null from public.projects where name = 'V02 unit social'),
               'V02: ... it stays waiting for the Purpose Head');

-- V03: writes to safeguarding notes are audited against the event, never with the text.
select test.ok(exists (select 1 from public.audit_log a
                       where a.table_name = 'event_safeguarding' and a.action in ('insert', 'update', 'delete')
                         and a.record_id = (select id from public.projects where name = 'Harvest outreach')),
               'V03: a safeguarding write is audited against its event');
select test.ok(not exists (select 1 from public.audit_log a where a.table_name = 'event_safeguarding' and a.detail::text like '%DBS%'),
               'V03: ... without the text of the notes');
-- Sound: no direct writes, no other church, the system copy kept.
select test.login('ops'); set role authenticated;
select test.throws(format($q$insert into public.event_safeguarding (project_id, church_id, notes) values (%L, %L, 'x')$q$,
                          (select id from public.projects where name = 'M25 carol service'), test.id('churchA')),
                   'V03: no one writes the safeguarding table directly');
reset role;
select test.login('b_ops'); set role authenticated;
select test.throws(format('select public.get_event_safeguarding(%L)', (select id from public.projects where name = 'Harvest outreach')),
                   'V03: another church''s Operations Lead cannot read the notes');
select test.throws(format('select public.set_event_safeguarding(%L, %L)', (select id from public.projects where name = 'Harvest outreach'), 'x'),
                   'V03: ... or write them');
select test.ok(not exists (select 1 from public.volunteer_shortfalls() s
                           join public.projects p on p.id = s.project_id where p.church_id = test.id('churchA')),
               'V03: shortfalls never list another church''s projects');
reset role;
select test.login('rp'); set role authenticated;
select test.throws(format('select public.create_sunday_service(%L)', current_setting('test.sun6')::date + 14),
                   'V03: the Resident Pastor cannot set up a Sunday (it would make them its owner)');
reset role;

-- V04 and V05: list entries are never empty or repeated.
select test.login('ul_a'); set role authenticated;
select test.throws(format($q$update public.people set phones = '{NULL}' where id = %L$q$, test.id('s3_member')),
                   'V04: a phone list cannot hold an empty (null) entry');
select test.throws(format($q$update public.people set other_emails = array[null, 'x@example.org'] where id = %L$q$, test.id('s3_member')),
                   'V04: ... nor an email list');
select test.throws(format($q$update public.people set phones = '{"07700 900123","07700 900123"}' where id = %L$q$, test.id('s3_member')),
                   'V05: the same phone number is not kept twice');
select test.throws(format($q$update public.people set email = 'dup.v05@example.org', other_emails = '{"dup.v05@example.org"}' where id = %L$q$, test.id('s3_member')),
                   'V05: an extra email cannot repeat the main email');
select test.lives(format($q$select public.create_member('{"first_name":"Dup","surname":"Lists","email":"Dup.Lists@example.org","phones":["07700 900111","07700 900111"],"other_emails":["dup.lists@example.org","Other.Dup@example.org","other.dup@example.org"]}', %L)$q$, test.id('A1')),
                  'V05: adding a member with repeated entries works');
select test.ok((select phones = '{"07700 900111"}' and other_emails = '{"other.dup@example.org"}' from public.people where first_name = 'Dup' and surname = 'Lists'),
               'V05: ... and keeps each phone and email once, the main email only as the main one');
reset role;

-- ---------- Migration 26: one-to-ones (slice 5) ----------
-- s3_member's one-to-one in A1 this quarter was written by ul_a (the Team Lead); ul_b is A1's
-- Deputy; 'ph' is A1's Purpose Head.
select test.login('nobody');
insert into test.ids select 'oto1', o.id from public.one_to_ones o
where o.person_id = test.id('s3_member') and o.unit_id = test.id('A1') order by o.held_on desc limit 1;
select test.login('ul_a'); set role authenticated;
select test.lives(format($q$update public.one_to_ones set sense_of_family = 'Feels part of the team', competence = 'Confident on camera 2' where id = %L$q$, test.id('oto1')),
                  'M26: the Team Lead records sense of family and competence');
select test.lives(format('select public.set_one_to_one_walk(%L, %L)', test.id('oto1'), 'Reading through John; joined a prayer group'),
                  'M26: ... and their personal walk with God, held apart');
select test.ok(public.get_one_to_one_walk(test.id('oto1')) like 'Reading through John%', 'M26: the Team Lead who wrote it reads it back');
select test.throws('select * from public.one_to_one_walk', 'M26: no one reads the walk-with-God table directly');
reset role;
select test.login('coord'); set role authenticated;
select test.lives(format('select public.get_one_to_one_walk(%L)', test.id('oto1')), 'M26: the G-Squad Coordinator reads it');
select test.throws(format('select public.set_one_to_one_walk(%L, %L)', test.id('oto1'), 'x'), 'M26: ... but does not write it');
reset role;
select test.login('rp'); set role authenticated;
select test.lives(format('select public.get_one_to_one_walk(%L)', test.id('oto1')), 'M26: the Resident Pastor reads it');
select test.ok(jsonb_array_length(public.export_person(test.id('s3_member')) -> 'one_to_one_walk') = 1,
               'M26: a subject access export includes it');
reset role;
select test.login('ph'); set role authenticated;
select test.ok(exists (select 1 from public.one_to_ones where id = test.id('oto1') and sense_of_family is not null),
               'M26: the Purpose Head reads the rest of the one-to-one');
select test.throws(format('select public.get_one_to_one_walk(%L)', test.id('oto1')), 'M26: ... but not the walk with God');
reset role;
select test.login('ul_b'); set role authenticated;
select test.throws(format('select public.get_one_to_one_walk(%L)', test.id('oto1')), 'M26: the Deputy Team Lead does not read it');
reset role;
select test.login('nobody');
select test.ok((select count(*) from public.audit_log where action = 'view_walk' and record_id = test.id('oto1')) >= 3,
               'M26: every view of the walk with God is logged');

-- Leadership questions and answers.
select test.login('ul_a'); set role authenticated;
select test.throws($q$insert into public.one_to_one_prompts (question, starts_on, ends_on) values ('Team Leads cannot ask', current_date, current_date + 30)$q$,
                   'M26: Team Leads do not set the leadership questions');
reset role;
select test.login('coord'); set role authenticated;
select test.lives($q$insert into public.one_to_one_prompts (question, starts_on, ends_on) values ('How are you finding the new service times?', date_trunc('quarter', current_date)::date, current_date + 60)$q$,
                  'M26: the G-Squad Coordinator sets a leadership question for a period');
insert into public.one_to_one_prompts (question, starts_on, ends_on) values ('An old question', current_date - 400, current_date - 300);
reset role;
select test.login('ul_a'); set role authenticated;
select test.lives(format($q$insert into public.one_to_one_answers (one_to_one_id, prompt_id, answer)
                            values (%L, (select id from public.one_to_one_prompts where question like 'How are you finding%%'), 'The 10:00 start suits me')$q$, test.id('oto1')),
                  'M26: the Team Lead records the answer in the one-to-one');
select test.throws(format($q$insert into public.one_to_one_answers (one_to_one_id, prompt_id, answer)
                             values (%L, (select id from public.one_to_one_prompts where question = 'An old question'), 'x')$q$, test.id('oto1')),
                   'M26: ... only for questions asked when it was held');
reset role;
select test.login('ph'); set role authenticated;
select test.ok((select count(*) from public.one_to_one_answers where one_to_one_id = test.id('oto1')) = 1,
               'M26: answers are read by whoever reads the one-to-one');
select test.throws(format($q$insert into public.one_to_one_answers (one_to_one_id, prompt_id, answer)
                             values (%L, (select id from public.one_to_one_prompts where question like 'How are you finding%%'), 'y')$q$, test.id('oto1')),
                   'M26: ... and written only by the Team Lead who wrote it');
reset role;
select test.login('ul_b'); set role authenticated;
select test.ok((select count(*) from public.one_to_one_answers) = 0, 'M26: the Deputy Team Lead sees no answers');
reset role;
select test.login('coord'); set role authenticated;
select test.throws($q$delete from public.one_to_one_prompts where question like 'How are you finding%'$q$,
                   'M26: an answered question is switched off, not deleted');
reset role;

-- ---------- Security review 17 (one-to-ones) ------------------------------------------
-- W01: the audit log's entries about walk-with-God notes (who wrote, changed or viewed them)
-- are for the Resident Pastor only, like those about faith fields and pastoral notes.
select test.login('ops'); set role authenticated;
select test.ok((select count(*) from public.audit_log where table_name = 'one_to_one_walk' or action = 'view_walk') = 0,
               'W01: the Operations Lead does not see who wrote or viewed walk-with-God notes');
reset role;
select test.login('rp'); set role authenticated;
select test.ok((select count(*) from public.audit_log where table_name = 'one_to_one_walk' or action = 'view_walk') >= 4,
               'W01: ... the Resident Pastor still does');
reset role;

-- W02: a one-to-one is never dated in the future, and its date cannot move outside the
-- period of a leadership question it already has an answer to. otoW is s3_member's one-to-one
-- in A1 last quarter (fixture, written by ul_a).
select test.login('nobody');
insert into public.one_to_ones (church_id, person_id, unit_id, lead_user_id, quarter_start, held_on, feeling)
values (test.id('churchA'), test.id('s3_member'), test.id('A1'), test.id('ul_a'),
        date_trunc('quarter', current_date - interval '3 months')::date,
        date_trunc('quarter', current_date - interval '3 months')::date + 10, 'doing_well');
insert into test.ids select 'otoW', o.id from public.one_to_ones o
where o.person_id = test.id('s3_member') and o.unit_id = test.id('A1')
  and o.quarter_start = date_trunc('quarter', current_date - interval '3 months')::date;
select test.login('ul_a'); set role authenticated;
select test.throws(format('update public.one_to_ones set held_on = current_date + 1 where id = %L', test.id('oto1')),
                   'W02: a one-to-one cannot be dated in the future');
select test.lives(format('update public.one_to_ones set held_on = held_on + 1 where id = %L', test.id('otoW')),
                  'W02: ... and with no answers its date moves freely within the quarter');
select test.lives(format('update public.one_to_ones set held_on = held_on - 1 where id = %L', test.id('otoW')),
                  'W02: ... (and back)');
reset role;
select test.login('coord'); set role authenticated;
insert into public.one_to_one_prompts (question, starts_on, ends_on)
select 'A one-day question', o.held_on, o.held_on from public.one_to_ones o where o.id = test.id('otoW');
reset role;
select test.login('ul_a'); set role authenticated;
select test.lives(format($q$insert into public.one_to_one_answers (one_to_one_id, prompt_id, answer)
                            values (%L, (select id from public.one_to_one_prompts where question = 'A one-day question'), 'Answered on the day')$q$, test.id('otoW')),
                  'W02 fixture: the one-day question is answered');
select test.throws(format('update public.one_to_ones set held_on = held_on + 1 where id = %L', test.id('otoW')),
                   'W02: the date cannot move outside the period of a question already answered');
reset role;

-- W03: once answered, a leadership question keeps its wording, and its period always covers
-- the one-to-ones that answered it. The author is always the caller.
select test.login('coord'); set role authenticated;
select test.throws($q$update public.one_to_one_prompts set question = 'Something else entirely' where question like 'How are you finding%'$q$,
                   'W03: an answered question cannot be reworded');
select test.throws($q$update public.one_to_one_prompts set starts_on = starts_on - 1, ends_on = ends_on - 1 where question = 'A one-day question'$q$,
                   'W03: ... nor re-dated so its answers fall outside it');
select test.lives($q$update public.one_to_one_prompts set ends_on = ends_on + 10 where question = 'A one-day question'$q$,
                  'W03: ... but its period can grow');
select test.lives($q$update public.one_to_one_prompts set question = 'An old question, reworded' where question = 'An old question'$q$,
                  'W03: an unanswered question can still be reworded');
insert into public.one_to_one_prompts (question, starts_on, ends_on, created_by)
select 'Who asked?', current_date, current_date, test.id('ul_a');
select test.ok((select created_by from public.one_to_one_prompts where question = 'Who asked?') = test.id('coord'),
               'W03: a question is always recorded as set by the caller');
select test.throws(format($q$update public.one_to_one_prompts set created_by = %L where question = 'Who asked?'$q$, test.id('ul_a')),
                   'W03: ... and its author cannot be changed');
reset role;

-- =====================================================================================
-- X. Slice 6 (migration 27): starting, content, snapshot, sending, test list
-- =====================================================================================
insert into test.ids select 'iss1', id from public.newsletter_issues
  where issue_month = (date_trunc('month', now()) + interval '1 month')::date;

-- X01: starting an issue makes its project, the issue and a team update per Team Lead.
select test.login('ul_a'); set role authenticated;
select test.throws($q$select public.start_newsletter_issue((date_trunc('month', now()) + interval '2 months')::date)$q$,
                   'X01: a Team Lead cannot start an issue');
reset role;
select test.login('rp'); set role authenticated;
select test.throws($q$select public.start_newsletter_issue((date_trunc('month', now()) + interval '2 months')::date)$q$,
                   'X01: ... nor the Resident Pastor (approves, does not own projects)');
reset role;
select test.login('editor'); set role authenticated;
select test.throws($q$select public.start_newsletter_issue((date_trunc('month', now()) - interval '1 month')::date)$q$,
                   'X01: an issue cannot be started for a past month');
select test.throws($q$select public.start_newsletter_issue((date_trunc('month', now()) + interval '1 month')::date)$q$,
                   'X01: one issue per month');
select test.lives($q$select public.start_newsletter_issue((date_trunc('month', now()) + interval '2 months')::date)$q$,
                  'X01: an editor starts an issue');
reset role;
insert into test.ids select 'iss2', id from public.newsletter_issues
  where issue_month = (date_trunc('month', now()) + interval '2 months')::date;
select test.ok((select p.owner_user_id = test.id('editor') and p.level = 'church' and p.status = 'draft'
                from public.newsletter_issues i join public.projects p on p.id = i.project_id where i.id = test.id('iss2')),
               'X01: the issue has a draft church project owned by the editor');
select test.ok((select count(*) from public.project_inputs pi join public.newsletter_issues i on i.project_id = pi.project_id
                where i.id = test.id('iss2'))
               = (select count(*) from public.units u join public.role_assignments ra on ra.unit_id = u.id
                  where ra.role = 'unit_lead' and ra.is_active and u.is_active and u.church_id = test.id('churchA')),
               'X01: a team update is requested from every active Team Lead');
select test.ok((select bool_and(pi.due_on >= current_date + 7) from public.project_inputs pi
                join public.newsletter_issues i on i.project_id = pi.project_id where i.id = test.id('iss2')),
               'X01: team updates are due in good time');

-- X02: content for the app; a Team Lead gives their update; editors leave items out.
select test.login('ul_a'); set role authenticated;
select test.throws(format('select public.newsletter_issue_content(%L)', test.id('iss2')), 'X02: a Team Lead cannot read the issue content');
update public.project_inputs set body = 'Production trained three new camera operators.', status = 'received'
where requested_from_user_id = test.id('ul_a') and unit_id = test.id('A1')
  and project_id = (select id from public.projects where name like 'The Greatness Brief: %');   -- Team Leads cannot read issues
reset role;
select test.login('editor'); set role authenticated;
select test.ok(jsonb_array_length(public.newsletter_issue_content(test.id('iss2')) -> 'team_updates') = 1,
               'X02: a received team update appears in the content');
select test.ok(public.newsletter_issue_content(test.id('iss2')) ? 'baptisms', 'X02: baptism counts are in the content');
update public.newsletter_issues set excluded = array[(select id from public.project_inputs where body like 'Production trained%')]
where id = test.id('iss2');
select test.ok((public.newsletter_issue_content(test.id('iss2')) -> 'team_updates' -> 0 ->> 'excluded')::boolean,
               'X02: an excluded update is shown to editors as left out');
select test.throws($q$select count(*) from public.newsletter_snapshots$q$, 'X02: editors cannot read snapshots');
select test.throws($q$select count(*) from public.newsletter_deliveries$q$, 'X02: editors cannot read who received it');
select test.throws($q$update public.newsletter_issues set send_on = current_date - 1$q$, 'X02: a send date cannot be in the past');
reset role;

-- X03: the test list and the live switch.
select test.login('editor'); set role authenticated;
update public.church_settings set newsletter_test_recipients = '{editor@example.org}';
reset role;
select test.ok((select cardinality(newsletter_test_recipients) = 0 from public.church_settings where church_id = test.id('churchA')),
               'X03: an editor cannot set the test list');
select test.login('coord'); set role authenticated;
select test.throws($q$update public.church_settings set newsletter_test_recipients = '{Not An Email}'$q$, 'X03: test addresses must be valid');
select test.throws($q$update public.church_settings set newsletter_test_recipients = '{coord@example.org,someone@outside.example}'$q$,
                   'Y04: a test address must be a leader''s sign-in address');
select test.lives($q$update public.church_settings set newsletter_test_recipients = '{coord@example.org,editor@example.org}'$q$,
                  'X03: the Coordinator sets the test list');
select test.throws($q$update public.church_settings set newsletter_live = true$q$,
                   'X03: the Coordinator cannot switch on sending to members');
reset role;
select test.login('ops'); set role authenticated;
select test.throws($q$update public.church_settings set newsletter_live = true$q$, 'X03: ... nor the Operations Lead');
reset role;
select test.ok((select count(*) from public.audit_log where table_name = 'church_settings' and detail -> 'columns' ? 'newsletter_test_recipients') >= 1,
               'X03: changes to the test list are logged');

-- X04: test sends: allowed readers, ten a day, logged.
select test.login('ul_a'); set role authenticated;
select test.throws(format('select public.newsletter_test_send(%L)', test.id('iss2')), 'X04: a Team Lead cannot send a test');
reset role;
select test.login('editor'); set role authenticated;
select test.ok(public.newsletter_test_send(test.id('iss2')) = '{coord@example.org,editor@example.org}', 'X04: a test send returns the test list');
select public.newsletter_test_send(test.id('iss2')) from generate_series(1, 9);
select test.throws(format('select public.newsletter_test_send(%L)', test.id('iss2')), 'X04: at most ten test sends a day per issue');
reset role;

-- X05: approval takes a snapshot; Send now; the job's functions are service-role only.
select test.login('editor'); set role authenticated;
update public.newsletter_issues set status = 'awaiting_coordinator' where id = test.id('iss2');
reset role;
select test.login('coord'); set role authenticated;
update public.newsletter_issues set status = 'awaiting_pastor', approved_version = public.newsletter_issue_content(id) ->> 'version'
where id = test.id('iss2');
select test.throws(format('update public.newsletter_issues set send_now_at = now() where id = %L', test.id('iss2')),
                   'X05: Send now only once approved');
reset role;
-- Y01: the Team Lead rewrites their update after the Coordinator approved.
select test.login('ul_a'); set role authenticated;
update public.project_inputs set body = 'Production trained three new camera operators. Also, something nobody approved.'
where body like 'Production trained%';
reset role;
select test.login('rp'); set role authenticated;
select test.throws(format($q$update public.newsletter_issues set status = 'approved', approved_version = public.newsletter_issue_content(id) ->> 'version'
                             where id = %L$q$, test.id('iss2')),
                   'Y01: content changed after the Coordinator approved cannot get final approval');
reset role;
select test.login('ul_a'); set role authenticated;
update public.project_inputs set body = 'Production trained three new camera operators.' where body like 'Production trained%';
reset role;
select test.login('rp'); set role authenticated;
select test.throws(format($q$update public.newsletter_issues set status = 'approved', approved_version = md5('what I saw yesterday') where id = %L$q$, test.id('iss2')),
                   'Y01: the Resident Pastor cannot approve a version they were not shown');
update public.newsletter_issues set status = 'approved', approved_version = public.newsletter_issue_content(id) ->> 'version'
where id = test.id('iss2');
reset role;
select test.ok((select status = 'approved' from public.newsletter_issues where id = test.id('iss2')),
               'Y01: the version the Coordinator approved gets final approval');
select test.ok((select count(*) from public.newsletter_snapshots where issue_id = test.id('iss2')) = 1, 'X05: final approval takes a snapshot');
select test.ok((select jsonb_array_length(content -> 'team_updates') from public.newsletter_snapshots where issue_id = test.id('iss2')) = 0,
               'X05: the snapshot leaves out what editors excluded');
select test.login('editor'); set role authenticated;
select test.throws(format('update public.newsletter_issues set send_now_at = now() where id = %L', test.id('iss2')),
                   'X05: an editor cannot press Send now');
select test.throws(format('update public.newsletter_issues set send_attempts = 3 where id = %L', test.id('iss2')),
                   'X05: nobody edits the sending record');
select test.throws('select * from public.newsletter_claim_due()', 'X05: signed-in users cannot claim issues to send');
select test.throws(format('select * from public.newsletter_next_recipients(%L)', test.id('iss2')), 'X05: ... nor list recipients and their links');
select test.throws(format('select public.newsletter_finish(%L)', test.id('iss2')), 'X05: ... nor mark an issue sent');
reset role;
select test.login('coord'); set role authenticated;
select test.lives(format('update public.newsletter_issues set send_now_at = now() where id = %L', test.id('iss2')),
                  'X05: the Coordinator presses Send now');
reset role;

-- X06: the job sends to the test list only while real sending is off.
select test.login(''); set role service_role;
select test.ok((select count(*) from public.newsletter_claim_due() where issue_id = test.id('iss2') and not live) = 1,
               'X06: the job claims the due issue, in test mode');
select test.ok((select count(*) from public.newsletter_claim_due()) = 0, 'X06: a claimed issue is not claimed twice');
create temporary table x_tests as select * from public.newsletter_next_recipients(test.id('iss2'));
select test.ok((select array_agg(email order by email) from x_tests) = '{coord@example.org,editor@example.org}'
               and (select bool_and(person_id is null and links is null) from x_tests),
               'X06: in test mode only the test list is returned, with no personal links');
select test.ok(not exists (select 1 from public.newsletter_next_recipients(test.id('iss2'))),
               'Y03: recipients handed over are not handed over again in the same run');
reset role;
select test.ok((select count(*) from public.newsletter_deliveries where issue_id = test.id('iss2') and provider_id is null) = 2,
               'Y03: they are recorded as handed over, not yet confirmed');
select test.login('editor'); set role authenticated;
select test.throws(format($q$update public.newsletter_issues set headline = 'Changed mid-send' where id = %L$q$, test.id('iss2')),
                   'X06: an issue cannot be edited while it is being sent');
reset role;
select test.login(''); set role service_role;
select public.newsletter_record_deliveries(test.id('iss2'), '[{"test_address":"coord@example.org","provider_id":"t1"}]');
select test.ok(public.newsletter_finish(test.id('iss2'), null) = 'retry', 'X06: with someone left, the run is retried');
select test.throws(format('select * from public.newsletter_next_recipients(%L)', test.id('iss2')),
                   'X06: ... and a released claim gives no recipients until claimed again');
reset role;
select test.ok((select send_started_at is null and send_error is not null from public.newsletter_issues where id = test.id('iss2')),
               'X06: the claim is released with a note');
select test.login(''); set role service_role;
select test.ok((select count(*) from public.newsletter_claim_due() where issue_id = test.id('iss2')) = 1,
               'Y03: the next run claims it again and releases the unconfirmed recipient');
select test.ok((select array_agg(email) from public.newsletter_next_recipients(test.id('iss2'))) = '{editor@example.org}',
               'X06: a retry skips who already received it');
select public.newsletter_record_deliveries(test.id('iss2'), '[{"test_address":"editor@example.org","provider_id":"t2"}]');
select test.ok(public.newsletter_finish(test.id('iss2'), null) = 'sent', 'X06: when everyone has it, the issue is sent');
reset role;
select test.ok((select status = 'sent' and sent_as_test and sent_at is not null from public.newsletter_issues where id = test.id('iss2')),
               'X06: a test-mode issue is marked as sent to the test list');
select test.ok(not exists (select 1 from public.newsletter_snapshots where issue_id = test.id('iss2')),
               'Y09: the snapshot (person ids, names, birthdays) is deleted once sent');
select test.login('editor'); set role authenticated;
select test.ok((select total from public.newsletter_issue_stats(test.id('iss2')) where item = 'delivered') = 2, 'X06: editors see how many received it');
reset role;

-- X07 fixture: earlier sections anonymised p1 to p3, so two new members (system change).
select test.login('');
do $$
declare v uuid;
begin
  insert into public.people (church_id, first_name, surname, email, birth_day, birth_month, celebration_opt_in, date_joined)
  values (test.id('churchA'), 'Nia', 'Brief', 'nia@example.org', 9, extract(month from current_date + interval '1 month')::int, true, current_date - 100)
  returning id into v;
  insert into test.ids values ('pN1', v);
  insert into public.people (church_id, first_name, surname, email, date_joined)
  values (test.id('churchA'), 'Obi', 'Brief', 'obi@example.org', current_date - 100) returning id into v;
  insert into test.ids values ('pN2', v);
end $$;
-- X07: live sending. Only the Resident Pastor switches it on.
select test.login('rp'); set role authenticated;
select test.lives($q$update public.church_settings set newsletter_live = true$q$, 'X07: the Resident Pastor switches on sending to members');
reset role;
-- The first issue (next month) is put back to the Resident Pastor's step (system change) and approved.
select test.login('');
update public.newsletter_issues set status = 'awaiting_pastor', send_on = current_date,
       approved_version = app.newsletter_content_version(id) where id = test.id('iss1');
select test.login('rp'); set role authenticated;
update public.newsletter_issues set status = 'approved', approved_version = public.newsletter_issue_content(id) ->> 'version'
where id = test.id('iss1');
reset role;
select test.ok((select count(*) from public.newsletter_snapshots s, jsonb_array_elements(s.content -> 'celebrations') c
                where s.issue_id = test.id('iss1') and c ->> 'kind' = 'birthday' and c ? 'person_id') = 1,
               'X07: the snapshot holds the opted-in birthday');
-- Nia withdraws her celebration opt-in after approval.
select test.login('');
update public.people set celebration_opt_in = false where id = test.id('pN1');
select test.login('coord'); set role authenticated;
update public.newsletter_issues set send_now_at = now() where id = test.id('iss1');
reset role;
select test.login(''); set role service_role;
select test.ok((select count(*) from public.newsletter_claim_due() where issue_id = test.id('iss1') and live) = 1,
               'X07: the job claims the issue for real sending');
select test.ok(jsonb_array_length(public.newsletter_send_content(test.id('iss1')) -> 'celebrations') = 0,
               'X07: a celebration withdrawn after approval is left out');
select test.ok(not (public.newsletter_send_content(test.id('iss1'))::text like '%person_id%'),
               'X07: the content sent has no person ids');
create temporary table x_recipients as select * from public.newsletter_next_recipients(test.id('iss1'), 100);
reset role;
select test.ok((select count(*) from x_recipients)
               = (select count(*) from public.people where church_id = test.id('churchA') and status = 'active'
                  and newsletter_subscribed and email is not null and anonymised_at is null),
               'X07: every subscribed member with an email is a recipient');
select test.ok((select bool_and(links ? 'unsubscribe' and jsonb_typeof(links -> 'react') = 'object') from x_recipients),
               'X07: each recipient gets their own unsubscribe and reaction links');
select test.ok((select count(*) from public.email_link_tokens where issue_id = test.id('iss1') and purpose = 'unsubscribe')
               = (select count(*) from x_recipients), 'X07: only link hashes are stored, one unsubscribe link each');
select test.login(''); set role service_role;
select test.ok((select public.peek_email_link(links ->> 'unsubscribe') ->> 'purpose' from x_recipients where person_id = test.id('pN2')) = 'unsubscribe',
               'X07: a link can be checked without using it');
select test.ok((select public.redeem_email_link(links ->> 'unsubscribe') from x_recipients where person_id = test.id('pN2')) = 'unsubscribe',
               'X07: an unsubscribe link works');
select public.newsletter_record_deliveries(test.id('iss1'),
  (select jsonb_agg(jsonb_build_object('person_id', person_id, 'provider_id', 'p')) from x_recipients where person_id = test.id('pN1')));
reset role;
select test.ok(not (select newsletter_subscribed from public.people where id = test.id('pN2')), 'X07: ... and the member is unsubscribed');
select test.login('anon'); set role anon;
select test.throws($q$select public.peek_email_link('x')$q$, 'X07: anonymous callers cannot check links');
reset role;
select test.login('editor'); set role authenticated;
select test.throws(format($q$update public.newsletter_issues set headline = 'Too late' where id = %L$q$, test.id('iss1')),
                   'X07: once anyone has received it, the issue cannot change');
reset role;
-- Y02: "Stop sending to members" part-way stops the issue; it never moves to the test list.
select test.login('coord'); set role authenticated;
update public.church_settings set newsletter_live = false;
reset role;
select test.login(''); set role service_role;
select test.throws(format('select * from public.newsletter_next_recipients(%L)', test.id('iss1')),
                   'Y02: no more members are handed over once sending to members is switched off');
select test.ok(public.newsletter_finish(test.id('iss1'), null) = 'retry', 'Y02: ... and the issue is not marked sent');
select test.ok((select count(*) from public.newsletter_claim_due() where issue_id = test.id('iss1')) = 0,
               'Y02: ... nor claimed again (not even for the test list)');
reset role;
select test.ok((select send_error = 'Sending to members was switched off' and send_live from public.newsletter_issues where id = test.id('iss1')),
               'Y02: the issue says why it stopped and stays a members'' issue');
select test.login('rp'); set role authenticated;
update public.church_settings set newsletter_live = true;
reset role;
select test.login(''); set role service_role;
select test.ok((select count(*) from public.newsletter_claim_due() where issue_id = test.id('iss1') and live) = 1,
               'Y02: switched back on, it carries on for members');
create temporary table x_again as select * from public.newsletter_next_recipients(test.id('iss1'), 100);
reset role;
select test.ok(not exists (select 1 from x_again where person_id in (test.id('pN1'), test.id('pN2')))
               and (select count(*) from x_again) = (select count(*) from x_recipients) - 2,
               'Y03: who already had it, and who unsubscribed, are not sent it again');
select test.login(''); set role service_role;
select public.newsletter_record_deliveries(test.id('iss1'),
  (select jsonb_agg(jsonb_build_object('person_id', person_id, 'provider_id', 'p')) from x_again));
select test.ok(public.newsletter_finish(test.id('iss1'), null) = 'sent', 'X07: the unsubscribed member is not waited for; the issue is sent');
reset role;
select test.ok((select status = 'sent' and not sent_as_test from public.newsletter_issues where id = test.id('iss1')), 'X07: sent to members');
select test.login('ops'); set role authenticated;
select test.ok(jsonb_array_length(public.export_person(test.id('pN1')) -> 'newsletter_deliveries') = 1,
               'X07: a subject access export lists the newsletters sent');
reset role;
select test.login('coord'); set role authenticated;
select test.lives($q$update public.church_settings set newsletter_live = false$q$, 'X07: the Coordinator can switch real sending off');
reset role;
select test.login('');
update public.people set celebration_opt_in = true where id = test.id('pN1');
update public.people set newsletter_subscribed = true where id = test.id('pN2');

-- =====================================================================================
-- Y. Security review 18 (slice 6)
-- =====================================================================================
select test.login('editor'); set role authenticated;
select public.start_newsletter_issue((date_trunc('month', now()) + interval '3 months')::date);
reset role;
insert into test.ids select 'iss3', id from public.newsletter_issues
  where issue_month = (date_trunc('month', now()) + interval '3 months')::date;
insert into test.ids select 'iss3p', project_id from public.newsletter_issues where id = test.id('iss3');

-- Y05: the issue's project collects team updates and nothing else.
select test.login('editor'); set role authenticated;
select test.throws(format($q$insert into public.team_demand (project_id, unit_id, on_date, slots_needed)
                             values (%L, %L, (date_trunc('month', now()) + interval '3 months')::date + 5, 2)$q$, test.id('iss3p'), test.id('A1')),
                   'Y05: the editor who owns an issue''s project cannot ask units for volunteers on it');
select test.throws(format($q$insert into public.event_plans (project_id, size, complexity) values (%L, 'small', 'low')$q$, test.id('iss3p')),
                   'Y05: ... nor add an event plan');
select test.throws(format($q$update public.projects set status = 'submitted' where id = %L$q$, test.id('iss3p')),
                   'Y05: ... nor submit it for approval onto the calendar');
select test.throws(format($q$update public.projects set starts_at = starts_at - interval '1 day' where id = %L$q$, test.id('iss3p')),
                   'Y05: ... nor move its dates');
select test.lives(format($q$update public.projects set description = 'Team updates for the issue.' where id = %L$q$, test.id('iss3p')),
                  'Y05: its description can still be changed');
reset role;
select test.login('ops'); set role authenticated;
select test.throws(format($q$insert into public.team_demand (project_id, unit_id, on_date, slots_needed)
                             values (%L, %L, (date_trunc('month', now()) + interval '3 months')::date + 5, 2)$q$, test.id('iss3p'), test.id('A1')),
                   'Y05: not by the Operations Lead either');
reset role;
select test.login('ul_a'); set role authenticated;
select test.lives(format($q$update public.project_inputs set body = 'Y05 update', status = 'received'
                            where project_id = %L and requested_from_user_id = %L$q$, test.id('iss3p'), test.id('ul_a')),
                  'Y05: Team Leads still give their team update on it');
reset role;

-- Y07: an issue that reached nobody is not marked sent (a sent issue is final).
select test.login('');
update public.church_settings set newsletter_test_recipients = '{}', newsletter_live = false where church_id = test.id('churchA');
update public.newsletter_issues set status = 'approved', send_now_at = now() where id = test.id('iss3');
select test.login(''); set role service_role;
select test.ok((select count(*) from public.newsletter_claim_due() where issue_id = test.id('iss3') and not live) = 1, 'Y07: claimed in test mode');
select test.ok(not exists (select 1 from public.newsletter_next_recipients(test.id('iss3'))), 'Y07: with an empty test list nobody is handed over');
select test.ok(public.newsletter_finish(test.id('iss3'), null) = 'retry', 'Y07: ... and the issue is not marked sent');
reset role;
select test.ok((select status = 'approved' and send_error like 'There are no test addresses%' from public.newsletter_issues where id = test.id('iss3')),
               'Y07: the issue says why');

-- Y08: Send now once; Try again only after sending has given up.
select test.login('coord'); set role authenticated;
select test.throws(format('update public.newsletter_issues set send_now_at = now() where id = %L', test.id('iss3')),
                   'Y08: Send now cannot be pressed again while sending is still being tried');
reset role;
select test.login('');
update public.newsletter_issues set send_attempts = 5 where id = test.id('iss3');
select test.login('editor'); set role authenticated;
select test.throws(format('update public.newsletter_issues set send_now_at = now() where id = %L', test.id('iss3')),
                   'Y08: an editor cannot restart sending');
reset role;
select test.login('rp'); set role authenticated;
select test.lives(format('update public.newsletter_issues set send_now_at = now() where id = %L', test.id('iss3')),
                  'Y08: the Resident Pastor can try again once sending has given up');
reset role;
select test.ok((select send_attempts = 0 from public.newsletter_issues where id = test.id('iss3')), 'Y08: ... which starts the attempts again');
select test.login('');
update public.church_settings set newsletter_test_recipients = '{coord@example.org,editor@example.org}' where church_id = test.id('churchA');

-- Y04: an address that stops being a leader's sign-in address drops out of the test list.
update public.app_users set is_active = false where id = test.id('editor');
select test.login(''); set role service_role;
select test.ok((select count(*) from public.newsletter_claim_due() where issue_id = test.id('iss3')) = 1, 'Y04: claimed');
select test.ok((select array_agg(email) from public.newsletter_next_recipients(test.id('iss3'))) = '{coord@example.org}',
               'Y04: a switched-off leader account no longer receives test sends');
reset role;
update public.app_users set is_active = true where id = test.id('editor');

-- Y12: links of a member who has left do nothing, except unsubscribing.
update public.people set status = 'left', date_left = current_date where id = test.id('pN1');
select test.login(''); set role service_role;
select test.ok((select public.peek_email_link(links -> 'react' ->> 'heart') ->> 'purpose' from x_recipients where person_id = test.id('pN1')) = 'invalid',
               'Y12: a reaction link of a member who has left is not valid');
select test.ok((select public.redeem_email_link(links -> 'react' ->> 'heart') from x_recipients where person_id = test.id('pN1')) = 'invalid',
               'Y12: ... and records nothing');
select test.ok((select public.peek_email_link(links ->> 'unsubscribe') ->> 'purpose' from x_recipients where person_id = test.id('pN1')) = 'unsubscribe',
               'Y12: unsubscribing still works');
reset role;
select test.login('');
update public.people set status = 'active', date_left = null where id = test.id('pN1');

-- Grants: nothing new for anonymous callers; the sending functions for the service role only.
select test.ok(not has_function_privilege('anon', p.oid, 'execute'), 'Y: anon cannot run ' || p.oid::regprocedure)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public', 'app')
  and p.proname in ('start_newsletter_issue','newsletter_issue_content','newsletter_claim_due','newsletter_send_content',
                    'newsletter_next_recipients','newsletter_record_deliveries','newsletter_release_deliveries','newsletter_finish',
                    'peek_email_link','redeem_email_link','newsletter_test_send','newsletter_issue_stats','newsletter_content',
                    'newsletter_content_version','newsletter_test_list','is_leader_email','email_link_usable','issue_project_only_inputs');
select test.ok(not has_function_privilege('authenticated', p.oid, 'execute'), 'Y: signed-in users cannot run ' || p.oid::regprocedure)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public', 'app')
  and p.proname in ('newsletter_claim_due','newsletter_send_content','newsletter_next_recipients','newsletter_record_deliveries',
                    'newsletter_release_deliveries','newsletter_finish','peek_email_link','redeem_email_link','newsletter_content',
                    'newsletter_content_version','newsletter_test_list','is_leader_email','email_link_usable','issue_project_only_inputs');

-- =====================================================================================
-- Z. Migration 28: one limit for all serving, counted in hours
-- =====================================================================================
-- Fixture (system): Nia (pN1) joins Production (A1); an approved outreach five months ahead
-- needs Production people for 4 hours on two days and 1 hour on two others.
select test.login('');
insert into public.unit_memberships (church_id, person_id, unit_id) values (test.id('churchA'), test.id('pN1'), test.id('A1'));
insert into public.projects (church_id, level, name, starts_at, ends_at, status, owner_user_id)
values (test.id('churchA'), 'church', 'Autumn outreach',
        date_trunc('month', current_date) + interval '5 months',
        date_trunc('month', current_date) + interval '6 months' - interval '1 second', 'approved', test.id('ops'));
insert into test.ids select 'zoutreach', id from public.projects where name = 'Autumn outreach';
create temporary table z_days as select (date_trunc('month', current_date) + interval '5 months')::date + n as d, n from generate_series(0, 9) n;
grant select on z_days to authenticated;
insert into public.team_demand (church_id, project_id, unit_id, on_date, slots_needed, hours)
select test.id('churchA'), test.id('zoutreach'), test.id('A1'), d, 2, case when n in (0, 1) then 4 when n in (2, 3) then 1 end
from z_days where n <= 4;

select test.login('ops'); set role authenticated;
select test.lives(format('insert into public.assignments (project_id, person_id, unit_id, serve_date, hours) values (%L, %L, %L, %L, 0.5)',
                         test.id('zoutreach'), test.id('pN1'), test.id('A1'), (select d from z_days where n = 0)),
                  'Z01: a 4-hour outreach slot is booked');
select test.ok((select hours from public.assignments where project_id = test.id('zoutreach') and serve_date = (select d from z_days where n = 0)) = 4,
               'Z01: its hours come from the volunteers-needed row, not the caller');
select test.lives(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values (%L, %L, %L, %L)',
                         test.id('zoutreach'), test.id('pN1'), test.id('A1'), (select d from z_days where n = 1)),
                  'Z02: a second 4-hour slot (8 of 9 hours)');
select test.lives(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values (%L, %L, %L, %L)',
                         test.id('zoutreach'), test.id('pN1'), test.id('A1'), (select d from z_days where n = 2)),
                  'Z02: a 1-hour activity still fits (9 of 9 hours)');
select test.throws(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values (%L, %L, %L, %L)',
                          test.id('zoutreach'), test.id('pN1'), test.id('A1'), (select d from z_days where n = 3)),
                   'Z02: one more hour goes over the monthly limit, across all serving');
select test.throws(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) values (%L, %L, %L, %L)',
                          test.id('zoutreach'), test.id('pN1'), test.id('A1'), (select d from z_days where n = 4)),
                   'Z03: a slot with no hours given counts the church default (3 hours), also over');
select test.lives(format('insert into public.assignments (project_id, person_id, unit_id, serve_date, override_reason) values (%L, %L, %L, %L, %L)',
                         test.id('zoutreach'), test.id('pN1'), test.id('A1'), (select d from z_days where n = 3), 'Only trained sound engineer'),
                  'Z04: the Operations Lead can go over with a reason');
update public.assignments set hours = 0.5 where project_id = test.id('zoutreach') and serve_date = (select d from z_days where n = 0);
select test.ok((select hours from public.assignments where project_id = test.id('zoutreach') and serve_date = (select d from z_days where n = 0)) = 4,
               'Z05: nobody can change a slot''s hours directly');
select test.ok((select hours_used = 10 and hours_limit = 9 from public.rota_candidates(test.id('A1'), (select d from z_days where n = 5)) where person_id = test.id('pN1')),
               'Z06: who-can-serve shows hours used and the limit in hours');
select test.ok((select (public.church_dashboard() ->> 'over_limit')::int) >= 0, 'Z07: the Church Dashboard still answers');
reset role;
select test.ok((select count(*) from public.audit_log where action = 'override_limit' and detail ->> 'person_id' = test.id('pN1')::text and detail ? 'limit_hours') = 1,
               'Z04: the override is logged with hours');
select test.login('');
select test.ok(app.hours_in_month(test.id('pN1'), (select d from z_days where n = 0)) = 10, 'Z08: hours across the month add up');
select test.ok(app.hours_limit(test.id('pN1')) = 9, 'Z08: the default limit is 3 slots x 3 hours');
update public.people set available_hours_month = 5 where id = test.id('pN1');
select test.ok(app.hours_limit(test.id('pN1')) = 5, 'Z08: a member who gives fewer hours has a lower limit');
update public.people set available_hours_month = null where id = test.id('pN1');
select test.login('anon'); set role anon;
select test.throws($q$select app.hours_in_month(gen_random_uuid(), current_date)$q$, 'Z09: anonymous callers cannot use the hours helpers');
reset role;

-- ---------- Security review 19 (Z01-Z12) ----------------------------------------------
-- Fixture (system): Zed and Zoe join Production (A1). "Review outreach" (approved, owned by the
-- Purpose Head, seven months ahead) asks A1 for: day 0 anyone 1 h; day 1 Member 1 h and
-- Welfare 8 h; day 2 anyone (church default); day 3 anyone 4 h. "Review draft" (draft) and
-- "Review other team" (approved, asks A2 only) ask nothing of A1 that A1 may fill.
select test.login('');
insert into public.people (church_id, first_name, surname) values (test.id('churchA'), 'Zed', 'Reviewer'), (test.id('churchA'), 'Zoe', 'Reviewer');
insert into test.ids select 'pZ' || first_name, id from public.people where surname = 'Reviewer';
insert into public.unit_memberships (church_id, person_id, unit_id)
select test.id('churchA'), id, test.id('A1') from public.people where surname = 'Reviewer';
insert into test.ids select 'zrMember', id from public.church_roles where church_id = test.id('churchA') and name = 'Member';
insert into test.ids select 'zrWelfare', id from public.church_roles where church_id = test.id('churchA') and name = 'Welfare and Pastoral Coordinator';
insert into public.projects (church_id, level, name, starts_at, ends_at, status, owner_user_id)
select test.id('churchA'), 'church', x.name, date_trunc('month', current_date) + interval '7 months',
       date_trunc('month', current_date) + interval '8 months' - interval '1 second', x.status::public.project_status, test.id('ph')
from (values ('Review outreach', 'approved'), ('Review draft', 'draft'), ('Review other team', 'approved')) x(name, status);
insert into test.ids select 'zr' || replace(substr(name, 8), ' ', ''), id from public.projects where name like 'Review %';
create temporary table z2 as select n, (date_trunc('month', current_date) + interval '7 months')::date + n as d from generate_series(0, 9) n;
grant select on z2 to authenticated;
insert into public.team_demand (church_id, project_id, unit_id, church_role_id, on_date, slots_needed, hours) values
  (test.id('churchA'), test.id('zroutreach'), test.id('A1'), null,                (select d from z2 where n = 0), 2, 1),
  (test.id('churchA'), test.id('zroutreach'), test.id('A1'), test.id('zrMember'),  (select d from z2 where n = 1), 1, 1),
  (test.id('churchA'), test.id('zroutreach'), test.id('A1'), test.id('zrWelfare'), (select d from z2 where n = 1), 1, 8),
  (test.id('churchA'), test.id('zroutreach'), test.id('A1'), null,                (select d from z2 where n = 2), 2, null),
  (test.id('churchA'), test.id('zroutreach'), test.id('A1'), null,                (select d from z2 where n = 3), 2, 4),
  (test.id('churchA'), test.id('zrdraft'),    test.id('A1'), null,                (select d from z2 where n = 0), 2, 1),
  (test.id('churchA'), test.id('zrotherteam'), test.id('A2'), null,               (select d from z2 where n = 0), 2, 1);
create or replace function pg_temp.zbook(p_project text, p_person text, p_day int, p_role text default null) returns text
language sql as $$
  select format('insert into public.assignments (project_id, person_id, unit_id, church_role_id, serve_date) values (%L, %L, %L, %L, %L)',
                test.id(p_project), test.id(p_person), test.id('A1'), case when p_role is null then null else test.id(p_role) end,
                (select d from z2 where n = p_day))
$$;
create or replace function pg_temp.zhours(p_person text, p_day int) returns numeric
language sql as $$
  select hours from public.assignments where person_id = test.id(p_person) and serve_date = (select d from z2 where n = p_day) and status = 'planned'
$$;

grant execute on function pg_temp.zbook(text, text, int, text), pg_temp.zhours(text, int) to authenticated;
select test.login('ul_a'); set role authenticated;
select test.lives(pg_temp.zbook('zroutreach', 'pZZed', 2), 'Z01: (Zed takes a default slot, 3 h)');
select test.lives(pg_temp.zbook('zroutreach', 'pZZed', 1, 'zrMember'), 'Z02: Zed takes a 1-hour Member place (4 of 9 h)');
select test.ok(pg_temp.zhours('pZZed', 1) = 1, 'Z02: ... counted as 1 hour');
select test.throws(format('update public.assignments set church_role_id = %L where person_id = %L and serve_date = %L',
                          test.id('zrWelfare'), test.id('pZZed'), (select d from z2 where n = 1)),
                   'Z02: switching the booking to the 8-hour Welfare place in place is checked against the limit (11 of 9 h)');
select test.ok(pg_temp.zhours('pZZed', 1) = 1, 'Z02: ... and the booking keeps its 1 hour');
select test.lives(pg_temp.zbook('zroutreach', 'pZZed', 0), 'Z01: Zed takes a 1-hour place on day 0 (5 of 9 h)');
reset role;

-- Z01: the project owner (Purpose Head) changes the hours after people are booked.
select test.login('ph'); set role authenticated;
select test.throws(format('update public.team_demand set hours = 8 where project_id = %L and on_date = %L',
                          test.id('zroutreach'), (select d from z2 where n = 0)),
                   'Z01: raising a place to 8 hours that would take a booked person over the limit is refused');
select test.lives(format('update public.team_demand set hours = 4 where project_id = %L and on_date = %L',
                         test.id('zroutreach'), (select d from z2 where n = 0)),
                  'Z01: raising it to 4 hours (8 of 9 h) is allowed');
reset role;
select test.ok(pg_temp.zhours('pZZed', 0) = 4, 'Z01: ... and the booking now counts 4 hours');
select test.ok(exists (select 1 from public.audit_log where action = 'demand_hours' and detail ->> 'to' = '4.0'),
               'Z09: the change of hours on a booked place is logged');
select test.login('ph'); set role authenticated;
select test.lives(format('update public.team_demand set hours = 2 where project_id = %L and on_date = %L',
                         test.id('zroutreach'), (select d from z2 where n = 0)),
                  'Z01: lowering a place''s hours is allowed');
reset role;
select test.ok(pg_temp.zhours('pZZed', 0) = 2, 'Z01: ... and the booking follows it (2 h)');
select test.login('ph'); set role authenticated;
-- Z03: a second row for the same place with fewer hours does not lower the default place.
select test.lives(format('insert into public.team_demand (project_id, unit_id, on_date, slots_needed, hours) values (%L, %L, %L, 1, 0.5)',
                         test.id('zroutreach'), test.id('A1'), (select d from z2 where n = 2)),
                  'Z03: (owner adds a half-hour row beside the default-hours row on day 2)');
reset role;
select test.ok(pg_temp.zhours('pZZed', 2) = 3, 'Z03: the default-hours booking still counts 3 hours');
select test.login('ul_a'); set role authenticated;
select test.lives(pg_temp.zbook('zroutreach', 'pZZoe', 2), 'Z03: (Zoe books day 2)');
select test.ok(pg_temp.zhours('pZZoe', 2) = 3, 'Z03: ... counted at the larger of the two (3 h, not 0.5)');
select test.lives(pg_temp.zbook('zroutreach', 'pZZoe', 3, 'zrMember'), 'Z03: (Zoe books the 4-hour any-role place on day 3 naming a role)');
select test.ok(pg_temp.zhours('pZZoe', 3) = 4, 'Z03: ... counted at that place''s 4 hours, not the default 3');
-- Z04: a booking fills a place the team was asked for, on an approved project.
select test.throws(pg_temp.zbook('zrdraft', 'pZZoe', 0), 'Z04: no booking on a draft project');
select test.throws(pg_temp.zbook('zrotherteam', 'pZZoe', 0), 'Z04: no booking on a project that did not ask this team');
select test.throws(pg_temp.zbook('zroutreach', 'pZZoe', 5), 'Z04: no booking on a day with no place for the team');
select test.throws(format('update public.assignments set project_id = %L where person_id = %L and serve_date = %L',
                          test.id('zrdraft'), test.id('pZZed'), (select d from z2 where n = 0)),
                   'Z04: a booking cannot be moved onto a draft project');
reset role;
-- Z05: the guard holds a per-person lock for the month, so two bookings at once queue (the race
-- itself was re-run by hand with two sessions). The booking is rolled back.
do $$
declare v boolean := false;
begin
  begin
    perform test.login('ul_a');
    set local role authenticated;
    execute pg_temp.zbook('zroutreach', 'pZZoe', 0);
    reset role;
    v := exists (select 1 from pg_locks where locktype = 'advisory' and pid = pg_backend_pid() and granted);
    raise exception 'roll back' using errcode = 'P0001';
  exception when sqlstate 'P0001' then null;
  end;
  perform test.ok(v, 'Z05: booking takes the person''s monthly lock until the transaction ends');
end $$;
-- Z06: removing a place keeps the hours of people booked for it.
select test.login('ph'); set role authenticated;
select test.lives(format('delete from public.team_demand where project_id = %L and on_date = %L', test.id('zroutreach'), (select d from z2 where n = 0)),
                  'Z06: (owner removes the day-0 place)');
reset role;
select test.ok(pg_temp.zhours('pZZed', 0) = 2, 'Z06: the booking keeps its 2 hours');
-- Z08: hours in half-hour steps; the church''s hours per slot within what a slot can hold.
select test.login('ph'); set role authenticated;
select test.throws(format('insert into public.team_demand (project_id, unit_id, on_date, slots_needed, hours) values (%L, %L, %L, 1, 0.7)',
                          test.id('zroutreach'), test.id('A1'), (select d from z2 where n = 4)),
                   'Z08: hours are in half-hour steps');
reset role;
select test.login('');
select test.throws(format('update public.church_settings set hours_per_slot = 20 where church_id = %L', test.id('churchA')),
                   'Z08: hours per slot cannot exceed 16 (a slot''s maximum)');
-- Z10: the hours helpers are for the database only.
select test.ok(not has_function_privilege('authenticated', 'app.hours_in_month(uuid, date, uuid)', 'execute')
               and not has_function_privilege('authenticated', 'app.hours_limit(uuid)', 'execute')
               and not has_function_privilege('authenticated', 'app.slot_hours(uuid, uuid, uuid, date)', 'execute')
               and not has_function_privilege('authenticated', 'app.place_hours(uuid, uuid, uuid, date)', 'execute'),
               'Z10: signed-in users cannot call the hours helpers directly');
select test.ok(not has_function_privilege('authenticated', 'app.demand_hours_sync()', 'execute'), 'Z10: nor the demand trigger');

-- =====================================================================================
-- F. Migrations 29-30: fair share, a Sunday off each month, leaders' load
-- =====================================================================================
-- Fixture (system): Obi (pN2) joins Production; the limit is raised to 10 slots for these
-- checks so only the Sunday rule decides; every Sunday eight months ahead gets a grid.
select test.login('');
insert into public.unit_memberships (church_id, person_id, unit_id) values (test.id('churchA'), test.id('pN2'), test.id('A1'));
update public.church_settings set serving_limit_per_month = 10 where church_id = test.id('churchA');
create temporary table f_sundays as
  select d::date as d, row_number() over (order by d) as n
  from generate_series(date_trunc('month', current_date + interval '8 months'),
                       date_trunc('month', current_date + interval '8 months') + interval '1 month - 1 day', interval '1 day') d
  where extract(isodow from d) = 7;
grant select on f_sundays to authenticated;
select test.login('ops'); set role authenticated;
select public.create_sunday_service(d) from f_sundays;
select test.ok(app_sundays.allowed = (select count(*) from f_sundays) - 1, 'F01: Sundays allowed = the month''s Sundays less one')
from (select a.sundays_allowed as allowed from public.rota_candidates(test.id('A1'), (select d from f_sundays where n = 1)) a
      where a.person_id = test.id('pN2')) app_sundays;
do $$
declare r record;
begin
  for r in select f.d, f.n from f_sundays f where f.n < (select count(*) from f_sundays) order by f.n loop
    insert into public.assignments (project_id, person_id, unit_id, serve_date)
    select g.project_id, test.id('pN2'), test.id('A1'), r.d from public.service_grids g where g.service_date = r.d;
  end loop;
end $$;
select test.ok((select sundays_served from public.rota_candidates(test.id('A1'), (select d from f_sundays where n = 1)) where person_id = test.id('pN2'))
               = (select count(*) - 1 from f_sundays), 'F02: every Sunday but one is booked');
select test.throws(format('insert into public.assignments (project_id, person_id, unit_id, serve_date) select project_id, %L, %L, service_date from public.service_grids where service_date = %L',
                          test.id('pN2'), test.id('A1'), (select max(d) from f_sundays)),
                   'F03: the last Sunday is refused: at least one Sunday off');
select test.lives(format('insert into public.assignments (project_id, person_id, unit_id, serve_date, override_reason) select project_id, %L, %L, service_date, %L from public.service_grids where service_date = %L',
                         test.id('pN2'), test.id('A1'), 'Covering an emergency', (select max(d) from f_sundays)),
                  'F04: the Operations Lead can override with a reason');
reset role;
select test.ok((select count(*) from public.audit_log where action = 'override_rest' and detail ->> 'person_id' = test.id('pN2')::text) = 1,
               'F04: the rest override is logged');
-- Leaders' load: allow one leadership role, so Team Leads with two teams are over.
select test.login('');
update public.church_settings set leader_roles_max = 1, serving_limit_per_month = 3 where church_id = test.id('churchA');
select test.login('coord'); set role authenticated;
select test.ok(exists (select 1 from public.leaders_carrying_too_much() where user_id = test.id('ul_a')),
               'F05: the Coordinator sees leaders carrying more than the church allows');
select test.ok((public.fair_share(current_date) ->> 'leaders_over')::int >= 1, 'F05: the Dashboard counts them');
select test.ok(public.fair_share(current_date) ?& array['bands', 'busiest_fifth_share', 'not_asked_3_months', 'members'],
               'F06: fair share gives bands, the busiest fifth''s share and members not asked');
select test.ok((select sum(value::int) from jsonb_each_text(public.fair_share(current_date) -> 'bands'))
               = (public.fair_share(current_date) ->> 'members')::int, 'F06: the bands add up to all members');
select test.ok((public.fair_share((current_date + interval '8 months')::date) ->> 'busiest_fifth_share')::int = 100
               or (public.fair_share((current_date + interval '8 months')::date) ->> 'busiest_fifth_share')::int > 0,
               'F06: the busiest fifth''s share is a percentage');
reset role;
select test.login('ul_b'); set role authenticated;
select test.throws('select * from public.leaders_carrying_too_much()', 'F07: a Team Lead cannot list leaders by name');
reset role;
select test.login('teci'); set role authenticated;
select test.throws('select public.fair_share(current_date)', 'F07: the TECi Coordinator does not see the fair-share panel');
reset role;
select test.login('anon'); set role anon;
select test.throws('select public.fair_share(current_date)', 'F07: nor anonymous callers');
reset role;
-- The nightly job raises a check-in flag for a leader linked to their own record.
select test.login('');
update public.app_users set person_id = test.id('pN2') where id = test.id('ul_a');
select app.raise_automatic_flags();
select test.ok(exists (select 1 from public.checkin_flags where person_id = test.id('pN2') and source = 'leader_load'),
               'F08: a leader carrying too much gets a pastoral check-in flag');
update public.church_settings set leader_roles_max = 2 where church_id = test.id('churchA');

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
