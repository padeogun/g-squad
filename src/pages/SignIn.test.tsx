// Sign-in screen: invite-only, and the same message whether or not the address is known.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';

// Stub Supabase: no network. signInWithOtp's result is set per test.
// The email is asked for through emailRequestClient (no PKCE, so the link and code work on
// any device); the 6-digit code is checked by the main client's verifyOtp.
const signInWithOtp = vi.fn();
const verifyOtp = vi.fn();
vi.mock('../lib/supabase', () => ({
  supabase: { auth: { verifyOtp: (...a: unknown[]) => verifyOtp(...a) } },
  emailRequestClient: { auth: { signInWithOtp: (...a: unknown[]) => signInWithOtp(...a) } },
}));
vi.mock('../auth/AuthProvider', () => ({ useAuth: () => ({ session: null, loading: false, signOut: vi.fn() }) }));

import { SignIn } from './SignIn';
import { safePath } from '../lib/paths';

function renderPage() {
  render(
    <MemoryRouter>
      <SignIn />
    </MemoryRouter>,
  );
}

describe('SignIn', () => {
  beforeEach(() => {
    signInWithOtp.mockReset();
    verifyOtp.mockReset();
  });

  it('signs in with the 6-digit code from the email', async () => {
    signInWithOtp.mockResolvedValue({ error: null });
    verifyOtp.mockResolvedValue({ error: null });
    renderPage();
    await userEvent.type(screen.getByLabelText(/email address/i), 'lead@example.org');
    await userEvent.click(screen.getByRole('button', { name: /email me a sign-in link/i }));
    await userEvent.type(await screen.findByLabelText(/6-digit code/i), '123 456');
    await userEvent.click(screen.getByRole('button', { name: /sign in with the code/i }));
    expect(verifyOtp).toHaveBeenCalledWith({ email: 'lead@example.org', token: '123456', type: 'email' });
  });

  it('says so when the code is wrong or expired', async () => {
    signInWithOtp.mockResolvedValue({ error: null });
    verifyOtp.mockResolvedValue({ error: { status: 403, message: 'Token has expired or is invalid' } });
    renderPage();
    await userEvent.type(screen.getByLabelText(/email address/i), 'lead@example.org');
    await userEvent.click(screen.getByRole('button', { name: /email me a sign-in link/i }));
    await userEvent.type(await screen.findByLabelText(/6-digit code/i), '000000');
    await userEvent.click(screen.getByRole('button', { name: /sign in with the code/i }));
    expect(await screen.findByText(/that code didn't work/i)).toBeInTheDocument();
  });

  it('never creates an account (invite-only)', async () => {
    signInWithOtp.mockResolvedValue({ error: null });
    renderPage();
    await userEvent.type(screen.getByLabelText(/email address/i), 'lead@example.org');
    await userEvent.click(screen.getByRole('button', { name: /email me a sign-in link/i }));
    expect(signInWithOtp).toHaveBeenCalledWith(
      expect.objectContaining({ email: 'lead@example.org', options: expect.objectContaining({ shouldCreateUser: false }) }),
    );
    expect(await screen.findByText(/check your email/i)).toBeInTheDocument();
  });

  it('shows the same message for an address that was never invited', async () => {
    signInWithOtp.mockResolvedValue({ error: { status: 422, message: 'Signups not allowed for otp' } });
    renderPage();
    await userEvent.type(screen.getByLabelText(/email address/i), 'stranger@example.org');
    await userEvent.click(screen.getByRole('button', { name: /email me a sign-in link/i }));
    expect(await screen.findByText(/check your email/i)).toBeInTheDocument();
  });

  // SECURITY REVIEW FIX J04: a repeat request for an invited address is rate-limited (429);
  // it must look the same as an address that was never invited.
  it('shows the same message when a repeat request is rate-limited', async () => {
    signInWithOtp.mockResolvedValue({
      error: { status: 429, message: 'For security purposes, you can only request this after 55 seconds.' },
    });
    renderPage();
    await userEvent.type(screen.getByLabelText(/email address/i), 'lead@example.org');
    await userEvent.click(screen.getByRole('button', { name: /email me a sign-in link/i }));
    expect(await screen.findByText(/check your email/i)).toBeInTheDocument();
    expect(screen.queryByText(/something went wrong/i)).not.toBeInTheDocument();
  });

  it('shows an error when sending genuinely fails', async () => {
    signInWithOtp.mockResolvedValue({ error: { status: 500, message: 'boom' } });
    renderPage();
    await userEvent.type(screen.getByLabelText(/email address/i), 'lead@example.org');
    await userEvent.click(screen.getByRole('button', { name: /email me a sign-in link/i }));
    expect(await screen.findByText(/something went wrong/i)).toBeInTheDocument();
  });
});

describe('safePath', () => {
  it('keeps in-app paths and rejects anything that could leave the app', () => {
    expect(safePath('/members')).toBe('/members');
    expect(safePath('//evil.example')).toBe('/');
    expect(safePath('https://evil.example')).toBe('/');
    expect(safePath(undefined)).toBe('/');
    // SECURITY REVIEW FIX J05: browsers drop tabs and newlines and read a backslash as "/" in URLs.
    expect(safePath('/\t/evil.example')).toBe('/');
    expect(safePath('/\n/evil.example')).toBe('/');
    expect(safePath('/\\evil.example')).toBe('/');
    expect(safePath('/a\\..\\/evil.example')).toBe('/');
    expect(safePath('javascript:alert(1)')).toBe('/');
  });
});
