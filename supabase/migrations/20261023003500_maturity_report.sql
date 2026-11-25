-- =====================================================================================
-- Migration 35: leadership stage history, the discipleship pathway stage, and the
-- quarterly Maturity report (decisions of 25 Nov 2026, Paul).
--
-- 1. Leadership stage history: every time a G-Squad member's leadership stage in a team is
--    set or changed, the database writes it down (leadership_stage_changes), so moves can be
--    seen over time. Written only by the trigger; read by those who can read the member.
-- 2. Pathway stage: the Maturity Team's discipleship pathway (Encounter, Foundation,
--    Community, Depth, Sending; G-Squad is Stage 5) as a reference list the retreat can
--    change (pathway_stages), and each member's stages reached, with dates
--    (person_pathway). Treated like the faith fields: no direct table access; read only
--    through get_person_pathway (logged) by those who may see the member's faith, recorded
--    through set_person_pathway / remove_person_pathway (logged) by their Team Lead or the
--    G-Squad Coordinator (app.can_edit_faith).
-- 3. maturity_report(quarter): counts only, never names, for the roles that read the
--    monthly report (as focus_areas_summary): leadership and pathway stages and moves,
--    courses, baptisms, settling in, mentoring and one-to-ones.
-- Anonymising removes a member's pathway and stage history (R8); export_person includes them.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Leadership stage history
-- -------------------------------------------------------------------------------------
create table public.leadership_stage_changes (
  id             uuid primary key default gen_random_uuid(),
  church_id      uuid not null default app.current_church_id() references public.churches(id) on delete restrict,
  membership_id  uuid not null,
  person_id      uuid not null,
  unit_id        uuid not null,
  from_stage_id  uuid,
  to_stage_id    uuid,
  changed_on     date not null default ((now() at time zone 'Europe/London')::date),
  changed_by     uuid,                      -- the leader who made the change (null: the system)
  changed_at     timestamptz not null default now(),
  unique (church_id, id),
  foreign key (church_id, membership_id) references public.unit_memberships(church_id, id) on delete cascade,
  foreign key (church_id, person_id) references public.people(church_id, id) on delete cascade,
  foreign key (church_id, unit_id) references public.units(church_id, id) on delete cascade,
  foreign key (church_id, from_stage_id) references public.leadership_stages(church_id, id) on delete set null (from_stage_id),
  foreign key (church_id, to_stage_id) references public.leadership_stages(church_id, id) on delete set null (to_stage_id)
);
create index leadership_stage_changes_person on public.leadership_stage_changes (person_id, changed_on);
create index leadership_stage_changes_church_day on public.leadership_stage_changes (church_id, changed_on);
comment on table public.leadership_stage_changes is
  'Each time a member''s leadership stage in a team is set or changed (migration 35). Written only by the trigger on unit_memberships.';

-- The trigger: one row per change of leadership_stage_id (set, moved, or cleared).
create or replace function app.record_leadership_stage() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.leadership_stage_id is null then
      return null;
    end if;
  elsif new.leadership_stage_id is not distinct from old.leadership_stage_id then
    return null;
  end if;
  insert into public.leadership_stage_changes (church_id, membership_id, person_id, unit_id, from_stage_id, to_stage_id, changed_by)
  values (new.church_id, new.id, new.person_id, new.unit_id,
          case when tg_op = 'UPDATE' then old.leadership_stage_id end, new.leadership_stage_id,
          (select auth.uid()));
  return null;
end $$;
revoke all on function app.record_leadership_stage() from public, anon, authenticated;
grant execute on function app.record_leadership_stage() to service_role;
create trigger unit_memberships_stage_history after insert or update of leadership_stage_id on public.unit_memberships
  for each row execute function app.record_leadership_stage();

-- Where each member stands today becomes the first entry (no "from"; dated when they joined
-- the team), so later moves have something to start from. These never count as moves.
insert into public.leadership_stage_changes (church_id, membership_id, person_id, unit_id, from_stage_id, to_stage_id, changed_on, changed_by)
select m.church_id, m.id, m.person_id, m.unit_id, null, m.leadership_stage_id, coalesce(m.joined_on, current_date), null
from public.unit_memberships m
where m.leadership_stage_id is not null;

alter table public.leadership_stage_changes enable row level security;
revoke all on public.leadership_stage_changes from public, anon, authenticated;
-- Read only: the history is written by the trigger, never by a leader directly.
grant select on public.leadership_stage_changes to authenticated;
create policy leadership_stage_changes_read on public.leadership_stage_changes for select to authenticated
  using (church_id = (select app.current_church_id()) and app.can_read_person(person_id));

-- -------------------------------------------------------------------------------------
-- 2. The discipleship pathway
-- -------------------------------------------------------------------------------------
create table public.pathway_stages (
  id           uuid primary key default gen_random_uuid(),
  church_id    uuid not null default app.current_church_id() references public.churches(id) on delete restrict,
  stage_no     smallint not null check (stage_no between 1 and 20),
  name         text not null check (length(btrim(name)) between 1 and 100),
  description  text check (length(description) <= 2000),
  marker       text check (length(marker) <= 2000),   -- how a leader knows someone is at this stage
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  unique (church_id, id),
  unique (church_id, name)
);
comment on table public.pathway_stages is
  'The Maturity Team''s discipleship pathway stages (reference form, migration 35). Approved at the December 2026 retreat; editable.';

alter table public.pathway_stages enable row level security;
revoke all on public.pathway_stages from public, anon;
grant select, insert, update, delete on public.pathway_stages to authenticated;
revoke truncate, references, trigger on public.pathway_stages from authenticated;
-- Every leader reads the list; the Operations Lead and G-Squad Coordinator keep it.
create policy pathway_stages_read on public.pathway_stages for select to authenticated
  using (church_id = (select app.current_church_id()));
-- (FOR ALL, as for the other reference forms: everyone reads the list anyway.)
create policy pathway_stages_write on public.pathway_stages for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])));
create trigger pathway_stages_audit after insert or update or delete on public.pathway_stages
  for each row execute function app.audit_row_change();

-- The pathway in the Discipleship and Maturity Plan 2027-2028, for each church (seed.sql
-- adds it for a new one). The retreat may rename, reword or switch stages off.
insert into public.pathway_stages (church_id, stage_no, name, description)
select c.id, x.stage_no, x.name, x.description
from public.churches c
cross join (values
  (1, 'Encounter', 'Meeting Jesus and the church for the first time.'),
  (2, 'Foundation', 'Laying the foundations of faith: the new converts class and water baptism.'),
  (3, 'Community', 'Belonging: in a Greatness Community and growing with others.'),
  (4, 'Depth', 'Growing deeper: the discipleship class, the Greatness Track Program and daily habits.'),
  (5, 'Sending', 'Serving and leading others: the G-Squad.')
) as x(stage_no, name, description)
on conflict do nothing;

-- A member's stages reached. Like person_faith: row-level security on, no policies, no
-- grants, so it is reached only through the logged functions below.
create table public.person_pathway (
  id           uuid primary key default gen_random_uuid(),
  church_id    uuid not null references public.churches(id) on delete restrict,
  person_id    uuid not null,
  stage_id     uuid not null,
  reached_on   date not null,
  recorded_by  uuid,
  recorded_at  timestamptz not null default now(),
  unique (church_id, id),
  foreign key (church_id, person_id) references public.people(church_id, id) on delete cascade,
  foreign key (church_id, stage_id) references public.pathway_stages(church_id, id) on delete restrict
);
create index person_pathway_person on public.person_pathway (person_id, reached_on);
comment on table public.person_pathway is
  'Pathway stages a G-Squad member has reached, with dates (migration 35). Treated like the faith fields: only through get_person_pathway / set_person_pathway / remove_person_pathway, every view and change logged.';
alter table public.person_pathway enable row level security;
revoke all on public.person_pathway from public, anon, authenticated;

-- Read a member's pathway (logged). VOLATILE, as get_person_faith (F03): PostgREST runs
-- STABLE functions read-only, where the audit insert would fail.
create or replace function public.get_person_pathway(p_person uuid)
returns table (id uuid, stage_id uuid, stage_no smallint, stage_name text, reached_on date, recorded_at timestamptz)
language plpgsql volatile security definer set search_path = ''
as $$
begin
  if not app.can_see_faith(p_person) then
    raise exception 'Not allowed to view the pathway for this person' using errcode = '42501';
  end if;
  perform app.audit('view_pathway', 'person_pathway', p_person);
  return query
    select x.id, x.stage_id, s.stage_no, s.name, x.reached_on, x.recorded_at
    from public.person_pathway x join public.pathway_stages s on s.id = x.stage_id
    where x.person_id = p_person
    order by x.reached_on, x.recorded_at;
end $$;
revoke all on function public.get_person_pathway(uuid) from public, anon;
grant execute on function public.get_person_pathway(uuid) to authenticated, service_role;

-- Record a stage reached (logged). Their Team Lead or the G-Squad Coordinator, as for the
-- faith fields; a stage in use, on a day that has come.
create or replace function public.set_person_pathway(p_person uuid, p_stage uuid, p_reached_on date default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Europe/London')::date;
  v_on date := coalesce(p_reached_on, v_today);
  v_id uuid;
begin
  if not app.can_edit_faith(p_person) then
    raise exception 'Only their Team Lead or the G-Squad Coordinator can record the pathway' using errcode = '42501';
  end if;
  if not exists (select 1 from public.pathway_stages s
                 where s.id = p_stage and s.church_id = app.current_church_id() and s.is_active) then
    raise exception 'Choose a pathway stage in use' using errcode = '23514';
  end if;
  if v_on > v_today then
    raise exception 'A stage is recorded once it is reached' using errcode = '23514';
  end if;
  if v_on < date '1900-01-01' then
    raise exception 'Check the date' using errcode = '23514';
  end if;
  insert into public.person_pathway (church_id, person_id, stage_id, reached_on, recorded_by)
  values (app.current_church_id(), p_person, p_stage, v_on, (select auth.uid()))
  returning id into v_id;
  perform app.audit('set_pathway', 'person_pathway', p_person, jsonb_build_object('stage_id', p_stage, 'reached_on', v_on));
  return v_id;
end $$;
revoke all on function public.set_person_pathway(uuid, uuid, date) from public, anon;
grant execute on function public.set_person_pathway(uuid, uuid, date) to authenticated, service_role;

-- Take back an entry recorded in error (logged). Same people as recording it.
create or replace function public.remove_person_pathway(p_entry uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_person uuid;
begin
  select x.person_id into v_person from public.person_pathway x
  where x.id = p_entry and x.church_id = app.current_church_id();
  -- The same refusal whether the entry is missing or not theirs to change.
  if v_person is null or not app.can_edit_faith(v_person) then
    raise exception 'Only their Team Lead or the G-Squad Coordinator can change the pathway' using errcode = '42501';
  end if;
  delete from public.person_pathway where id = p_entry;
  perform app.audit('remove_pathway', 'person_pathway', v_person, jsonb_build_object('entry', p_entry));
end $$;
revoke all on function public.remove_person_pathway(uuid) from public, anon;
grant execute on function public.remove_person_pathway(uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- Anonymising (R8) removes both; re-created whole from migration 34 with the marked lines.
-- -------------------------------------------------------------------------------------
create or replace function app.anonymise(p_person uuid) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  -- Marker read by app.people_guard() so this one update may set anonymised_at.
  perform set_config('gsquad.anonymising', 'on', true);
  update public.people set
    first_name = 'Former', other_names = null, surname = 'member',
    email = null, area = null, marital_status = null,
    phones = '{}', other_emails = '{}',   -- migration 25
    birth_day = null, birth_month = null, anniversary_day = null, anniversary_month = null,
    greatness_community_id = null, available_hours_month = null, preferred_times = '{}',
    newsletter_subscribed = false, celebration_opt_in = false,
    status = 'left', date_left = coalesce(date_left, current_date),
    anonymised_at = now()
  where id = p_person and anonymised_at is null;
  delete from public.person_faith where person_id = p_person;
  delete from public.pastoral_notes where person_id = p_person;
  delete from public.one_to_ones where person_id = p_person;
  delete from public.recognitions where person_id = p_person;   -- ASHLIE: free text about the person
  delete from public.holidays where person_id = p_person;
  delete from public.checkin_flags where person_id = p_person;
  delete from public.email_link_tokens where person_id = p_person;
  -- Migration 34: settling-in steps, courses, and pairings on either side.
  delete from public.assimilation_steps where person_id = p_person;
  delete from public.course_completions where person_id = p_person;
  delete from public.member_mentors where person_id = p_person or mentor_person_id = p_person;
  -- Migration 35: their pathway stages (like faith) and leadership stage history.
  delete from public.person_pathway where person_id = p_person;
  delete from public.leadership_stage_changes where person_id = p_person;
  update public.community_support_roles set person_id = null where person_id = p_person;
  update public.app_users set person_id = null where person_id = p_person;
  -- Decision of 23 Oct 2026: an anonymised person leaves every unit, so "Former member" no
  -- longer appears on any team list. Serving history (assignments) stays as anonymous counts.
  -- SECURITY REVIEW FIX N02: date the end to when the person left (set just above), not to
  -- today. greatest() keeps the end on or after the joining date for oddly entered records.
  update public.unit_memberships m
     set status = 'ended',
         ended_on = greatest(m.joined_on, coalesce((select p.date_left from public.people p where p.id = p_person), current_date))
   where m.person_id = p_person and m.status <> 'ended';
  -- SECURITY REVIEW FIX F14: the free-text override reason can describe the person's
  -- circumstances; wipe it with the rest of their personal details.
  update public.assignments set override_reason = null where person_id = p_person and override_reason is not null;
  perform set_config('gsquad.anonymising', 'off', true);
end $$;
revoke all on function app.anonymise(uuid) from public, anon, authenticated;
grant execute on function app.anonymise(uuid) to service_role;

-- -------------------------------------------------------------------------------------
-- export_person (rights requests) gains both. Re-created whole from migration 34 with the
-- marked additions.
-- -------------------------------------------------------------------------------------
create or replace function public.export_person(p_person uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v jsonb;
begin
  if not (app.has_role('operations_lead') or app.has_role('resident_pastor'))
     or not exists (select 1 from public.people p where p.id = p_person and p.church_id = app.current_church_id()) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'person',        (select to_jsonb(p) - 'created_by' from public.people p where p.id = p_person),
    'memberships',   (select coalesce(jsonb_agg(to_jsonb(m)), '[]') from public.unit_memberships m where m.person_id = p_person),
    'holidays',      (select coalesce(jsonb_agg(to_jsonb(h)), '[]') from public.holidays h where h.person_id = p_person),
    'assignments',   (select coalesce(jsonb_agg(to_jsonb(a) - 'override_reason'), '[]') from public.assignments a where a.person_id = p_person),
    'one_to_ones',   case when app.has_role('resident_pastor')
                          then (select coalesce(jsonb_agg(to_jsonb(o)), '[]') from public.one_to_ones o where o.person_id = p_person)
                     end,
    'one_to_one_walk', case when app.has_role('resident_pastor')
                          then (select coalesce(jsonb_agg(to_jsonb(w)), '[]') from public.one_to_one_walk w
                                join public.one_to_ones o on o.id = w.one_to_one_id where o.person_id = p_person)
                     end,
    'one_to_one_answers', case when app.has_role('resident_pastor')
                          then (select coalesce(jsonb_agg(jsonb_build_object('question', q.question, 'answer', a.answer, 'quarter', o.quarter_start)), '[]')
                                from public.one_to_one_answers a
                                join public.one_to_ones o on o.id = a.one_to_one_id
                                join public.one_to_one_prompts q on q.id = a.prompt_id
                                where o.person_id = p_person)
                     end,
    'faith',         case when app.can_see_faith(p_person)
                          then (select to_jsonb(f) from public.person_faith f where f.person_id = p_person)
                     end,
    'pastoral_notes', case when app.has_role('resident_pastor')
                          then (select coalesce(jsonb_agg(to_jsonb(n)), '[]') from public.pastoral_notes n where n.person_id = p_person)
                     end,
    'recognitions',  (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from public.recognitions r where r.person_id = p_person),
    'newsletter_rsvps', (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from public.newsletter_rsvps r where r.person_id = p_person),
    'newsletter_reactions', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from public.newsletter_reactions x where x.person_id = p_person),
    -- Migration 27: which issues were emailed to them, and when.
    'newsletter_deliveries', (select coalesce(jsonb_agg(jsonb_build_object('issue_month', i.issue_month, 'sent_at', d.sent_at)), '[]')
                              from public.newsletter_deliveries d join public.newsletter_issues i on i.id = d.issue_id
                              where d.person_id = p_person and d.provider_id is not null),   -- Y03: confirmed only
    'checkin_flags',    (select coalesce(jsonb_agg(to_jsonb(cf)), '[]') from public.checkin_flags cf where cf.person_id = p_person),
    'community_roles',  (select coalesce(jsonb_agg(to_jsonb(c)), '[]') from public.community_support_roles c where c.person_id = p_person),
    -- Migration 34: settling-in steps, courses completed, and pairings (the other person by name only).
    'settling_in',      (select coalesce(jsonb_agg(jsonb_build_object('step', s.step, 'done_on', s.done_on) order by s.done_on), '[]')
                         from public.assimilation_steps s where s.person_id = p_person),
    'courses',          (select coalesce(jsonb_agg(jsonb_build_object('course', t.name, 'completed_on', c.completed_on) order by c.completed_on), '[]')
                         from public.course_completions c join public.course_types t on t.id = c.course_type_id
                         where c.person_id = p_person
                           -- SECURITY REVIEW 26 (T01), all courses the same (25 Nov 2026): only for
                           -- a caller who may see the member's faith, as for 'faith' above.
                           and app.can_see_faith(p_person)),
    'pairings',         (select coalesce(jsonb_agg(jsonb_build_object(
                           'kind', mm.kind, 'role', case when mm.person_id = p_person then 'supported by' else 'supporting' end,
                           'other_person', (select o.first_name || ' ' || o.surname from public.people o
                                            where o.id = case when mm.person_id = p_person then mm.mentor_person_id else mm.person_id end),
                           'started_on', mm.started_on, 'ended_on', mm.ended_on) order by mm.started_on), '[]')
                         from public.member_mentors mm where mm.person_id = p_person or mm.mentor_person_id = p_person),
    -- Migration 35: leadership stage history, and pathway stages only for a caller who may
    -- see the member's faith (treated like the faith fields, decision of 25 Nov 2026).
    'leadership_stages', (select coalesce(jsonb_agg(jsonb_build_object(
                            'team', u.name, 'from', fs.name, 'to', ts.name, 'changed_on', c.changed_on) order by c.changed_on, c.changed_at), '[]')
                          from public.leadership_stage_changes c
                          join public.units u on u.id = c.unit_id
                          left join public.leadership_stages fs on fs.id = c.from_stage_id
                          left join public.leadership_stages ts on ts.id = c.to_stage_id
                          where c.person_id = p_person),
    'pathway',          case when app.can_see_faith(p_person)
                          then (select coalesce(jsonb_agg(jsonb_build_object('stage', s.name, 'reached_on', x.reached_on)
                                                          order by x.reached_on, x.recorded_at), '[]')
                                from public.person_pathway x join public.pathway_stages s on s.id = x.stage_id
                                where x.person_id = p_person)
                     end
  ) into v;
  perform app.audit('export_person', 'people', p_person);
  return v;
end $$;
revoke all on function public.export_person(uuid) from public, anon;
grant execute on function public.export_person(uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 3. The quarterly Maturity report: counts only, never names.
-- -------------------------------------------------------------------------------------
create or replace function public.maturity_report(p_quarter date default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_church uuid := app.current_church_id();
  v_q date := date_trunc('quarter', coalesce(p_quarter, (now() at time zone 'Europe/London')::date))::date;
  v_end date := (v_q + interval '3 months')::date;
  v_leadership jsonb;
  v_pathway jsonb;
  v_rest jsonb;
begin
  -- The roles that read the monthly report and the four focus areas.
  if not app.has_any_role(array['gsquad_coordinator','resident_pastor','purpose_head',
                                'operations_lead','pastoral_lead']::public.app_role[]) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  -- Leadership: members at each stage now (active members in a live team place, counted once
  -- per stage), and moves to a later stage during the quarter.
  with live as (
    select distinct m.person_id, m.leadership_stage_id
    from public.unit_memberships m join public.people p on p.id = m.person_id
    where m.church_id = v_church and m.status = 'active' and p.status = 'active' and p.anonymised_at is null
  ), moves as (
    select c.person_id
    from public.leadership_stage_changes c
    join public.leadership_stages fs on fs.id = c.from_stage_id
    join public.leadership_stages ts on ts.id = c.to_stage_id
    where c.church_id = v_church and c.changed_on >= v_q and c.changed_on < v_end and ts.sort_order > fs.sort_order
  )
  select jsonb_build_object(
           'stages', (select coalesce(jsonb_agg(jsonb_build_object('stage', ls.name,
                               'members', (select count(distinct l.person_id) from live l where l.leadership_stage_id = ls.id))
                             order by ls.sort_order), '[]')
                      from public.leadership_stages ls where ls.church_id = v_church),
           'no_stage', (select count(distinct l.person_id) from live l
                        where l.leadership_stage_id is null
                          and not exists (select 1 from live l2 where l2.person_id = l.person_id and l2.leadership_stage_id is not null)),
           'moves_up', (select count(*) from moves),
           'members_moved_up', (select count(distinct person_id) from moves),
           'leadership_courses', (select count(*) from public.course_completions c join public.course_types t on t.id = c.course_type_id
                                  where c.church_id = v_church and t.kind = 'leadership' and c.completed_on >= v_q and c.completed_on < v_end))
    into v_leadership;

  -- Pathway: each active member's latest stage reached by the quarter's end, and moves to a
  -- later stage recorded in the quarter (first entries counted apart).
  with entries as (
    select x.person_id, x.reached_on, x.recorded_at, s.stage_no, s.id as stage_id,
           lag(s.stage_no) over (partition by x.person_id order by x.reached_on, x.recorded_at) as prev_no
    from public.person_pathway x join public.pathway_stages s on s.id = x.stage_id
    where x.church_id = v_church and x.reached_on < v_end
  ), latest as (
    select distinct on (e.person_id) e.person_id, e.stage_id
    from entries e join public.people p on p.id = e.person_id
    where p.status = 'active' and p.anonymised_at is null
    order by e.person_id, e.reached_on desc, e.recorded_at desc
  )
  select jsonb_build_object(
           'stages', (select coalesce(jsonb_agg(jsonb_build_object('stage', s.name, 'stage_no', s.stage_no,
                               'members', (select count(*) from latest l where l.stage_id = s.id))
                             order by s.stage_no), '[]')
                      from public.pathway_stages s where s.church_id = v_church),
           'not_recorded', (select count(*) from public.people p
                            where p.church_id = v_church and p.status = 'active' and p.anonymised_at is null
                              and not exists (select 1 from latest l where l.person_id = p.id)),
           'moved_on', (select count(*) from entries e where e.reached_on >= v_q and e.prev_no is not null and e.stage_no > e.prev_no),
           'first_recorded', (select count(*) from entries e where e.reached_on >= v_q and e.prev_no is null))
    into v_pathway;

  select jsonb_build_object(
           'members', (select count(*) from public.people p
                       where p.church_id = v_church and p.status = 'active' and p.anonymised_at is null),
           'courses', (select coalesce(jsonb_agg(jsonb_build_object('course', t.name, 'kind', t.kind,
                               'completed', (select count(*) from public.course_completions c
                                             where c.course_type_id = t.id and c.completed_on >= v_q and c.completed_on < v_end))
                             order by t.sort_order), '[]')
                       from public.course_types t where t.church_id = v_church),
           'water_baptisms', (select count(*) from public.person_faith f
                              where f.church_id = v_church and f.water_baptism_date >= v_q and f.water_baptism_date < v_end),
           'spirit_baptisms', (select count(*) from public.person_faith f
                               where f.church_id = v_church and f.holy_spirit_baptism_date >= v_q and f.holy_spirit_baptism_date < v_end),
           'new_members', (select count(*) from public.people p
                           where p.church_id = v_church and p.anonymised_at is null and p.date_joined >= v_q and p.date_joined < v_end),
           -- Settled in during the quarter: the six recorded steps all done, the last of them in it.
           'settled_in', (select count(*) from (
                            select s.person_id from public.assimilation_steps s
                            where s.church_id = v_church
                            group by s.person_id
                            having count(distinct s.step) = 6 and max(s.done_on) >= v_q and max(s.done_on) < v_end) z),
           'day_30_held', (select count(*) from public.assimilation_steps s
                           where s.church_id = v_church and s.step = 'day_30_conversation' and s.done_on >= v_q and s.done_on < v_end),
           'day_90_held', (select count(*) from public.assimilation_steps s
                           where s.church_id = v_church and s.step = 'day_90_conversation' and s.done_on >= v_q and s.done_on < v_end),
           -- Pairings open at the quarter's end, by kind, and those started in it.
           'pairings', (select coalesce(jsonb_agg(jsonb_build_object('kind', k.kind,
                               'open', (select count(*) from public.member_mentors mm
                                        where mm.church_id = v_church and mm.kind = k.kind and mm.started_on < v_end
                                          and (mm.ended_on is null or mm.ended_on >= v_end)),
                               'started', (select count(*) from public.member_mentors mm
                                           where mm.church_id = v_church and mm.kind = k.kind
                                             and mm.started_on >= v_q and mm.started_on < v_end))
                             order by k.kind), '[]')
                        from unnest(enum_range(null::public.mentor_kind)) as k(kind)),
           'one_to_ones', (select count(distinct o.person_id) from public.one_to_ones o
                           where o.church_id = v_church and o.quarter_start = v_q))
    into v_rest;

  return jsonb_build_object('quarter_start', v_q, 'quarter_end', (v_end - 1),
                            'leadership', v_leadership, 'pathway', v_pathway) || v_rest;
end $$;
revoke all on function public.maturity_report(date) from public, anon;
grant execute on function public.maturity_report(date) to authenticated, service_role;
