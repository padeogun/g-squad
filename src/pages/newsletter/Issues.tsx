// -------------------------------------------------------------------------------------
// The Greatness Brief: every issue, newest first, and starting the next one. Below, the
// sending settings: the test list (the G-Squad Coordinator or Operations Lead) and the switch
// that starts sending to members, which only the Resident Pastor may turn on, once the DPIA
// is signed (decision of 25 Oct 2026; church_settings_guard, migration 27).
// Readers: editors, the Coordinator, the Resident Pastor and the Operations Lead (RLS).
// -------------------------------------------------------------------------------------
import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { isoToLondon } from '../../data/projects';
import { shortDate } from '../../data/sundays';
import { monthLabel } from '../../../supabase/functions/_shared/newsletter.ts';
import {
  parseTestList,
  READER_ROLES,
  startableMonths,
  STARTER_ROLES,
  STATUS_LABEL,
  STATUS_TONE,
  useIssues,
  useRecipientCount,
  useSettings,
} from '../../data/newsletter';
import { hasRole, useMe } from '../../auth/useMe';

const { SectionHeading, Card, Notice, Button, DataTable, Chip, SelectField, Checkbox } = TEC;

export function Issues() {
  const me = useMe();
  const issues = useIssues();
  const nav = useNavigate();
  const [today] = useState(() => isoToLondon(new Date().toISOString()).date);
  const months = startableMonths(today, (issues.data ?? []).map((i) => i.issue_month));
  const [month, setMonth] = useState('');
  const chosen = month || months[0] || '';
  const canStart = hasRole(me.data, ...STARTER_ROLES);
  const canRead = hasRole(me.data, ...READER_ROLES);

  const start = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('start_newsletter_issue', { p_month: chosen });
      if (error) throw error;
      return data as string;
    },
    onSuccess: (id) => nav(`/newsletter/${id}`),
  });

  if (me.isPending) return <p>Loading…</p>;
  if (!canRead)
    return (
      <>
        <SectionHeading eyebrow="Communication" title="The Greatness Brief" rule />
        <Notice tone="info">The newsletter is prepared by its editors and approved by the G-Squad Coordinator and the Resident Pastor.</Notice>
      </>
    );

  return (
    <>
      <SectionHeading eyebrow="Communication" title="The Greatness Brief" rule>
        The monthly newsletter for G-Squad members. Editors write it, Team Leads send their team updates by the 25th, then the
        G-Squad Coordinator and the Resident Pastor approve it before it is emailed.
      </SectionHeading>

      {canStart && months.length > 0 && (
        <Card title="Start an issue" tone="tint">
          <p className="type-caption" style={{ margin: 0 }}>
            Starting an issue asks every Team Lead for a team update (they give it on the issue&apos;s project page).
          </p>
          <div className="tec-fields">
            <SelectField id="ni-month" label="Month" value={chosen} onChange={(e) => setMonth(e.target.value)} options={months.map((m) => ({ value: m, label: monthLabel(m) }))} />
          </div>
          {start.isError && <Notice tone="danger">{friendlyError(start.error)}</Notice>}
          <div>
            <Button variant="primary" disabled={!chosen || start.isPending} onClick={() => start.mutate()}>
              Start the {chosen ? monthLabel(chosen) : ''} issue
            </Button>
          </div>
        </Card>
      )}

      <Card title="Issues">
        {issues.isPending && <p>Loading…</p>}
        {issues.error && <Notice tone="danger">{friendlyError(issues.error)}</Notice>}
        {issues.data && issues.data.length === 0 && <p style={{ margin: 0 }}>No issues yet.</p>}
        {issues.data && issues.data.length > 0 && (
          <DataTable
            columns={[
              { key: 'month', label: 'Issue' },
              { key: 'headline', label: 'Headline' },
              { key: 'status', label: 'Status' },
              { key: 'send', label: 'Send date' },
            ]}
            rows={issues.data.map((i) => ({
              id: i.id,
              month: <Link to={`/newsletter/${i.id}`}>{monthLabel(i.issue_month)}</Link>,
              headline: i.headline ?? '–',
              status: (
                <Chip tone={STATUS_TONE[i.status]}>
                  {STATUS_LABEL[i.status]}
                  {i.status === 'sent' && i.sent_as_test ? ' (test list)' : ''}
                </Chip>
              ),
              send: i.sent_at ? `Sent ${shortDate(i.sent_at.slice(0, 10))}` : i.send_on ? shortDate(i.send_on) : '–',
            }))}
          />
        )}
      </Card>

      {hasRole(me.data, 'gsquad_coordinator', 'operations_lead', 'resident_pastor') && <SendingSettings />}
    </>
  );
}

// The test list and the live switch.
function SendingSettings() {
  const me = useMe();
  const qc = useQueryClient();
  const settings = useSettings();
  const recipients = useRecipientCount();
  const [draft, setDraft] = useState<string | null>(null);
  const [dpia, setDpia] = useState(false);
  const canList = hasRole(me.data, 'gsquad_coordinator', 'operations_lead');
  const isRp = hasRole(me.data, 'resident_pastor');
  const s = settings.data;
  const text = draft ?? (s?.newsletter_test_recipients ?? []).join('\n');
  const parsed = parseTestList(text);

  const save = useMutation({
    mutationFn: async (patch: { newsletter_test_recipients?: string[]; newsletter_live?: boolean }) => {
      const { error } = await supabase.from('church_settings').update(patch).eq('church_id', s!.church_id).select('church_id').single();
      if (error) throw error;
    },
    onSuccess: () => {
      setDraft(null);
      setDpia(false);
      qc.invalidateQueries({ queryKey: ['church_settings'] });
    },
  });

  if (!s) return null;
  return (
    <Card title="Sending">
      {s.newsletter_live ? (
        <Notice tone="ok" title="Sending to members">
          Approved issues go to {recipients.data ?? '…'} G-Squad members at {s.newsletter_send_hour}:00 on their send date.
        </Notice>
      ) : (
        <Notice tone="warn" title="Test list only">
          Until the DPIA is signed, approved issues go only to the test list below, marked TEST. Members receive nothing.
        </Notice>
      )}
      <label className="tec-field" htmlFor="ns-tests">
        <span>Test list (up to 10 addresses, one per line)</span>
        <textarea
          id="ns-tests"
          className="tec-input app-textarea"
          rows={4}
          value={text}
          disabled={!canList}
          onChange={(e) => setDraft(e.target.value)}
        />
      </label>
      {parsed.bad.length > 0 && <Notice tone="danger">Not an email address: {parsed.bad.join(', ')}</Notice>}
      {parsed.list.length > 10 && <Notice tone="danger">Up to 10 test addresses.</Notice>}
      {save.isError && <Notice tone="danger">{friendlyError(save.error)}</Notice>}
      <div className="tec-row" style={{ padding: 0 }}>
        {canList && (
          <Button
            variant="secondary"
            disabled={draft === null || parsed.bad.length > 0 || parsed.list.length > 10 || save.isPending}
            onClick={() => save.mutate({ newsletter_test_recipients: parsed.list })}
          >
            Save test list
          </Button>
        )}
        {s.newsletter_live && (
          <Button variant="secondary" disabled={save.isPending} onClick={() => save.mutate({ newsletter_live: false })}>
            Stop sending to members
          </Button>
        )}
      </div>
      {!s.newsletter_live && isRp && (
        <div className="app-form">
          <Checkbox
            id="ns-dpia"
            label="The DPIA for the newsletter is signed and members' real details are in the app."
            checked={dpia}
            onChange={(e) => setDpia(e.target.checked)}
          />
          <div>
            <Button variant="primary" disabled={!dpia || save.isPending} onClick={() => save.mutate({ newsletter_live: true })}>
              Start sending to members
            </Button>
          </div>
        </div>
      )}
      {!s.newsletter_live && !isRp && (
        <p className="type-caption" style={{ margin: 0 }}>
          Only the Resident Pastor can start sending to members.
        </p>
      )}
    </Card>
  );
}
