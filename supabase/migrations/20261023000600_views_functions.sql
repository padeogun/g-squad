-- =====================================================================================
-- G-Squad Planner: 6. Views and read functions
-- Views use security_invoker, so the caller's row-level security applies to them.
-- public.* functions are callable through the API (RPC); each one checks the caller's role
-- itself and, for restricted data, writes the audit log. None is callable by "anon".
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- Calculation helpers (private)
-- -------------------------------------------------------------------------------------

-- A person's monthly slot limit: the church limit, or fewer when their available hours are
-- lower (R10). e.g. 6 hours a month at 3 hours a slot = 2 slots.
create or replace function app.personal_limit(p_person uuid) returns integer
language sql stable security definer set search_path = ''
as $$
  select least(
           s.serving_limit_per_month::int,
           coalesce(floor(p.available_hours_month / s.hours_per_slot)::int, s.serving_limit_per_month::int)
         )
  from public.people p
  join public.church_settings s on s.church_id = p.church_id
  where p.id = p_person
$$;

-- Live slots a person holds in the calendar month containing p_day, across all units.
create or replace function app.slots_in_month(p_person uuid, p_day date, p_exclude uuid default null) returns integer
language sql stable security definer set search_path = ''
as $$
  select count(*)::int
  from public.assignments a
  where a.person_id = p_person
    and a.status in ('planned', 'served')
    and date_trunc('month', a.serve_date) = date_trunc('month', p_day)
    and (p_exclude is null or a.id <> p_exclude)
$$;

-- Is the person on holiday on this day?
create or replace function app.on_holiday(p_person uuid, p_day date) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.holidays h
                 where h.person_id = p_person and p_day between h.starts_on and h.ends_on)
$$;

-- Spare capacity of a unit in a month (spec: slots its members offer the unit, minus its
-- regular monthly need, minus project demand). A person in two units offers their slots
-- once, split between them; days on holiday reduce what they offer pro rata.
-- p_exclude_project leaves one project's own demand out, for the approval check (R6).
create or replace function app.unit_capacity(p_unit uuid, p_month date, p_exclude_project uuid default null)
returns numeric
language sql stable security definer set search_path = ''
as $$
  with bounds as (
    select date_trunc('month', p_month)::date as m_start,
           (date_trunc('month', p_month) + interval '1 month - 1 day')::date as m_end
  ),
  members as (
    select m.person_id
    from public.unit_memberships m
    join public.people p on p.id = m.person_id
    cross join bounds b
    where m.unit_id = p_unit and m.status = 'active' and p.status = 'active'
      and m.joined_on <= b.m_end
  ),
  offers as (
    select mb.person_id,
           app.personal_limit(mb.person_id)::numeric
             / greatest(1, (select count(*) from public.unit_memberships x
                            where x.person_id = mb.person_id and x.status = 'active'))
             * (1 - coalesce((
                  select sum(least(h.ends_on, b.m_end) - greatest(h.starts_on, b.m_start) + 1)
                  from public.holidays h
                  where h.person_id = mb.person_id and h.starts_on <= b.m_end and h.ends_on >= b.m_start
                ), 0)::numeric / (b.m_end - b.m_start + 1)) as offer
    from members mb, bounds b
  ),
  demand as (
    select coalesce(sum(d.slots_needed), 0) as slots
    from public.team_demand d
    join public.projects pr on pr.id = d.project_id, bounds b
    where d.unit_id = p_unit
      and d.on_date between b.m_start and b.m_end
      and pr.status in ('submitted', 'approved', 'in_progress')
      and (p_exclude_project is null or pr.id <> p_exclude_project)
  )
  select round(coalesce((select sum(offer) from offers), 0)
               - (select u.regular_monthly_need from public.units u where u.id = p_unit)
               - (select slots from demand), 1)
$$;

-- -------------------------------------------------------------------------------------
-- Views
-- -------------------------------------------------------------------------------------

-- Engagement level per person (R4), calculated from the serving record on every read, so it
-- is never stale. Order of precedence: Left, Paused, New, Active, Inactive, Occasional.
create view public.v_engagement with (security_invoker = true) as
select p.id as person_id,
       p.church_id,
       case
         when p.status = 'left'   then 'left'
         when p.status = 'paused' then 'paused'
         when p.date_joined > current_date - s.new_volunteer_days then 'new'
         when (select count(*) from public.assignments a
               where a.person_id = p.id and a.status = 'served'
                 and a.serve_date > current_date - (s.active_window_weeks * 7)) >= s.active_min_serves then 'active'
         when not exists (select 1 from public.assignments a
                          where a.person_id = p.id and a.status = 'served'
                            and a.serve_date > current_date - (s.inactive_after_weeks * 7)) then 'inactive'
         else 'occasional'
       end as engagement,
       (select max(a.serve_date) from public.assignments a
        where a.person_id = p.id and a.status = 'served') as last_served
from public.people p
join public.church_settings s on s.church_id = p.church_id;

-- Input tracker with the derived Overdue status (R9: overdue the day after the due date).
create view public.v_project_inputs with (security_invoker = true) as
select i.*,
       case when i.status = 'received' then 'received'
            when i.due_on < current_date then 'overdue'
            else 'requested' end as display_status
from public.project_inputs i;

-- Service grid segments with their worked-out end times.
create view public.v_service_segments with (security_invoker = true) as
select s.*, (s.starts_at + make_interval(mins => s.duration_minutes))::time as ends_at
from public.service_segments s;

-- -------------------------------------------------------------------------------------
-- Restricted reads (logged)
-- -------------------------------------------------------------------------------------

-- Faith fields for one person. Allowed: Resident Pastor, G-Squad Coordinator, TECi
-- Coordinator, the person's own Unit Lead. Every successful read is logged.
create or replace function public.get_person_faith(p_person uuid)
returns setof public.person_faith
-- SECURITY REVIEW FIX F03: VOLATILE, not STABLE. PostgREST runs STABLE functions in a
-- read-only transaction, where the audit insert below would fail and the read be refused.
language plpgsql volatile security definer set search_path = ''
as $$
begin
  if not app.can_see_faith(p_person) then
    raise exception 'Not allowed to view faith fields for this person' using errcode = '42501';
  end if;
  perform app.audit('view_faith', 'person_faith', p_person);
  return query select f.* from public.person_faith f where f.person_id = p_person;
end $$;

-- Pastoral notes for one person. Every successful read is logged.
create or replace function public.get_pastoral_notes(p_person uuid)
returns setof public.pastoral_notes
-- SECURITY REVIEW FIX F03: VOLATILE, not STABLE. PostgREST runs STABLE functions in a
-- read-only transaction, where the audit insert below would fail and the read be refused.
language plpgsql volatile security definer set search_path = ''
as $$
begin
  if not app.can_see_pastoral(p_person) then
    raise exception 'Not allowed to view pastoral notes for this person' using errcode = '42501';
  end if;
  perform app.audit('view_pastoral', 'pastoral_notes', p_person);
  return query select n.* from public.pastoral_notes n where n.person_id = p_person order by n.created_at desc;
end $$;

-- The app calls this whenever a user downloads an export, so every export is logged.
create or replace function public.log_export(p_scope text, p_row_count integer)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if app.current_church_id() is null then
    raise exception 'No active account' using errcode = '42501';
  end if;
  -- SECURITY REVIEW FIX F12: the audit detail must never hold personal values, so the scope
  -- must be a short code such as 'people_unit' (not free text that could hold a name).
  if p_scope is null or p_scope !~ '^[a-z0-9_]{1,40}$' then
    raise exception 'Export scope must be a short code (a-z, 0-9, _)' using errcode = '22023';
  end if;
  perform app.audit('export', null, null,
                    jsonb_build_object('scope', p_scope, 'rows', greatest(coalesce(p_row_count, 0), 0)));
end $$;

-- -------------------------------------------------------------------------------------
-- Counts and newsletter data (no personal details beyond what the newsletter prints)
-- -------------------------------------------------------------------------------------

-- Baptism counts for a month: numbers only, never names. Used by the monthly report and the
-- newsletter, so the Coordinator, Resident Pastor, TECi Coordinator and editors may call it.
create or replace function public.baptism_counts(p_month date)
returns table (water_baptisms integer, holy_spirit_baptisms integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not app.has_any_role(array['resident_pastor','gsquad_coordinator','teci_coordinator',
                                'newsletter_editor','purpose_head']::public.app_role[]) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select count(*) filter (where date_trunc('month', f.water_baptism_date) = date_trunc('month', p_month))::int,
           count(*) filter (where date_trunc('month', f.holy_spirit_baptism_date) = date_trunc('month', p_month))::int
    from public.person_faith f
    where f.church_id = app.current_church_id();
end $$;

-- Celebrations for a newsletter month: opted-in members only (R18), first name and surname
-- initial, day and month only. New members are those whose date joined falls in the
-- previous month.
create or replace function public.newsletter_celebrations(p_issue_month date)
returns table (kind text, display_name text, day smallint, month smallint)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_month int := extract(month from p_issue_month)::int;
begin
  if not app.has_any_role(array['newsletter_editor','gsquad_coordinator','resident_pastor',
                                'operations_lead']::public.app_role[]) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select x.kind, x.display_name, x.day, x.month from (
      select 'birthday'::text as kind, p.first_name || ' ' || left(p.surname, 1) || '.' as display_name,
             p.birth_day as day, p.birth_month as month
      from public.people p
      where p.church_id = app.current_church_id() and p.status = 'active'
        and p.celebration_opt_in and p.birth_month = v_month
      union all
      select 'anniversary', p.first_name || ' ' || left(p.surname, 1) || '.', p.anniversary_day, p.anniversary_month
      from public.people p
      where p.church_id = app.current_church_id() and p.status = 'active'
        and p.celebration_opt_in and p.anniversary_month = v_month
      union all
      select 'new_member', p.first_name || ' ' || left(p.surname, 1) || '.',
             extract(day from p.date_joined)::smallint, extract(month from p.date_joined)::smallint
      from public.people p
      where p.church_id = app.current_church_id() and p.status = 'active' and p.celebration_opt_in
        and date_trunc('month', p.date_joined) = date_trunc('month', p_issue_month) - interval '1 month'
    ) x
    order by x.kind, x.month, x.day;
end $$;

-- How many people will receive the newsletter: a count only, so editors never see addresses.
create or replace function public.newsletter_recipient_count()
returns integer
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not app.has_any_role(array['newsletter_editor','gsquad_coordinator','resident_pastor',
                                'operations_lead']::public.app_role[]) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return (select count(*)::int from public.people p
          where p.church_id = app.current_church_id() and p.status = 'active'
            and p.newsletter_subscribed and p.email is not null and p.anonymised_at is null);
end $$;

-- RSVP and reaction counts for an issue.
create or replace function public.newsletter_issue_stats(p_issue uuid)
returns table (item text, label text, total integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not app.has_any_role(array['newsletter_editor','gsquad_coordinator','resident_pastor',
                                'operations_lead']::public.app_role[])
     or not exists (select 1 from public.newsletter_issues i
                    where i.id = p_issue and i.church_id = app.current_church_id()) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select 'rsvp'::text, pr.name, count(r.person_id)::int
    from public.newsletter_rsvps r join public.projects pr on pr.id = r.project_id
    where r.issue_id = p_issue group by pr.name
    union all
    select 'reaction', x.reaction::text, count(*)::int
    from public.newsletter_reactions x where x.issue_id = p_issue group by x.reaction;
end $$;

-- Figures for the monthly G-Squad report (R13), filled automatically.
create or replace function public.monthly_report_figures(p_month date)
returns table (active_volunteers integer, occasional integer, inactive integer, new_members integer,
               one_to_ones_done integer, people_baptised_water integer, holy_spirit_baptisms integer)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_church uuid := app.current_church_id();
  v_q date := (date_trunc('quarter', p_month))::date;
begin
  if not app.has_any_role(array['gsquad_coordinator','resident_pastor','purpose_head',
                                'operations_lead','pastoral_lead']::public.app_role[]) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select
      (select count(*)::int from public.v_engagement e where e.church_id = v_church and e.engagement = 'active'),
      (select count(*)::int from public.v_engagement e where e.church_id = v_church and e.engagement = 'occasional'),
      (select count(*)::int from public.v_engagement e where e.church_id = v_church and e.engagement = 'inactive'),
      (select count(*)::int from public.people p
        where p.church_id = v_church and date_trunc('month', p.date_joined) = date_trunc('month', p_month)),
      (select count(*)::int from public.one_to_ones o where o.church_id = v_church and o.quarter_start = v_q),
      (select count(*)::int from public.person_faith f
        where f.church_id = v_church and date_trunc('month', f.water_baptism_date) = date_trunc('month', p_month)),
      (select count(*)::int from public.person_faith f
        where f.church_id = v_church and date_trunc('month', f.holy_spirit_baptism_date) = date_trunc('month', p_month));
end $$;

-- Capacity calendar: spare capacity per unit per month for a year (Leadership group).
create or replace function public.capacity_calendar(p_year integer)
returns table (unit_id uuid, unit_name text, month date, spare numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not app.has_any_role(array['resident_pastor','purpose_head','gsquad_coordinator','unit_lead',
                                'operations_lead']::public.app_role[]) then
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
-- Email links: redeemed only by the Edge Function running as service_role.
-- The raw token is hashed here and compared with the stored hash; links are single-purpose
-- and expire. RSVP and reaction links can be used again (idempotent); unsubscribe sets the flag.
-- -------------------------------------------------------------------------------------
create or replace function public.redeem_email_link(p_token text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  t public.email_link_tokens%rowtype;
begin
  -- SECURITY REVIEW FIX F13: defence in depth on top of the EXECUTE grant: refuse any caller
  -- with a signed-in or anonymous API identity, so only the service role / jobs can redeem.
  if not app.is_system() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  -- Tokens are URL-safe random strings; reject anything else before hashing.
  if p_token is null or length(p_token) < 32 or length(p_token) > 256 or p_token !~ '^[A-Za-z0-9_-]+$' then
    return 'invalid';
  end if;
  select * into t from public.email_link_tokens
  where token_hash = pg_catalog.sha256(pg_catalog.convert_to(p_token, 'UTF8'));   -- core SHA-256, no extension needed
  if not found or t.expires_at < now() then
    return 'invalid';
  end if;
  if t.purpose = 'rsvp' then
    insert into public.newsletter_rsvps (church_id, project_id, person_id, issue_id)
    values (t.church_id, t.target_project, t.person_id, t.issue_id)
    on conflict do nothing;
  elsif t.purpose = 'react' then
    insert into public.newsletter_reactions (church_id, issue_id, person_id, reaction)
    values (t.church_id, t.issue_id, t.person_id, t.reaction)
    on conflict do nothing;
  else
    update public.people set newsletter_subscribed = false where id = t.person_id;
  end if;
  update public.email_link_tokens set used_at = coalesce(used_at, now()) where token_hash = t.token_hash;
  return t.purpose::text;
end $$;
