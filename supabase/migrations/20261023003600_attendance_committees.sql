-- =====================================================================================
-- Migration 36: event attendance, maturity habits, team engagement, and planning committees
-- in leaders' load (decisions of 27 Nov 2026, Paul).
--
-- 1. Event attendance (event_attendance): who attended an event, recorded by check-in like a
--    Sunday. The event's owner, the Operations Lead or the G-Squad Coordinator records anyone
--    they can see; a Team Lead records members they look after. Members who RSVP'd through
--    The Greatness Brief are listed first (event_attendance_candidates). Decisions of 27 Nov
--    2026: this holds at every event, maturity events included; attendance is taken only while
--    an event is live (approved or under way); cancelling a live event removes its entries and
--    moving its dates removes days outside them (logged; a finished event's record is kept).
-- 2. Maturity habits: prayer can't be tracked, but attending maturity events can. A maturity
--    event is one whose event type is marked "counts as a maturity habit" (Prayer and the new
--    Bible study type to start) or whose primary aim is Discipleship & Maturity
--    (app.is_maturity_event). Shown as facts, never a score: "attended 4 prayer or Bible study
--    events this quarter" on the member's record and in the one-to-one (person_engagement);
--    counts in the Maturity report.
-- 3. Team engagement: attending and serving at events (not Sundays) count as taking part;
--    per team counts on My Unit (team_engagement) and in the Maturity report.
-- 4. Planning committees: named G-Squad members on each event's committee
--    (project_committee_members). While the event is live, seats count in leaders' load as a
--    separate, lighter count with its own limit (church_settings.committees_max, default 2);
--    over either limit flags a pastoral check-in as before (flag, never block).
-- Anonymising removes attendance and committee seats; export_person includes them.
-- SECURITY REVIEW 28 (Ann): attendance at maturity events is read (and counted per person or
-- per team) only by those who may see the member's faith, the event's own owner and (decision of
-- 27 Nov 2026) the Operations Lead (A01);
-- the check-in list opens only for a day of an approved event (A02); committee seats count in
-- leaders' load once the event is approved (A03).
-- SECURITY REVIEW 29: a finished event's attendance is never removed by a later change (R01);
-- removals caused by cancelling or moving an event are logged (R02); a member's engagement read
-- with maturity counts is logged, as faith reads are (R03); entries can be removed by hand only
-- while the event is live (R04).
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- Event types that count as maturity habits
-- -------------------------------------------------------------------------------------
alter table public.project_types add column maturity_habit boolean not null default false;
comment on column public.project_types.maturity_habit is
  'Attending an event of this type counts as a maturity habit (migration 36).';
update public.project_types set maturity_habit = true where name = 'Prayer';
insert into public.project_types (church_id, name, default_level, newsletter_tag, maturity_habit)
select c.id, 'Bible study', 'unit', null, true from public.churches c
on conflict do nothing;

-- A maturity event: its type is marked, or its primary aim is Discipleship & Maturity.
create or replace function app.is_maturity_event(p_project uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.projects p join public.project_types t on t.id = p.type_id
                 where p.id = p_project and t.maturity_habit)
      or exists (select 1 from public.project_focus f
                 where f.project_id = p_project and f.is_primary and f.area = 'discipleship')
$$;
revoke all on function app.is_maturity_event(uuid) from public, anon;
grant execute on function app.is_maturity_event(uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 1. Event attendance
-- -------------------------------------------------------------------------------------
create table public.event_attendance (
  id           uuid primary key default gen_random_uuid(),
  church_id    uuid not null default app.current_church_id() references public.churches(id) on delete restrict,
  project_id   uuid not null,
  person_id    uuid not null,
  attended_on  date not null,
  recorded_by  uuid,
  created_at   timestamptz not null default now(),
  unique (church_id, id),
  unique (project_id, person_id, attended_on),
  foreign key (church_id, project_id) references public.projects(church_id, id) on delete cascade,
  foreign key (church_id, person_id) references public.people(church_id, id) on delete cascade
);
create index event_attendance_person on public.event_attendance (person_id, attended_on);
create index event_attendance_church_day on public.event_attendance (church_id, attended_on);
comment on table public.event_attendance is
  'Who attended an event, by check-in (migration 36). Facts only, never a score.';

-- Who may record a member's attendance at an event: the event's manager, for anyone they can
-- see; the Operations Lead, for anyone they can see; or the member's Team Lead or the G-Squad
-- Coordinator (app.can_edit_person). SECURITY REVIEW 28 (A01) first limited the Operations Lead
-- to their own maturity events; Paul's decision of 27 Nov 2026 restored them at every event.
create or replace function app.can_record_attendance(p_project uuid, p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  -- Decision of 27 Nov 2026 (Paul): the Operations Lead, the G-Squad Coordinator and the
  -- member's Team Lead record attendance at every event, maturity events included (the
  -- Coordinator and Team Lead through app.can_edit_person). This widens review 28's A01.
  select (app.can_read_person(p_person)
          and (app.owns_project(p_project) or app.has_role('operations_lead')))
      or app.can_edit_person(p_person)
$$;
revoke all on function app.can_record_attendance(uuid, uuid) from public, anon;
grant execute on function app.can_record_attendance(uuid, uuid) to authenticated, service_role;

-- SECURITY REVIEW 28 (Ann A01): who may read an entry. The event's owner, for their own event
-- (they ran it); the Operations Lead, at every event (decision of 27 Nov 2026); and those who
-- can read the member, except that an entry at a maturity event needs someone who may see the
-- member's faith (Team Lead, Deputy, Coordinator, Resident Pastor, TECi Coordinator) or edit
-- the member. So the Pastoral Lead, Purpose Heads and owners of other projects do not read who
-- came to prayer meetings.
create or replace function app.can_read_attendance(p_project uuid, p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  -- Decision of 27 Nov 2026: the Operations Lead records at every event, so reads every entry.
  select app.owns_project(p_project)
      or app.has_role('operations_lead')
      or (not app.is_maturity_event(p_project) and app.can_read_person(p_person))
      or (app.is_maturity_event(p_project)
          and app.can_read_person(p_person)
          and (app.can_see_faith(p_person) or app.can_edit_person(p_person)))
$$;
revoke all on function app.can_read_attendance(uuid, uuid) from public, anon;
grant execute on function app.can_read_attendance(uuid, uuid) to authenticated, service_role;

create or replace function app.event_attendance_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Europe/London')::date;
  v_p record;
begin
  if app.is_system() then
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' then
    -- Let removals through when the event or the member is being removed (cascade, anonymising).
    if not exists (select 1 from public.projects p where p.id = old.project_id) or app.person_gone(old.person_id) then
      return old;
    end if;
    -- Decision of 27 Nov 2026: entries go when their event is cancelled, or moved so that the
    -- day is no longer one of its days (app.attendance_follows_event, below, which logs them).
    -- SECURITY REVIEW 29 (R01): never for a finished event, whose record is kept.
    if exists (select 1 from public.projects p where p.id = old.project_id and p.status <> 'done'
               and (p.status = 'cancelled'
                    or old.attended_on < (p.starts_at at time zone 'Europe/London')::date
                    or old.attended_on > (p.ends_at at time zone 'Europe/London')::date)) then
      return old;
    end if;
    if not app.can_record_attendance(old.project_id, old.person_id) then
      raise exception 'Only the event''s owner, the Operations Lead, or the member''s Team Lead or the G-Squad Coordinator, can change attendance'
        using errcode = '42501';
    end if;
    -- SECURITY REVIEW 29 (R04): ticks are taken off only while they can be put back, that is
    -- while the event is live; a finished event's attendance stays as recorded.
    if not exists (select 1 from public.projects p where p.id = old.project_id and p.status in ('approved', 'in_progress')) then
      raise exception 'Attendance is changed while an event is live (approved or under way)' using errcode = '23514';
    end if;
    return old;
  end if;
  -- INSERT (updates are not granted: a correction is a removal and a new entry).
  select p.church_id, p.is_event, p.status, (p.starts_at at time zone 'Europe/London')::date as d0,
         (p.ends_at at time zone 'Europe/London')::date as d1
    into v_p
    from public.projects p where p.id = new.project_id and p.church_id = app.current_church_id();
  if v_p is null or not app.can_record_attendance(new.project_id, new.person_id) then
    raise exception 'Only the event''s owner, the Operations Lead, or the member''s Team Lead or the G-Squad Coordinator, can record attendance'
      using errcode = '42501';
  end if;
  if not v_p.is_event or app.is_sunday_project(new.project_id) then
    raise exception 'Attendance is recorded for events (Sundays have their own check-in)' using errcode = '23514';
  end if;
  -- Decision of 27 Nov 2026: attendance is taken only while the event is live (approved or
  -- under way), never once it is done or cancelled.
  if v_p.status not in ('approved', 'in_progress') then
    raise exception 'Attendance is taken while an event is live (approved or under way)' using errcode = '23514';
  end if;
  if new.attended_on > v_today or new.attended_on < v_p.d0 or new.attended_on > v_p.d1 then
    raise exception 'Choose a day of the event that has come' using errcode = '23514';
  end if;
  if not exists (select 1 from public.people x where x.id = new.person_id and x.status = 'active' and x.anonymised_at is null) then
    raise exception 'Attendance is recorded for current G-Squad members' using errcode = '23514';
  end if;
  new.church_id := v_p.church_id;
  new.recorded_by := (select auth.uid());
  new.created_at := now();
  return new;
end $$;
revoke all on function app.event_attendance_guard() from public, anon, authenticated;
grant execute on function app.event_attendance_guard() to service_role;
create trigger event_attendance_guard before insert or delete on public.event_attendance
  for each row execute function app.event_attendance_guard();

alter table public.event_attendance enable row level security;
revoke all on public.event_attendance from public, anon, authenticated;
grant select, insert, delete on public.event_attendance to authenticated;
-- Read: those who can read the member, and the event's manager for their own event.
-- SECURITY REVIEW 28 (Ann A01): maturity events only for those who may see faith (above).
create policy event_attendance_read on public.event_attendance for select to authenticated
  using (church_id = (select app.current_church_id()) and app.can_read_attendance(project_id, person_id));
create policy event_attendance_insert on public.event_attendance for insert to authenticated
  with check (church_id = (select app.current_church_id()) and app.can_record_attendance(project_id, person_id));
create policy event_attendance_delete on public.event_attendance for delete to authenticated
  using (church_id = (select app.current_church_id()) and app.can_record_attendance(project_id, person_id));

-- Decision of 27 Nov 2026: attendance counts only for a live event. When an event is cancelled
-- its entries are removed; when its dates move, entries for days no longer in it are removed.
-- SECURITY REVIEW 29 (R01): a finished event (done before or after the change) keeps its record,
-- so a later edit can't erase maturity history. (R02): each removal is logged with the count
-- and the reason, so the owner can't erase entries others recorded without a trace.
create or replace function app.attendance_follows_event() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_n integer := 0;
  v_why text;
begin
  if old.status = 'done' or new.status = 'done' then
    return null;
  end if;
  if new.status = 'cancelled' then
    delete from public.event_attendance a where a.project_id = new.id;
    get diagnostics v_n = row_count;
    v_why := 'cancelled';
  elsif new.starts_at is distinct from old.starts_at or new.ends_at is distinct from old.ends_at then
    delete from public.event_attendance a
     where a.project_id = new.id
       and (a.attended_on < (new.starts_at at time zone 'Europe/London')::date
            or a.attended_on > (new.ends_at at time zone 'Europe/London')::date);
    get diagnostics v_n = row_count;
    v_why := 'dates_moved';
  end if;
  if v_n > 0 then
    perform app.audit('attendance_removed_by_event_change', 'event_attendance', new.id,
                      jsonb_build_object('removed', v_n, 'reason', v_why));
  end if;
  return null;
end $$;
revoke all on function app.attendance_follows_event() from public, anon, authenticated;
grant execute on function app.attendance_follows_event() to service_role;
create trigger projects_attendance_follows_event after update of status, starts_at, ends_at on public.projects
  for each row when (new.status is distinct from old.status or new.starts_at is distinct from old.starts_at
                     or new.ends_at is distinct from old.ends_at)
  execute function app.attendance_follows_event();

-- The check-in list for one day of an event: the members this leader may record, those who
-- RSVP'd first, with whether they are already marked. Names only for members the caller can
-- read anyway.
create or replace function public.event_attendance_candidates(p_project uuid, p_on date)
returns table (person_id uuid, display_name text, rsvp boolean, attended boolean)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Europe/London')::date;
begin
  if not exists (select 1 from public.projects p where p.id = p_project and p.church_id = app.current_church_id()) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  -- SECURITY REVIEW 28 (Ann A02): only for a day on which attendance can be recorded (as the
  -- guard checks). RSVPs are otherwise read by no signed-in user (only counts, migration 6);
  -- before, any leader could list their members' RSVPs to any project, draft or not, at any time.
  if not exists (select 1 from public.projects p
                 where p.id = p_project and p.is_event and p.status in ('approved', 'in_progress')   -- live only (27 Nov 2026)
                   and p_on <= v_today
                   and p_on between (p.starts_at at time zone 'Europe/London')::date and (p.ends_at at time zone 'Europe/London')::date)
     or app.is_sunday_project(p_project) then
    raise exception 'Choose a day that has come of an event that is live' using errcode = '23514';
  end if;
  return query
    select x.id, (x.first_name || ' ' || x.surname)::text,
           exists (select 1 from public.newsletter_rsvps r where r.project_id = p_project and r.person_id = x.id),
           exists (select 1 from public.event_attendance a where a.project_id = p_project and a.person_id = x.id and a.attended_on = p_on)
    from public.people x
    where x.church_id = app.current_church_id() and x.status = 'active' and x.anonymised_at is null
      and app.can_record_attendance(p_project, x.id)
    order by 3 desc, 2;   -- those who RSVP'd first, then by name
end $$;
revoke all on function public.event_attendance_candidates(uuid, date) from public, anon;
grant execute on function public.event_attendance_candidates(uuid, date) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 2. Planning committees
-- -------------------------------------------------------------------------------------
create table public.project_committee_members (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null default app.current_church_id() references public.churches(id) on delete restrict,
  project_id  uuid not null,
  person_id   uuid not null,
  role        text check (length(role) <= 80),
  added_by    uuid,
  created_at  timestamptz not null default now(),
  unique (church_id, id),
  unique (project_id, person_id),
  foreign key (church_id, project_id) references public.projects(church_id, id) on delete cascade,
  foreign key (church_id, person_id) references public.people(church_id, id) on delete cascade
);
create index project_committee_members_person on public.project_committee_members (person_id);
comment on table public.project_committee_members is
  'G-Squad members on an event''s planning committee (migration 36); seats on live events count in leaders'' load.';

create or replace function app.committee_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' then
    if not exists (select 1 from public.projects p where p.id = old.project_id) or app.person_gone(old.person_id) then
      return old;
    end if;
    if not app.can_manage_project(old.project_id) then
      raise exception 'Only the event''s owner or the Operations Lead changes its committee' using errcode = '42501';
    end if;
    return old;
  end if;
  if not app.can_manage_project(new.project_id) or not app.can_read_person(new.person_id) then
    raise exception 'Only the event''s owner or the Operations Lead changes its committee' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and (new.project_id <> old.project_id or new.person_id <> old.person_id or new.id <> old.id) then
    raise exception 'Only the role on the committee can change' using errcode = '23514';
  end if;
  if tg_op = 'INSERT' then
    if exists (select 1 from public.projects p where p.id = new.project_id and (p.status in ('done', 'cancelled') or not p.is_event)) then
      raise exception 'A committee is named for an event that is still to happen' using errcode = '23514';
    end if;
    if not exists (select 1 from public.people x where x.id = new.person_id and x.status = 'active' and x.anonymised_at is null) then
      raise exception 'Committee members are current G-Squad members' using errcode = '23514';
    end if;
    new.added_by := (select auth.uid());
    new.created_at := now();
  else
    new.added_by := old.added_by;
    new.created_at := old.created_at;
    new.church_id := old.church_id;
  end if;
  return new;
end $$;
revoke all on function app.committee_guard() from public, anon, authenticated;
grant execute on function app.committee_guard() to service_role;
create trigger project_committee_members_guard before insert or update or delete on public.project_committee_members
  for each row execute function app.committee_guard();

alter table public.project_committee_members enable row level security;
revoke all on public.project_committee_members from public, anon, authenticated;
grant select, insert, update, delete on public.project_committee_members to authenticated;
-- Read across the church, as projects and event plans are; changed by the event's manager.
create policy project_committee_members_read on public.project_committee_members for select to authenticated
  using (church_id = (select app.current_church_id()));
create policy project_committee_members_insert on public.project_committee_members for insert to authenticated
  with check (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));
create policy project_committee_members_update on public.project_committee_members for update to authenticated
  using (church_id = (select app.current_church_id()) and app.can_manage_project(project_id))
  with check (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));
create policy project_committee_members_delete on public.project_committee_members for delete to authenticated
  using (church_id = (select app.current_church_id()) and app.can_manage_project(project_id));

-- -------------------------------------------------------------------------------------
-- Leaders' load: committee seats as a separate, lighter count with its own limit.
-- -------------------------------------------------------------------------------------
alter table public.church_settings
  add column committees_max smallint not null default 2 check (committees_max between 1 and 10);
comment on column public.church_settings.committees_max is
  'Planning committee seats on live events a leader may hold before a pastoral check-in is suggested (migration 36).';

-- Re-created with committee seats (return type changes, so dropped first). "over" now means
-- over either limit, so the fair share count, the nightly flags and the panel all include it.
drop function public.leaders_carrying_too_much();
drop function app.leader_loads(uuid);
create function app.leader_loads(p_church uuid default null)
returns table (church_id uuid, user_id uuid, person_id uuid, display_name text, team_roles integer, live_projects integer,
               committee_seats integer, roles_over boolean, committees_over boolean, over boolean)
language sql stable security definer set search_path = ''
as $$
  select u.church_id, u.id, u.person_id, u.display_name, r.n, pr.n, cm.n,
         (r.n + pr.n) > coalesce(s.leader_roles_max, 2),
         cm.n > coalesce(s.committees_max, 2),
         (r.n + pr.n) > coalesce(s.leader_roles_max, 2) or cm.n > coalesce(s.committees_max, 2)
  from public.app_users u
  left join public.church_settings s on s.church_id = u.church_id
  cross join lateral (select count(*)::int as n from public.role_assignments ra
                      where ra.user_id = u.id and ra.is_active and ra.role in ('unit_lead', 'deputy_unit_lead')
                        and (ra.unit_id is null
                             or exists (select 1 from public.units un where un.id = ra.unit_id and un.is_active))) r
  cross join lateral (select count(*)::int as n from public.projects p
                      where p.owner_user_id = u.id and p.status in ('submitted', 'approved', 'in_progress')
                        and not app.is_sunday_project(p.id)) pr
  -- Seats on live events' committees, through the leader's own G-Squad record.
  -- SECURITY REVIEW 28 (Ann A03): only once the event is approved, so someone other than the
  -- event's owner has agreed to it. Before, a Team Lead could create events, submit them and
  -- name another leader they can see on each committee, putting that leader by name on the
  -- "carrying a lot" list and raising a pastoral check-in on them, without anyone else's say.
  cross join lateral (select count(*)::int as n from public.project_committee_members c
                      join public.projects p on p.id = c.project_id
                      where u.person_id is not null and c.person_id = u.person_id
                        and p.status in ('approved', 'in_progress')) cm
  where u.is_active and (p_church is null or u.church_id = p_church)
$$;
revoke all on function app.leader_loads(uuid) from public, anon, authenticated;
grant execute on function app.leader_loads(uuid) to service_role;

create function public.leaders_carrying_too_much()
returns table (user_id uuid, display_name text, team_roles integer, live_projects integer, committee_seats integer,
               roles_over boolean, committees_over boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if app.current_church_id() is null
     or not app.has_any_role(array['gsquad_coordinator','resident_pastor','operations_lead','pastoral_lead']::public.app_role[]) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select l.user_id, l.display_name, l.team_roles, l.live_projects, l.committee_seats, l.roles_over, l.committees_over
    from app.leader_loads(app.current_church_id()) l
    where l.over
    order by l.team_roles + l.live_projects + l.committee_seats desc, l.display_name;
end $$;
revoke all on function public.leaders_carrying_too_much() from public, anon;
grant execute on function public.leaders_carrying_too_much() to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- 3. Facts for one member, and engagement for one team, this quarter (counts only)
-- -------------------------------------------------------------------------------------
create or replace function public.person_engagement(p_person uuid, p_quarter date default null)
returns jsonb
language plpgsql volatile security definer set search_path = ''   -- volatile: it logs (review 29 R03)
as $$
declare
  v_q date := date_trunc('quarter', coalesce(p_quarter, (now() at time zone 'Europe/London')::date))::date;
  v_end date := (v_q + interval '3 months')::date;
  v_faith boolean;
begin
  if not app.can_read_person(p_person) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  -- SECURITY REVIEW 28 (Ann A01): maturity events are counted only for a caller who may see
  -- the member's faith (or edit the member); for others maturity_attended is null and
  -- events_attended leaves maturity events out, so the one can't be worked out from the other.
  -- Decision of 27 Nov 2026: the Operations Lead, who records at every event, sees them too.
  v_faith := app.can_see_faith(p_person) or app.can_edit_person(p_person) or app.has_role('operations_lead');
  -- SECURITY REVIEW 29 (R03): a read that includes maturity attendance is logged, as faith reads are.
  if v_faith then
    perform app.audit('view_engagement', 'event_attendance', p_person, jsonb_build_object('quarter', v_q));
  end if;
  return jsonb_build_object(
    'quarter_start', v_q,
    'events_attended', (select count(*) from public.event_attendance a
                        where a.person_id = p_person and a.attended_on >= v_q and a.attended_on < v_end
                          and (v_faith or not app.is_maturity_event(a.project_id))),
    'maturity_attended', case when v_faith then
                          (select count(*) from public.event_attendance a
                           where a.person_id = p_person and a.attended_on >= v_q and a.attended_on < v_end
                             and app.is_maturity_event(a.project_id)) end,
    'events_served', (select count(distinct a.project_id) from public.assignments a
                      where a.person_id = p_person and a.status in ('planned', 'served')
                        and a.serve_date >= v_q and a.serve_date < v_end and not app.is_sunday_project(a.project_id)),
    -- SECURITY REVIEW 28 (Ann A03): approved events only, not drafts an owner has not put forward.
    'committees', (select count(*) from public.project_committee_members c join public.projects p on p.id = c.project_id
                   where c.person_id = p_person and p.starts_at < v_end and p.ends_at >= v_q
                     and p.status in ('approved', 'in_progress', 'done')));
end $$;
revoke all on function public.person_engagement(uuid, date) from public, anon;
grant execute on function public.person_engagement(uuid, date) to authenticated, service_role;

create or replace function public.team_engagement(p_unit uuid, p_quarter date default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_q date := date_trunc('quarter', coalesce(p_quarter, (now() at time zone 'Europe/London')::date))::date;
  v_end date := (v_q + interval '3 months')::date;
  v jsonb;
  v_faith boolean;
begin
  if not exists (select 1 from public.units u where u.id = p_unit and u.church_id = app.current_church_id())
     or not app.can_view_unit(p_unit) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  -- SECURITY REVIEW 28 (Ann A01): in a small team a count is a person. Maturity events are
  -- counted only for those who may see these members' faith: the team's Lead or Deputy, the
  -- Coordinator, the Resident Pastor and (decision of 27 Nov 2026) the Operations Lead. For
  -- Purpose Heads, attended_maturity is null and "attended" leaves maturity events out.
  v_faith := app.sees_unit(p_unit) or app.has_any_role(array['resident_pastor','gsquad_coordinator','operations_lead']::public.app_role[]);   -- Ops Lead: decision of 27 Nov 2026
  select jsonb_build_object(
           'quarter_start', v_q,
           'members', count(distinct m.person_id),
           'attended', count(distinct m.person_id) filter (where exists (
               select 1 from public.event_attendance ea
               where ea.person_id = m.person_id and ea.attended_on >= v_q and ea.attended_on < v_end
                 and (v_faith or not app.is_maturity_event(ea.project_id)))),
           'attended_maturity', case when v_faith then count(distinct m.person_id) filter (where exists (
               select 1 from public.event_attendance ea
               where ea.person_id = m.person_id and ea.attended_on >= v_q and ea.attended_on < v_end
                 and app.is_maturity_event(ea.project_id))) end,
           'served', count(distinct m.person_id) filter (where exists (
               select 1 from public.assignments a
               where a.person_id = m.person_id and a.unit_id = p_unit and a.status in ('planned', 'served')
                 and a.serve_date >= v_q and a.serve_date < v_end and not app.is_sunday_project(a.project_id))),
           'on_committees', count(distinct m.person_id) filter (where exists (
               select 1 from public.project_committee_members c join public.projects p on p.id = c.project_id
               where c.person_id = m.person_id and p.starts_at < v_end and p.ends_at >= v_q
                 and p.status in ('approved', 'in_progress', 'done'))))   -- SECURITY REVIEW 28 (Ann A03)
    into v
    from public.unit_memberships m join public.people pp on pp.id = m.person_id
    where m.unit_id = p_unit and m.status = 'active' and pp.status = 'active' and pp.anonymised_at is null;
  return v;
end $$;
revoke all on function public.team_engagement(uuid, date) from public, anon;
grant execute on function public.team_engagement(uuid, date) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- Anonymising and export (re-created whole from migration 35 with the marked lines).
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
  -- Migration 36: events they attended and committee seats.
  delete from public.event_attendance where person_id = p_person;
  delete from public.project_committee_members where person_id = p_person;
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
                     end,
    -- Migration 36: events attended and planning committee seats.
    -- SECURITY REVIEW 28 (Ann A01): maturity events only for a caller who may see the
    -- member's faith (the Resident Pastor) and the Operations Lead (decision of 27 Nov 2026).
    'events_attended', (select coalesce(jsonb_agg(jsonb_build_object('event', p.name, 'attended_on', ea.attended_on)
                                                  order by ea.attended_on), '[]')
                        from public.event_attendance ea join public.projects p on p.id = ea.project_id
                        where ea.person_id = p_person
                          and (app.can_see_faith(p_person) or app.has_role('operations_lead')   -- Ops Lead: decision of 27 Nov 2026
                               or not app.is_maturity_event(ea.project_id))),
    'committees',      (select coalesce(jsonb_agg(jsonb_build_object('event', p.name, 'role', cm.role) order by p.starts_at), '[]')
                        from public.project_committee_members cm join public.projects p on p.id = cm.project_id
                        where cm.person_id = p_person)
  ) into v;
  perform app.audit('export_person', 'people', p_person);
  return v;
end $$;
revoke all on function public.export_person(uuid) from public, anon;
grant execute on function public.export_person(uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- The quarterly Maturity report (re-created whole from migration 35): maturity habits and
-- team engagement added, counts only.
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
  v_faith boolean;
begin
  -- The roles that read the monthly report and the four focus areas.
  if not app.has_any_role(array['gsquad_coordinator','resident_pastor','purpose_head',
                                'operations_lead','pastoral_lead']::public.app_role[]) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  -- SECURITY REVIEW 28 (Ann A01): team by team, a count in a small team is a person, so
  -- maturity events are counted per team only for the Coordinator and the Resident Pastor (who
  -- may see every member's faith) and the Operations Lead (decision of 27 Nov 2026). For the others the team's attended_maturity is null and
  -- took_part leaves maturity events out. Church-wide habit totals stay for all five roles,
  -- as the pathway counts do (review 27, P05).
  v_faith := app.has_any_role(array['gsquad_coordinator','resident_pastor','operations_lead']::public.app_role[]);   -- Ops Lead: decision of 27 Nov 2026

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
                           where o.church_id = v_church and o.quarter_start = v_q),
           -- Migration 36 (decision of 27 Nov 2026): taking part in maturity events (prayer,
           -- Bible study, or an event whose primary aim is Discipleship & Maturity) counts as a
           -- maturity habit. Counts only: facts, never a score for anyone.
           'habits', (select jsonb_build_object(
                        'maturity_events', count(distinct ea.project_id),
                        'attendances', count(*),
                        'members_attending', count(distinct ea.person_id),
                        'members_attending_3_plus', (select count(*) from (
                            select ea2.person_id from public.event_attendance ea2
                            where ea2.church_id = v_church and ea2.attended_on >= v_q and ea2.attended_on < v_end
                              and app.is_maturity_event(ea2.project_id)
                            group by ea2.person_id having count(*) >= 3) z))
                      from public.event_attendance ea
                      where ea.church_id = v_church and ea.attended_on >= v_q and ea.attended_on < v_end
                        and app.is_maturity_event(ea.project_id)),
           -- Team engagement: per active team, members who attended an event or served on one
           -- (not Sundays) in the quarter, and members on a planning committee.
           'teams', (select coalesce(jsonb_agg(jsonb_build_object(
                        'team', u.name,
                        'members', t.members, 'took_part', t.took_part, 'attended_maturity', t.maturity, 'on_committees', t.committees)
                        order by u.name), '[]')
                     from public.units u
                     cross join lateral (
                       select count(distinct m.person_id) as members,
                              count(distinct m.person_id) filter (where
                                exists (select 1 from public.event_attendance ea
                                        where ea.person_id = m.person_id and ea.attended_on >= v_q and ea.attended_on < v_end
                                          and (v_faith or not app.is_maturity_event(ea.project_id)))
                                or exists (select 1 from public.assignments a
                                           where a.person_id = m.person_id and a.unit_id = m.unit_id
                                             and a.status in ('planned', 'served') and a.serve_date >= v_q and a.serve_date < v_end
                                             and not app.is_sunday_project(a.project_id))) as took_part,
                              case when v_faith then count(distinct m.person_id) filter (where
                                exists (select 1 from public.event_attendance ea
                                        where ea.person_id = m.person_id and ea.attended_on >= v_q and ea.attended_on < v_end
                                          and app.is_maturity_event(ea.project_id))) end as maturity,
                              count(distinct m.person_id) filter (where
                                exists (select 1 from public.project_committee_members cm join public.projects p on p.id = cm.project_id
                                        where cm.person_id = m.person_id and p.starts_at < v_end
                                          and (p.ends_at >= v_q)
                                          and p.status in ('approved', 'in_progress', 'done'))) as committees   -- SECURITY REVIEW 28 (Ann A03)
                       from public.unit_memberships m join public.people pp on pp.id = m.person_id
                       where m.unit_id = u.id and m.status = 'active' and pp.status = 'active' and pp.anonymised_at is null) t
                     where u.church_id = v_church and u.is_active))
    into v_rest;

  return jsonb_build_object('quarter_start', v_q, 'quarter_end', (v_end - 1),
                            'leadership', v_leadership, 'pathway', v_pathway) || v_rest;
end $$;
revoke all on function public.maturity_report(date) from public, anon;
grant execute on function public.maturity_report(date) to authenticated, service_role;
