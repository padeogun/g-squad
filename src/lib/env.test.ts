// Checks the settings guard: a secret key or plain-http URL must never reach the browser build.
import { describe, expect, it } from 'vitest';
import { isSecretKey, parseEnv } from './env';

// Builds a fake legacy JWT with the given role in its payload.
const jwt = (role: string) => `x.${btoa(JSON.stringify({ role }))}.y`;

describe('parseEnv', () => {
  it('accepts an https URL and a publishable key', () => {
    expect(
      parseEnv({ VITE_SUPABASE_URL: 'https://abc.supabase.co/', VITE_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_x' }),
    ).toEqual({ supabaseUrl: 'https://abc.supabase.co', supabaseKey: 'sb_publishable_x' });
  });

  it('rejects missing values', () => {
    expect(() => parseEnv({})).toThrow(/Missing/);
  });

  it('rejects a plain-http remote URL', () => {
    expect(() =>
      parseEnv({ VITE_SUPABASE_URL: 'http://abc.supabase.co', VITE_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_x' }),
    ).toThrow(/https/);
  });

  it('allows http for local Supabase', () => {
    expect(
      parseEnv({ VITE_SUPABASE_URL: 'http://127.0.0.1:54321', VITE_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_x' })
        .supabaseUrl,
    ).toBe('http://127.0.0.1:54321');
  });

  it('rejects a secret key', () => {
    expect(() =>
      parseEnv({ VITE_SUPABASE_URL: 'https://abc.supabase.co', VITE_SUPABASE_PUBLISHABLE_KEY: 'sb_secret_x' }),
    ).toThrow(/secret/);
  });

  it('rejects a legacy service-role key but accepts a legacy anon key', () => {
    const url = 'https://abc.supabase.co';
    expect(() => parseEnv({ VITE_SUPABASE_URL: url, VITE_SUPABASE_PUBLISHABLE_KEY: jwt('service_role') })).toThrow(
      /secret/,
    );
    expect(parseEnv({ VITE_SUPABASE_URL: url, VITE_SUPABASE_PUBLISHABLE_KEY: jwt('anon') }).supabaseKey).toBe(
      jwt('anon'),
    );
  });
});

// SECURITY REVIEW FIX J01: the same check stops the build (vite.config.ts) for any VITE_* variable.
describe('isSecretKey', () => {
  it('flags secret keys in either format, whatever the case or spacing', () => {
    expect(isSecretKey('sb_secret_abc')).toBe(true);
    expect(isSecretKey(' SB_SECRET_abc ')).toBe(true);
    expect(isSecretKey(jwt('service_role'))).toBe(true);
  });

  it('does not flag publishable or anon keys, or ordinary values', () => {
    expect(isSecretKey('sb_publishable_abc')).toBe(false);
    expect(isSecretKey(jwt('anon'))).toBe(false);
    expect(isSecretKey('https://abc.supabase.co')).toBe(false);
  });
});
