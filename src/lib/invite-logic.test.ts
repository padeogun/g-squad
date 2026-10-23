// Tests for the invite-leader Edge Function's rules (supabase/functions/invite-leader/logic.ts).
// The database enforces the same rules; these make sure a refused invite never sends an email.
import { describe, expect, it } from 'vitest';
import {
  checkGrants,
  corsHeaders,
  parseOrigins,
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

  it('keeps senior roles for the Resident Pastor', () => {
    for (const role of ['resident_pastor', 'gsquad_coordinator', 'teci_coordinator', 'pastoral_lead'] as const) {
      expect(checkGrants(['operations_lead'], [{ role }])).toMatch(/Resident Pastor/);
      expect(checkGrants(['gsquad_coordinator'], [{ role }])).toMatch(/Resident Pastor/);
      expect(checkGrants(['resident_pastor'], [{ role }])).toBeNull();
    }
  });

  it('keeps the Operations Lead role from the Coordinator', () => {
    expect(checkGrants(['gsquad_coordinator'], [{ role: 'operations_lead' }])).toMatch(/Operations Lead role/);
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
