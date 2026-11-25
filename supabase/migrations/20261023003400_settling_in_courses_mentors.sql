-- =====================================================================================
-- Migration 34: settling in, courses and mentors (decision of 24 Nov 2026, Paul).
-- "Members" here are G-Squad members.
--
-- 1. Settling in (Assimilation): the steps a new G-Squad member is walked through. Six are
--    ticked by their Team Lead (or the Coordinator): welcomed, a TEC culture and ASHLIE values
--    session, first serve alongside their buddy, time with another team, and the 30- and
--    90-day conversations. Two come from the record itself: a buddy named (member_mentors)
--    and joined a Greatness Community (people.greatness_community_id).
-- 2. Courses: which discipleship and leadership courses a member has completed (the new
--    converts class, the discipleship class, the Greatness Track Program, the baptism class,
--    leadership training). Completion only, with a date; the list is a reference form.
-- 3. Mentors: a named person beside a member, of three kinds: a buddy for a new member, a
--    leader with an apprentice, and "each one disciples one". One live pairing of each kind
--    per member; a pairing is ended, not rewritten.
-- Written by those who edit the member's record (their Team Lead and the G-Squad Coordinator,
-- app.can_edit_person); the TECi Coordinator may also record courses. Read by those who can
-- read the member; courses only by those who may see their faith (review 26 T01; all
-- courses the same, decision of 25 Nov 2026). Pairings end when a member leaves; the
-- G-Squad Coordinator may remove a pairing at any time (decisions of 25 Nov 2026).
-- Anonymising a member removes all three (R8); export_person includes them.
-- =====================================================================================

create type public.assimilation_step as enum
  ('welcomed', 'values_session', 'first_serve_with_buddy', 'met_other_teams', 'day_30_conversation', 'day_90_conversation');
create type public.course_kind as enum ('discipleship', 'leadership');
create type public.mentor_kind as enum ('buddy', 'apprentice', 'discipleship');

-- Is the row's member gone? Then a cascade or the anonymising job is removing it, and the
-- guards below let the delete through.
-- SECURITY REVIEW 26 (T03): this used to trust the gsquad.anonymising setting, which any
-- database session can set for itself with set_config(). It now asks the record instead:
-- deleted (the cascade: outside it the foreign key means the person exists), or already
-- anonymised (app.anonymise sets anonymised_at before it deletes, and people_guard lets only
-- app.anonymise set it). Neither can be faked by a caller.
create or replace function app.person_gone(p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select not exists (select 1 from public.people p where p.id = p_person and p.anonymised_at is null)
$$;
revoke all on function app.person_gone(uuid) from public, anon, authenticated;
grant execute on function app.person_gone(uuid) to service_role;

-- -------------------------------------------------------------------------------------
-- 1. Settling in
-- -------------------------------------------------------------------------------------
create table public.assimilation_steps (
  id           uuid primary key default gen_random_uuid(),
  church_id    uuid not null default app.current_church_id(),
  person_id    uuid not null,
  step         public.assimilation_step not null,
  done_on      date not null default current_date,
  recorded_by  uuid default auth.uid(),
  recorded_at  timestamptz not null default now(),
  unique (person_id, step),
  foreign key (church_id, person_id) references public.people(church_id, id) on delete cascade
);
comment on table public.assimilation_steps is
  'Settling-in steps a new G-Squad member has been walked through (migration 34). The buddy and Greatness Community steps come from the record itself.';

-- -------------------------------------------------------------------------------------
-- 2. Courses
-- -------------------------------------------------------------------------------------
create table public.course_types (
  id           uuid primary key default gen_random_uuid(),
  church_id    uuid not null references public.churches(id) on delete restrict,
  sort_order   smallint not null check (sort_order between 1 and 50),
  name         text not null check (length(btrim(name)) between 1 and 100),
  kind         public.course_kind not null default 'discipleship',
  description  text check (length(description) <= 2000),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  unique (church_id, id),
  unique (church_id, name)
);
comment on table public.course_types is 'Discipleship and leadership courses a G-Squad member can complete (reference form, migration 34).';

create table public.course_completions (
  id              uuid primary key default gen_random_uuid(),
  church_id       uuid not null default app.current_church_id(),
  person_id       uuid not null,
  course_type_id  uuid not null,
  completed_on    date not null,
  recorded_by     uuid default auth.uid(),
  recorded_at     timestamptz not null default now(),
  unique (person_id, course_type_id),
  foreign key (church_id, person_id) references public.people(church_id, id) on delete cascade,
  foreign key (church_id, course_type_id) references public.course_types(church_id, id) on delete restrict
);
comment on table public.course_completions is 'Courses a G-Squad member has completed, with the date (migration 34). Completion only.';

-- -------------------------------------------------------------------------------------
-- 3. Mentors
-- -------------------------------------------------------------------------------------
create table public.member_mentors (
  id                uuid primary key default gen_random_uuid(),
  church_id         uuid not null default app.current_church_id(),
  person_id         uuid not null,    -- the member being helped
  mentor_person_id  uuid not null,    -- the buddy, leader or discipler beside them
  kind              public.mentor_kind not null,
  started_on        date not null default current_date,
  ended_on          date,
  set_by            uuid default auth.uid(),
  created_at        timestamptz not null default now(),
  check (person_id <> mentor_person_id),
  check (ended_on is null or ended_on >= started_on),
  foreign key (church_id, person_id) references public.people(church_id, id) on delete cascade,
  foreign key (church_id, mentor_person_id) references public.people(church_id, id) on delete cascade
);
-- One live pairing of each kind per member.
create unique index member_mentors_one_live on public.member_mentors (person_id, kind) where ended_on is null;
create index member_mentors_mentor on public.member_mentors (mentor_person_id);
comment on table public.member_mentors is
  'A named person beside a G-Squad member: a buddy (new member), a leader and apprentice, or each one disciples one (migration 34).';

-- -------------------------------------------------------------------------------------
-- Guards: who writes, what may change, and the database's own record of who and when.
-- -------------------------------------------------------------------------------------
create or replace function app.growth_record_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_person uuid := case when tg_op = 'DELETE' then old.person_id else new.person_id end;
  p public.people;
  v_today date := (now() at time zone 'Europe/London')::date;
begin
  if app.is_system() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  -- Decision of 25 Nov 2026: a member's open pairings end when they leave (people.status
  -- becomes 'left'). app.end_pairings_on_leaving sets the end date; whoever marked the member
  -- as left may not edit the other person in the pairing, so this one change (an end date,
  -- today or earlier, nothing else) is let through when either person has left.
  -- (Nested: PL/pgSQL looks up old.ended_on even when an earlier test is false.)
  if tg_op = 'UPDATE' and tg_table_name = 'member_mentors' then
    if old.ended_on is null and new.ended_on is not null and new.ended_on <= v_today
     and new.id = old.id and new.church_id = old.church_id and new.person_id = old.person_id
     and new.mentor_person_id = old.mentor_person_id and new.kind = old.kind
     and new.started_on = old.started_on and new.set_by is not distinct from old.set_by
     and new.created_at = old.created_at
     and exists (select 1 from public.people x
                 where x.id in (old.person_id, old.mentor_person_id) and x.status = 'left') then
      return new;
    end if;
  end if;
  if tg_op = 'DELETE' then
    if app.person_gone(old.person_id) then
      return old;
    end if;
    -- (Nested: only member_mentors has a mentor column.)
    if tg_table_name = 'member_mentors' then
      if app.person_gone(old.mentor_person_id) then
        return old;
      end if;
    end if;
  end if;

  select * into p from public.people where id = v_person and church_id = app.current_church_id();
  if not found or p.anonymised_at is not null then
    raise exception 'Member not found' using errcode = '42501';
  end if;
  -- Their Team Lead or the G-Squad Coordinator; the TECi Coordinator may also record courses.
  if not (app.can_edit_person(v_person)
          or (tg_table_name = 'course_completions' and app.has_role('teci_coordinator'))) then
    raise exception 'Only the member''s Team Lead or the G-Squad Coordinator can change this' using errcode = '42501';
  end if;
  -- Decision of 25 Nov 2026 (all courses the same): every course completion is treated like
  -- the faith fields, so only someone who may see this member's faith records one.
  if tg_table_name = 'course_completions' and not app.can_see_faith(v_person) then
    raise exception 'Only the member''s Team Lead or the G-Squad Coordinator can change this' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then
    -- SECURITY REVIEW 26 (T04): a pairing is ended, never rewritten, so it is not deleted
    -- either (delete and re-add would rewrite its history). A slip may be taken back on
    -- the day it was recorded while it is still open; after that, end it.
    -- Decision of 25 Nov 2026: the G-Squad Coordinator may remove a pairing at any time.
    if tg_table_name = 'member_mentors' and not app.has_role('gsquad_coordinator')
       and (old.ended_on is not null or (old.created_at at time zone 'Europe/London')::date <> v_today) then
      raise exception 'End this pairing instead; only a pairing named today can be taken back' using errcode = '42501';
    end if;
    return old;
  end if;

  -- SECURITY REVIEW 26 (T04): the row's own id does not change either.
  if tg_op = 'UPDATE' and (new.id <> old.id or new.person_id <> old.person_id or new.church_id <> old.church_id) then
    raise exception 'A record cannot be moved to another member' using errcode = '42501';
  end if;

  if tg_table_name = 'assimilation_steps' then
    if tg_op = 'UPDATE' and new.step <> old.step then
      raise exception 'Record another step instead' using errcode = '42501';
    end if;
    if new.done_on > v_today then
      raise exception 'A step is recorded once it has happened' using errcode = '23514';
    end if;
    new.recorded_by := (select auth.uid());
    new.recorded_at := now();

  elsif tg_table_name = 'course_completions' then
    if tg_op = 'UPDATE' and new.course_type_id <> old.course_type_id then
      raise exception 'Record the other course instead' using errcode = '42501';
    end if;
    if new.completed_on > v_today then
      raise exception 'A course is recorded once it is completed' using errcode = '23514';
    end if;
    if tg_op = 'INSERT' and not exists (select 1 from public.course_types t where t.id = new.course_type_id and t.is_active) then
      raise exception 'That course is switched off' using errcode = '23514';
    end if;
    new.recorded_by := (select auth.uid());
    new.recorded_at := now();

  else -- member_mentors
    if tg_op = 'UPDATE' then
      -- A pairing is ended, never rewritten: only the end date may be set, once.
      if new.mentor_person_id <> old.mentor_person_id or new.kind <> old.kind or new.started_on <> old.started_on
         or new.set_by is distinct from old.set_by or new.created_at <> old.created_at then
        raise exception 'End this pairing and start a new one instead' using errcode = '42501';
      end if;
      if old.ended_on is not null then
        raise exception 'This pairing has already ended' using errcode = '23514';
      end if;
      if new.ended_on is not null and new.ended_on > v_today then
        raise exception 'A pairing ends today or earlier' using errcode = '23514';
      end if;
      return new;
    end if;
    -- A new pairing: the person beside them is a current member of this church, not themselves.
    -- SECURITY REVIEW 26 (T02): and someone the person naming them may read. Otherwise a Team
    -- Lead could name (and so learn the status of) anyone in the church by id, beyond the
    -- people the page offers them. Same answer whichever way it fails.
    if not app.can_read_person(new.mentor_person_id)
       or not exists (select 1 from public.people m
                   where m.id = new.mentor_person_id and m.church_id = new.church_id
                     and m.status = 'active' and m.anonymised_at is null) then
      raise exception 'Choose an active G-Squad member' using errcode = '23514';
    end if;
    if new.started_on > v_today then
      raise exception 'A pairing starts today or earlier' using errcode = '23514';
    end if;
    if new.ended_on is not null then
      raise exception 'A new pairing starts open' using errcode = '23514';
    end if;
    new.set_by := (select auth.uid());
    new.created_at := now();
  end if;
  return new;
end $$;
revoke all on function app.growth_record_guard() from public, anon, authenticated;
grant execute on function app.growth_record_guard() to service_role;
create trigger growth_record_guard before insert or update or delete on public.assimilation_steps
  for each row execute function app.growth_record_guard();
create trigger growth_record_guard before insert or update or delete on public.course_completions
  for each row execute function app.growth_record_guard();
create trigger growth_record_guard before insert or update or delete on public.member_mentors
  for each row execute function app.growth_record_guard();

-- -------------------------------------------------------------------------------------
-- Row-level security
-- -------------------------------------------------------------------------------------
alter table public.assimilation_steps enable row level security;
alter table public.course_types enable row level security;
alter table public.course_completions enable row level security;
alter table public.member_mentors enable row level security;
revoke all on public.assimilation_steps, public.course_types, public.course_completions, public.member_mentors from public, anon;
grant select, insert, update, delete on public.assimilation_steps, public.course_types, public.course_completions, public.member_mentors to authenticated;
-- As SECURITY REVIEW 25 (S04): no TRUNCATE (it skips row-level security and the guards).
revoke truncate, references, trigger on public.assimilation_steps, public.course_types, public.course_completions, public.member_mentors from authenticated;

create policy assimilation_steps_read on public.assimilation_steps for select to authenticated
  using (church_id = (select app.current_church_id()) and app.can_read_person(person_id));
create policy assimilation_steps_write on public.assimilation_steps for all to authenticated
  using (church_id = (select app.current_church_id()) and app.can_edit_person(person_id))
  with check (church_id = (select app.current_church_id()) and app.can_edit_person(person_id));

-- The course list: every leader reads it; the Operations Lead and G-Squad Coordinator keep it.
create policy course_types_read on public.course_types for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy course_types_write on public.course_types for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['operations_lead','gsquad_coordinator']::public.app_role[])));
create trigger course_types_audit after insert or update or delete on public.course_types
  for each row execute function app.audit_row_change();

-- SECURITY REVIEW 26 (T01): a discipleship course (the new converts class, the water baptism
-- class...) tells of the member's faith journey as surely as the faith fields do. Decision of
-- 25 Nov 2026: all courses the same, leadership training included, so every completion is
-- read only by those who may see the member's faith (app.can_see_faith). p_course is kept so
-- the policy and export need not change. Counts in the summary are unaffected.
create or replace function app.can_read_course(p_person uuid, p_course uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select app.can_read_person(p_person) and app.can_see_faith(p_person)
$$;
revoke all on function app.can_read_course(uuid, uuid) from public, anon;
grant execute on function app.can_read_course(uuid, uuid) to authenticated, service_role;

create policy course_completions_read on public.course_completions for select to authenticated
  using (church_id = (select app.current_church_id()) and app.can_read_course(person_id, course_type_id));
-- Writes are split by command (not FOR ALL), so reading stays with the read policy alone: a
-- FOR ALL policy would also let every writer read. Writers must see the member's faith too.
create policy course_completions_insert on public.course_completions for insert to authenticated
  with check (church_id = (select app.current_church_id()) and app.can_see_faith(person_id)
         and (app.can_edit_person(person_id) or (select app.has_role('teci_coordinator'))));
create policy course_completions_update on public.course_completions for update to authenticated
  using (church_id = (select app.current_church_id()) and app.can_see_faith(person_id)
         and (app.can_edit_person(person_id) or (select app.has_role('teci_coordinator'))))
  with check (church_id = (select app.current_church_id()) and app.can_see_faith(person_id)
         and (app.can_edit_person(person_id) or (select app.has_role('teci_coordinator'))));
create policy course_completions_delete on public.course_completions for delete to authenticated
  using (church_id = (select app.current_church_id()) and app.can_see_faith(person_id)
         and (app.can_edit_person(person_id) or (select app.has_role('teci_coordinator'))));

-- A pairing is read by those who can read the member being helped; the mentor's name is
-- shown with it (they are a G-Squad member too).
create policy member_mentors_read on public.member_mentors for select to authenticated
  using (church_id = (select app.current_church_id()) and app.can_read_person(person_id));
create policy member_mentors_write on public.member_mentors for all to authenticated
  using (church_id = (select app.current_church_id()) and app.can_edit_person(person_id))
  with check (church_id = (select app.current_church_id()) and app.can_edit_person(person_id));

-- Decision of 25 Nov 2026: when a member leaves (status becomes 'left'), their open pairings
-- end, on both sides: as the member helped and as the person beside someone. The end date is
-- the day they left (never before the pairing started, never in the future).
create or replace function app.end_pairings_on_leaving() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Europe/London')::date;
begin
  update public.member_mentors mm
     set ended_on = greatest(mm.started_on, least(v_today, coalesce(new.date_left, v_today)))
   where mm.church_id = new.church_id
     and mm.ended_on is null
     and (mm.person_id = new.id or mm.mentor_person_id = new.id);
  return null;
end $$;
revoke all on function app.end_pairings_on_leaving() from public, anon, authenticated;
grant execute on function app.end_pairings_on_leaving() to service_role;
create trigger people_end_pairings_on_leaving after update of status on public.people
  for each row when (new.status = 'left' and old.status is distinct from 'left')
  execute function app.end_pairings_on_leaving();

-- The starting course list for each church (seed.sql adds it for a new one).
insert into public.course_types (church_id, sort_order, name, kind, description)
select c.id, x.sort_order, x.name, x.kind::public.course_kind, x.description
from public.churches c
cross join (values
  (1, 'New converts class', 'discipleship', 'Foundations for someone new to faith.'),
  (2, 'Discipleship class', 'discipleship', 'Growing as a follower of Jesus.'),
  (3, 'Greatness Track Program', 'discipleship', 'TEC''s discipleship track.'),
  (4, 'Water baptism class', 'discipleship', 'Preparation for water baptism.'),
  (5, 'Leadership training', 'leadership', 'Training for those leading or about to lead a team.')
) as x(sort_order, name, kind, description)
on conflict do nothing;

-- -------------------------------------------------------------------------------------
-- Anonymising (R8) removes the three, as it removes one-to-ones and recognitions.
-- app.anonymise re-created whole from migration 25 with the marked additions.
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
-- export_person (rights requests) gains the three. Re-created whole from migration 27 with
-- the marked additions.
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
                         from public.member_mentors mm where mm.person_id = p_person or mm.mentor_person_id = p_person)
  ) into v;
  perform app.audit('export_person', 'people', p_person);
  return v;
end $$;
revoke all on function public.export_person(uuid) from public, anon;
grant execute on function public.export_person(uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- The four focus areas summary (migration 33) gains settling in, courses and mentoring
-- counts. Re-created whole from migration 33 with the marked addition.
-- -------------------------------------------------------------------------------------
create or replace function public.focus_areas_summary(p_quarter date default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_church uuid := app.current_church_id();
  v_q date := date_trunc('quarter', coalesce(p_quarter, (now() at time zone 'Europe/London')::date))::date;
  v_end date := (v_q + interval '3 months')::date;
  v_areas jsonb;
  v_outcomes jsonb;
  v_gsquad jsonb;
begin
  if not app.has_any_role(array['gsquad_coordinator','resident_pastor','purpose_head',
                                'operations_lead','pastoral_lead']::public.app_role[]) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  -- Events in the quarter (by their London start date), not cancelled.
  with ev as (
    select p.id from public.projects p
    where p.church_id = v_church and p.is_event and not p.is_sunday_service and p.status <> 'cancelled'
      and (p.starts_at at time zone 'Europe/London')::date >= v_q
      and (p.starts_at at time zone 'Europe/London')::date < v_end
  )
  select jsonb_agg(jsonb_build_object(
           'area', a.area,
           'events_aimed', (select count(*) from public.project_focus f join ev on ev.id = f.project_id where f.area = a.area),
           'events_primary', (select count(*) from public.project_focus f join ev on ev.id = f.project_id where f.area = a.area and f.is_primary),
           'events_rated', (select count(*) from public.project_focus_review r join ev on ev.id = r.project_id where r.area = a.area),
           'rating_counts', (select jsonb_agg((select count(*) from public.project_focus_review r join ev on ev.id = r.project_id
                                               where r.area = a.area and r.rating = lvl) order by lvl)
                             from generate_series(0, 4) lvl),
           'members_growing', (select count(*) from public.one_to_ones o
                               where o.church_id = v_church and o.quarter_start = v_q and o.growth_area = a.area),
           'teams_talked', (select count(distinct u.unit_id) from public.unit_focus_reflections u
                            where u.church_id = v_church and u.quarter_start = v_q and u.area = a.area)
         ) order by a.area)
    into v_areas
  from unnest(enum_range(null::public.focus_area)) as a(area);

  select jsonb_build_object(
           'events', count(*),
           'first_time_guests', coalesce(sum(o.first_time_guests), 0),
           'decisions_for_christ', coalesce(sum(o.decisions_for_christ), 0),
           'guests_contacted_48h', coalesce(sum(o.guests_contacted_48h), 0),
           'connected_to_community', coalesce(sum(o.connected_to_community), 0),
           'next_step_signups', coalesce(sum(o.next_step_signups), 0),
           'care_followups', coalesce(sum(o.care_followups), 0))
    into v_outcomes
  from public.project_outcomes o join public.projects p on p.id = o.project_id
  where o.church_id = v_church and p.status <> 'cancelled'
    and (p.starts_at at time zone 'Europe/London')::date >= v_q
    and (p.starts_at at time zone 'Europe/London')::date < v_end;

  -- The G-Squad itself, from what the app already holds.
  select jsonb_build_object(
           'members', (select count(*) from public.people p
                       where p.church_id = v_church and p.status = 'active' and p.anonymised_at is null),
           'in_community', (select count(*) from public.people p
                            where p.church_id = v_church and p.status = 'active' and p.anonymised_at is null
                              and p.greatness_community_id is not null),
           'one_to_ones', (select count(distinct o.person_id) from public.one_to_ones o
                           where o.church_id = v_church and o.quarter_start = v_q),
           'steps_done', (select count(*) from public.one_to_ones o
                          where o.church_id = v_church and o.quarter_start = v_q and o.last_step = 'done'),
           'steps_followed_up', (select count(*) from public.one_to_ones o
                                 where o.church_id = v_church and o.quarter_start = v_q and o.last_step is not null),
           'open_checkins', (select count(*) from public.checkin_flags f where f.church_id = v_church and f.status = 'open'),
           'celebrations_opted_in', (select count(*) from public.people p
                                     where p.church_id = v_church and p.status = 'active' and p.celebration_opt_in),
           'recognitions', (select count(*) from public.recognitions r
                            where r.church_id = v_church and r.recognised_on >= v_q and r.recognised_on < v_end),
           'in_teci', (select count(*) from public.people p
                       where p.church_id = v_church and p.status = 'active' and p.teci_stage_id is not null),
           -- Migration 34: settling in, courses and mentoring (counts only).
           'new_members', (select count(*) from public.people p
                           where p.church_id = v_church and p.anonymised_at is null
                             and p.date_joined >= v_q and p.date_joined < v_end),
           'new_with_buddy', (select count(*) from public.people p
                              where p.church_id = v_church and p.anonymised_at is null
                                and p.date_joined >= v_q and p.date_joined < v_end
                                and exists (select 1 from public.member_mentors mm
                                            where mm.person_id = p.id and mm.kind = 'buddy')),
           'day_30_held', (select count(*) from public.assimilation_steps s
                           where s.church_id = v_church and s.step = 'day_30_conversation'
                             and s.done_on >= v_q and s.done_on < v_end),
           'day_90_held', (select count(*) from public.assimilation_steps s
                           where s.church_id = v_church and s.step = 'day_90_conversation'
                             and s.done_on >= v_q and s.done_on < v_end),
           'discipleship_courses', (select count(*) from public.course_completions c
                                    join public.course_types t on t.id = c.course_type_id
                                    where c.church_id = v_church and t.kind = 'discipleship'
                                      and c.completed_on >= v_q and c.completed_on < v_end),
           'leadership_courses', (select count(*) from public.course_completions c
                                  join public.course_types t on t.id = c.course_type_id
                                  where c.church_id = v_church and t.kind = 'leadership'
                                    and c.completed_on >= v_q and c.completed_on < v_end),
           'apprentices', (select count(*) from public.member_mentors mm
                           where mm.church_id = v_church and mm.kind = 'apprentice' and mm.ended_on is null),
           'discipling', (select count(*) from public.member_mentors mm
                          where mm.church_id = v_church and mm.kind = 'discipleship' and mm.ended_on is null),
           'water_baptisms', (select count(*) from public.person_faith f
                              where f.church_id = v_church and f.water_baptism_date >= v_q and f.water_baptism_date < v_end),
           'spirit_baptisms', (select count(*) from public.person_faith f
                               where f.church_id = v_church and f.holy_spirit_baptism_date >= v_q
                                 and f.holy_spirit_baptism_date < v_end))
    into v_gsquad;

  return jsonb_build_object('quarter_start', v_q, 'quarter_end', (v_end - 1),
                            'areas', v_areas, 'outcomes', v_outcomes, 'gsquad', v_gsquad);
end $$;
revoke all on function public.focus_areas_summary(date) from public, anon;
grant execute on function public.focus_areas_summary(date) to authenticated, service_role;
