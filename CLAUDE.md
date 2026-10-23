# Working on the G-Squad Planner

Guidance for anyone (people or AI assistants) changing this codebase. See README.md for set-up.

## Rules that are not negotiable

- **Access lives in the database.** Every table has row-level security; screens never decide who may see data. A new table ships with its RLS policies and a check in `supabase/tests/10_access_and_rules.sql`.
- **Faith fields and pastoral notes** are read and written only through the logged functions (`get_person_faith`, `set_person_faith`, `get_pastoral_notes`). Never add direct table access.
- **Database changes are new migration files only.** Never edit an applied migration; add a new one. Regenerate types with `npm run db:types` and commit them.
- **Only the publishable key in the browser.** No secret or service-role key in any `VITE_*` variable or in `src/`. Server-side work goes in Supabase Edge Functions.
- **ASHLIE values are recognised, never scored** (business rule R20). No ratings, rankings or league tables of values.
- **Sample data only** until the DPIA is signed.

## Conventions

- Inline comments explain *why*, at the top of each file and above anything non-obvious.
- UI comes from the TEC Design System (`const { Button, Card } = TEC;`). New colours, spacing or type go into `tokens.json`, not raw values in CSS.
- Server data goes through TanStack Query; the Supabase client is `src/lib/supabase.ts`.
- Every slice gets an independent security review; findings and fixes are added to `SECURITY_LOG.md`.
- `npm run check` and `npm run db:test` pass before a pull request is opened.
