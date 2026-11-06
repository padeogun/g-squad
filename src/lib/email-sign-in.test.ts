// Tests for reading sign-in links and codes (src/lib/email-sign-in.ts).
import { describe, expect, it } from 'vitest';
import { cleanCode, parseEmailLink } from './email-sign-in';

const HASH = 'a3f1c2d4e5b60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c';

describe('parseEmailLink', () => {
  it('reads an invitation and a sign-in link', () => {
    expect(parseEmailLink(`?token_hash=${HASH}&type=invite`)).toEqual({ tokenHash: HASH, type: 'invite' });
    expect(parseEmailLink(`?token_hash=${HASH}&type=email`)).toEqual({ tokenHash: HASH, type: 'email' });
  });
  it('treats the older "magiclink" type as email, and accepts a pkce_ hash', () => {
    expect(parseEmailLink(`?token_hash=pkce_${HASH}&type=magiclink`)).toEqual({ tokenHash: `pkce_${HASH}`, type: 'email' });
  });
  it('refuses other types and odd hashes', () => {
    expect(parseEmailLink(`?token_hash=${HASH}&type=recovery`)).toBeNull();
    expect(parseEmailLink(`?token_hash=${HASH}&type=signup`)).toBeNull();
    expect(parseEmailLink('?token_hash=abc&type=email')).toBeNull();
    expect(parseEmailLink(`?token_hash=${HASH}%27%3B&type=email`)).toBeNull();
    expect(parseEmailLink('?type=email')).toBeNull();
    expect(parseEmailLink('')).toBeNull();
  });
});

describe('cleanCode', () => {
  it('accepts 6 to 10 digits, ignoring spaces and dashes', () => {
    expect(cleanCode(' 123 456 ')).toBe('123456');
    expect(cleanCode('123-456')).toBe('123456');
    expect(cleanCode('12345678')).toBe('12345678');
  });
  it('refuses anything else', () => {
    expect(cleanCode('12345')).toBeNull();
    expect(cleanCode('12345a')).toBeNull();
    expect(cleanCode('')).toBeNull();
  });
});
