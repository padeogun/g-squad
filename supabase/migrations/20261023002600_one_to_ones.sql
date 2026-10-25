-- =====================================================================================
-- G-Squad Planner: 26. Care and growth: one-to-ones (slice 5; decisions of 23 and 25 Oct 2026)
-- The quarterly Team Lead one-to-one (one per member per team per quarter, migration 3)
-- focuses on:
--   * the ASHLIE values: a value lived out and a value to grow in, as notes, never scored
--     (R20; columns from migration 11);
--   * sense of family as a team member (new: sense_of_family);
--   * competence in their role or unit (new: competence);
--   * personal walk with God: held apart in public.one_to_one_walk, like faith data. Read
--     only through public.get_one_to_one_walk (every view logged) by the Team Lead who wrote
--     the one-to-one, the G-Squad Coordinator and the Resident Pastor; the Purpose Head reads
--     the rest of the one-to-one but not this. Written by that Team Lead through
--     public.set_one_to_one_walk;
--   * ad hoc questions from the leadership: public.one_to_one_prompts, set by the G-Squad
--     Coordinator (or the Resident Pastor) for a period, and their answers in
--     public.one_to_one_answers, readable by whoever reads the one-to-one.
-- Each area is a short note; there are no ratings.
-- =====================================================================================

alter table public.one_to_ones
  add column sense_of_family text check (length(sense_of_family) <= 1000),
  add column competence      text check (length(competence) <= 1000);

-- Who reads / writes a given one-to-one (by id), for policies on the tables below. SECURITY
-- DEFINER so the answer does not depend on one_to_ones' own row-level security.
create or replace function app.can_read_one_to_one_id(p_oto uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.one_to_ones o
                 where o.id = p_oto and o.church_id = app.current_church_id()
                   and app.can_read_one_to_one(o.unit_id, o.lead_user_id))
$$;
create or replace function app.writes_one_to_one(p_oto uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.one_to_ones o
                 where o.id = p_oto and o.church_id = app.current_church_id()
                   and o.lead_user_id = (select auth.uid()) and app.is_unit_lead_of(o.unit_id))
$$;
revoke all on function app.can_read_one_to_one_id(uuid), app.writes_one_to_one(uuid) from public, anon;
grant execute on function app.can_read_one_to_one_id(uuid), app.writes_one_to_one(uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- Personal walk with God: restricted and logged.
-- -------------------------------------------------------------------------------------
create table public.one_to_one_walk (
  one_to_one_id  uuid primary key references public.one_to_ones(id) on delete cascade,
  church_id      uuid not null references public.churches(id) on delete restrict,
  notes          text not null check (length(btrim(notes)) between 1 and 1000),
  updated_by     uuid default auth.uid(),
  updated_at     timestamptz not null default now()
);
alter table public.one_to_one_walk enable row level security;
-- No policies and no grants: reached only through the two functions below (as person_faith).
revoke all on public.one_to_one_walk from public, anon, authenticated;
create trigger one_to_one_walk_touch before update on public.one_to_one_walk
  for each row execute function app.touch_updated_at();
-- Every write is logged against the one-to-one (never the text).
create or replace function app.walk_audit() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.audit_log (church_id, actor_id, action, table_name, record_id, detail)
  values (coalesce(new.church_id, old.church_id), (select auth.uid()), lower(tg_op), 'one_to_one_walk',
          coalesce(new.one_to_one_id, old.one_to_one_id), '{}'::jsonb);
  return null;
end $$;
revoke all on function app.walk_audit() from public, anon, authenticated;
grant execute on function app.walk_audit() to service_role;
create trigger one_to_one_walk_audit after insert or update or delete on public.one_to_one_walk
  for each row execute function app.walk_audit();

-- SECURITY REVIEW 17 (W01): the audit log's entries about these notes (who wrote, changed,
-- removed or viewed them, and for which one-to-one) are as sensitive as those about faith
-- fields and pastoral notes, so they are for the Resident Pastor only (F04). audit_read is
-- re-created whole from migration 7 with 'one_to_one_walk' and 'view_walk' added.
drop policy audit_read on public.audit_log;
create policy audit_read on public.audit_log for select to authenticated
  using (church_id = (select app.current_church_id())
         and ((select app.has_role('resident_pastor'))
              or ((select app.has_role('operations_lead'))
                  and coalesce(table_name, '') not in ('person_faith', 'pastoral_notes', 'one_to_ones', 'one_to_one_walk')
                  and action not in ('view_faith', 'view_pastoral', 'view_walk'))));

-- Readers: the Team Lead who wrote the one-to-one (not while they are that team's Deputy,
-- as for the one-to-one itself), the G-Squad Coordinator and the Resident Pastor.
create or replace function app.can_see_walk(p_oto uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.one_to_ones o
                 where o.id = p_oto and o.church_id = app.current_church_id()
                   and ((o.lead_user_id = (select auth.uid()) and not app.is_unit_deputy_of(o.unit_id))
                        or app.has_any_role(array['gsquad_coordinator','resident_pastor']::public.app_role[])))
$$;
revoke all on function app.can_see_walk(uuid) from public, anon;
grant execute on function app.can_see_walk(uuid) to authenticated, service_role;

-- Read (logged). VOLATILE so the audit insert works (as get_person_faith, F03).
create or replace function public.get_one_to_one_walk(p_one_to_one uuid) returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare v text;
begin
  if not app.can_see_walk(p_one_to_one) then
    raise exception 'Not allowed to view this part of the one-to-one' using errcode = '42501';
  end if;
  perform app.audit('view_walk', 'one_to_one_walk', p_one_to_one);
  select w.notes into v from public.one_to_one_walk w where w.one_to_one_id = p_one_to_one;
  return v;
end $$;
revoke all on function public.get_one_to_one_walk(uuid) from public, anon;
grant execute on function public.get_one_to_one_walk(uuid) to authenticated, service_role;

-- Write: the Team Lead who wrote the one-to-one. Empty text removes it.
create or replace function public.set_one_to_one_walk(p_one_to_one uuid, p_notes text) returns void
language plpgsql volatile security definer set search_path = ''
as $$
begin
  if not app.writes_one_to_one(p_one_to_one) then
    raise exception 'Only the Team Lead who wrote this one-to-one can record this' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_notes, '')), '') is null then
    delete from public.one_to_one_walk where one_to_one_id = p_one_to_one;
  else
    insert into public.one_to_one_walk as w (one_to_one_id, church_id, notes, updated_by)
    values (p_one_to_one, app.current_church_id(), btrim(p_notes), (select auth.uid()))
    on conflict (one_to_one_id) do update set notes = excluded.notes, updated_by = excluded.updated_by;
  end if;
end $$;
revoke all on function public.set_one_to_one_walk(uuid, text) from public, anon;
grant execute on function public.set_one_to_one_walk(uuid, text) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- Leadership questions for a period, and their answers.
-- -------------------------------------------------------------------------------------
create table public.one_to_one_prompts (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null default app.current_church_id() references public.churches(id) on delete restrict,
  question    text not null check (length(btrim(question)) between 1 and 300),
  starts_on   date not null,
  ends_on     date not null,
  is_active   boolean not null default true,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  unique (church_id, id),
  check (ends_on >= starts_on)
);
create trigger one_to_one_prompts_audit after insert or update or delete on public.one_to_one_prompts
  for each row execute function app.audit_row_change();
alter table public.one_to_one_prompts enable row level security;
revoke all on public.one_to_one_prompts from anon;
create policy prompts_read on public.one_to_one_prompts for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy prompts_write on public.one_to_one_prompts for all to authenticated
  using (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['gsquad_coordinator','resident_pastor']::public.app_role[])))
  with check (church_id = (select app.current_church_id())
         and (select app.has_any_role(array['gsquad_coordinator','resident_pastor']::public.app_role[])));
-- A question that has been answered is switched off, not deleted (the answers keep their question).

-- SECURITY REVIEW 17 (W03): the author was taken from the request (created_by had only a
-- default), and an answered question could be reworded or re-dated, so the answers already
-- given would then read as answers to a question no one asked, or fall outside its period.
-- The author and time are now set by the database; once a question has answers its wording
-- is fixed and its period must still cover every one-to-one that answered it. Switching it
-- off and on stays free. (one_to_one_answers is created below; it is read only when this runs.)
create or replace function app.prompt_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := (select auth.uid());
    new.created_at := now();
    return new;
  end if;
  if new.created_by is distinct from old.created_by or new.created_at <> old.created_at
     or new.church_id <> old.church_id then
    raise exception 'Who set a question, and when, cannot be changed' using errcode = '42501';
  end if;
  if new.question <> old.question
     and exists (select 1 from public.one_to_one_answers a where a.prompt_id = old.id) then
    raise exception 'This question has been answered, so its wording cannot change. Switch it off and add a new one.' using errcode = '23514';
  end if;
  if (new.starts_on <> old.starts_on or new.ends_on <> old.ends_on)
     and exists (select 1 from public.one_to_one_answers a
                 join public.one_to_ones o on o.id = a.one_to_one_id
                 where a.prompt_id = old.id and o.held_on not between new.starts_on and new.ends_on) then
    raise exception 'Some answers to this question are from one-to-ones outside those dates' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function app.prompt_guard() from public, anon, authenticated;
grant execute on function app.prompt_guard() to service_role;
create trigger one_to_one_prompts_guard before insert or update on public.one_to_one_prompts
  for each row execute function app.prompt_guard();

create table public.one_to_one_answers (
  id             uuid primary key default gen_random_uuid(),
  church_id      uuid not null default app.current_church_id(),
  one_to_one_id  uuid not null references public.one_to_ones(id) on delete cascade,
  prompt_id      uuid not null,
  answer         text not null check (length(btrim(answer)) between 1 and 1000),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  foreign key (church_id, prompt_id) references public.one_to_one_prompts(church_id, id) on delete restrict,
  unique (one_to_one_id, prompt_id)
);
create trigger one_to_one_answers_touch before update on public.one_to_one_answers
  for each row execute function app.touch_updated_at();
alter table public.one_to_one_answers enable row level security;
revoke all on public.one_to_one_answers from anon;
create policy answers_read on public.one_to_one_answers for select to authenticated
  using (church_id = (select app.current_church_id()) and app.can_read_one_to_one_id(one_to_one_id));
create policy answers_write on public.one_to_one_answers for all to authenticated
  using (church_id = (select app.current_church_id()) and app.writes_one_to_one(one_to_one_id))
  with check (church_id = (select app.current_church_id()) and app.writes_one_to_one(one_to_one_id));

-- An answer stays with its one-to-one and question, and the question must have been asked
-- when the one-to-one was held (its period covers the day, and it was switched on).
create or replace function app.answer_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_held date;
begin
  if tg_op = 'UPDATE' and (new.one_to_one_id <> old.one_to_one_id or new.prompt_id <> old.prompt_id or new.church_id <> old.church_id) then
    raise exception 'An answer cannot move to another one-to-one or question' using errcode = '42501';
  end if;
  select o.held_on into v_held from public.one_to_ones o where o.id = new.one_to_one_id and o.church_id = new.church_id;
  if v_held is null then
    raise exception 'One-to-one not found' using errcode = '42501';
  end if;
  if tg_op = 'INSERT' and not exists (select 1 from public.one_to_one_prompts q
                                      where q.id = new.prompt_id and q.church_id = new.church_id and q.is_active
                                        and v_held between q.starts_on and q.ends_on) then
    raise exception 'That question was not being asked when this one-to-one was held' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function app.answer_guard() from public, anon, authenticated;
grant execute on function app.answer_guard() to service_role;
create trigger one_to_one_answers_guard before insert or update on public.one_to_one_answers
  for each row execute function app.answer_guard();

-- SECURITY REVIEW 17 (W02): the table check keeps held_on inside its quarter, but nothing
-- stopped a one-to-one being dated later this quarter (counted as held on the dashboards before
-- it happened), and the answer check above runs only when an answer is written, so moving the
-- date afterwards left answers to questions that were not being asked on the new day. The
-- date is now never after today (London), and cannot move outside the period of a question
-- already answered.
create or replace function app.one_to_one_date_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (tg_op = 'INSERT' or new.held_on <> old.held_on)
     and new.held_on > (now() at time zone 'Europe/London')::date then
    raise exception 'A one-to-one is recorded once it has been held: the date cannot be in the future' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and new.held_on <> old.held_on
     and exists (select 1 from public.one_to_one_answers a
                 join public.one_to_one_prompts q on q.id = a.prompt_id
                 where a.one_to_one_id = new.id and new.held_on not between q.starts_on and q.ends_on) then
    raise exception 'A leadership question answered in this one-to-one was not being asked on that date. Remove that answer first.' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function app.one_to_one_date_guard() from public, anon, authenticated;
grant execute on function app.one_to_one_date_guard() to service_role;
create trigger one_to_ones_date_guard before insert or update of held_on on public.one_to_ones
  for each row execute function app.one_to_one_date_guard();

-- export_person, re-created whole from migration 11 with the walk notes and answers added.
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
    -- Migration 26: the parts of one-to-ones held apart (walk with God; leadership questions'
    -- answers) belong in a subject access export too, for the same reader.
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
    -- SECURITY REVIEW FIX F14: a subject access export must hold everything kept on the person.
    'newsletter_reactions', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from public.newsletter_reactions x where x.person_id = p_person),
    'checkin_flags',    (select coalesce(jsonb_agg(to_jsonb(cf)), '[]') from public.checkin_flags cf where cf.person_id = p_person),
    'community_roles',  (select coalesce(jsonb_agg(to_jsonb(c)), '[]') from public.community_support_roles c where c.person_id = p_person)
  ) into v;
  perform app.audit('export_person', 'people', p_person);
  return v;
end $$;
