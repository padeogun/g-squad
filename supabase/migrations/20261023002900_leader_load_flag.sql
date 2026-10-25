-- =====================================================================================
-- G-Squad Planner: 29. A check-in flag for leaders carrying too much (decision of 25 Oct 2026)
-- Only adds the enum value. Postgres cannot use a new enum value in the same transaction that
-- adds it, and each migration runs in one transaction, so the rules that use it are in
-- migration 30 (as migrations 21 and 22 did).
-- =====================================================================================
alter type public.flag_source add value if not exists 'leader_load';
