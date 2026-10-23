// -------------------------------------------------------------------------------------
// Sign-in by emailed link. G-Squad is invite-only: shouldCreateUser is false, so an
// address that was never invited gets no account. The message after sending is the same
// whether or not the address is known, so the form can't be used to discover who is a leader.
// -------------------------------------------------------------------------------------
import { useState, type FormEvent } from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { TEC, tecMark } from '../design-system';
import { supabase } from '../lib/supabase';
import { useAuth } from '../auth/AuthProvider';
import { safePath } from '../lib/paths';

const { Button, Card, TextField, Notice } = TEC;

type Status = 'idle' | 'sending' | 'sent' | 'error';

export function SignIn() {
  const { session } = useAuth();
  const location = useLocation();
  const [email, setEmail] = useState('');
  const [status, setStatus] = useState<Status>('idle');

  // Already signed in: go back to where they were heading, or home.
  const from = (location.state as { from?: string } | null)?.from;
  if (session) return <Navigate to={safePath(from)} replace />;

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setStatus('sending');
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim(),
      options: {
        shouldCreateUser: false, // invite-only
        emailRedirectTo: window.location.origin + '/',
      },
    });
    // "Signups not allowed" means the address isn't invited; show the same message as success.
    // SECURITY REVIEW FIX J04: a rate-limit refusal (429) gets the same message too. Supabase
    // limits repeat links per address only for real accounts, so asking twice for the same
    // address used to show "Something went wrong" for an invited leader and "Check your email"
    // for a stranger, which revealed who is a leader.
    if (error && error.status !== 422 && error.status !== 429 && !/signups? not allowed/i.test(error.message)) {
      setStatus('error');
      return;
    }
    setStatus('sent');
  }

  return (
    <main className="auth-page" id="main">
      <div className="auth-card">
        <div className="auth-brand">
          <img src={tecMark} alt="The Elevation Church" width={48} height={48} />
          <div>
            <div className="type-eyebrow">The Elevation Church · Manchester</div>
            <h1 className="type-heading" style={{ margin: 0 }}>
              G-Squad Planner
            </h1>
          </div>
        </div>
        <Card title="Sign in">
          {status === 'sent' ? (
            <Notice tone="ok" title="Check your email">
              If this address belongs to a G-Squad leader, a sign-in link is on its way. It works once and
              expires in an hour. If nothing arrives within a few minutes, check your spam folder, then try again.
            </Notice>
          ) : (
            <form className="auth-form" onSubmit={onSubmit} noValidate>
              <TextField
                id="email"
                label="Email address"
                type="email"
                autoComplete="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
              {status === 'error' && (
                <Notice tone="danger" title="Something went wrong">
                  The link couldn't be sent. Please try again in a minute.
                </Notice>
              )}
              <Button type="submit" variant="primary" disabled={status === 'sending' || !email.includes('@')}>
                {status === 'sending' ? 'Sending…' : 'Email me a sign-in link'}
              </Button>
            </form>
          )}
        </Card>
        <p className="type-caption" style={{ color: 'var(--ink-muted)', margin: 0 }}>
          Access is by invitation from the Operations Lead.
        </p>
      </div>
    </main>
  );
}
