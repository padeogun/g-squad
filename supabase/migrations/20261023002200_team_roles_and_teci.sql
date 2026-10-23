-- =====================================================================================
-- G-Squad Planner: 22. Team roles, Deputy Team Lead, Purpose Head rule and TECi
-- (decisions of 23 Oct 2026)
--   1. Every team has four default roles: Team Lead, Deputy Team Lead, Welfare and Pastoral
--      Coordinator, Member. They are church-wide, created for every church, and cannot be
--      renamed, moved, switched off or deleted. The Welfare and Pastoral Coordinator is a
--      label only (no extra app access).
--   2. Roles have a permanence: Operational (routine) or Project (temporary). A standing team
--      membership takes operational roles only; project roles are for project teams (slice 4).
--   3. No co-leads: one Team Lead per team, both as the access role (unit_lead) and as the
--      team-role label on memberships. unit_memberships.is_team_leader now simply follows the
--      Team Lead label, so the two can't disagree.
--   4. Deputy Team Lead (access role deputy_unit_lead, scoped to one unit): view-only access to
--      what the Team Lead sees, including faith fields (every read still logged) and check-in
--      flags, but NOT one-to-ones. Every write rule still names the Team Lead (unit_lead), so
--      the Deputy writes nothing.
--   5. G-Squad Coordinator and Operations Lead are functions held by a Purpose Head or the
--      Resident Pastor. Giving either needs that role first (it can be given in the same
--      request), and removing someone's last Purpose Head / Resident Pastor role is refused
--      while they hold either function. Existing assignments are not re-checked.
--   6. TECi: the TECi Coordinator verifies each member's TECi stage (who and when are
--      recorded; changing a stage clears it), and may add a new member who has completed a
--      TECi level and is not yet in any team. The TECi Coordinator no longer sees the Church
--      Dashboard (migration 20).
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 4 (part). Role scope: the Deputy Team Lead is scoped to a unit, like the Team Lead.
-- -------------------------------------------------------------------------------------
alter table public.role_assignments drop constraint role_scope_ok;
alter table public.role_assignments add constraint role_scope_ok check (
  (role = 'purpose_head' and purpose_id is not null and unit_id is null) or
  (role in ('unit_lead','deputy_unit_lead') and unit_id is not null and purpose_id is null) or
  (role not in ('purpose_head','unit_lead','deputy_unit_lead') and purpose_id is null and unit_id is null)
);

-- SECURITY REVIEW 13 (S05): existing co-leads would make the index below fail with a bare
-- "could not create unique index" error. Stop with a message that says what to fix first
-- (choosing who stays Team Lead is TEC's decision, not the migration's).
do $$
declare v_units text;
begin
  select string_agg(u.name, ', ' order by u.name) into v_units
  from public.units u
  where (select count(*) from public.role_assignments ra
         where ra.unit_id = u.id and ra.role = 'unit_lead' and ra.is_active) > 1;
  if v_units is not null then
    raise exception 'Migration 22 needs one Team Lead per team. These teams have more than one active unit_lead: %. Switch off all but one first.', v_units;
  end if;
end $$;

-- 3. One active Team Lead per unit (backstop for the friendlier check in the trigger below).
create unique index role_assignments_one_team_lead
  on public.role_assignments (unit_id) where role = 'unit_lead' and is_active;

-- Is the signed-in user the Deputy Team Lead of this unit?
create or replace function app.is_unit_deputy_of(p_unit uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.role_assignments ra
    join public.app_users u on u.id = ra.user_id and u.is_active
    where ra.user_id = (select auth.uid()) and ra.role = 'deputy_unit_lead'
      and ra.unit_id = p_unit and ra.is_active
  )
$$;

-- Team Lead or Deputy: who may VIEW a unit's team. Never use this for a write.
create or replace function app.sees_unit(p_unit uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select app.is_unit_lead_of(p_unit) or app.is_unit_deputy_of(p_unit)
$$;

-- -------------------------------------------------------------------------------------
-- 4. Deputy read access. can_read_person is split in two:
--   app.can_read_person_as_leader  the rule as it was (migration 16), used where seeing a
--                                  person also lets you ACT on them (raising a check-in flag);
--   app.can_read_person            that rule plus the Deputy of a unit the person is in now.
-- -------------------------------------------------------------------------------------
create or replace function app.can_read_person_as_leader(p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.people p
    where p.id = p_person
      and p.church_id = app.current_church_id()
      and (
        app.is_church_wide_reader()
        or exists (
          select 1 from public.unit_memberships m
          where m.person_id = p.id and m.status <> 'ended'
            and (app.is_unit_lead_of(m.unit_id) or app.is_purpose_head_of_unit(m.unit_id))
        )
        or exists (
          select 1 from public.assignments a
          join public.projects pr on pr.id = a.project_id
          where a.person_id = p.id and a.status in ('planned', 'served')
            and pr.owner_user_id = (select auth.uid())
        )
      )
  )
$$;

create or replace function app.can_read_person(p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select app.can_read_person_as_leader(p_person)
      or exists (
        select 1 from public.people p
        join public.unit_memberships m on m.person_id = p.id and m.status <> 'ended'
        where p.id = p_person
          and p.church_id = app.current_church_id()
          and app.is_unit_deputy_of(m.unit_id)
      )
$$;

-- Faith fields: as migration 3, plus the Deputy of an ACTIVE membership (as for the Team
-- Lead, F07). Reads still go only through public.get_person_faith(), which logs each one.
create or replace function app.can_see_faith(p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.people p
    where p.id = p_person
      and p.church_id = app.current_church_id()
      and (
        app.has_any_role(array['resident_pastor','gsquad_coordinator','teci_coordinator']::public.app_role[])
        or exists (
          select 1 from public.unit_memberships m
          where m.person_id = p.id and m.status = 'active' and app.sees_unit(m.unit_id)
        )
      )
  )
$$;

-- Memberships: the Deputy sees the unit's memberships, like the Team Lead.
drop policy memberships_read on public.unit_memberships;
create policy memberships_read on public.unit_memberships for select to authenticated
  using (church_id = (select app.current_church_id())
         and (app.can_read_person(person_id) or app.sees_unit(unit_id) or app.is_purpose_head_of_unit(unit_id)));

-- Check-in flags: the Deputy SEES them (flags_read uses can_read_person) but does not raise
-- them; raising stays with those who could before.
drop policy flags_insert on public.checkin_flags;
create policy flags_insert on public.checkin_flags for insert to authenticated
  with check (church_id = (select app.current_church_id()) and app.can_read_person_as_leader(person_id)
              and source = 'manual' and status = 'open' and raised_by = (select auth.uid()));

-- Assignments (rota): the Deputy sees the unit's rota; making assignments is unchanged.
drop policy assignments_read on public.assignments;
create policy assignments_read on public.assignments for select to authenticated
  using (church_id = (select app.current_church_id())
         and (app.sees_unit(unit_id) or app.is_purpose_head_of_unit(unit_id)
              or app.owns_project(project_id)
              or (select app.has_any_role(array['operations_lead','resident_pastor','gsquad_coordinator']::public.app_role[]))));

-- Recognitions: the Deputy sees the unit's recognitions (giving them is unchanged).
create or replace function app.can_read_recognition(p_unit uuid, p_author uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_author = (select auth.uid())
      or app.sees_unit(p_unit) or app.is_purpose_head_of_unit(p_unit)
      or app.has_any_role(array['gsquad_coordinator','resident_pastor','operations_lead']::public.app_role[])
$$;

-- Dashboards (migration 20 helpers): the Deputy sees the Church Dashboard like the Team Lead,
-- and their unit's dashboard. One-to-one figures stay hidden from them: app.one_to_ones_seen
-- and app.can_read_one_to_one do not include the Deputy, so those come back null.
create or replace function app.is_dashboard_reader() returns boolean
language sql stable security definer set search_path = ''
as $$
  select app.has_any_role(array['resident_pastor','purpose_head','unit_lead','deputy_unit_lead',
                                'gsquad_coordinator','operations_lead','pastoral_lead']::public.app_role[])
$$;

-- SECURITY REVIEW 13 (S01): one-to-ones, re-created whole from migration 3. The writer read
-- their own one-to-ones whatever role they now held, so a Team Lead who became the Deputy of
-- the same team kept reading them (and their dates on the unit dashboard), against the
-- decision that the Deputy does not see one-to-ones. The writer now reads them except while
-- they are that unit's Deputy. (Purpose Head, Coordinator and Resident Pastor as before.)
create or replace function app.can_read_one_to_one(p_unit uuid, p_lead uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select (p_lead = (select auth.uid()) and not app.is_unit_deputy_of(p_unit))
      or app.has_any_role(array['resident_pastor','gsquad_coordinator']::public.app_role[])
      or app.is_purpose_head_of_unit(p_unit)
$$;

create or replace function app.can_view_unit(p_unit uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select app.sees_unit(p_unit) or app.is_purpose_head_of_unit(p_unit)
      or app.has_any_role(array['resident_pastor','operations_lead','gsquad_coordinator']::public.app_role[])
$$;

-- Capacity calendar (migration 6), re-created whole with the Deputy added.
create or replace function public.capacity_calendar(p_year integer)
returns table (unit_id uuid, unit_name text, month date, spare numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not app.has_any_role(array['resident_pastor','purpose_head','gsquad_coordinator','unit_lead',
                                'deputy_unit_lead','operations_lead']::public.app_role[]) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select u.id, u.name, m::date, app.unit_capacity(u.id, m::date)
    from public.units u
    cross join generate_series(make_date(p_year, 1, 1), make_date(p_year, 12, 1), interval '1 month') m
    where u.church_id = app.current_church_id() and u.is_active
    order by u.name, m;
end $$;

-- -------------------------------------------------------------------------------------
-- 3 and 5. Role assignment rules, checked after each statement (so a request that gives
-- Purpose Head and Operations Lead together, in one insert, passes).
-- -------------------------------------------------------------------------------------
create or replace function app.role_rules() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_functions public.app_role[] := array['gsquad_coordinator','operations_lead']::public.app_role[];
  v_holders   public.app_role[] := array['purpose_head','resident_pastor']::public.app_role[];
  v_people    uuid[];
  v_person    uuid;
begin
  -- Service role / SQL editor: bootstrapping and data fixes are not limited.
  if app.is_system() then return null; end if;

  -- SECURITY REVIEW 13 (S03): two requests at the same time (one giving Operations Lead, the
  -- other removing the same person's Purpose Head) each saw the other's row as not yet
  -- committed, so both passed and left the function with no holder. One lock per person,
  -- held to the end of the transaction, makes the second wait; its checks below then run on a
  -- fresh snapshot (this function is volatile) and see the first one's change. Locks are
  -- taken in a fixed order so an UPDATE that moves a row between two people cannot deadlock.
  if tg_op = 'INSERT' then
    v_people := array[new.user_id];
  elsif tg_op = 'DELETE' then
    v_people := array[old.user_id];
  else
    v_people := array[least(old.user_id, new.user_id), greatest(old.user_id, new.user_id)];
  end if;
  foreach v_person in array v_people loop
    perform pg_advisory_xact_lock(hashtextextended('gsquad.role_rules:' || v_person::text, 0));
  end loop;

  if tg_op <> 'DELETE' and new.is_active then
    -- 5. The Coordinator and Operations Lead functions need a Purpose Head or Resident Pastor.
    if new.role = any (v_functions)
       and not exists (select 1 from public.role_assignments ra
                       where ra.user_id = new.user_id and ra.is_active and ra.role = any (v_holders)) then
      raise exception 'The G-Squad Coordinator and Operations Lead functions are held by a Purpose Head or the Resident Pastor. Give them that role first.'
        using errcode = '42501';
    end if;
    -- 3. No co-leads (friendlier than the unique index's error).
    if new.role = 'unit_lead'
       and exists (select 1 from public.role_assignments ra
                   where ra.unit_id = new.unit_id and ra.role = 'unit_lead' and ra.is_active and ra.id <> new.id) then
      raise exception 'This team already has a Team Lead' using errcode = '23505';
    end if;
    -- One person is not both Team Lead and Deputy of the same team.
    if new.role in ('unit_lead','deputy_unit_lead')
       and exists (select 1 from public.role_assignments ra
                   where ra.user_id = new.user_id and ra.unit_id = new.unit_id and ra.is_active
                     and ra.role in ('unit_lead','deputy_unit_lead') and ra.role <> new.role) then
      raise exception 'Someone cannot be both Team Lead and Deputy Team Lead of the same team' using errcode = '42501';
    end if;
  end if;

  -- 5. Removing (or switching off) someone's last Purpose Head / Resident Pastor role while
  -- they still hold one of the functions.
  if tg_op <> 'INSERT' and old.is_active and old.role = any (v_holders)
     and exists (select 1 from public.role_assignments ra
                 where ra.user_id = old.user_id and ra.is_active and ra.role = any (v_functions))
     and not exists (select 1 from public.role_assignments ra
                     where ra.user_id = old.user_id and ra.is_active and ra.role = any (v_holders)) then
    raise exception 'Remove their G-Squad Coordinator or Operations Lead function first; it is held by a Purpose Head or the Resident Pastor.'
      using errcode = '42501';
  end if;
  return null;
end $$;
revoke all on function app.role_rules() from public, anon, authenticated;
grant execute on function app.role_rules() to service_role;

create trigger role_assignments_rules after insert or update or delete on public.role_assignments
  for each row execute function app.role_rules();

-- -------------------------------------------------------------------------------------
-- 1 and 2. Default team roles and permanence.
-- -------------------------------------------------------------------------------------
create type public.role_permanence as enum ('operational', 'project');

alter table public.church_roles
  add column permanence public.role_permanence not null default 'operational',
  -- Marks the four default roles; null for roles a church adds itself.
  add column default_key text check (default_key in ('team_lead', 'deputy_team_lead', 'welfare_pastoral', 'member')),
  -- Default roles are church-wide (every team has them) and operational.
  add constraint church_roles_default_shape check (default_key is null or (unit_id is null and permanence = 'operational'));
create unique index church_roles_default_unique on public.church_roles (church_id, default_key) where default_key is not null;

-- Creates (or adopts, if a church-wide role of that name already exists) the four defaults.
create or replace function app.add_default_team_roles(p_church uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  d record;
begin
  -- Marks this transaction's inserts as the app's own (app.church_roles_guard lets them
  -- through); the marker is transaction-local and cleared at the end.
  perform set_config('gsquad.default_roles', 'on', true);
  for d in select * from (values
      ('team_lead',        'Team Lead',                          'Leads the team. One per team.'),
      ('deputy_team_lead', 'Deputy Team Lead',                   'Supports the Team Lead; can view what the Team Lead sees except one-to-ones.'),
      ('welfare_pastoral', 'Welfare and Pastoral Coordinator',   'Looks out for the team''s welfare and pastoral care.'),
      ('member',           'Member',                             'Serves in the team.')) as v(k, n, descr)
  loop
    continue when exists (select 1 from public.church_roles r where r.church_id = p_church and r.default_key = d.k);
    update public.church_roles r
       set default_key = d.k, permanence = 'operational', is_active = true
     where r.church_id = p_church and r.unit_id is null and lower(r.name) = lower(d.n) and r.default_key is null;
    if not found then
      insert into public.church_roles (church_id, name, description, default_key)
      values (p_church, d.n, d.descr, d.k);
    end if;
  end loop;
  perform set_config('gsquad.default_roles', 'off', true);
end $$;
revoke all on function app.add_default_team_roles(uuid) from public, anon, authenticated;
grant execute on function app.add_default_team_roles(uuid) to service_role;

-- Existing churches now; new churches when they are created.
do $$ begin perform app.add_default_team_roles(c.id) from public.churches c; end $$;

create or replace function app.church_default_roles() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.add_default_team_roles(new.id);
  return null;
end $$;
revoke all on function app.church_default_roles() from public, anon, authenticated;
grant execute on function app.church_default_roles() to service_role;
create trigger churches_default_roles after insert on public.churches
  for each row execute function app.church_default_roles();

-- The defaults are fixed: their description and "appears on rotas" may change, nothing else.
create or replace function app.church_roles_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return coalesce(new, old); end if;
  -- SECURITY REVIEW 13 (S07): a team-specific role could be called "Team Lead" (the name
  -- index is per team), so a second person could be shown as a team's Team Lead without the
  -- default label that the no-co-leads rule counts. The default names are kept for the defaults.
  if tg_op <> 'DELETE' and new.default_key is null
     and (tg_op = 'INSERT' or lower(new.name) <> lower(old.name))
     and exists (select 1 from public.church_roles r
                 where r.church_id = new.church_id and r.default_key is not null and lower(r.name) = lower(btrim(new.name))) then
    raise exception 'That name belongs to one of the default team roles; choose another' using errcode = '23505';
  end if;
  if tg_op = 'INSERT' then
    if new.default_key is not null and current_setting('gsquad.default_roles', true) is distinct from 'on' then
      raise exception 'The default team roles are created by the app' using errcode = '42501';
    end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if old.default_key is not null then
      raise exception 'The default team roles cannot be deleted' using errcode = '42501';
    end if;
    return old;
  end if;
  if new.default_key is distinct from old.default_key
     and current_setting('gsquad.default_roles', true) is distinct from 'on' then
    raise exception 'The default team roles are set by the app' using errcode = '42501';
  end if;
  if old.default_key is not null
     and (new.name <> old.name or new.unit_id is distinct from old.unit_id or new.permanence <> old.permanence
          or not new.is_active or new.church_id <> old.church_id) then
    raise exception 'Default team roles cannot be renamed, moved to a team, made a project role or switched off'
      using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app.church_roles_guard() from public, anon, authenticated;
grant execute on function app.church_roles_guard() to service_role;
create trigger church_roles_guard before insert or update or delete on public.church_roles
  for each row execute function app.church_roles_guard();

-- Memberships: the team role must be an operational role of this team (or church-wide);
-- one live Team Lead per team; is_team_leader follows the Team Lead label.
create or replace function app.membership_role_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_role public.church_roles;
begin
  if new.church_role_id is not null then
    select * into v_role from public.church_roles r where r.id = new.church_role_id;
    if not app.is_system() and new.status <> 'ended'
       and (tg_op = 'INSERT' or new.church_role_id is distinct from old.church_role_id or new.status is distinct from old.status) then
      if v_role.permanence = 'project' then
        raise exception 'Project roles are for project teams; choose an operational role for the team'
          using errcode = '22023';
      end if;
      if v_role.unit_id is not null and v_role.unit_id <> new.unit_id then
        raise exception 'That role belongs to another team' using errcode = '22023';
      end if;
      if v_role.default_key = 'team_lead'
         and exists (select 1 from public.unit_memberships m
                     where m.unit_id = new.unit_id and m.church_role_id = new.church_role_id
                       and m.status <> 'ended' and m.id <> new.id) then
        raise exception 'This team already has a Team Lead' using errcode = '23505';
      end if;
    end if;
  end if;
  new.is_team_leader := coalesce(v_role.default_key = 'team_lead', false);
  return new;
end $$;
revoke all on function app.membership_role_guard() from public, anon, authenticated;
grant execute on function app.membership_role_guard() to service_role;
create trigger unit_memberships_role_guard before insert or update on public.unit_memberships
  for each row execute function app.membership_role_guard();

-- SECURITY REVIEW 13 (S02): the trigger's "already has a Team Lead" check reads committed rows
-- only, so two changes at the same moment (two tabs, or the Team Lead and the Operations Lead)
-- both passed and the team had two Team Leads. A unique index cannot be raced.
-- SECURITY REVIEW 13 (S05): before it, existing memberships are brought into line. Their
-- is_team_leader flag was set by the old checkbox and would otherwise stay true without the
-- label (still shown as "(lead)" and blocking the label on My Unit) until the row next changed.
do $$
declare v_units text;
begin
  -- Two labelled Team Leads can exist only if a church already had a church-wide role called
  -- "Team Lead", which add_default_team_roles adopted. Say so plainly rather than guess.
  select string_agg(u.name, ', ' order by u.name) into v_units
  from public.units u
  where (select count(*) from public.unit_memberships m
         join public.church_roles r on r.id = m.church_role_id and r.default_key = 'team_lead'
         where m.unit_id = u.id and m.status <> 'ended') > 1;
  if v_units is not null then
    raise exception 'Migration 22 needs one Team Lead per team. These teams have more than one member with the Team Lead role: %. Change all but one first.', v_units;
  end if;
end $$;
update public.unit_memberships m
   set is_team_leader = coalesce((select r.default_key = 'team_lead' from public.church_roles r where r.id = m.church_role_id), false)
 where m.is_team_leader is distinct from coalesce((select r.default_key = 'team_lead' from public.church_roles r where r.id = m.church_role_id), false);
create unique index unit_memberships_one_team_lead
  on public.unit_memberships (unit_id) where is_team_leader and status <> 'ended';

-- -------------------------------------------------------------------------------------
-- 6. TECi: verification and adding TECi graduates who are not yet in a team.
-- -------------------------------------------------------------------------------------
alter table public.people
  add column teci_verified_at timestamptz,
  add column teci_verified_by uuid,
  -- A verification belongs to a stage.
  add constraint teci_verified_needs_stage check (teci_verified_at is null or teci_stage_id is not null);

-- The TECi Coordinator may now add members (only TECi graduates; people_guard checks).
drop policy people_insert on public.people;
create policy people_insert on public.people for insert to authenticated
  with check (church_id = (select app.current_church_id())
              and created_by = (select auth.uid())
              and (select app.has_any_role(array['unit_lead','operations_lead','teci_coordinator']::public.app_role[])));

-- people_guard, re-created whole from migration 16 with the TECi verification rules:
--   * verifying is the TECi Coordinator's alone, and is always recorded as them, now;
--   * changing a stage without verifying it clears the old verification;
--   * someone adding a member only through the TECi route must record their TECi stage.
create or replace function app.people_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if app.is_system() then return new; end if;

  if tg_op = 'INSERT' then
    -- The TECi stage is set by the TECi Coordinator (or the Ops Lead), not on entry.
    if new.teci_stage_id is not null
       and not app.has_any_role(array['teci_coordinator','operations_lead']::public.app_role[]) then
      raise exception 'Only the TECi Coordinator can set a TECi stage' using errcode = '42501';
    end if;
    -- The TECi Coordinator adds members who have completed a TECi level.
    if new.teci_stage_id is null and not app.has_any_role(array['unit_lead','operations_lead']::public.app_role[]) then
      raise exception 'Choose the TECi stage they have completed' using errcode = '22023';
    end if;
    -- SECURITY REVIEW 13 (S04): the TECi route records the minimum: name, email and the stage.
    -- create_member (and a direct insert) accepted birthdays, marital status, anniversaries,
    -- area, availability and so on from the TECi Coordinator, who cannot edit or correct the
    -- record afterwards (only the G-Squad Coordinator can until they join a team). The rest is
    -- added once the Operations Lead has put them in a team and their Team Lead can edit them.
    if not app.has_any_role(array['unit_lead','operations_lead']::public.app_role[])
       and (new.birth_day is not null or new.birth_month is not null or new.marital_status is not null
            or new.anniversary_day is not null or new.anniversary_month is not null or new.area is not null
            or new.greatness_community_id is not null or new.available_hours_month is not null
            or coalesce(cardinality(new.preferred_times), 0) > 0 or new.date_left is not null
            or new.status <> 'active' or new.celebration_opt_in
            or new.consent_notice_version is not null or new.consent_at is not null) then
      raise exception 'The TECi Coordinator records only a name, email address and TECi stage; the rest is added when they join a team'
        using errcode = '42501';
    end if;
    if new.teci_verified_at is not null and new.teci_stage_id is not null and app.has_role('teci_coordinator') then
      new.teci_verified_at := now();
      new.teci_verified_by := (select auth.uid());
    else
      new.teci_verified_at := null;
      new.teci_verified_by := null;
    end if;
    new.anonymised_at := null;
    return new;
  end if;

  -- An anonymised record stays anonymised (migration 15, L02).
  if old.anonymised_at is not null then
    raise exception 'This record has been anonymised and cannot be changed' using errcode = '42501';
  end if;

  -- UPDATE: identity columns never change through the API.
  if new.id <> old.id or new.church_id <> old.church_id or new.created_by is distinct from old.created_by then
    raise exception 'id, church and creator cannot be changed' using errcode = '42501';
  end if;
  -- Anonymising goes through app.anonymise() (migration 8, F09).
  if current_setting('gsquad.anonymising', true) = 'on' then
    if new.anonymised_at is null or new.email is not null or new.area is not null
       or new.status <> 'left' or new.birth_day is not null or new.anniversary_day is not null then
      raise exception 'The anonymising marker may only be used to anonymise' using errcode = '42501';
    end if;
    return new;
  end if;
  if new.anonymised_at is distinct from old.anonymised_at then
    raise exception 'Use public.anonymise_person() to anonymise a record' using errcode = '42501';
  end if;
  -- Decision 1 (migration 16): the TECi stage of an existing member is the TECi Coordinator's alone.
  if new.teci_stage_id is distinct from old.teci_stage_id and not app.has_role('teci_coordinator') then
    raise exception 'Only the TECi Coordinator can change a TECi stage' using errcode = '42501';
  end if;
  -- Verification: only the TECi Coordinator, always as themselves and now.
  if new.teci_verified_at is distinct from old.teci_verified_at or new.teci_verified_by is distinct from old.teci_verified_by then
    if not app.has_role('teci_coordinator') then
      raise exception 'Only the TECi Coordinator can verify a TECi stage' using errcode = '42501';
    end if;
    if new.teci_verified_at is not null then
      if new.teci_stage_id is null then
        raise exception 'Set a TECi stage before verifying it' using errcode = '22023';
      end if;
      new.teci_verified_at := now();
      new.teci_verified_by := (select auth.uid());
    else
      new.teci_verified_by := null;
    end if;
  elsif new.teci_stage_id is distinct from old.teci_stage_id then
    -- A changed stage is unverified until it is confirmed again.
    new.teci_verified_at := null;
    new.teci_verified_by := null;
  end if;
  -- Someone who is not this person's editor (the TECi Coordinator route) changes TECi only.
  if not app.can_edit_person(old.id)
     and (to_jsonb(new) - 'teci_stage_id' - 'teci_verified_at' - 'teci_verified_by' - 'updated_at')
         <> (to_jsonb(old) - 'teci_stage_id' - 'teci_verified_at' - 'teci_verified_by' - 'updated_at') then
    raise exception 'Only their Team Lead or the G-Squad Coordinator can edit this record' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app.people_guard() from public, anon, authenticated;
grant execute on function app.people_guard() to service_role;

-- create_member, re-created whole from migration 15: p_unit may now be empty for a TECi
-- graduate added by the TECi Coordinator (or the Operations Lead), who must give the stage.
-- p_is_team_leader is kept for compatibility but ignored: the Team Lead label decides.
create or replace function public.create_member(
  p_person jsonb,
  p_unit uuid,
  p_church_role uuid default null,
  p_is_team_leader boolean default false,
  p_leadership_stage uuid default null,
  p_faith jsonb default null)
returns uuid
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  -- The id is made here, not returned by INSERT ... RETURNING, which people_read refuses.
  v_id uuid := gen_random_uuid();
  r public.people;
begin
  r := jsonb_populate_record(null::public.people, coalesce(p_person, '{}'::jsonb));
  if p_unit is null then
    if not app.has_any_role(array['teci_coordinator','operations_lead']::public.app_role[]) then
      raise exception 'Choose the unit they are joining' using errcode = '22023';
    end if;
    if r.teci_stage_id is null then
      raise exception 'Choose the TECi stage they have completed' using errcode = '22023';
    end if;
  end if;

  begin
    insert into public.people (id, first_name, other_names, surname, email, area,
        birth_day, birth_month, marital_status, anniversary_day, anniversary_month,
        date_joined, date_left, status, teci_stage_id, teci_verified_at, greatness_community_id,
        newsletter_subscribed, celebration_opt_in)
    values (v_id, r.first_name, r.other_names, r.surname,
        -- Same normalisation as the unique index people_email_unique (lower(email)).
        nullif(lower(btrim(r.email)), ''), r.area,
        r.birth_day, r.birth_month, r.marital_status,
        -- An anniversary is kept only for married members (data minimisation).
        case when r.marital_status = 'married' then r.anniversary_day end,
        case when r.marital_status = 'married' then r.anniversary_month end,
        coalesce(r.date_joined, current_date), r.date_left,
        -- left_consistent: a leaving date means "left".
        case when r.date_left is not null then 'left'::public.person_status
             else coalesce(nullif(r.status, 'left'), 'active') end,
        -- people_guard keeps a verification only from the TECi Coordinator, stamped now.
        r.teci_stage_id, r.teci_verified_at, r.greatness_community_id,
        coalesce(r.newsletter_subscribed, true), coalesce(r.celebration_opt_in, false));
  exception when unique_violation then
    raise exception 'A member with that email address is already recorded' using errcode = 'P0001';
  end;

  if p_unit is not null then
    insert into public.unit_memberships (person_id, unit_id, church_role_id, leadership_stage_id)
    values (v_id, p_unit, p_church_role, p_leadership_stage);
  end if;

  -- Faith fields only through the logged function (it checks access and audits the write).
  if p_faith is not null then
    perform public.set_person_faith(v_id,
      (p_faith->>'salvation_date')::date,
      coalesce((p_faith->>'water_baptism')::boolean, false),       (p_faith->>'water_baptism_date')::date,
      coalesce((p_faith->>'holy_spirit_baptism')::boolean, false), (p_faith->>'holy_spirit_baptism_date')::date,
      coalesce((p_faith->>'speaks_in_tongues')::boolean, false),   (p_faith->>'speaks_in_tongues_date')::date);
  end if;
  return v_id;
end $$;

-- New helpers follow the schema default (migration 3): callable by signed-in users and the
-- service role, never by anon. The trigger functions above set their own grants.
revoke all on function app.is_unit_deputy_of(uuid), app.sees_unit(uuid), app.can_read_person_as_leader(uuid)
  from public, anon;
grant execute on function app.is_unit_deputy_of(uuid), app.sees_unit(uuid), app.can_read_person_as_leader(uuid)
  to authenticated, service_role;
