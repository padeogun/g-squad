-- =====================================================================================
-- G-Squad Planner: 5. Monthly G-Squad report and The Greatness Brief newsletter
-- =====================================================================================

-- Monthly G-Squad report (R13). Engagement, new members, one-to-one completion and people
-- baptised are worked out by public.monthly_report_figures(); the Coordinator adds the number
-- of Water Baptism services held and commentary, then submits to the Resident Pastor.
create type public.report_status as enum ('draft', 'submitted');

create table public.monthly_reports (
  id                       uuid primary key default gen_random_uuid(),
  church_id                uuid not null references public.churches(id) on delete restrict,
  report_month             date not null check (extract(day from report_month) = 1),
  water_baptism_services   smallint not null default 0 check (water_baptism_services >= 0),
  commentary               text check (length(commentary) <= 8000),
  status                   public.report_status not null default 'draft',
  submitted_by             uuid,
  submitted_at             timestamptz,
  updated_at               timestamptz not null default now(),
  unique (church_id, report_month),
  check ((status = 'submitted') = (submitted_at is not null))
);
create trigger monthly_reports_touch before update on public.monthly_reports
  for each row execute function app.touch_updated_at();

-- -------------------------------------------------------------------------------------
-- The Greatness Brief. Each issue is linked to a church project so that team updates are
-- requested and tracked through the input tracker (project_inputs, due by the 25th).
-- Approval order (R17): G-Squad Coordinator, then Resident Pastor. Enforced in migration 8.
-- -------------------------------------------------------------------------------------

create type public.issue_status as enum ('draft', 'awaiting_coordinator', 'awaiting_pastor', 'approved', 'sent');

create table public.newsletter_issues (
  id                        uuid primary key default gen_random_uuid(),
  church_id                 uuid not null,
  project_id                uuid not null unique,          -- the issue's project, for the input tracker
  issue_month               date not null check (extract(day from issue_month) = 1),
  headline                  text check (length(headline) <= 200),
  standfirst                text check (length(standfirst) <= 500),
  pastor_word               text check (length(pastor_word) <= 2000),
  pastor_name               text check (length(pastor_name) <= 100),
  status                    public.issue_status not null default 'draft',
  coordinator_approved_by   uuid,
  coordinator_approved_at   timestamptz,
  pastor_approved_by        uuid,
  pastor_approved_at        timestamptz,
  send_on                   date,
  sent_at                   timestamptz,
  updated_at                timestamptz not null default now(),
  unique (church_id, id),
  unique (church_id, issue_month),
  foreign key (church_id, project_id) references public.projects(church_id, id) on delete restrict
);

-- Typed items: Wins and Testimonies, and any other notices. A named personal item needs the
-- person's agreement ticked before the issue can be approved (R18).
create type public.newsletter_item_kind as enum ('win', 'notice');

create table public.newsletter_items (
  id                 uuid primary key default gen_random_uuid(),
  church_id          uuid not null,
  issue_id           uuid not null,
  kind               public.newsletter_item_kind not null,
  position           smallint not null default 1 check (position between 1 and 100),
  title              text check (length(title) <= 200),
  body               text not null check (length(body) between 1 and 2000),
  names_a_person     boolean not null default false,
  agreement_ticked   boolean not null default false,
  source_project_id  uuid,                                 -- set when offered from an event review
  created_by         uuid default auth.uid(),
  created_at         timestamptz not null default now(),
  foreign key (church_id, issue_id)          references public.newsletter_issues(church_id, id) on delete cascade,
  foreign key (church_id, source_project_id) references public.projects(church_id, id) on delete set null (source_project_id)
);

-- RSVPs and reactions are recorded by the email-link Edge Function (service role), never by
-- the browser directly. Editors see counts only, through newsletter_issue_stats().
create table public.newsletter_rsvps (
  church_id   uuid not null,
  project_id  uuid not null,
  person_id   uuid not null,
  issue_id    uuid,
  created_at  timestamptz not null default now(),
  primary key (project_id, person_id),
  foreign key (church_id, project_id) references public.projects(church_id, id) on delete cascade,
  foreign key (church_id, person_id)  references public.people(church_id, id) on delete cascade,
  foreign key (church_id, issue_id)   references public.newsletter_issues(church_id, id) on delete set null (issue_id)
);

create type public.reaction_kind as enum ('heart', 'pray', 'fire', 'clap');

create table public.newsletter_reactions (
  church_id   uuid not null,
  issue_id    uuid not null,
  person_id   uuid not null,
  reaction    public.reaction_kind not null,
  created_at  timestamptz not null default now(),
  primary key (issue_id, person_id, reaction),
  foreign key (church_id, issue_id)  references public.newsletter_issues(church_id, id) on delete cascade,
  foreign key (church_id, person_id) references public.people(church_id, id) on delete cascade
);

-- Personal email links (RSVP, reaction, unsubscribe). Only a SHA-256 hash of each token is
-- stored, so a database leak does not expose working links. Each link has one purpose and an
-- expiry. Service role only: no API role can read or write this table.
create type public.link_purpose as enum ('rsvp', 'react', 'unsubscribe');

create table public.email_link_tokens (
  token_hash      bytea primary key check (length(token_hash) = 32),
  church_id       uuid not null,
  person_id       uuid not null,
  issue_id        uuid not null,
  purpose         public.link_purpose not null,
  target_project  uuid,                         -- for RSVP links
  reaction        public.reaction_kind,         -- for reaction links
  expires_at      timestamptz not null,
  used_at         timestamptz,
  foreign key (church_id, person_id)      references public.people(church_id, id) on delete cascade,
  foreign key (church_id, issue_id)       references public.newsletter_issues(church_id, id) on delete cascade,
  foreign key (church_id, target_project) references public.projects(church_id, id) on delete cascade,
  check ((purpose = 'rsvp') = (target_project is not null)),
  check ((purpose = 'react') = (reaction is not null))
);
create index email_link_tokens_expiry on public.email_link_tokens (expires_at);
