-- =====================================================================================
-- G-Squad Planner: 1. Foundation
-- Churches, sites, users, role assignments, church settings (the business-rule thresholds)
-- and the audit log. Every church-owned table in later migrations carries church_id, and
-- every child row references its parent through (church_id, id), so a record can never be
-- linked to another church's record, even by a bug in the app.
-- =====================================================================================

-- gen_random_uuid() and sha256() are built into Postgres 13+, so pgcrypto is not needed.
-- btree_gist lets an exclusion constraint combine "same person" with "overlapping dates"
-- (holidays). Supabase keeps extensions in the "extensions" schema.
create schema if not exists extensions;
create extension if not exists btree_gist with schema extensions;

-- Private schema for helper functions used by RLS policies and triggers.
-- Supabase's API (PostgREST) only exposes "public", so nothing here is callable over the API.
create schema if not exists app;
revoke all on schema app from public;
grant usage on schema app to authenticated, service_role;

-- -------------------------------------------------------------------------------------
-- Enumerated types
-- -------------------------------------------------------------------------------------

-- In-app roles from the spec. "Project owner" is not a role: it is projects.owner_user_id.
create type public.app_role as enum (
  'resident_pastor',      -- Lead Pastor
  'purpose_head',         -- scoped to one purpose
  'gsquad_coordinator',   -- function of the Maturity Purpose Head
  'teci_coordinator',     -- Maturity team; manages TECi stages
  'unit_lead',            -- scoped to one unit
  'operations_lead',      -- church admin
  'pastoral_lead',        -- G-Squad pastoral lead
  'newsletter_editor',    -- one of the 4 Greatness Brief editors
  'finance'               -- approves event budgets (High-level Event Planning, section 5)
);

-- -------------------------------------------------------------------------------------
-- Churches and sites
-- -------------------------------------------------------------------------------------

create table public.churches (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(name) between 1 and 200),
  slug        text not null unique check (slug ~ '^[a-z0-9-]{2,60}$'),
  created_at  timestamptz not null default now()
);
comment on table public.churches is 'One row per church. TEC Manchester only at launch; the church_id on every record lets other churches be added later.';

create table public.sites (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null references public.churches(id) on delete restrict,
  name        text not null check (length(name) between 1 and 200),
  area        text check (length(area) <= 200),          -- general area only, e.g. "Salford M6"
  created_at  timestamptz not null default now(),
  unique (church_id, id),                                -- target for composite foreign keys
  unique (church_id, name)
);

-- -------------------------------------------------------------------------------------
-- Church settings: every threshold in the Business rules table is a setting, not a constant.
-- One row per church; defaults come from the G-Squad 2027 Volunteer Framework.
-- -------------------------------------------------------------------------------------

create table public.church_settings (
  church_id                   uuid primary key references public.churches(id) on delete cascade,
  serving_limit_per_month     smallint not null default 3  check (serving_limit_per_month between 1 and 31),   -- R1
  hours_per_slot              numeric(4,1) not null default 3 check (hours_per_slot > 0),                    -- R10 personal cap
  units_before_approval       smallint not null default 2  check (units_before_approval between 1 and 10),    -- R3
  new_volunteer_days          smallint not null default 90 check (new_volunteer_days > 0),                   -- R4
  active_window_weeks         smallint not null default 8  check (active_window_weeks > 0),                  -- R4
  active_min_serves           smallint not null default 2  check (active_min_serves > 0),                    -- R4
  inactive_after_weeks        smallint not null default 12 check (inactive_after_weeks > 0),                 -- R4
  -- SECURITY REVIEW FIX F17: bound the array so a caller cannot store an unbounded list.
  unfilled_reminder_weeks     smallint[] not null default '{4,2}' check (cardinality(unfilled_reminder_weeks) <= 10), -- R7
  retention_months            smallint not null default 12 check (retention_months > 0),                     -- R8
  input_reminder_days         smallint not null default 7  check (input_reminder_days >= 0),                 -- R9
  grid_finalise_dow           smallint not null default 4  check (grid_finalise_dow between 0 and 6),        -- R11, 4 = Thursday
  one_to_one_reminder_days    smallint not null default 14 check (one_to_one_reminder_days >= 0),            -- R12
  monthly_report_due_day      smallint not null default 7  check (monthly_report_due_day between 1 and 28),  -- R13
  lead_time_small_weeks       smallint not null default 2  check (lead_time_small_weeks >= 0),               -- R14
  lead_time_medium_weeks      smallint not null default 4  check (lead_time_medium_weeks >= 0),              -- R14
  lead_time_large_weeks       smallint not null default 8  check (lead_time_large_weeks >= 0),               -- R14
  newsletter_update_due_day   smallint not null default 25 check (newsletter_update_due_day between 1 and 28), -- R17
  purpose_heads_read_pastoral boolean  not null default false,   -- open question in the spec; off by default
  -- SECURITY REVIEW FIX F17: labels are a small object of display words; cap their size.
  labels                      jsonb    not null default '{}'::jsonb
                              check (jsonb_typeof(labels) = 'object' and length(labels::text) <= 4000),  -- the church's own words: {"unit":"unit","g_squad":"G-Squad"}
  updated_at                  timestamptz not null default now()
);

-- -------------------------------------------------------------------------------------
-- Users. Volunteers do NOT log in; only leaders and staff have accounts.
-- app_users.id is the Supabase Auth user id.
-- -------------------------------------------------------------------------------------

create table public.app_users (
  id            uuid primary key references auth.users(id) on delete cascade,
  church_id     uuid not null references public.churches(id) on delete restrict,
  display_name  text not null check (length(display_name) between 1 and 200),
  person_id     uuid,                               -- optional link to the user's own G-Squad record (FK added in migration 3)
  is_active     boolean not null default true,      -- deactivate instead of deleting, so audit history stays readable
  created_at    timestamptz not null default now(),
  unique (church_id, id)
);
comment on table public.app_users is 'Leaders and staff who sign in. One church per user.';

-- Purposes are created here (not in the reference migration) because role assignments
-- for Purpose Heads point at a purpose.
create table public.purposes (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null references public.churches(id) on delete restrict,
  name        text not null check (length(name) between 1 and 100),
  description text check (length(description) <= 2000),
  created_at  timestamptz not null default now(),
  unique (church_id, id),
  unique (church_id, name)
);

-- Units ("G-Squad Units" form): objectives and scope, the purpose they sit under.
create table public.units (
  id                    uuid primary key default gen_random_uuid(),
  church_id             uuid not null references public.churches(id) on delete restrict,
  purpose_id            uuid,
  name                  text not null check (length(name) between 1 and 100),
  objectives            text check (length(objectives) <= 4000),
  scope                 text check (length(scope) <= 4000),
  target_headcount      smallint check (target_headcount >= 0),
  regular_monthly_need  smallint not null default 0 check (regular_monthly_need >= 0),  -- slots the unit needs every month (capacity formula)
  is_active             boolean not null default true,
  created_at            timestamptz not null default now(),
  unique (church_id, id),
  unique (church_id, name),
  foreign key (church_id, purpose_id) references public.purposes(church_id, id) on delete restrict
);

-- Role assignments. A user can hold several roles and gets the widest access of them,
-- except for pastoral notes. Purpose Heads are scoped to a purpose, Unit Leads to a unit.
create table public.role_assignments (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null references public.churches(id) on delete restrict,
  user_id     uuid not null,
  role        public.app_role not null,
  purpose_id  uuid,
  unit_id     uuid,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  foreign key (church_id, user_id)    references public.app_users(church_id, id) on delete cascade,
  foreign key (church_id, purpose_id) references public.purposes(church_id, id) on delete cascade,
  foreign key (church_id, unit_id)    references public.units(church_id, id) on delete cascade,
  -- Scoped roles must carry their scope; unscoped roles must not.
  constraint role_scope_ok check (
    (role = 'purpose_head' and purpose_id is not null and unit_id is null) or
    (role = 'unit_lead'    and unit_id is not null and purpose_id is null) or
    (role not in ('purpose_head','unit_lead') and purpose_id is null and unit_id is null)
  )
);
-- One active copy of each (user, role, scope).
create unique index role_assignments_one_active
  on public.role_assignments (user_id, role, coalesce(purpose_id, '00000000-0000-0000-0000-000000000000'), coalesce(unit_id, '00000000-0000-0000-0000-000000000000'))
  where is_active;
create index role_assignments_user on public.role_assignments (user_id) where is_active;

-- -------------------------------------------------------------------------------------
-- Audit log: append-only. Rows are written only by SECURITY DEFINER functions and triggers;
-- no API role has insert, update or delete rights. Kept 2 years (see migration 9).
-- -------------------------------------------------------------------------------------

create table public.audit_log (
  id          bigint generated always as identity primary key,
  church_id   uuid references public.churches(id) on delete cascade,
  actor_id    uuid,                         -- auth user id; null for system jobs
  action      text not null,                -- e.g. 'insert', 'update', 'view_pastoral', 'export', 'override_limit'
  table_name  text,
  record_id   uuid,
  detail      jsonb not null default '{}'::jsonb,   -- never personal free text; ids and changed column names only
  at          timestamptz not null default now()
);
create index audit_log_church_at on public.audit_log (church_id, at desc);

-- -------------------------------------------------------------------------------------
-- Helper functions for RLS. SECURITY DEFINER so they can read app_users / role_assignments
-- without triggering those tables' own policies (avoids recursion). search_path is pinned
-- to empty and every name is schema-qualified, so a caller cannot hijack them.
-- -------------------------------------------------------------------------------------

-- The signed-in user's church, or null if they have no active account.
create or replace function app.current_church_id() returns uuid
language sql stable security definer set search_path = ''
as $$
  select u.church_id
  from public.app_users u
  where u.id = (select auth.uid()) and u.is_active
$$;

-- Does the signed-in user hold this role (any scope)?
create or replace function app.has_role(r public.app_role) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.role_assignments ra
    join public.app_users u on u.id = ra.user_id and u.is_active
    where ra.user_id = (select auth.uid()) and ra.role = r and ra.is_active
  )
$$;

-- Does the signed-in user hold any of these roles?
create or replace function app.has_any_role(rs public.app_role[]) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.role_assignments ra
    join public.app_users u on u.id = ra.user_id and u.is_active
    where ra.user_id = (select auth.uid()) and ra.role = any (rs) and ra.is_active
  )
$$;

-- Is the signed-in user the Unit Lead of this unit?
create or replace function app.is_unit_lead_of(p_unit uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.role_assignments ra
    join public.app_users u on u.id = ra.user_id and u.is_active
    where ra.user_id = (select auth.uid()) and ra.role = 'unit_lead'
      and ra.unit_id = p_unit and ra.is_active
  )
$$;

-- Is the signed-in user the Purpose Head of the purpose this unit sits under?
create or replace function app.is_purpose_head_of_unit(p_unit uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.role_assignments ra
    join public.app_users u on u.id = ra.user_id and u.is_active
    join public.units un on un.purpose_id = ra.purpose_id
    where ra.user_id = (select auth.uid()) and ra.role = 'purpose_head'
      and un.id = p_unit and ra.is_active
  )
$$;

-- Church-wide leadership roles that may see every volunteer's contact and member details.
create or replace function app.is_church_wide_reader() returns boolean
language sql stable security definer set search_path = ''
as $$
  select app.has_any_role(array['resident_pastor','gsquad_coordinator','operations_lead',
                                'pastoral_lead','teci_coordinator']::public.app_role[])
$$;

-- Writes an audit row. Called from triggers and RPC functions only.
create or replace function app.audit(p_action text, p_table text, p_record uuid, p_detail jsonb default '{}'::jsonb)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.audit_log (church_id, actor_id, action, table_name, record_id, detail)
  values (app.current_church_id(), (select auth.uid()), p_action, p_table, p_record, coalesce(p_detail, '{}'::jsonb))
$$;

-- Keeps updated_at current on any table that has the column.
create or replace function app.touch_updated_at() returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger church_settings_touch before update on public.church_settings
  for each row execute function app.touch_updated_at();

-- Generic audit trigger for sensitive configuration tables: logs who changed what, with
-- the names of changed columns only (never the values, which may be personal).
create or replace function app.audit_row_change() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_changed text[];
  v_id uuid;
begin
  -- SECURITY REVIEW FIX F04: for special category tables even the changed column names are
  -- personal (e.g. "water_baptism_date" changing tells the reader the person was baptised),
  -- so only the fact of the change is logged for them.
  if tg_op = 'UPDATE' and tg_table_name not in ('person_faith', 'pastoral_notes', 'one_to_ones') then
    select array_agg(n.key order by n.key) into v_changed
    from jsonb_each(to_jsonb(new)) n
    join jsonb_each(to_jsonb(old)) o using (key)
    where n.value is distinct from o.value;
  end if;
  -- Tables keyed by church_id (settings) have no "id" column; fall back to church_id.
  v_id := coalesce((to_jsonb(coalesce(new, old)) ->> 'id')::uuid,
                   (to_jsonb(coalesce(new, old)) ->> 'church_id')::uuid);
  insert into public.audit_log (church_id, actor_id, action, table_name, record_id, detail)
  values ((to_jsonb(coalesce(new, old)) ->> 'church_id')::uuid, (select auth.uid()),
          lower(tg_op), tg_table_name, v_id,
          case when v_changed is null then '{}'::jsonb else jsonb_build_object('columns', v_changed) end);
  return coalesce(new, old);
end $$;

create trigger role_assignments_audit after insert or update or delete on public.role_assignments
  for each row execute function app.audit_row_change();
create trigger church_settings_audit after insert or update or delete on public.church_settings
  for each row execute function app.audit_row_change();
create trigger app_users_audit after insert or update or delete on public.app_users
  for each row execute function app.audit_row_change();

-- Lock the helper functions down: callable by the API roles only through policies.
revoke all on all functions in schema app from public;
grant execute on all functions in schema app to authenticated, service_role;
