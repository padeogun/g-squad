// -------------------------------------------------------------------------------------
// Checks for guards that live outside the React app (security review 5).
//   J06  scripts/db-test.sh refuses anything that is not a local test database. A fake psql
//        is used throughout, so no connection is ever attempted.
//   J01  no file in src/ passes import.meta.env as a whole object, because Vite would then
//        inline every VITE_* variable from the build environment into the public bundle.
//   K01  (review 21) scripts/sample-data-prepare.sh lets only a plain email, a GitHub user name
//        and a run number into the sample-data SQL, and the workflow never pastes an input
//        into a script with ${{ }}.
// -------------------------------------------------------------------------------------
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// Vitest runs from the repository root (where vite.config.ts is).
const root = process.cwd();

// A fake psql first on PATH: it connects to nothing and just reports that it was reached.
// So these tests never touch a database, local or remote, whatever the guard does.
const fakeBin = mkdtempSync(join(tmpdir(), 'gsquad-fake-psql-'));
writeFileSync(join(fakeBin, 'psql'), '#!/bin/sh\necho FAKE_PSQL_REACHED >&2\nexit 3\n');
chmodSync(join(fakeBin, 'psql'), 0o755);

// Runs db-test.sh with the given admin URL (and extra environment).
function runDbTest(url: string, extraEnv: Record<string, string> = {}) {
  return spawnSync('bash', [join(root, 'scripts/db-test.sh')], {
    env: { PATH: `${fakeBin}:/usr/bin:/bin`, DB_ADMIN_URL: url, ...extraEnv },
    encoding: 'utf8',
  });
}

describe('db-test.sh guard (J06)', () => {
  const refused = [
    'postgresql://postgres:pw@db.abcdefghijklmnopqrst.supabase.co:5432/postgres',
    'postgresql://postgres:pw@DB.ABCDEFGHIJKLMNOPQRST.SUPABASE.CO:5432/postgres',
    'postgresql://postgres.ref:pw@aws-0-eu-west-2.pooler.supabase.com:6543/postgres',
    'postgresql://postgres:pw@203.0.113.10:5432/postgres',
    'postgresql://postgres:pw@localhost:5432/postgres?host=db.example.org',
    'postgresql://postgres:pw@localhost:5432/postgres?hostaddr=203.0.113.10',
    'postgresql://postgres:pw@localhost:5432/postgres?service=prod',
    'postgresql:///postgres',
    'host=localhost dbname=postgres',
  ];

  it.each(refused)('refuses %s', (url) => {
    const r = runDbTest(url);
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/Refusing to run/);
    expect(r.stderr).not.toMatch(/FAKE_PSQL_REACHED/);
  });

  it.each(['localhost:5432', '127.0.0.1', '[::1]:5432', 'LOCALHOST'])('lets %s through to psql', (host) => {
    const r = runDbTest(`postgresql://postgres:postgres@${host}/postgres`);
    expect(r.stderr).toMatch(/FAKE_PSQL_REACHED/);
  });

  it('only allows another host when it is listed explicitly', () => {
    expect(runDbTest('postgresql://p:p@db:5432/postgres').stderr).toMatch(/not a local test server/);
    expect(runDbTest('postgresql://p:p@db:5432/postgres', { DB_TEST_ALLOWED_HOSTS: 'db' }).stderr).toMatch(
      /FAKE_PSQL_REACHED/,
    );
  });
});

// Lists every .ts/.tsx file under a folder.
function sourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return sourceFiles(path);
    return /\.tsx?$/.test(name) ? [path] : [];
  });
}

describe('browser bundle (J01)', () => {
  it('never uses import.meta.env as a whole object', () => {
    const offenders = sourceFiles(join(root, 'src')).filter((file) =>
      // Allowed: import.meta.env.NAME. Anything else (passing or spreading the object) is not.
      /import\.meta\.env(?!\.[A-Z_])/.test(readFileSync(file, 'utf8').replace(/\/\/.*$/gm, '')),
    );
    expect(offenders).toEqual([]);
  });
});

// Builds the sample-data SQL as the workflow would, into a temporary file.
function prepareSample(env: Record<string, string>) {
  const out = join(mkdtempSync(join(tmpdir(), 'gsquad-sample-')), 'run.sql');
  const r = spawnSync('bash', [join(root, 'scripts/sample-data-prepare.sh')], {
    env: { PATH: '/usr/bin:/bin', OUT: out, ...env },
    encoding: 'utf8',
  });
  return { ...r, sql: r.status === 0 ? readFileSync(out, 'utf8') : '' };
}

describe('sample data workflow input (K01)', () => {
  const hostile = [
    "x'); select 1; --@example.org",
    'a@b.org/e; s/.*/drop table people/',
    'a&b@example.org',
    'a\\@example.org',
    'a@example.org\nselect 1',
    '$(id)@example.org',
    '`id`@example.org',
    'a"b@example.org',
    'no-at-sign.example.org',
  ];

  it.each(hostile)('refuses %j', (email) => {
    const r = prepareSample({ ACTION: 'load', TESTER_EMAIL: email });
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/plain email/);
  });

  it('puts a plain address in, and the Resident Pastor role only when asked', () => {
    const plain = prepareSample({ ACTION: 'load', TESTER_EMAIL: ' Ops.Lead+test@example.org\n' });
    expect(plain.status).toBe(0);
    expect(plain.sql).toContain("lower('Ops.Lead+test@example.org')");
    expect(plain.sql).not.toContain('__TEST_EMAIL__');
    expect(plain.sql).toContain("'no' = 'yes'");
    const rp = prepareSample({ ACTION: 'load', TESTER_EMAIL: 'a@example.org', GIVE_RESIDENT_PASTOR: 'true' });
    expect(rp.sql).toContain("'yes' = 'yes'");
  });

  // A sign-in per role (Paul, 25 Oct 2026): a fixed choice of role set reaches the SQL.
  it('gives one role or every role, and Resident Pastor alone only with the box ticked', () => {
    expect(prepareSample({ ACTION: 'load', TESTER_EMAIL: 'a@example.org' }).sql).toContain("when 'all' in");
    expect(prepareSample({ ACTION: 'load', TESTER_EMAIL: 'a@example.org', ROLE_SET: 'team_lead' }).sql).toContain("when 'team_lead' in");
    const noTick = prepareSample({ ACTION: 'load', TESTER_EMAIL: 'a@example.org', ROLE_SET: 'resident_pastor' });
    expect(noTick.status).toBe(1);
    expect(noTick.stderr).toMatch(/Tick the Resident Pastor box/);
    const ticked = prepareSample({ ACTION: 'load', TESTER_EMAIL: 'a@example.org', ROLE_SET: 'resident_pastor', GIVE_RESIDENT_PASTOR: 'true' });
    expect(ticked.sql).toContain("when 'resident_pastor' in");
    expect(prepareSample({ ACTION: 'load', ROLE_SET: "all'; drop table people; --" }).status).toBe(1);
  });

  it('leaves the placeholder (no roles) when the email is blank', () => {
    const r = prepareSample({ ACTION: 'load', TESTER_EMAIL: '' });
    expect(r.status).toBe(0);
    expect(r.sql).toContain("lower('__TEST_EMAIL__')");
  });

  it('logs an unexpected user name or run number as a harmless label', () => {
    const r = prepareSample({ ACTION: 'remove', RUN_BY: "x'; drop table people; --", RUN_ID: '1;2' });
    expect(r.status).toBe(0);
    expect(r.sql).toContain("'github_user', 'unknown'");
    expect(r.sql).toContain("'github_run', '0'");
  });

  it('refuses an unknown action', () => {
    expect(prepareSample({ ACTION: 'drop' }).status).toBe(1);
  });

  // Allowed: an environment variable (NAME: ${{ ... }}) or a step condition (if: ${{ ... }}).
  // Anything else, such as a ${{ }} on any line of a run: script, is refused.
  it('never pastes a ${{ }} value into a script in the database workflows', () => {
    for (const name of ['sample-data.yml', 'deploy-database.yml']) {
      const lines = readFileSync(join(root, '.github/workflows', name), 'utf8').split('\n');
      const offenders = lines.filter(
        (line) => line.includes('${{') && !/^\s*([A-Z][A-Z0-9_]*|if): \$\{\{[^}]*\}\}\s*$/.test(line),
      );
      expect(offenders, name).toEqual([]);
    }
  });
});

// SECURITY REVIEW 22: the auth email templates. Each must link only to the app's own
// /auth/confirm page with a token hash (which signs in only when a button is pressed), at the
// admin-set Site URL, never Supabase's /verify link (used up by email scanners) or the
// requester-chosen RedirectTo (L01). Every template file must also be deployed (L02, L05).
describe('sign-in email templates (L01, L02, L05)', () => {
  const dir = join(root, 'supabase/templates');
  const files = readdirSync(dir).filter((f) => f.endsWith('.html'));
  const workflow = readFileSync(join(root, '.github/workflows/deploy-database.yml'), 'utf8');
  const config = readFileSync(join(root, 'supabase/config.toml'), 'utf8');

  it('covers the invite, magic link and confirm signup emails', () => {
    expect(files.sort()).toEqual(['confirmation.html', 'invite.html', 'magic_link.html']);
  });

  it.each(files)('%s links only to /auth/confirm at the Site URL', (file) => {
    const html = readFileSync(join(dir, file), 'utf8');
    expect(html).not.toMatch(/ConfirmationURL|RedirectTo\s*\}\}|\/auth\/v1\/verify/);
    const hrefs = [...html.matchAll(/href="([^"]*)"/g)].map((m) => m[1]);
    expect(hrefs.length).toBeGreaterThan(0);
    for (const href of hrefs) {
      expect(href).toMatch(/^\{\{ \.SiteURL \}\}\/auth\/confirm\?token_hash=\{\{ \.TokenHash \}\}&type=(invite|email)$/);
    }
    // Template actions in the leading comment would be filled in too; keep them out of it.
    const comment = html.slice(0, html.indexOf('-->'));
    expect(comment).not.toContain('{{');
  });

  it.each(files)('%s is deployed by the workflow and set for the local stack', (file) => {
    expect(workflow).toContain(`--rawfile`);
    expect(workflow).toContain(`supabase/templates/${file}`);
    expect(config).toContain(`content_path = "./supabase/templates/${file}"`);
  });
});
