# G-Squad Planner

Volunteer and event planning for G-Squad at The Elevation Church (TEC) Manchester: people and teams, Sunday service grids and rotas, projects and events, one-to-ones guided by the ASHLIE core values, and The Greatness Brief newsletter.

- **Build plan:** [G-Squad Planner Build Plan](https://claude.ai/artifact/KLDMGpymwH1ripp7qpL8SQ)
- **Database design:** [docs/database.md](docs/database.md)
- **Security reviews and fixes:** [SECURITY_LOG.md](SECURITY_LOG.md)

## How it fits together

| Part | Technology | Where |
| --- | --- | --- |
| Screens | React + TypeScript, built with Vite | `src/` |
| Look and feel | TEC Design System (tokens, components, self-hosted Lexend and Inter) | `src/design-system/` |
| Data, sign-in, access rules | Supabase: Postgres with row-level security, Auth (invite-only email link) | `supabase/` |
| Hosting | Netlify, with a preview link for every pull request | `netlify.toml` |
| Checks | GitHub Actions: lint, unit tests, build, dependency audit, 219 database checks | `.github/workflows/` |

Access is enforced **in the database** (row-level security), not by hiding screens. The browser only ever holds the publishable key.

## Working on it

You need Node 22 and, for the database checks, a local Postgres (16 or 17).

```bash
npm ci
cp .env.example .env.local          # add the publishable key
npm run dev                         # http://localhost:5173
```

| Command | What it does |
| --- | --- |
| `npm run check` | Lint, unit tests and production build (what CI's app job runs) |
| `npm run db:test` | Rebuilds a throwaway local database from the migrations and runs the access and rules checks |
| `npm run db:types` | Regenerates `src/lib/database.types.ts` after a migration change |
| `npm run tokens` | Regenerates `src/design-system/tokens.css` from `tokens.json` |

`db:test` and `db:types` read `DB_ADMIN_URL` (default `postgresql://postgres:postgres@localhost:5432/postgres`). They run only against a local server (`localhost`, `127.0.0.1` or `[::1]`; list any other throwaway host in `DB_TEST_ALLOWED_HOSTS`) and refuse any server that looks like Supabase.

## Making a change

1. Branch from `main`, make the change, open a pull request.
2. CI runs; Netlify posts a preview link on the pull request.
3. A TEC developer reviews the code; the Operations Lead checks the preview.
4. Merge. Netlify publishes the app; new migrations go to Supabase through the **Deploy database** workflow.

Database changes are **always new migration files** in `supabase/migrations/`, never edits in the Supabase dashboard, so every environment matches the history.

## First-time set-up (once)

1. **Supabase:** Authentication > Sign In / Providers > Email: turn **off** "Allow new users to sign up" (the app is invite-only). Set the Site URL to the Netlify address and add it under Redirect URLs.
2. **GitHub:** Settings > Environments > create `supabase-test` with secrets `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD` and variable `SUPABASE_PROJECT_REF`. Then Actions > Deploy database > Run workflow, ticking "include seed".
3. **Netlify:** import this repository; set `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`.
4. **Branch protection:** require the CI checks and one review before merging to `main`.
5. **First Operations Lead:** invite them in Supabase Auth, then add their `app_users` and `role_assignments` rows (see [docs/database.md](docs/database.md)). They invite everyone else.

## Data

Until the data protection impact assessment (DPIA) is signed, the database holds **fictional sample data only**. No real member, faith or pastoral information goes in before then.
