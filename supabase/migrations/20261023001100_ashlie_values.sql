-- =====================================================================================
-- G-Squad Planner: 11. Core values (ASHLIE)
-- ASHLIE (Accountability, Service, Humility, Love, Integrity, Excellence) is the guide for all
-- G-Squad service. The app uses it in two places (decision of 23 Oct 2026):
--   * the quarterly one-to-one records a value lived out and a value to grow in
--   * Values in Action: a leader recognises a member for an act of service, tagged with a value
-- R19: a recognition reaches the newsletter or a G-Squad meeting only with the member's agreement.
-- R20: values are never scored, rated or ranked; reports count recognitions by value, never
--      per person.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- Core values reference form. TEC's six values are seeded in seed/seed.sql.
-- Changed only by the Resident Pastor, and every change is audited.
-- -------------------------------------------------------------------------------------
create table public.core_values (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null default app.current_church_id() references public.churches(id) on delete restrict,
  letter      text not null check (letter ~ '^[A-Z]$'),
  name        text not null check (length(name) between 1 and 40),
  behaviour   text not null check (length(behaviour) between 1 and 300),   -- "We serve responsibly: owning our roles..."
  sort_order  smallint not null check (sort_order between 1 and 12),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (church_id, id),
  unique (church_id, sort_order),
  unique (church_id, name)
);
create trigger core_values_audit after insert or update or delete on public.core_values
  for each row execute function app.audit_row_change();

-- -------------------------------------------------------------------------------------
-- One-to-one reflection: one value lived out this quarter and one to grow in. Names of
-- values only, never a mark (R20). Optional, so earlier entries stay valid.
-- -------------------------------------------------------------------------------------
alter table public.one_to_ones
  add column value_lived_id      uuid,
  add column value_lived_note    text check (length(value_lived_note) <= 280),
  add column value_to_grow_id    uuid,
  add column value_to_grow_note  text check (length(value_to_grow_note) <= 280),
  add foreign key (church_id, value_lived_id)   references public.core_values(church_id, id) on delete restrict,
  add foreign key (church_id, value_to_grow_id) references public.core_values(church_id, id) on delete restrict,
  -- A note only makes sense with its value chosen.
  add constraint value_lived_note_needs_value  check (value_lived_note is null or value_lived_id is not null),
  add constraint value_grow_note_needs_value   check (value_to_grow_note is null or value_to_grow_id is not null);

-- -------------------------------------------------------------------------------------
-- Values in Action recognitions (R19).
-- -------------------------------------------------------------------------------------
create table public.recognitions (
  id                     uuid primary key default gen_random_uuid(),
  church_id              uuid not null default app.current_church_id(),
  person_id              uuid not null,
  unit_id                uuid not null,                    -- the unit the act of service was in
  value_id               uuid not null,
  description            text not null check (length(btrim(description)) between 1 and 280),
  recognised_by          uuid not null default auth.uid(),
  recognised_on          date not null default current_date,
  offered_to_newsletter  boolean not null default false,
  offered_to_meeting     boolean not null default false,
  person_agreed          boolean not null default false,   -- the member agreed to it being shared
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  foreign key (church_id, person_id)     references public.people(church_id, id) on delete cascade,
  foreign key (church_id, unit_id)       references public.units(church_id, id) on delete restrict,
  foreign key (church_id, value_id)      references public.core_values(church_id, id) on delete restrict,
  foreign key (church_id, recognised_by) references public.app_users(church_id, id) on delete restrict,
  -- R19: nothing is offered for sharing without the member's agreement.
  constraint shared_only_with_agreement check (not (offered_to_newsletter or offered_to_meeting) or person_agreed)
);
create index recognitions_person on public.recognitions (person_id);
create index recognitions_unit_date on public.recognitions (unit_id, recognised_on);
create index recognitions_shared on public.recognitions (church_id, recognised_on) where offered_to_newsletter and person_agreed;
create trigger recognitions_touch before update on public.recognitions
  for each row execute function app.touch_updated_at();
-- SECURITY REVIEW FIX G04: R19 rests on the agreement tick, so record who changed a recognition
-- and when. The generic trigger logs column names only (e.g. "person_agreed"), never the text.
create trigger recognitions_audit after insert or update or delete on public.recognitions
  for each row execute function app.audit_row_change();

-- Who may recognise someone in a unit: that unit's lead, the unit's Purpose Head, the
-- G-Squad Coordinator, the Resident Pastor or the Operations Lead; the person must be an
-- active member of the unit.
create or replace function app.can_recognise(p_person uuid, p_unit uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.unit_memberships m
    join public.units u on u.id = m.unit_id
    where m.person_id = p_person and m.unit_id = p_unit and m.status = 'active'
      and u.church_id = app.current_church_id()
  )
  and (
    app.is_unit_lead_of(p_unit) or app.is_purpose_head_of_unit(p_unit)
    or app.has_any_role(array['gsquad_coordinator','resident_pastor','operations_lead']::public.app_role[])
  )
$$;

-- Who may see a recognition: its author, the unit's lead and Purpose Head, and church-wide
-- leaders. Editors see shared ones only, through public.newsletter_recognitions().
create or replace function app.can_read_recognition(p_unit uuid, p_author uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_author = (select auth.uid())
      or app.is_unit_lead_of(p_unit) or app.is_purpose_head_of_unit(p_unit)
      or app.has_any_role(array['gsquad_coordinator','resident_pastor','operations_lead']::public.app_role[])
$$;

-- Guards: person, unit, author and church never change; changing who or where means a new
-- recognition. Turning sharing on needs the agreement tick (also a CHECK constraint).
create or replace function app.recognition_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  -- Recognitions are for service already given (checked here: a CHECK constraint cannot use today's date).
  if new.recognised_on > current_date then
    raise exception 'A recognition is for service already given' using errcode = '23514';
  end if;
  if app.is_system() then return new; end if;
  -- SECURITY REVIEW FIX G03: only a current value can be chosen (as for one-to-ones). A retired
  -- value would also drop out of values_in_action_counts, which lists active values only.
  if (tg_op = 'INSERT' or new.value_id <> old.value_id)
     and not exists (select 1 from public.core_values v where v.id = new.value_id and v.is_active) then
    raise exception 'Choose one of the current core values' using errcode = '23514';
  end if;
  if tg_op = 'INSERT' then
    new.recognised_by := (select auth.uid());       -- the author is always the caller
    -- SECURITY REVIEW FIX G02: a leader who also serves in the unit cannot recognise themselves
    -- (and so tick their own agreement and put themselves forward for the newsletter).
    if exists (select 1 from public.app_users u
               where u.id = new.recognised_by and u.person_id = new.person_id) then
      raise exception 'You cannot recognise yourself' using errcode = '42501';
    end if;
    return new;
  end if;
  if new.person_id <> old.person_id or new.unit_id <> old.unit_id
     or new.recognised_by <> old.recognised_by or new.church_id <> old.church_id then
    raise exception 'Person, unit and author of a recognition cannot change' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger recognition_guard before insert or update on public.recognitions
  for each row execute function app.recognition_guard();

-- One-to-one reflection values must belong to the same church and be active.
create or replace function app.one_to_one_values_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (new.value_lived_id is not null and not exists (select 1 from public.core_values v where v.id = new.value_lived_id and v.is_active))
     or (new.value_to_grow_id is not null and not exists (select 1 from public.core_values v where v.id = new.value_to_grow_id and v.is_active)) then
    raise exception 'Choose one of the current core values' using errcode = '23514';
  end if;
  return new;
end $$;

create trigger one_to_one_values_guard before insert or update of value_lived_id, value_to_grow_id on public.one_to_ones
  for each row execute function app.one_to_one_values_guard();

-- -------------------------------------------------------------------------------------
-- Row-level security
-- -------------------------------------------------------------------------------------
alter table public.core_values enable row level security;
alter table public.recognitions enable row level security;
revoke all on public.core_values, public.recognitions from anon;

create policy core_values_read on public.core_values for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy core_values_write on public.core_values for all to authenticated
  using (church_id = (select app.current_church_id()) and (select app.has_role('resident_pastor')))
  with check (church_id = (select app.current_church_id()) and (select app.has_role('resident_pastor')));

create policy recognitions_read on public.recognitions for select to authenticated
  using (church_id = (select app.current_church_id()) and app.can_read_recognition(unit_id, recognised_by));
create policy recognitions_insert on public.recognitions for insert to authenticated
  with check (church_id = (select app.current_church_id()) and app.can_recognise(person_id, unit_id));
-- The author edits their own recognition (wording, value, sharing ticks) while they can still
-- recognise in that unit.
create policy recognitions_update on public.recognitions for update to authenticated
  using (church_id = (select app.current_church_id()) and recognised_by = (select auth.uid()))
  with check (church_id = (select app.current_church_id()) and recognised_by = (select auth.uid())
              and app.can_recognise(person_id, unit_id));
create policy recognitions_delete on public.recognitions for delete to authenticated
  using (church_id = (select app.current_church_id())
         and (recognised_by = (select auth.uid()) or (select app.has_role('operations_lead'))));
revoke truncate, references, trigger on public.core_values, public.recognitions from authenticated;

-- -------------------------------------------------------------------------------------
-- Read functions
-- -------------------------------------------------------------------------------------

-- Recognitions offered to the newsletter, with agreement, for the month before the issue.
-- First name and surname initial only, as for other celebrations.
create or replace function public.newsletter_recognitions(p_issue_month date)
returns table (value_letter text, value_name text, display_name text, description text, recognised_on date)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not app.has_any_role(array['newsletter_editor','gsquad_coordinator','resident_pastor','operations_lead']::public.app_role[]) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select v.letter, v.name, p.first_name || ' ' || left(p.surname, 1) || '.', r.description, r.recognised_on
    from public.recognitions r
    join public.core_values v on v.id = r.value_id
    join public.people p on p.id = r.person_id
    where r.church_id = app.current_church_id()
      and r.offered_to_newsletter and r.person_agreed
      and p.status = 'active' and p.anonymised_at is null
      and date_trunc('month', r.recognised_on) = date_trunc('month', p_issue_month) - interval '1 month'
    order by v.sort_order, r.recognised_on;
end $$;

-- R20: recognitions counted by value, never per person. Church-wide leaders may ask for the
-- whole church or any unit; a Unit Lead or Purpose Head only for a unit in their scope.
create or replace function public.values_in_action_counts(p_from date, p_to date, p_unit uuid default null)
returns table (letter text, value_name text, recognitions integer)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_wide boolean := app.has_any_role(array['gsquad_coordinator','resident_pastor','operations_lead']::public.app_role[]);
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 3660 then
    raise exception 'Give a date range of up to ten years' using errcode = '22023';
  end if;
  if not v_wide and (p_unit is null or not (app.is_unit_lead_of(p_unit) or app.is_purpose_head_of_unit(p_unit))) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select v.letter, v.name, count(r.id)::int
    from public.core_values v
    left join public.recognitions r
      on r.value_id = v.id and r.recognised_on between p_from and p_to
     and (p_unit is null or r.unit_id = p_unit)
    where v.church_id = app.current_church_id() and v.is_active
    group by v.letter, v.name, v.sort_order
    order by v.sort_order;
end $$;

-- SECURITY REVIEW FIX G01: withdrawing agreement (R19; UK GDPR: as easy to withdraw as to give).
-- The update policy lets only the author edit, and only while they can still recognise in the
-- unit, so once the author changed role or the member left the unit nobody could untick sharing
-- short of deleting the record. Anyone who may read the recognition (author, the unit's lead and
-- Purpose Head, church-wide leaders) can now turn sharing off. It can only switch sharing off.
create or replace function public.withdraw_recognition_sharing(p_recognition uuid) returns void
language plpgsql volatile security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.recognitions r
                 where r.id = p_recognition and r.church_id = app.current_church_id()
                   and app.can_read_recognition(r.unit_id, r.recognised_by)) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  update public.recognitions
     set offered_to_newsletter = false, offered_to_meeting = false, person_agreed = false
   where id = p_recognition;   -- logged by the recognitions_audit trigger (G04)
end $$;

-- -------------------------------------------------------------------------------------
-- People's rights: anonymising removes recognitions; exports include them.
-- (Both functions are re-created whole, as in migration 9, with the recognitions added.)
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
  update public.community_support_roles set person_id = null where person_id = p_person;
  update public.app_users set person_id = null where person_id = p_person;
  -- SECURITY REVIEW FIX F14: the free-text override reason can describe the person's
  -- circumstances; wipe it with the rest of their personal details.
  update public.assignments set override_reason = null where person_id = p_person and override_reason is not null;
  perform set_config('gsquad.anonymising', 'off', true);
end $$;

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

-- -------------------------------------------------------------------------------------
-- Grants. Since migration 10, new functions are not executable by PUBLIC or anon by default,
-- so each one is granted explicitly here.
-- -------------------------------------------------------------------------------------
revoke all on function app.can_recognise(uuid, uuid), app.can_read_recognition(uuid, uuid),
                       app.recognition_guard(), app.one_to_one_values_guard() from public, anon;
grant execute on function app.can_recognise(uuid, uuid), app.can_read_recognition(uuid, uuid) to authenticated, service_role;
grant execute on function app.recognition_guard(), app.one_to_one_values_guard() to service_role;
revoke all on function public.newsletter_recognitions(date), public.values_in_action_counts(date, date, uuid) from public, anon;
grant execute on function public.newsletter_recognitions(date), public.values_in_action_counts(date, date, uuid) to authenticated, service_role;
revoke all on function public.withdraw_recognition_sharing(uuid) from public, anon;
grant execute on function public.withdraw_recognition_sharing(uuid) to authenticated, service_role;
grant select, insert, update, delete on public.core_values to authenticated;
-- SECURITY REVIEW FIX G05: authors may update only the editable columns. Person, unit, author and
-- church are also held by app.recognition_guard; created_at is no longer rewritable either.
-- (The default privileges give authenticated table-wide UPDATE on new tables, so revoke it first.)
revoke update on public.recognitions from authenticated;
grant select, insert, delete on public.recognitions to authenticated;
grant update (value_id, description, recognised_on, offered_to_newsletter, offered_to_meeting, person_agreed)
  on public.recognitions to authenticated;
grant all on public.core_values, public.recognitions to service_role;
