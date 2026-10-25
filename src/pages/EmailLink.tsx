// -------------------------------------------------------------------------------------
// The page a member's personal link in The Greatness Brief opens: /e/<token>. Public (members
// do not sign in). It first asks the email-link Edge Function what the link is for, without
// using it, and acts only when the member presses Confirm, so a mail scanner that opens links
// changes nothing. "test" is the link in test emails and previews.
// -------------------------------------------------------------------------------------
import { useEffect, useRef, useState } from 'react';
import { useParams } from 'react-router-dom';
import { TEC, tecMark } from '../design-system';
import { supabase } from '../lib/supabase';
import { linkWords, type Peek } from '../data/newsletter';

const { Card, Notice, Button } = TEC;

async function ask(token: string, confirm: boolean): Promise<Peek> {
  const { data, error } = await supabase.functions.invoke('email-link', { body: { token, confirm } });
  if (error) throw error;
  return data as Peek;
}

export function EmailLink() {
  const { token = '' } = useParams();
  const [peek, setPeek] = useState<Peek | null>(null);
  const [state, setState] = useState<'loading' | 'ready' | 'done' | 'error'>(token === 'test' ? 'ready' : 'loading');
  // SECURITY REVIEW 18 (Y13): the button disappears when pressed, so focus moves to the answer.
  const answer = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (state === 'done' || state === 'error') answer.current?.focus();
  }, [state]);

  useEffect(() => {
    if (token === 'test') return;
    let live = true;
    ask(token, false)
      .then((p) => {
        if (!live) return;
        setPeek(p);
        setState('ready');
      })
      .catch(() => live && setState('error'));
    return () => {
      live = false;
    };
  }, [token]);

  const confirm = () => {
    setState('loading');
    ask(token, true)
      .then((p) => {
        setPeek(p);
        setState(p.purpose === 'invalid' ? 'ready' : 'done');
      })
      .catch(() => setState('error'));
  };

  const words = peek ? linkWords(peek) : null;
  return (
    <main className="app-link-page">
      <div>
        <img src={tecMark} alt="The Elevation Church" width={48} height={48} />
        {/* SECURITY REVIEW 18 (Y13): the page had no main heading, and its changes (loading, the
            answer) were not announced: the card body is now a polite live region. */}
        <h1 className="app-link-title">The Greatness Brief</h1>
        <Card title="Your link">
          <div ref={answer} tabIndex={-1} aria-live="polite" className="app-link-body">
          {token === 'test' && <Notice tone="info">This link came from a test email or a preview, so it does nothing.</Notice>}
          {state === 'loading' && <p style={{ margin: 0 }}>One moment…</p>}
          {state === 'error' && <Notice tone="danger">Something went wrong. Please try the link again later.</Notice>}
          {state === 'ready' && peek?.purpose === 'invalid' && <Notice tone="warn">This link has expired or is not valid.</Notice>}
          {state === 'ready' && peek && peek.purpose !== 'invalid' && words && (
            <>
              <p style={{ margin: 0 }}>{words.ask}</p>
              {peek.used && peek.purpose !== 'unsubscribe' && <p className="type-caption" style={{ margin: 0 }}>You have used this link before; pressing again changes nothing.</p>}
              <div>
                <Button variant="primary" onClick={confirm}>
                  {words.button}
                </Button>
              </div>
            </>
          )}
          {state === 'done' && words && <Notice tone="ok">{words.done}</Notice>}
          </div>
        </Card>
      </div>
    </main>
  );
}
