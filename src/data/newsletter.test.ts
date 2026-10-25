// Tests for the newsletter page helpers: which months can be started, the approval steps,
// which buttons each leader is offered (a courtesy; the database decides), and input parsing.
import { describe, expect, it } from 'vitest';
import { approvalSteps, isSending, issueActions, linkWords, parseTestList, startableMonths, toggleExcluded } from './newsletter';

describe('startableMonths', () => {
  it('offers this month and the next 12, skipping months that have an issue, across a year end', () => {
    const m = startableMonths('2026-11-20', ['2026-12-01']);
    expect(m[0]).toBe('2026-11-01');
    expect(m).not.toContain('2026-12-01');
    expect(m).toContain('2027-01-01');
    expect(m.at(-1)).toBe('2027-11-01');
    expect(m).toHaveLength(12);
  });
});

describe('approvalSteps', () => {
  it('marks where the issue is', () => {
    expect(approvalSteps('draft').map((s) => s.state)).toEqual(['current', 'todo', 'todo', 'todo']);
    expect(approvalSteps('awaiting_pastor').map((s) => s.state)).toEqual(['done', 'done', 'current', 'todo']);
    expect(approvalSteps('sent').map((s) => s.state)).toEqual(['done', 'done', 'done', 'done']);
  });
});

describe('issueActions', () => {
  const draft = { status: 'draft' as const, send_started_at: null, send_now_at: null, send_attempts: 0 };
  it('lets editors write and submit, not approve', () => {
    const a = issueActions(draft, ['newsletter_editor'], false);
    expect(a.edit && a.submit).toBe(true);
    expect(a.coordinatorApprove || a.pastorApprove || a.sendNow).toBe(false);
  });
  it('follows the approval order (R17)', () => {
    expect(issueActions({ ...draft, status: 'awaiting_coordinator' }, ['gsquad_coordinator'], false).coordinatorApprove).toBe(true);
    expect(issueActions({ ...draft, status: 'awaiting_coordinator' }, ['resident_pastor'], false).pastorApprove).toBe(false);
    expect(issueActions({ ...draft, status: 'awaiting_pastor' }, ['resident_pastor'], false).pastorApprove).toBe(true);
    expect(issueActions({ ...draft, status: 'approved' }, ['gsquad_coordinator'], false).sendNow).toBe(true);
    expect(issueActions({ ...draft, status: 'approved' }, ['newsletter_editor'], false).sendNow).toBe(false);
  });
  // SECURITY REVIEW 18 (Y08): "Try sending again" once sending has given up, for the two roles.
  it('offers Try again only after 5 failed attempts, to the Coordinator and Resident Pastor', () => {
    const pressed = { ...draft, status: 'approved' as const, send_now_at: '2026-11-01T09:00:00Z' };
    expect(issueActions({ ...pressed, send_attempts: 2 }, ['gsquad_coordinator'], false)).toMatchObject({ sendNow: false, retry: false });
    expect(issueActions({ ...pressed, send_attempts: 5 }, ['resident_pastor'], false).retry).toBe(true);
    expect(issueActions({ ...pressed, send_attempts: 5 }, ['newsletter_editor'], false).retry).toBe(false);
  });
  it('offers nothing to change while sending or once sent', () => {
    const a = issueActions({ ...draft, status: 'approved' }, ['newsletter_editor', 'gsquad_coordinator'], true);
    expect(a.edit || a.sendNow || a.sendBack).toBe(false);
    expect(issueActions({ ...draft, status: 'sent' }, ['newsletter_editor'], false).test).toBe(false);
  });
});

describe('isSending', () => {
  it('holds for 15 minutes after the job starts', () => {
    const now = Date.parse('2026-11-01T09:10:00Z');
    expect(isSending('2026-11-01T09:00:00Z', now)).toBe(true);
    expect(isSending('2026-11-01T08:50:00Z', now)).toBe(false);
    expect(isSending(null, now)).toBe(false);
  });
});

describe('parseTestList and toggleExcluded', () => {
  it('cleans the test list and reports bad addresses', () => {
    expect(parseTestList('A@Example.org, b@example.org\na@example.org')).toEqual({ list: ['a@example.org', 'b@example.org'], bad: [] });
    expect(parseTestList('not-an-email').bad).toEqual(['not-an-email']);
  });
  it('adds and removes an id', () => {
    expect(toggleExcluded(['a'], 'b')).toEqual(['a', 'b']);
    expect(toggleExcluded(['a', 'b'], 'a')).toEqual(['b']);
  });
});

describe('linkWords', () => {
  it('asks before acting, for each kind of link', () => {
    expect(linkWords({ purpose: 'rsvp', event: 'Prayer Night' }).ask).toMatch(/Prayer Night/);
    expect(linkWords({ purpose: 'react', reaction: 'pray' }).ask).toMatch(/Praying/);
    expect(linkWords({ purpose: 'unsubscribe' }).button).toBe('Stop the emails');
  });
});
