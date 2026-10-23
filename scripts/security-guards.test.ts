// -------------------------------------------------------------------------------------
// Checks for guards that live outside the React app (security review 5).
//   J06  scripts/db-test.sh refuses anything that is not a local test database. A fake psql
//        is used throughout, so no connection is ever attempted.
//   J01  no file in src/ passes import.meta.env as a whole object, because Vite would then
//        inline every VITE_* variable from the build environment into the public bundle.
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
