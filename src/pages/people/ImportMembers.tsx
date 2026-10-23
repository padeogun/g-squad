// -------------------------------------------------------------------------------------
// Upload members: add many G-Squad members from an Excel or CSV file (decision of 23 Oct 2026).
//   1. Download the template (headings only) and fill it in, or use your own spreadsheet with
//      the same headings.
//   2. Choose the file: it is read and checked here in the browser, and every problem is
//      listed by spreadsheet row. Nothing is sent yet.
//   3. Import: public.import_members saves all rows or none (migration 23). The database
//      decides every row as it does for one member: the G-Squad Coordinator and Operations
//      Lead add to any team, a Team Lead to their own; faith fields only from the Coordinator
//      or the team's Team Lead, through the logged faith function.
// Sample data only until the DPIA is signed (CLAUDE.md).
// -------------------------------------------------------------------------------------
import { useState, type ChangeEvent } from 'react';
import { Link } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { TEC } from '../../design-system';
import { supabase } from '../../lib/supabase';
import { friendlyError } from '../../data/errors';
import { useChurchRoles, useLeadershipStages, useTeciStages, useUnits } from '../../data/reference';
import { buildImport, COLUMNS, MAX_ROWS, serverProblems, templateCsv, type Problem } from '../../data/importMembers';
import { readSpreadsheet } from '../../data/readSpreadsheet';
import { hasRole, ledUnitIds, useMe } from '../../auth/useMe';
import type { Json } from '../../lib/database.types';

const { SectionHeading, Card, Notice, DataTable, Button, Checkbox, StatTile } = TEC;

type Built = ReturnType<typeof buildImport>;

export function ImportMembers() {
  const me = useMe();
  const qc = useQueryClient();
  const units = useUnits();
  const roles = useChurchRoles();
  const stages = useLeadershipStages();
  const teci = useTeciStages();
  const [fileName, setFileName] = useState('');
  const [readError, setReadError] = useState<string | null>(null);
  const [built, setBuilt] = useState<Built | null>(null);
  const [skipExisting, setSkipExisting] = useState(true);

  // Who may upload, and into which units (mirrors the database; it checks every row anyway).
  const isWide = hasRole(me.data, 'gsquad_coordinator', 'operations_lead');
  const led = ledUnitIds(me.data);
  const allowed = isWide || led.length > 0;
  const isCoordinator = hasRole(me.data, 'gsquad_coordinator');
  const refsReady = !!(units.data && roles.data && stages.data && teci.data);

  const save = useMutation({
    mutationFn: async (b: Built) => {
      const { data, error } = await supabase.rpc('import_members', {
        p_rows: b.rows.map(({ display: _display, ...r }) => r) as unknown as Json,
        p_skip_existing: skipExisting,
      });
      if (error) throw error;
      return data as { added: number; skipped: number };
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['people'] });
      qc.invalidateQueries({ queryKey: ['memberships'] });
    },
  });
  // Row problems the database found (the upload was undone), shown like the browser's own.
  const saveError = save.error as { message?: string; details?: string; hint?: string } | null;
  const rowErrors: Problem[] = saveError?.hint === 'import_rows' ? serverProblems(saveError.details) : [];

  async function onFile(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    // Clear the picker so choosing the same (corrected) file again still triggers a fresh read.
    e.target.value = '';
    save.reset();
    setBuilt(null);
    setReadError(null);
    setFileName(file?.name ?? '');
    if (!file || !refsReady) return;
    try {
      const cells = await readSpreadsheet(file);
      setBuilt(
        buildImport(
          cells,
          {
            units: units.data!,
            roles: roles.data!,
            stages: stages.data!,
            teciStages: teci.data!,
          },
          {
            allowedUnitIds: isWide ? null : led,
            canRecordFaith: (unitId) => isCoordinator || led.includes(unitId),
            canSetTeci: hasRole(me.data, 'teci_coordinator', 'operations_lead', 'gsquad_coordinator'),
          },
        ),
      );
    } catch (err) {
      setReadError(err instanceof Error ? err.message : 'The file could not be read.');
    }
  }

  function downloadTemplate() {
    // A byte-order mark so Excel opens the file as UTF-8 (names with accents stay intact).
    const blob = new Blob(['﻿' + templateCsv()], { type: 'text/csv;charset=utf-8' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'g-squad-members-template.csv';
    a.click();
    URL.revokeObjectURL(a.href);
  }

  if (me.isPending) return <p>Loading…</p>;
  if (!allowed)
    return (
      <>
        <SectionHeading eyebrow="People and Teams" title="Upload members" rule />
        <Notice tone="info">Members are uploaded by the G-Squad Coordinator, the Operations Lead or a Team Lead for their own team.</Notice>
      </>
    );

  const problems = built?.problems ?? [];
  const ready = !!built && !built.headingProblem && problems.length === 0 && built.rows.length > 0;

  return (
    <>
      <SectionHeading eyebrow="People and Teams" title="Upload members" rule>
        Add up to {MAX_ROWS} G-Squad members at once from an Excel (.xlsx) or CSV file. Everything is checked before anything is
        saved, and either every row is added or none is.
      </SectionHeading>
      <p style={{ margin: 0 }}>
        <Link to="/members">All members</Link>
      </p>
      <Notice tone="warn" title="Sample data only">
        Use made-up members until the data protection impact assessment (DPIA) is signed.
      </Notice>

      <Card title="1. Prepare the file">
        <p style={{ margin: 0 }}>
          Download the template, or use your own spreadsheet with these headings in the first row. Only First name, Surname and
          Unit are needed{isWide ? '' : ' (Unit can be left empty for your own team)'}; leave anything you don't know empty.
        </p>
        <ul className="app-points">
          <li>Dates are day first (14/03/2025); birthdays and anniversaries are day and month only (14/03).</li>
          <li>Unit, Team role and Leadership stage use the names in Reference forms. TECi stage is its number (1 to 5).</li>
          <li>Yes/No columns take Yes or No. Faith columns are recorded only by the G-Squad Coordinator or the team's Team Lead.</li>
        </ul>
        <details>
          <summary>All {COLUMNS.length} column headings</summary>
          <p className="type-caption">{COLUMNS.map((c) => c.header).join(' · ')}</p>
        </details>
        <div>
          <Button variant="secondary" icon="download" onClick={downloadTemplate}>
            Download template (CSV)
          </Button>
        </div>
      </Card>

      <Card title="2. Choose the file">
        <label className="tec-field" htmlFor="import-file">
          <span>
            Members file <span className="tec-hint">Excel (.xlsx) or CSV, up to 2 MB</span>
          </span>
          <input
            id="import-file"
            className="tec-input app-file-input"
            type="file"
            accept=".xlsx,.csv,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            disabled={!refsReady}
            onChange={onFile}
          />
        </label>
        {!refsReady && <p className="type-caption">Loading units and roles…</p>}
        {/* The picker is cleared after reading (so a corrected file can be chosen again), so say which file was read. */}
        {fileName && !readError && <p className="type-caption" style={{ margin: 0 }}>Read: {fileName}</p>}
        {readError && (
          <Notice tone="danger" title="Couldn't read the file">
            {readError}
          </Notice>
        )}
        {built?.headingProblem && (
          <Notice tone="danger" title={`Couldn't use ${fileName}`}>
            {built.headingProblem}
          </Notice>
        )}
        {built && built.unknown.length > 0 && (
          <Notice tone="info" title="Columns left out">
            These headings aren't in the template, so their data won't be imported: {built.unknown.join(', ')}.
          </Notice>
        )}
      </Card>

      {built && !built.headingProblem && (
        <Card title="3. Check and import">
          <div className="tec-stats" style={{ padding: 0 }}>
            <StatTile label="Ready to add" value={built.rows.length} tone="brand" />
            <StatTile label="Rows to fix" value={problems.length} tone={problems.length ? 'danger' : 'default'} />
          </div>
          {problems.length > 0 && <ProblemList title="Fix these rows in the file, then choose it again" problems={problems} />}
          {built.rows.length > 0 && (
            <DataTable
              caption={problems.length ? 'Rows without problems' : 'Members to add'}
              columns={[
                { key: 'row', label: 'Row', align: 'right' },
                { key: 'name', label: 'Name' },
                { key: 'unit', label: 'Unit' },
                { key: 'role', label: 'Team role' },
                { key: 'email', label: 'Email' },
              ]}
              rows={built.rows.slice(0, 50).map((r) => ({ id: String(r.row), row: String(r.row), ...r.display }))}
            />
          )}
          {built.rows.length > 50 && <p className="type-caption">Showing the first 50 of {built.rows.length}.</p>}
          <Checkbox
            id="import-skip"
            label="Skip people already recorded (same email address) instead of stopping"
            checked={skipExisting}
            onChange={(e) => setSkipExisting(e.target.checked)}
          />
          {rowErrors.length > 0 ? (
            <ProblemList title="Nothing was imported. The database refused these rows" problems={rowErrors} />
          ) : (
            save.isError && (
              <Notice tone="danger" title="Nothing was imported">
                {friendlyError(save.error)}
              </Notice>
            )
          )}
          {save.isSuccess && (
            <Notice tone="ok" title="Imported">
              {save.data.added} member{save.data.added === 1 ? '' : 's'} added
              {save.data.skipped ? `; ${save.data.skipped} already recorded and skipped` : ''}.{' '}
              <Link to="/members">See all members</Link>
            </Notice>
          )}
          <div>
            <Button variant="primary" disabled={!ready || save.isPending || save.isSuccess} onClick={() => built && save.mutate(built)}>
              {save.isPending ? 'Importing…' : `Import ${built.rows.length} member${built.rows.length === 1 ? '' : 's'}`}
            </Button>
          </div>
        </Card>
      )}
    </>
  );
}

// Problems by spreadsheet row, so the leader can find each one in the file.
function ProblemList({ title, problems }: { title: string; problems: Problem[] }) {
  return (
    <Notice tone="danger" title={title}>
      <ul className="app-points" style={{ color: 'inherit' }}>
        {problems.slice(0, 100).map((p) => (
          <li key={p.row}>
            <strong>Row {p.row}:</strong> {p.messages.join('; ')}
          </li>
        ))}
      </ul>
      {problems.length > 100 && <p>…and {problems.length - 100} more rows.</p>}
    </Notice>
  );
}
