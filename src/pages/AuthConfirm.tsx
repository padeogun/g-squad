// -------------------------------------------------------------------------------------
// /auth/confirm: where invitation and sign-in emails now land (see src/lib/email-sign-in.ts).
//
// Opening this page does nothing by itself: email scanners open links, and a one-time link
// used by a scanner is gone before the leader clicks it. The leader presses "Sign in", and
// only then is the link's token hash exchanged for a session. It works on any device, not only
// the one that asked for the link. If the link is no longer valid, the page says so and offers
// the sign-in page, where the 6-digit code from the same email also works.
// -------------------------------------------------------------------------------------
import { useEffect, useRef, useState } from 'react';
import { Link, Navigate } from 'react-router-dom';
import { TEC, tecMark } from '../design-system';
import { supabase } from '../lib/supabase';
import { clearPendingLink, pendingEmailLink } from '../lib/invite-landing';
import { useAuth } from '../auth/AuthProvider';

const { Card, Notice, Button } = TEC;

type State = 'ready' | 'working' | 'failed';

export function AuthConfirm() {
  const { session } = useAuth();
  const [link] = useState(pendingEmailLink);
  const [state, setState] = useState<State>('ready');
  const message = useRef<HTMLDivElement>(null);
  // The button disappears on failure, so focus moves to the explanation (screen readers).
  useEffect(() => {
    if (state === 'failed') message.current?.focus();
  }, [state]);

  // Signed in (just now, or already): into the app.
  if (session && state !== 'failed') return <Navigate to="/" replace />;
  // No link in memory (page reloaded, or opened by hand): the normal sign-in page.
  if (!link) return <Navigate to="/sign-in" replace />;

  async function signIn() {
    if (!link) return;
    setState('working');
    const { error } = await supabase.auth.verifyOtp({ token_hash: link.tokenHash, type: link.type });
    clearPendingLink(); // used or refused: never offered again
    if (error) setState('failed');
    // On success the auth listener sets the session and the redirect above runs.
  }

  const invited = link.type === 'invite';
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
        <Card title={invited ? 'Accept your invitation' : 'Sign in'}>
          {state === 'failed' ? (
            <div ref={message} tabIndex={-1}>
              <Notice tone="warn" title="This link has already been used or has expired">
                Each link works once, for an hour. Go to the sign-in page and ask for a new one; you can also type
                the 6-digit code from that email instead of clicking its link.
              </Notice>
              <p style={{ marginTop: 12 }}>
                <Link to="/sign-in">Go to the sign-in page</Link>
              </p>
            </div>
          ) : (
            <div style={{ display: 'grid', gap: 12 }}>
              <p style={{ margin: 0 }}>
                {invited
                  ? 'Welcome. Press the button to accept your invitation and sign in.'
                  : 'Press the button to finish signing in.'}
              </p>
              <Button variant="primary" onClick={signIn} disabled={state === 'working'}>
                {state === 'working' ? 'Signing in…' : invited ? 'Accept and sign in' : 'Sign in'}
              </Button>
            </div>
          )}
        </Card>
      </div>
    </main>
  );
}
