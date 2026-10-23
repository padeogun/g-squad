-- =====================================================================================
-- G-Squad Planner: 2. Reference forms
-- The lists other forms pick from, so names and stages are set once and never retyped:
-- Roles, TECi Stages, Leadership Stages, Greatness Community Types, Greatness Communities,
-- Projects and Events Types, and the reusable blocks used on the Sunday Service Grid.
-- (G-Squad Units and purposes are in migration 1, because role assignments point at them.)
-- =====================================================================================

-- Roles form: every church role G-Squad members fill.
create table public.church_roles (
  id            uuid primary key default gen_random_uuid(),
  church_id     uuid not null references public.churches(id) on delete restrict,
  unit_id       uuid,                                   -- null = a church-wide role
  name          text not null check (length(name) between 1 and 100),
  description   text check (length(description) <= 2000),
  is_rota_role  boolean not null default false,         -- appears on Sunday rotas
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (church_id, id),
  foreign key (church_id, unit_id) references public.units(church_id, id) on delete restrict
);
-- Role names are unique within a unit (or among church-wide roles).
create unique index church_roles_name_unique
  on public.church_roles (church_id, coalesce(unit_id, '00000000-0000-0000-0000-000000000000'), lower(name));

-- TECi Stages form: the 5 stages of TEC's training and leadership development programme.
-- Managed by the TECi Coordinator.
create table public.teci_stages (
  id                   uuid primary key default gen_random_uuid(),
  church_id            uuid not null references public.churches(id) on delete restrict,
  stage_no             smallint not null check (stage_no between 1 and 5),
  name                 text not null check (length(name) between 1 and 100),
  description          text check (length(description) <= 2000),
  completion_criteria  text check (length(completion_criteria) <= 2000),
  created_at           timestamptz not null default now(),
  unique (church_id, id),
  unique (church_id, stage_no)
);

-- Leadership Stages definition form (replaces the hard-coded Spotted / Developing / Ready / Leading).
create table public.leadership_stages (
  id                uuid primary key default gen_random_uuid(),
  church_id         uuid not null references public.churches(id) on delete restrict,
  sort_order        smallint not null check (sort_order between 1 and 50),
  name              text not null check (length(name) between 1 and 100),
  description       text check (length(description) <= 2000),
  advance_criteria  text check (length(advance_criteria) <= 2000),   -- what moves a person to the next stage
  created_at        timestamptz not null default now(),
  unique (church_id, id),
  unique (church_id, sort_order),
  unique (church_id, name)
);

-- Greatness Community Types: interest-based groups or location-based groups.
create type public.community_category as enum ('interest', 'location');

create table public.community_types (
  id                uuid primary key default gen_random_uuid(),
  church_id         uuid not null references public.churches(id) on delete restrict,
  name              text not null check (length(name) between 1 and 100),
  category          public.community_category not null,
  objective         text check (length(objective) <= 2000),
  meeting_schedule  text check (length(meeting_schedule) <= 500),   -- e.g. "First Saturday of each month, 11:00"
  created_at        timestamptz not null default now(),
  unique (church_id, id),
  unique (church_id, name)
);

-- Greatness Communities: name and type. Support roles and the members filling them are in
-- migration 3 (community_support_roles), because they reference people.
create table public.greatness_communities (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null references public.churches(id) on delete restrict,
  type_id     uuid not null,
  name        text not null check (length(name) between 1 and 100),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (church_id, id),
  unique (church_id, name),
  foreign key (church_id, type_id) references public.community_types(church_id, id) on delete restrict
);

-- Projects and Events Types. default_level and newsletter_tag ("MEETING", "PRAYER") are
-- used by the project page and the newsletter's Upcoming Gatherings.
create type public.project_level as enum ('unit', 'church');

create table public.project_types (
  id              uuid primary key default gen_random_uuid(),
  church_id       uuid not null references public.churches(id) on delete restrict,
  name            text not null check (length(name) between 1 and 100),
  default_level   public.project_level not null default 'church',
  newsletter_tag  text check (length(newsletter_tag) <= 30),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (church_id, id),
  unique (church_id, name)
);

-- Reusable blocks for the Sunday Service Grid (After Service Notes, Guest Welcome Script).
create table public.reusable_blocks (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null references public.churches(id) on delete restrict,
  name        text not null check (length(name) between 1 and 100),
  body        text not null check (length(body) <= 20000),
  updated_at  timestamptz not null default now(),
  unique (church_id, id),
  unique (church_id, name)
);
create trigger reusable_blocks_touch before update on public.reusable_blocks
  for each row execute function app.touch_updated_at();

-- Changes to the reference forms are audited (who changed which list, and when).
create trigger church_roles_audit after insert or update or delete on public.church_roles
  for each row execute function app.audit_row_change();
create trigger teci_stages_audit after insert or update or delete on public.teci_stages
  for each row execute function app.audit_row_change();
create trigger leadership_stages_audit after insert or update or delete on public.leadership_stages
  for each row execute function app.audit_row_change();
create trigger units_audit after insert or update or delete on public.units
  for each row execute function app.audit_row_change();
