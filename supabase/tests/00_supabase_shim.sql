-- =====================================================================================
-- LOCAL TEST SHIM ONLY. Do NOT run this on a real Supabase project.
-- Recreates the small parts of Supabase the migrations rely on, so they can be tested on
-- plain Postgres: the anon / authenticated / service_role roles, the auth schema, the
-- auth.users table and auth.uid(), which reads the signed-in user's id from the JWT claims.
-- =====================================================================================

-- API roles. service_role bypasses row-level security, exactly as on Supabase.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

create schema if not exists auth;

-- Minimal auth.users: Supabase Auth owns this table on a real project.
create table if not exists auth.users (
  id    uuid primary key,
  email text
);

-- Same logic as Supabase's auth.uid(): the "sub" claim of the request's JWT.
create or replace function auth.uid() returns uuid
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- Supabase grants table privileges on public to the API roles by default; RLS then decides
-- which rows they see. Mirror those defaults so the tests exercise RLS, not missing grants.
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
