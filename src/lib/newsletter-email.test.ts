// Tests for The Greatness Brief email (supabase/functions/_shared/newsletter.ts), used by the
// send-newsletter Edge Function and by the app's preview.
import { describe, expect, it } from 'vitest';
import {
  batchKey,
  esc,
  isToken,
  linkUrl,
  monthLabel,
  renderHtml,
  renderText,
  subjectFor,
  unsubscribeHeaders,
  validFrom,
  whenLabel,
  type IssueContent,
} from '../../supabase/functions/_shared/newsletter.ts';

const APP = 'https://tecmanchester-g-squad.netlify.app';
const G = '11111111-1111-4111-8111-111111111111';

const content = (over: Partial<IssueContent> = {}): IssueContent => ({
  issue_month: '2026-11-01',
  headline: 'Your finance and the Ministry',
  standfirst: 'One line under the headline',
  pastor_word: 'God is calling us to relevance.',
  pastor_name: 'Pastor Sample',
  gatherings: [{ id: G, name: 'G-Squad Prayer Night', starts_at: '2026-11-14T18:00:00Z', ends_at: '2026-11-14T20:00:00Z', tag: 'PRAYER', site: 'Salford' }],
  celebrations: [
    { kind: 'birthday', name: 'Ada T.', day: 12, month: 11 },
    { kind: 'new_member', name: 'Ben S.', day: 3, month: 10 },
  ],
  baptisms: { water: 2, holy_spirit: 0 },
  team_updates: [{ id: 'u1', unit: 'Production', body: 'Three new camera operators.' }],
  recognitions: [{ id: 'r1', letter: 'S', value: 'Service', name: 'Esther B.', description: 'Covered two Sundays.' }],
  items: [{ id: 'i1', kind: 'win', title: null, body: 'Twins welcomed.' }],
  ...over,
});

describe('words', () => {
  it('names the month and the subject', () => {
    expect(monthLabel('2026-11-01')).toBe('November 2026');
    expect(subjectFor(content())).toBe('The Greatness Brief · November 2026: Your finance and the Ministry');
    expect(subjectFor(content(), true)).toMatch(/^\[TEST\] /);
  });
  it('keeps the subject on one line', () => {
    expect(subjectFor(content({ headline: 'A\r\nBcc: x@example.org' }))).not.toMatch(/[\r\n]/);
  });
  it('shows gatherings in London time', () => {
    expect(whenLabel('2026-11-14T18:00:00Z')).toBe('Sat 14 Nov, 6:00pm');
    expect(whenLabel('2026-07-14T18:00:00Z')).toBe('Tue 14 Jul, 7:00pm'); // British Summer Time
  });
});

describe('renderHtml', () => {
  it('escapes everything typed by people', () => {
    const html = renderHtml(content({ headline: '<script>alert(1)</script>', team_updates: [{ id: 'u', unit: '"x"', body: '<img src=x onerror=alert(1)>' }] }), { appUrl: APP });
    expect(html).not.toContain('<script>alert');
    expect(html).not.toContain('<img src=x');
    expect(html).toContain('&lt;script&gt;');
    expect(esc(`a"b'c`)).toBe('a&quot;b&#39;c');
  });
  it('puts each member\'s own links in their email', () => {
    const html = renderHtml(content(), {
      appUrl: APP,
      firstName: 'Ada',
      links: { unsubscribe: 'u'.repeat(64), react: { heart: 'h'.repeat(64) }, rsvp: { [G]: 'r'.repeat(64) } },
    });
    expect(html).toContain('Hi Ada,');
    expect(html).toContain(`${APP}/e/${'r'.repeat(64)}`);
    expect(html).toContain(`${APP}/e/${'u'.repeat(64)}`);
    expect(html).toContain(`${APP}/e/${'h'.repeat(64)}`);
    // Reactions without a link are left out rather than pointing nowhere.
    expect(html.match(/\/e\//g)?.length).toBe(3);
  });
  it('points test and preview links at the test page and says it is a test', () => {
    const html = renderHtml(content(), { appUrl: APP, links: null, test: true });
    expect(html).toContain(`${APP}/e/test`);
    expect(html).toContain('Test email');
  });
  it('leaves out what editors excluded and empty sections', () => {
    const html = renderHtml(
      content({ gatherings: [{ ...content().gatherings[0], excluded: true }], team_updates: [], baptisms: { water: 0, holy_spirit: 0 } }),
      { appUrl: APP },
    );
    expect(html).not.toContain('G-Squad Prayer Night');
    expect(html).not.toContain('From the teams');
    expect(html).not.toContain('Baptisms last month');
  });
  it('shows celebrations by day and month only', () => {
    const html = renderHtml(content(), { appUrl: APP });
    expect(html).toContain('12 November');
    expect(html).not.toContain('2026-11-12');
  });
});

describe('renderText', () => {
  it('has the same content in plain text', () => {
    const t = renderText(content(), { appUrl: APP });
    expect(t).toContain('UPCOMING GATHERINGS');
    expect(t).toContain('Production: Three new camera operators.');
    expect(t).toContain('Esther B. (Service)');
  });
});

describe('sending helpers', () => {
  it('gives the same key to the same batch', () => {
    expect(batchKey('i', ['a', 'b'])).toBe(batchKey('i', ['a', 'b']));
    expect(batchKey('i', ['a', 'b'])).not.toBe(batchKey('i', ['a']));
  });
  it('builds one-click unsubscribe headers', () => {
    expect(unsubscribeHeaders('https://x.supabase.co/functions/v1', 'abc')).toEqual({
      'List-Unsubscribe': '<https://x.supabase.co/functions/v1/email-link?t=abc>',
      'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click',
    });
  });
  it('accepts only well-formed tokens and From addresses', () => {
    expect(isToken('a'.repeat(64))).toBe(true);
    expect(isToken('short')).toBe(false);
    expect(isToken('a'.repeat(40) + '<')).toBe(false);
    expect(validFrom('The Greatness Brief <brief@example.org>')).toBe('The Greatness Brief <brief@example.org>');
    expect(validFrom('x\r\nBcc: y@example.org <a@b.co>')).toBeNull();
    expect(validFrom(undefined)).toBeNull();
    expect(linkUrl(APP, null)).toBe(`${APP}/e/test`);
  });
});
