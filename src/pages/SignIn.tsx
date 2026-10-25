// -------------------------------------------------------------------------------------
// Sign-in by emailed link. G-Squad is invite-only: shouldCreateUser is false, so an
// address that was never invited gets no account. The message after sending is the same
// whether or not the address is known, so the form can't be used to discover who is a leader.
//
// The email carries a link to /auth/confirm and an 8-digit code (src/lib/email-sign-in.ts).
// The code can be typed here, which helps when the email is read on another device or the
// link was used up by an email scanner.
// -------------------------------------------------------------------------------------
import { useState, type FormEvent } from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { TEC, tecMark } from '../design-system';
import { supabase, emailRequestClient } from '../lib/supabase';
import { cleanCode } from '../lib/email-sign-in';
import { useAuth } from '../auth/AuthProvider';
import { safePath } from '../lib/paths';
import { takeInviteWelcome } from '../lib/invite-landing';

const { Button, Card, TextField, Notice } = TEC;

type Status = 'idle' | 'sending' | 'sent' | 'error';

export function SignIn() {
  const { session } = useAuth();
  const location = useLocation();
  const [email, setEmail] = useState('');
  const [status, setStatus] = useState<Status>('idle');
  const [code, setCode] = useState('');
  const [codeState, setCodeState] = useState<'idle' | 'checking' | 'wrong'>('idle');
  // Arrived from an invitation email: say welcome and explain the one extra step.
  const [welcome] = useState(takeInviteWelcome);

  // Already signed in: go back to where they were heading, or home.
  const from = (location.state as { from?: string } | null)?.from;
  if (session) return <Navigate to={safePath(from)} replace />;

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setStatus('sending');
    // The request client: no PKCE, so the link and code work on any device (see supabase.ts).
    const { error } = await emailRequestClient.auth.signInWithOtp({
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

  async function onCode(e: FormEvent) {
    e.preventDefault();
    const token = cleanCode(code);
    if (!token) {
      setCodeState('wrong');
      return;
    }
    setCodeState('checking');
    // A wrong or expired code and an unknown address give the same answer, as above.
    const { error } = await supabase.auth.verifyOtp({ email: email.trim(), token, type: 'email' });
    setCodeState(error ? 'wrong' : 'idle');
    // On success the auth listener sets the session and the redirect at the top runs.
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
            <form className="auth-form" onSubmit={onCode} noValidate>
              <Notice tone="ok" title="Check your email">
                If this address belongs to a G-Squad leader, an email is on its way. Open its link and press Sign
                in, or type its 8-digit code here. Both work once, for an hour. If nothing arrives within a few
                minutes, check your spam folder, then try again.
              </Notice>
              <TextField
                id="code"
                label="8-digit code from the email"
                inputMode="numeric"
                autoComplete="one-time-code"
                value={code}
                onChange={(e) => {
                  setCode(e.target.value);
                  setCodeState('idle');
                }}
              />
              {codeState === 'wrong' && (
                <Notice tone="danger" title="That code didn't work">
                  Check the code, or ask for a new email. Codes work once and expire after an hour.
                </Notice>
              )}
              <Button type="submit" variant="primary" disabled={codeState === 'checking' || !code.trim()}>
                {codeState === 'checking' ? 'Checking…' : 'Sign in with the code'}
              </Button>
              <Button
                type="button"
                variant="secondary"
                onClick={() => {
                  setStatus('idle');
                  setCode('');
                  setCodeState('idle');
                }}
              >
                Use a different email or send again
              </Button>
            </form>
          ) : (
            <form className="auth-form" onSubmit={onSubmit} noValidate>
              {welcome && (
                <Notice tone="ok" title="Welcome to the G-Squad Planner">
                  Your invitation is confirmed. Enter your email address and we'll send your sign-in link.
                </Notice>
              )}
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
