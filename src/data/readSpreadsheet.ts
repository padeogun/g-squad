// -------------------------------------------------------------------------------------
// Reads an uploaded members file into rows of cells, in the browser (nothing is uploaded until
// the leader presses Import). Uses existing libraries rather than a home-made parser:
//   * Excel (.xlsx): read-excel-file (MIT), which returns real dates for date cells;
//   * CSV: Papa Parse (MIT), which handles quoted commas and line breaks.
// Both are loaded only when a file is chosen, so they stay out of the main bundle.
// -------------------------------------------------------------------------------------
import type { Cell } from './importMembers';

// Large enough for 500 members with every column; small enough to read quickly on a phone.
export const MAX_FILE_BYTES = 2 * 1024 * 1024;

export async function readSpreadsheet(file: File): Promise<Cell[][]> {
  if (file.size > MAX_FILE_BYTES) throw new Error('The file is larger than 2 MB. Split it into smaller files.');
  const name = file.name.toLowerCase();
  if (name.endsWith('.xlsx')) {
    // SECURITY REVIEW 14 (T02, T04): checked and re-packed first, so a hostile file can't
    // freeze the tab and the library never needs a web worker (blocked by our CSP).
    const [{ prepareXlsx }, { readSheet }] = await Promise.all([import('./xlsxSafety'), import('read-excel-file/browser')]);
    const safe = prepareXlsx(new Uint8Array(await file.arrayBuffer()));
    // The first sheet; cells come back as text, numbers, true/false or dates.
    return (await readSheet(safe)) as unknown as Cell[][];
  }
  if (name.endsWith('.csv')) {
    const Papa = (await import('papaparse')).default;
    return new Promise((resolve, reject) =>
      Papa.parse<string[]>(file, {
        skipEmptyLines: 'greedy',
        complete: (r) => resolve(r.data),
        error: (e) => reject(new Error(`The CSV file could not be read: ${e.message}`)),
      }),
    );
  }
  if (name.endsWith('.xls')) throw new Error('Older Excel files (.xls) are not supported. Save it as .xlsx or CSV first.');
  throw new Error('Choose an Excel (.xlsx) or CSV file.');
}
