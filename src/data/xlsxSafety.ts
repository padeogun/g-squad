// -------------------------------------------------------------------------------------
// SECURITY REVIEW 14 (T02, T04): checks an Excel (.xlsx) file before read-excel-file sees it,
// and hands it over in a form the library can read without web workers.
//
// An .xlsx file is a zip of XML files. Two problems with passing an uploaded one straight in:
//   * T02: fflate (inside read-excel-file) unpacks any XML file of 512 KB or more in a web
//     worker made from a blob: URL. Our Content Security Policy (script-src 'self', no
//     worker-src) rightly blocks that, so a full 500-member sheet (about 530 KB of XML) could
//     not be read at all. Rather than loosen the policy, we unpack here, synchronously, and
//     pass the library a re-packed copy with no compression, which it reads without workers.
//   * T04: a small, hostile file could freeze or crash the tab. A 5 KB sheet with one cell
//     at XFD200000 made the library build a 200,000 x 16,384 table (it ran out of memory),
//     and a 2 MB zip can declare thousands of XML files. We check the declared sizes before
//     unpacking (fflate never writes more than the declared size into its buffer when unpacking
//     synchronously) and the furthest cell any worksheet refers to.
// Limits are generous for 500 members with every column; a real members file is far smaller.
// -------------------------------------------------------------------------------------
import { unzipSync, zipSync } from 'fflate';

export const XLSX_LIMITS = {
  // XML parts kept (the library ignores everything else, such as pictures).
  maxParts: 200,
  // Total unpacked size of those parts.
  maxUnpackedBytes: 20 * 1024 * 1024,
  // The furthest row and column a worksheet may refer to (column 200 is "GR").
  maxRow: 5000,
  maxColumn: 200,
};

const isXmlPart = (name: string) => name.endsWith('.xml') || name.endsWith('.xml.rels');
const isWorksheet = (name: string) => /^xl\/worksheets\/[^/]+\.xml$/.test(name);

// "A" = 1, "Z" = 26, "AA" = 27 ...; letters only, so the loop is short.
function columnNumber(letters: string): number {
  let n = 0;
  for (const ch of letters.toUpperCase()) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n;
}

// The furthest row and column referred to by any <row r="..."> or <c r="..."> in a sheet.
export function sheetExtent(xml: string): { rows: number; columns: number } {
  let rows = 0;
  let columns = 0;
  const ref = /<(?:[\w-]+:)?(?:c|row)\b[^>]*?\sr\s*=\s*["']([A-Za-z]{0,7})(\d{1,12})["']/g;
  for (let m = ref.exec(xml); m; m = ref.exec(xml)) {
    rows = Math.max(rows, Number(m[2]));
    if (m[1]) columns = Math.max(columns, columnNumber(m[1]));
  }
  return { rows, columns };
}

// Checks the archive and returns an uncompressed copy holding only its XML parts.
export function prepareXlsx(bytes: Uint8Array): ArrayBuffer {
  let parts = 0;
  let total = 0;
  let files: Record<string, Uint8Array>;
  try {
    files = unzipSync(bytes, {
      filter: (f) => {
        if (!isXmlPart(f.name)) return false;
        parts += 1;
        total += f.originalSize;
        if (parts > XLSX_LIMITS.maxParts || total > XLSX_LIMITS.maxUnpackedBytes) throw new TooBig();
        return true;
      },
    });
  } catch (e) {
    if (e instanceof TooBig) throw new Error(TOO_BIG);
    throw new Error('This Excel file could not be read. If it has a password, remove it, or save it again as .xlsx or CSV.');
  }
  const decoder = new TextDecoder();
  for (const [name, data] of Object.entries(files)) {
    if (!isWorksheet(name)) continue;
    const { rows, columns } = sheetExtent(decoder.decode(data));
    if (rows > XLSX_LIMITS.maxRow || columns > XLSX_LIMITS.maxColumn)
      throw new Error(
        'A sheet in this file reaches too far (beyond row 5,000 or column 200). Copy just the members into a new file, or save it as CSV.',
      );
  }
  const out = zipSync(files, { level: 0 });
  return out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength) as ArrayBuffer;
}

class TooBig extends Error {}
const TOO_BIG = 'This Excel file unpacks to more than a members list needs. Copy just the members into a new file, or save it as CSV.';
