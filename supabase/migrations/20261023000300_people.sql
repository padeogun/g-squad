-- =====================================================================================
-- G-Squad Planner: 3. People and Teams
-- The member entry form, restricted faith fields, unit memberships (team role, team leader,
-- leadership stage), holidays, Greatness Community support roles and check-in flags.
-- Data protection decisions (spec, 22 Oct 2026):
--   * birthday held as day and month only; wedding anniversary likewise, and optional
--   * location held as an area only, never a full address
--   * faith fields per person, in their own table, readable only through a logged function
-- =====================================================================================

create type public.marital_status as enum ('single', 'married');
create type public.person_status  as enum ('active', 'paused', 'left');

-- Member entry form.
create table public.people (
  id                      uuid primary key default gen_random_uuid(),
  church_id               uuid not null references public.churches(id) on delete restrict,
  first_name              text not null check (length(first_name) between 1 and 100),
  other_names             text check (length(other_names) <= 200),
  surname                 text not null check (length(surname) between 1 and 100),
  date_joined             date not null default current_date,
  date_left               date check (date_left is null or date_left >= date_joined),
  status                  public.person_status not null default 'active',
  -- Birthday: day and month only (no year), validated as a real calendar day (29 Feb allowed).
  birth_day               smallint,
  birth_month             smallint check (birth_month between 1 and 12),
  -- SECURITY REVIEW FIX F17: RFC 5321 caps an address at 254 characters.
  email                   text check (email is null or (length(email) <= 254 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
  area                    text check (length(area) <= 100),          -- town or postcode district only, e.g. "M6"
  marital_status          public.marital_status,                     -- optional, with the person's agreement
  anniversary_day         smallint,
  anniversary_month       smallint check (anniversary_month between 1 and 12),
  teci_stage_id           uuid,                                      -- set by the TECi Coordinator
  greatness_community_id  uuid,
  available_hours_month   numeric(5,1) check (available_hours_month >= 0),  -- lowers the personal serving cap (R10)
  -- SECURITY REVIEW FIX F17: bounded (at most 10 entries, 500 characters in all).
  preferred_times         text[] not null default '{}'               -- e.g. {"Sunday mornings","Weekday evenings"}
                          check (cardinality(preferred_times) <= 10 and length(array_to_string(preferred_times, '|')) <= 500),
  newsletter_subscribed   boolean not null default true,             -- receives The Greatness Brief (unsubscribe sets false)
  celebration_opt_in      boolean not null default false,            -- R18: shown in newsletter celebrations only when true
  consent_notice_version  text check (length(consent_notice_version) <= 20),  -- privacy notice version accepted
  consent_at              timestamptz,
  created_by              uuid default auth.uid(),                   -- lets the creating Unit Lead see the row before a membership exists
  anonymised_at           timestamptz,                               -- R8: set when personal fields are wiped
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  unique (church_id, id),
  foreign key (church_id, teci_stage_id)          references public.teci_stages(church_id, id) on delete restrict,
  foreign key (church_id, greatness_community_id) references public.greatness_communities(church_id, id) on delete set null (greatness_community_id),
  -- Day and month must both be present or both absent, and form a real date.
  constraint birthday_valid check (
    (birth_day is null and birth_month is null) or
    (birth_day is not null and birth_month is not null and
     birth_day between 1 and extract(day from (make_date(2000, birth_month, 1) + interval '1 month - 1 day'))::int)
  ),
  constraint anniversary_valid check (
    (anniversary_day is null and anniversary_month is null) or
    (anniversary_day is not null and anniversary_month is not null and
     anniversary_day between 1 and extract(day from (make_date(2000, anniversary_month, 1) + interval '1 month - 1 day'))::int)
  ),
  -- Leaving sets status to "left" and a date, together.
  constraint left_consistent check ((status = 'left') = (date_left is not null))
);
create index people_church on public.people (church_id);
create unique index people_email_unique on public.people (church_id, lower(email)) where email is not null;
create trigger people_touch before update on public.people
  for each row execute function app.touch_updated_at();

-- A leader's account may point at their own G-Squad record.
alter table public.app_users
  add foreign key (church_id, person_id) references public.people(church_id, id) on delete set null (person_id);

-- Faith fields: special category data (religious belief). Separate table so access can be
-- restricted and every read logged. There is deliberately NO select policy for API roles;
-- reads go through public.get_person_faith(), which checks access and writes the audit log.
create table public.person_faith (
  person_id                uuid primary key,
  church_id                uuid not null,
  salvation_date           date,
  water_baptism            boolean not null default false,
  water_baptism_date       date,
  holy_spirit_baptism      boolean not null default false,
  holy_spirit_baptism_date date,
  speaks_in_tongues        boolean not null default false,
  speaks_in_tongues_date   date,
  updated_by               uuid default auth.uid(),
  updated_at               timestamptz not null default now(),
  foreign key (church_id, person_id) references public.people(church_id, id) on delete cascade,
  -- A date only makes sense when the tick is set.
  check (water_baptism or water_baptism_date is null),
  check (holy_spirit_baptism or holy_spirit_baptism_date is null),
  check (speaks_in_tongues or speaks_in_tongues_date is null)
);
create trigger person_faith_touch before update on public.person_faith
  for each row execute function app.touch_updated_at();
-- Every write to faith fields is audited (column names only, never the values).
create trigger person_faith_audit after insert or update or delete on public.person_faith
  for each row execute function app.audit_row_change();

-- Unit memberships: team role and team leader live here, because one person can lead one
-- unit and serve in another. Joining beyond the church's limit (default 2 units) needs a
-- Resident Pastor's approval (R3), so such rows start as "pending_approval".
create type public.membership_status as enum ('pending_approval', 'active', 'ended');

create table public.unit_memberships (
  id                    uuid primary key default gen_random_uuid(),
  church_id             uuid not null,
  person_id             uuid not null,
  unit_id               uuid not null,
  church_role_id        uuid,                                   -- team role, from the Roles form
  is_team_leader        boolean not null default false,
  leadership_stage_id   uuid,                                   -- leadership pipeline board
  status                public.membership_status not null default 'active',
  joined_on             date not null default current_date,
  ended_on              date,
  approved_by           uuid,                                   -- the Resident Pastor who approved a third unit
  created_at            timestamptz not null default now(),
  unique (church_id, id),
  foreign key (church_id, person_id)           references public.people(church_id, id) on delete cascade,
  foreign key (church_id, unit_id)             references public.units(church_id, id) on delete restrict,
  foreign key (church_id, church_role_id)      references public.church_roles(church_id, id) on delete set null (church_role_id),
  foreign key (church_id, leadership_stage_id) references public.leadership_stages(church_id, id) on delete set null (leadership_stage_id),
  check ((status = 'ended') = (ended_on is not null))
);
-- A person holds at most one live membership per unit.
create unique index unit_memberships_live on public.unit_memberships (person_id, unit_id) where status <> 'ended';
create index unit_memberships_unit on public.unit_memberships (unit_id) where status = 'active';

-- Holidays: a person on holiday is not offered for any slot (R10) and reduces capacity.
create table public.holidays (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null,
  person_id   uuid not null,
  starts_on   date not null,
  ends_on     date not null,
  created_at  timestamptz not null default now(),
  foreign key (church_id, person_id) references public.people(church_id, id) on delete cascade,
  check (ends_on >= starts_on),
  -- No overlapping holidays for the same person.
  exclude using gist (person_id with =, daterange(starts_on, ends_on, '[]') with &&)
);

-- Greatness Community support roles and the G-Squad member filling each one.
create table public.community_support_roles (
  id            uuid primary key default gen_random_uuid(),
  church_id     uuid not null,
  community_id  uuid not null,
  role_name     text not null check (length(role_name) between 1 and 100),
  person_id     uuid,                                -- null = vacant
  created_at    timestamptz not null default now(),
  foreign key (church_id, community_id) references public.greatness_communities(church_id, id) on delete cascade,
  foreign key (church_id, person_id)    references public.people(church_id, id) on delete set null (person_id),
  unique (community_id, role_name)
);

-- Check-in flags (R5). A flag carries no reason text; the code says only which rule raised it.
create type public.flag_source as enum ('inactive', 'over_limit_two_months', 'new_90_days', 'many_units', 'manual');
create type public.flag_status as enum ('open', 'closed');

create table public.checkin_flags (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null,
  person_id   uuid not null,
  source      public.flag_source not null default 'manual',
  status      public.flag_status not null default 'open',
  raised_by   uuid default auth.uid(),     -- null when raised by the nightly job
  raised_at   timestamptz not null default now(),
  closed_by   uuid,
  closed_at   timestamptz,
  unique (church_id, id),
  foreign key (church_id, person_id) references public.people(church_id, id) on delete cascade
);
-- One open flag per person per source, so the nightly job does not pile up duplicates.
create unique index checkin_flags_one_open on public.checkin_flags (person_id, source) where status = 'open';

-- Pastoral notes: restricted store. No select policy; read through public.get_pastoral_notes(),
-- which checks access and logs every view. Left out of every export except a pastor's own.
create table public.pastoral_notes (
  id            uuid primary key default gen_random_uuid(),
  church_id     uuid not null,
  person_id     uuid not null,
  author_id     uuid not null default auth.uid(),
  note          text not null check (length(note) between 1 and 4000),
  follow_up_on  date,
  created_at    timestamptz not null default now(),
  foreign key (church_id, person_id) references public.people(church_id, id) on delete cascade
);
create trigger pastoral_notes_audit after insert or update or delete on public.pastoral_notes
  for each row execute function app.audit_row_change();

-- Quarterly one-to-ones (Team Lead One-on-One form, R12). One per member per unit per quarter.
create type public.serving_feeling as enum ('thriving', 'doing_well', 'finding_it_hard', 'overstretched');
create type public.support_need    as enum ('none', 'training', 'fewer_slots', 'change_of_role', 'pastoral_check_in');

create table public.one_to_ones (
  id                uuid primary key default gen_random_uuid(),
  church_id         uuid not null,
  person_id         uuid not null,
  unit_id           uuid not null,
  lead_user_id      uuid not null default auth.uid(),
  quarter_start     date not null check (extract(day from quarter_start) = 1 and extract(month from quarter_start) in (1,4,7,10)),
  held_on           date not null,
  feeling           public.serving_feeling not null,
  support_needed    public.support_need not null default 'none',
  development_goal  text check (length(development_goal) <= 1000),
  notes             text check (length(notes) <= 2000),   -- serving only; pastoral matters go to a check-in flag
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  foreign key (church_id, person_id)    references public.people(church_id, id) on delete cascade,
  foreign key (church_id, unit_id)      references public.units(church_id, id) on delete restrict,
  foreign key (church_id, lead_user_id) references public.app_users(church_id, id) on delete restrict,
  unique (person_id, unit_id, quarter_start),
  check (held_on >= quarter_start and held_on < quarter_start + interval '3 months')
);
create trigger one_to_ones_touch before update on public.one_to_ones
  for each row execute function app.touch_updated_at();

-- -------------------------------------------------------------------------------------
-- Person-scope helper functions (used by RLS in migration 7)
-- -------------------------------------------------------------------------------------

-- Can the signed-in user see this person's contact and member details?
--   Church-wide readers: everyone. Purpose Head: people in units of their purpose.
--   Unit Lead: people in their unit, or a person they have just created.
--   Project owner: people assigned to their projects (checked in migration 4's override).
create or replace function app.can_read_person(p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.people p
    where p.id = p_person
      and p.church_id = app.current_church_id()
      and (
        app.is_church_wide_reader()
        or p.created_by = (select auth.uid())
        or exists (
          select 1 from public.unit_memberships m
          where m.person_id = p.id and m.status <> 'ended'
            and (app.is_unit_lead_of(m.unit_id) or app.is_purpose_head_of_unit(m.unit_id))
        )
      )
  )
$$;

-- Can the signed-in user edit this person's member record?
create or replace function app.can_edit_person(p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.people p
    where p.id = p_person
      and p.church_id = app.current_church_id()
      and (
        app.has_any_role(array['operations_lead','gsquad_coordinator','teci_coordinator']::public.app_role[])
        or p.created_by = (select auth.uid())
        or exists (
          select 1 from public.unit_memberships m
          where m.person_id = p.id and m.status <> 'ended' and app.is_unit_lead_of(m.unit_id)
        )
      )
  )
$$;

-- Faith fields: Resident Pastor, G-Squad Coordinator, TECi Coordinator, and the person's
-- own Unit Lead only (decision of 22 Oct 2026). Operations Lead is deliberately excluded.
create or replace function app.can_see_faith(p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.people p
    where p.id = p_person
      and p.church_id = app.current_church_id()
      and (
        app.has_any_role(array['resident_pastor','gsquad_coordinator','teci_coordinator']::public.app_role[])
        -- SECURITY REVIEW FIX F07: only an ACTIVE membership makes someone "their" Unit Lead;
        -- a membership still pending the Resident Pastor's approval (R3) does not.
        or exists (
          select 1 from public.unit_memberships m
          where m.person_id = p.id and m.status = 'active' and app.is_unit_lead_of(m.unit_id)
        )
      )
  )
$$;

-- Pastoral notes: the pastoral lead and the Resident Pastor; Purpose Heads for their purpose
-- only when the church setting allows it (off by default).
create or replace function app.can_see_pastoral(p_person uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.people p
    where p.id = p_person
      and p.church_id = app.current_church_id()
      and (
        app.has_any_role(array['resident_pastor','pastoral_lead']::public.app_role[])
        or (
          (select s.purpose_heads_read_pastoral from public.church_settings s where s.church_id = p.church_id)
          and exists (
            select 1 from public.unit_memberships m
            where m.person_id = p.id and m.status <> 'ended' and app.is_purpose_head_of_unit(m.unit_id)
          )
        )
      )
  )
$$;

-- One-to-ones: the writing Unit Lead, the unit's Purpose Head, the G-Squad Coordinator and
-- the Resident Pastor. The Operations Lead cannot read them.
create or replace function app.can_read_one_to_one(p_unit uuid, p_lead uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_lead = (select auth.uid())
      or app.has_any_role(array['resident_pastor','gsquad_coordinator']::public.app_role[])
      or app.is_purpose_head_of_unit(p_unit)
$$;

revoke all on all functions in schema app from public;
grant execute on all functions in schema app to authenticated, service_role;
