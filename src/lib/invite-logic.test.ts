// Tests for the invite-leader Edge Function's rules (supabase/functions/invite-leader/logic.ts).
// The database enforces the same rules; these make sure a refused invite never sends an email.
import { describe, expect, it } from 'vitest';
import {
  bodyTooLarge,
  checkGrants,
  corsHeaders,
  defaultOrigins,
  invitesPerHour,
  isFreshUser,
  parseOrigins,
  PRODUCTION_ORIGINS,
  safeDbMessage,
  validateInvite,
} from '../../supabase/functions/invite-leader/logic.ts';

const UNIT = '11111111-1111-4111-8111-111111111111';
const PURPOSE = '22222222-2222-4222-8222-222222222222';

describe('validateInvite', () => {
  it('accepts a clean request and normalises email and name', () => {
    const r = validateInvite({ email: ' Lead@Example.org ', display_name: '  Ada   Test ', roles: [{ role: 'unit_lead', unit_id: UNIT }] });
    expect(r).toEqual({
      ok: true,
      value: { email: 'lead@example.org', display_name: 'Ada Test', roles: [{ role: 'unit_lead', unit_id: UNIT, purpose_id: null }] },
    });
  });

  it('rejects bad email, missing name, unknown roles and too many roles', () => {
    expect(validateInvite({ email: 'nope', display_name: 'A', roles: [{ role: 'unit_lead', unit_id: UNIT }] }).ok).toBe(false);
    expect(validateInvite({ email: 'a@b.org', display_name: '', roles: [{ role: 'finance' }] }).ok).toBe(false);
    expect(validateInvite({ email: 'a@b.org', display_name: 'A', roles: [{ role: 'superuser' }] }).ok).toBe(false);
    expect(validateInvite({ email: 'a@b.org', display_name: 'A', roles: [] }).ok).toBe(false);
    const six = Array.from({ length: 6 }, () => ({ role: 'finance' }));
    expect(validateInvite({ email: 'a@b.org', display_name: 'A', roles: six }).ok).toBe(false);
    expect(validateInvite(null).ok).toBe(false);
  });

  it('rejects control characters in the name', () => {
    expect(validateInvite({ email: 'a@b.org', display_name: 'A\u0000B', roles: [{ role: 'finance' }] }).ok).toBe(false);
  });

  it('needs the right scope for scoped roles, and none for others', () => {
    expect(validateInvite({ email: 'a@b.org', display_name: 'A', roles: [{ role: 'unit_lead' }] }).ok).toBe(false);
    expect(validateInvite({ email: 'a@b.org', display_name: 'A', roles: [{ role: 'purpose_head' }] }).ok).toBe(false);
    expect(validateInvite({ email: 'a@b.org', display_name: 'A', roles: [{ role: 'finance', unit_id: UNIT }] }).ok).toBe(false);
    expect(validateInvite({ email: 'a@b.org', display_name: 'A', roles: [{ role: 'unit_lead', unit_id: 'x' }] }).ok).toBe(false);
    expect(validateInvite({ email: 'a@b.org', display_name: 'A', roles: [{ role: 'purpose_head', purpose_id: PURPOSE }] }).ok).toBe(true);
  });
});

describe('checkGrants', () => {
  const unitLead = [{ role: 'unit_lead' as const, unit_id: UNIT }];

  it('lets the Operations Lead and Coordinator invite Unit Leads', () => {
    expect(checkGrants(['operations_lead'], unitLead)).toBeNull();
    expect(checkGrants(['gsquad_coordinator'], unitLead)).toBeNull();
  });

  it('refuses callers who are not inviters', () => {
    expect(checkGrants(['unit_lead'], unitLead)).toMatch(/Only the Operations Lead/);
    expect(checkGrants([], unitLead)).toMatch(/Only the Operations Lead/);
  });

  // Migration 18: senior roles are given by the Resident Pastor or the G-Squad Coordinator;
  // the Resident Pastor role by the Resident Pastor only.
  it('lets the Coordinator give senior roles, but not the Resident Pastor role', () => {
    for (const role of ['gsquad_coordinator', 'teci_coordinator', 'pastoral_lead'] as const) {
      expect(checkGrants(['operations_lead'], [{ role }])).toMatch(/Resident Pastor or the G-Squad Coordinator/);
      expect(checkGrants(['gsquad_coordinator'], [{ role }])).toBeNull();
      expect(checkGrants(['resident_pastor'], [{ role }])).toBeNull();
    }
    expect(checkGrants(['gsquad_coordinator'], [{ role: 'resident_pastor' }])).toMatch(/Resident Pastor role/);
    expect(checkGrants(['operations_lead'], [{ role: 'resident_pastor' }])).toMatch(/Resident Pastor role/);
    expect(checkGrants(['resident_pastor'], [{ role: 'resident_pastor' }])).toBeNull();
  });

  it('lets the Coordinator and Operations Leads give the Operations Lead role', () => {
    expect(checkGrants(['gsquad_coordinator'], [{ role: 'operations_lead' }])).toBeNull();
    expect(checkGrants(['operations_lead'], [{ role: 'operations_lead' }])).toBeNull();
  });
});

describe('CORS', () => {
  it('only echoes allowed origins', () => {
    const allowed = ['https://app.example.org'];
    expect(corsHeaders('https://app.example.org', allowed)['Access-Control-Allow-Origin']).toBe('https://app.example.org');
    expect(corsHeaders('https://evil.example', allowed)['Access-Control-Allow-Origin']).toBeUndefined();
    expect(corsHeaders(null, allowed)['Access-Control-Allow-Origin']).toBeUndefined();
  });

  it('parses the origins list and falls back when empty or invalid', () => {
    expect(parseOrigins('https://a.org/, http://localhost:5173', ['x'])).toEqual(['https://a.org', 'http://localhost:5173']);
    expect(parseOrigins('', ['https://fallback.org'])).toEqual(['https://fallback.org']);
    expect(parseOrigins('javascript:alert(1), https://a.org/path', ['f'])).toEqual(['f']);
  });
});

// Security review 6 (SECURITY_LOG.md, K01 and K05 to K08).
describe('security review 6', () => {
  it('K01: only a user created by this request counts as new', () => {
    const start = Date.parse('2026-10-23T12:00:00Z');
    expect(isFreshUser('2026-10-23T12:00:00.300Z', start)).toBe(true);
    expect(isFreshUser('2026-10-23T11:59:58Z', start)).toBe(true); // clock slack
    expect(isFreshUser('2026-10-22T09:00:00Z', start)).toBe(false); // pending invitation from yesterday
    expect(isFreshUser(undefined, start)).toBe(false);
    expect(isFreshUser('not a date', start)).toBe(false);
  });

  it('K05: passes on our rule messages only', () => {
    const fb = 'These roles could not be given';
    expect(safeDbMessage({ code: '42501', message: 'Only the Resident Pastor can assign or remove this role' }, fb)).toMatch(
      /Resident Pastor/,
    );
    expect(safeDbMessage({ code: '42501', message: 'new row violates row-level security policy for table "x"' }, fb)).toBe(fb);
    expect(safeDbMessage({ code: '23503', message: 'violates foreign key constraint "role_assignments_church_id_unit_id_fkey"' }, fb)).toBe(fb);
    expect(safeDbMessage(null, fb)).toBe(fb);
  });

  it('K06: refuses a large or nonsense Content-Length', () => {
    expect(bodyTooLarge(null)).toBe(false);
    expect(bodyTooLarge('512')).toBe(false);
    expect(bodyTooLarge('4001')).toBe(true);
    expect(bodyTooLarge('-1')).toBe(true);
    expect(bodyTooLarge('abc')).toBe(true);
  });

  it('K07: localhost is allowed only on a local Supabase stack', () => {
    expect(defaultOrigins('https://abcd.supabase.co')).toEqual(PRODUCTION_ORIGINS);
    expect(defaultOrigins(undefined)).toEqual(PRODUCTION_ORIGINS);
    expect(defaultOrigins('http://kong:8000')).toContain('http://localhost:5173');
    expect(defaultOrigins('http://127.0.0.1:54321')).toContain('http://127.0.0.1:5173');
    expect(defaultOrigins('http://localhost.evil.example')).toEqual(PRODUCTION_ORIGINS);
  });

  it('K08: hourly invitation limit defaults to 20 and stays in range', () => {
    expect(invitesPerHour(undefined)).toBe(20);
    expect(invitesPerHour('5')).toBe(5);
    expect(invitesPerHour('0')).toBe(20);
    expect(invitesPerHour('100000')).toBe(20);
    expect(invitesPerHour('2.5')).toBe(20);
  });
});
