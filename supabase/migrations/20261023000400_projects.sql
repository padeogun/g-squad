-- =====================================================================================
-- G-Squad Planner: 4. Projects
-- Everything that needs volunteers: Sunday services (rotas are repeating projects), events
-- and longer projects. Each has team demand, assignments, an input tracker, and for events
-- the High-level Event Planning form. Sunday services also have a Service Grid.
-- =====================================================================================

create type public.project_status as enum ('draft', 'submitted', 'approved', 'in_progress', 'done', 'cancelled');
create type public.project_origin as enum ('tec', 'network', 'global');   -- network/global = for information only
create type public.shortfall_action as enum ('move', 'scale_down', 'borrow', 'recruit');  -- R6

create table public.projects (
  id                     uuid primary key default gen_random_uuid(),
  church_id              uuid not null,
  site_id                uuid,
  type_id                uuid,
  level                  public.project_level not null,
  unit_id                uuid,                                -- the unit, for unit-level projects
  name                   text not null check (length(name) between 1 and 200),
  description            text check (length(description) <= 4000),
  starts_at              timestamptz not null,
  ends_at                timestamptz not null,
  status                 public.project_status not null default 'draft',
  is_sunday_service      boolean not null default false,
  origin                 public.project_origin not null default 'tec',
  origin_note            text check (length(origin_note) <= 500),
  owner_user_id          uuid not null default auth.uid(),
  shortfall_action       public.shortfall_action,             -- recorded when approving despite a shortfall
  shortfall_action_note  text check (length(shortfall_action_note) <= 1000),
  approved_by            uuid,
  approved_at            timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (church_id, id),
  foreign key (church_id, site_id)       references public.sites(church_id, id) on delete restrict,
  foreign key (church_id, type_id)       references public.project_types(church_id, id) on delete restrict,
  foreign key (church_id, unit_id)       references public.units(church_id, id) on delete restrict,
  foreign key (church_id, owner_user_id) references public.app_users(church_id, id) on delete restrict,
  check (ends_at >= starts_at),
  -- A unit project names its unit; a church project does not.
  check ((level = 'unit') = (unit_id is not null)),
  -- Sunday services are church-level.
  check (not is_sunday_service or level = 'church')
);
create index projects_church_starts on public.projects (church_id, starts_at);
create trigger projects_touch before update on public.projects
  for each row execute function app.touch_updated_at();

-- Team demand: how many slots a project needs from a unit, optionally for one role and date.
create table public.team_demand (
  id              uuid primary key default gen_random_uuid(),
  church_id       uuid not null,
  project_id      uuid not null,
  unit_id         uuid not null,
  church_role_id  uuid,
  on_date         date not null,
  slots_needed    smallint not null check (slots_needed between 1 and 500),
  created_at      timestamptz not null default now(),
  foreign key (church_id, project_id)     references public.projects(church_id, id) on delete cascade,
  foreign key (church_id, unit_id)        references public.units(church_id, id) on delete restrict,
  foreign key (church_id, church_role_id) references public.church_roles(church_id, id) on delete restrict
);
create index team_demand_unit_date on public.team_demand (unit_id, on_date);

-- Assignments: one person serving one slot. Status is recorded after the day.
create type public.assignment_status as enum ('planned', 'served', 'no_show', 'cancelled');

create table public.assignments (
  id               uuid primary key default gen_random_uuid(),
  church_id        uuid not null,
  project_id       uuid not null,
  person_id        uuid not null,
  unit_id          uuid not null,
  church_role_id   uuid,
  serve_date       date not null,
  status           public.assignment_status not null default 'planned',
  override_reason  text check (length(override_reason) <= 500),   -- R2: required to go over the limit
  assigned_by      uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  foreign key (church_id, project_id)     references public.projects(church_id, id) on delete cascade,
  foreign key (church_id, person_id)      references public.people(church_id, id) on delete cascade,
  foreign key (church_id, unit_id)        references public.units(church_id, id) on delete restrict,
  foreign key (church_id, church_role_id) references public.church_roles(church_id, id) on delete restrict
);
-- The same person cannot hold two live slots in the same project on the same day for the same role.
create unique index assignments_no_double on public.assignments
  (project_id, person_id, serve_date, coalesce(church_role_id, '00000000-0000-0000-0000-000000000000'))
  where status in ('planned', 'served');
create index assignments_person_date on public.assignments (person_id, serve_date) where status in ('planned', 'served');
create trigger assignments_touch before update on public.assignments
  for each row execute function app.touch_updated_at();

-- Input tracker (R9). Also carries newsletter team updates (unit_id + body).
create type public.input_status as enum ('requested', 'received');   -- "Overdue" is derived: see v_project_inputs

create table public.project_inputs (
  id                      uuid primary key default gen_random_uuid(),
  church_id               uuid not null,
  project_id              uuid not null,
  title                   text not null check (length(title) between 1 and 200),
  requested_from_user_id  uuid not null,
  unit_id                 uuid,                  -- set for unit volunteer plans and newsletter team updates
  due_on                  date not null,
  is_required             boolean not null default true,
  status                  public.input_status not null default 'requested',
  body                    text check (length(body) <= 4000),       -- the input itself, e.g. a team update
  -- SECURITY REVIEW FIX F17: https only, no spaces or control characters, at most 2000 characters.
  link_url                text check (link_url is null or (length(link_url) <= 2000 and link_url ~ '^https://[^\s]+$')),  -- e.g. a budget sheet
  received_at             timestamptz,
  requested_by            uuid default auth.uid(),
  created_at              timestamptz not null default now(),
  unique (church_id, id),
  foreign key (church_id, project_id)             references public.projects(church_id, id) on delete cascade,
  foreign key (church_id, requested_from_user_id) references public.app_users(church_id, id) on delete restrict,
  foreign key (church_id, unit_id)                references public.units(church_id, id) on delete restrict,
  check ((status = 'received') = (received_at is not null))
);
create index project_inputs_open on public.project_inputs (requested_from_user_id, due_on) where status = 'requested';

-- -------------------------------------------------------------------------------------
-- High-level Event Planning form: one row per event project, sections 1 to 12, following
-- TEC's TECM High-level Event Planning workbook.
-- -------------------------------------------------------------------------------------

create type public.event_size        as enum ('small', 'medium', 'large');      -- under 100 / 100-200 / 200+
create type public.event_complexity  as enum ('low', 'moderate', 'high');
create type public.calendar_check    as enum ('not_checked', 'confirmed', 'conflict');
create type public.venue_kind        as enum ('internal', 'external');
create type public.budget_status     as enum ('not_needed', 'pending', 'approved', 'rejected');
create type public.funding_kind      as enum ('free', 'ticketed', 'ministry_budget');
create type public.asset_status      as enum ('not_started', 'in_progress', 'done');

create table public.event_plans (
  project_id              uuid primary key,
  church_id               uuid not null,
  -- 1. Event profile
  size                    public.event_size not null,
  complexity              public.event_complexity not null,
  -- 2. Initiation
  purpose_why             text check (length(purpose_why) <= 2000),
  spiritual_outcome       text check (length(spiritual_outcome) <= 2000),
  alignment               text check (length(alignment) <= 2000),
  target_audience         text check (length(target_audience) <= 1000),
  -- 3. Leadership and ownership (event owner = projects.owner_user_id)
  has_planning_committee  boolean not null default false,
  committee_members       text check (length(committee_members) <= 1000),
  -- 4. Feasibility
  calendar_check          public.calendar_check not null default 'not_checked',
  venue_kind              public.venue_kind,
  venue_name              text check (length(venue_name) <= 200),
  -- 5. Budget (approval by Finance or the Resident Pastor only; enforced in migration 8)
  budget_estimate_gbp     numeric(10,2) check (budget_estimate_gbp >= 0),   -- past events plus 10% contingency
  budget_status           public.budget_status not null default 'pending',
  budget_decided_by       uuid,
  budget_decided_at       timestamptz,
  funding                 public.funding_kind,
  money_handling_plan     text check (length(money_handling_plan) <= 2000),
  -- 6. Resources and logistics
  required_resources      text check (length(required_resources) <= 2000),
  resource_gaps           text check (length(resource_gaps) <= 2000),
  -- 7. Event design
  setup_minutes           smallint check (setup_minutes >= 0),
  packdown_minutes        smallint check (packdown_minutes >= 0),
  main_attraction         text check (length(main_attraction) <= 1000),
  engagement              text check (length(engagement) <= 1000),
  side_activities         text check (length(side_activities) <= 1000),
  -- 8. Event operations
  media_plan              text check (length(media_plan) <= 2000),
  logistics_plan          text check (length(logistics_plan) <= 2000),
  childcare_needed        boolean not null default false,
  risk_assessment_needed  boolean not null default false,
  safeguarding_notes      text check (length(safeguarding_notes) <= 2000),
  -- 9. Communications
  comms_plan_done         boolean not null default false,
  comms_strategy          text check (length(comms_strategy) <= 2000),
  assets_status           public.asset_status not null default 'not_started',
  signup_method           text check (length(signup_method) <= 500),
  followup_plan           text check (length(followup_plan) <= 1000),
  -- 10. Experience
  guest_journey           text check (length(guest_journey) <= 2000),
  hospitality             text check (length(hospitality) <= 2000),
  decor                   text check (length(decor) <= 1000),
  -- 11. Execution
  on_day_lead_person_id   uuid,
  qc_checklist            text check (length(qc_checklist) <= 2000),
  -- 12. Review
  review_impact           text check (length(review_impact) <= 4000),
  review_accounts_done    boolean not null default false,
  review_operational      text check (length(review_operational) <= 4000),   -- stop / start / continue
  review_feedback         text check (length(review_feedback) <= 4000),
  review_completed_at     timestamptz,
  updated_at              timestamptz not null default now(),
  foreign key (church_id, project_id)            references public.projects(church_id, id) on delete cascade,
  foreign key (church_id, on_day_lead_person_id) references public.people(church_id, id) on delete set null (on_day_lead_person_id),
  -- A ticketed event needs a money-handling plan.
  check (funding is distinct from 'ticketed' or money_handling_plan is not null)
);
create trigger event_plans_touch before update on public.event_plans
  for each row execute function app.touch_updated_at();

-- Action points against any section of the event plan, each with an owner.
create type public.action_status as enum ('open', 'done');

create table public.event_plan_actions (
  id             uuid primary key default gen_random_uuid(),
  church_id      uuid not null,
  project_id     uuid not null,
  section_no     smallint not null check (section_no between 1 and 12),
  description    text not null check (length(description) between 1 and 1000),
  owner_user_id  uuid,
  due_on         date,
  status         public.action_status not null default 'open',
  created_at     timestamptz not null default now(),
  foreign key (church_id, project_id)    references public.projects(church_id, id) on delete cascade,
  foreign key (church_id, owner_user_id) references public.app_users(church_id, id) on delete set null (owner_user_id)
);

-- -------------------------------------------------------------------------------------
-- Sunday Service Grid (R11). One grid per Sunday service project. Any change after it is
-- finalised raises the version number and needs the Resident Pastor's approval again.
-- -------------------------------------------------------------------------------------

create type public.grid_status as enum ('draft', 'finalised', 'approved');

create table public.service_grids (
  id            uuid primary key default gen_random_uuid(),
  church_id     uuid not null,
  project_id    uuid not null unique,
  service_date  date not null,
  theme         text check (length(theme) <= 200),
  status        public.grid_status not null default 'draft',
  version       integer not null default 1 check (version >= 1),
  finalised_at  timestamptz,
  approved_by   uuid,
  approved_at   timestamptz,
  updated_at    timestamptz not null default now(),
  unique (church_id, id),
  foreign key (church_id, project_id) references public.projects(church_id, id) on delete cascade,
  check (extract(isodow from service_date) = 7)   -- Sundays only
);

-- Segments in order. Led by a unit (pulls in that unit's rota), a named person (an officiating
-- leader), or free text for a guest. End time = start + duration, worked out in v_service_segments.
create table public.service_segments (
  id                uuid primary key default gen_random_uuid(),
  church_id         uuid not null,
  grid_id           uuid not null,
  position          smallint not null check (position between 1 and 200),
  title             text not null check (length(title) between 1 and 200),
  -- SECURITY REVIEW FIX F17: bounded (at most 20 points, 4000 characters in all).
  sub_points        text[] not null default '{}'
                    check (cardinality(sub_points) <= 20 and length(array_to_string(sub_points, '|')) <= 4000),
  starts_at         time not null,
  duration_minutes  smallint not null check (duration_minutes between 1 and 600),
  led_by_unit_id    uuid,
  led_by_person_id  uuid,
  led_by_text       text check (length(led_by_text) <= 200),
  foreign key (church_id, grid_id)          references public.service_grids(church_id, id) on delete cascade,
  foreign key (church_id, led_by_unit_id)   references public.units(church_id, id) on delete restrict,
  foreign key (church_id, led_by_person_id) references public.people(church_id, id) on delete set null (led_by_person_id),
  unique (grid_id, position) deferrable initially deferred,   -- lets the app reorder segments in one transaction
  check (num_nonnulls(led_by_unit_id, led_by_person_id, led_by_text) >= 1)
);

-- Reusable blocks printed at the end of a grid's PDF, in order.
create table public.service_grid_blocks (
  church_id   uuid not null,
  grid_id     uuid not null,
  block_id    uuid not null,
  position    smallint not null check (position between 1 and 50),
  primary key (grid_id, block_id),
  foreign key (church_id, grid_id)  references public.service_grids(church_id, id) on delete cascade,
  foreign key (church_id, block_id) references public.reusable_blocks(church_id, id) on delete restrict
);

-- -------------------------------------------------------------------------------------
-- Project-scope helper functions
-- -------------------------------------------------------------------------------------

-- Is the signed-in user the owner of this project?
create or replace function app.owns_project(p_project uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.projects p
                 where p.id = p_project and p.owner_user_id = (select auth.uid()))
$$;

-- Can the signed-in user manage this project's plan, demand and inputs?
create or replace function app.can_manage_project(p_project uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select app.owns_project(p_project) or app.has_role('operations_lead')
$$;

-- Project owners also see contact details of volunteers assigned to their projects.
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
        or exists (
          select 1 from public.assignments a
          join public.projects pr on pr.id = a.project_id
          where a.person_id = p.id and a.status in ('planned', 'served')
            and pr.owner_user_id = (select auth.uid())
        )
      )
  )
$$;

revoke all on all functions in schema app from public;
grant execute on all functions in schema app to authenticated, service_role;
