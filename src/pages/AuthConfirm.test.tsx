// /auth/confirm: opening the page must not use the link (email scanners open links);
// only pressing the button does, and a used link explains what to do next.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';

const verifyOtp = vi.fn();
let pending: { tokenHash: string; type: 'invite' | 'email' } | null = null;
vi.mock('../lib/supabase', () => ({ supabase: { auth: { verifyOtp: (...a: unknown[]) => verifyOtp(...a) } } }));
vi.mock('../lib/invite-landing', () => ({ pendingEmailLink: () => pending, clearPendingLink: () => (pending = null) }));
let session: object | null = null;
vi.mock('../auth/AuthProvider', () => ({ useAuth: () => ({ session, loading: false, signOut: vi.fn() }) }));

import { AuthConfirm } from './AuthConfirm';

function renderPage() {
  render(
    <MemoryRouter>
      <AuthConfirm />
    </MemoryRouter>,
  );
}

describe('AuthConfirm', () => {
  beforeEach(() => {
    verifyOtp.mockReset();
    session = null;
    pending = { tokenHash: 'a'.repeat(56), type: 'invite' };
  });

  it('does nothing until the button is pressed', async () => {
    verifyOtp.mockResolvedValue({ error: null });
    renderPage();
    expect(verifyOtp).not.toHaveBeenCalled();
    await userEvent.click(screen.getByRole('button', { name: /accept and sign in/i }));
    expect(verifyOtp).toHaveBeenCalledWith({ token_hash: 'a'.repeat(56), type: 'invite' });
  });

  it('explains a used or expired link', async () => {
    pending = { tokenHash: 'b'.repeat(56), type: 'email' };
    verifyOtp.mockResolvedValue({ error: { status: 403, message: 'Email link is invalid or has expired' } });
    renderPage();
    await userEvent.click(screen.getByRole('button', { name: /^sign in$/i }));
    expect(await screen.findByText(/already been used or has expired/i)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /sign-in page/i })).toBeInTheDocument();
  });

  // Review 22 (L06): someone else's link must never switch the account in use.
  it('drops a link opened while already signed in, without using it', () => {
    session = { user: { id: 'u1' } };
    renderPage();
    expect(verifyOtp).not.toHaveBeenCalled();
    expect(pending).toBeNull();
  });
});
