-- =====================================================================================
-- G-Squad Planner: 21. Deputy Team Lead access role (decision of 23 Oct 2026)
-- Only adds the enum value. Postgres cannot use a new enum value in the same transaction
-- that adds it, and each migration runs in one transaction, so the rules that use it are
-- in migration 22.
-- =====================================================================================

-- Deputy Team Lead: scoped to one unit; view-only access to what the Team Lead sees, except
-- one-to-ones. ("unit_lead" is the Team Lead.)
alter type public.app_role add value if not exists 'deputy_unit_lead' after 'unit_lead';
