// Security review 14 (T02, T04): reading uploaded Excel files safely. The files are built here
// with fflate, so the tests need no fixtures on disk.
import { describe, expect, it } from 'vitest';
import { strToU8, unzipSync, zipSync } from 'fflate';
import { readSpreadsheet } from './readSpreadsheet';
import { prepareXlsx, sheetExtent } from './xlsxSafety';

const CT = `<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>`;
const RELS = `<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`;
const WB = `<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Members" sheetId="1" r:id="rId1"/></sheets></workbook>`;
const WB_RELS = `<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>`;

const cell = (ref: string, v: string) => `<c r="${ref}" t="inlineStr"><is><t>${v}</t></is></c>`;
function sheet(rows: string[]) {
  return `<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>${rows.join('')}</sheetData></worksheet>`;
}
function xlsx(sheetXml: string, extra: Record<string, Uint8Array> = {}) {
  return zipSync({
    '[Content_Types].xml': strToU8(CT),
    '_rels/.rels': strToU8(RELS),
    'xl/workbook.xml': strToU8(WB),
    'xl/_rels/workbook.xml.rels': strToU8(WB_RELS),
    'xl/worksheets/sheet1.xml': strToU8(sheetXml),
    ...extra,
  });
}
const asFile = (bytes: Uint8Array, name = 'members.xlsx') => new File([bytes as BlobPart], name);

describe('reading Excel files (security review 14)', () => {
  it('T02: reads a full-size sheet (over 512 KB of XML) without a web worker', async () => {
    const cols = 'ABCDEFGHIJKLMNOPQRSTUV'.split('');
    const rows = [`<row r="1">${cell('A1', 'First name')}${cell('B1', 'Surname')}${cell('C1', 'Unit')}</row>`];
    for (let r = 2; r <= 600; r++) rows.push(`<row r="${r}">${cols.map((c) => cell(`${c}${r}`, `value ${c}${r}`)).join('')}</row>`);
    const xml = sheet(rows);
    expect(xml.length).toBeGreaterThan(512 * 1024);
    // jsdom has no Worker, like a browser under our CSP: before the fix this rejected.
    const read = await readSpreadsheet(asFile(xlsx(xml)));
    expect(read.length).toBe(600);
    expect(read[0].slice(0, 3)).toEqual(['First name', 'Surname', 'Unit']);
    expect(read[599][21]).toBe('value V600');
  });

  it('T02: the copy handed to the library is stored uncompressed, so no part needs a worker', () => {
    const big = sheet(Array.from({ length: 3000 }, (_, i) => `<row r="${i + 1}">${cell(`A${i + 1}`, 'x'.repeat(200))}</row>`));
    const methods: number[] = [];
    unzipSync(new Uint8Array(prepareXlsx(xlsx(big))), {
      filter: (f) => {
        methods.push(f.compression);
        return false;
      },
    });
    // fflate's browser build unpacks a compressed part of 512 KB or more in a blob: worker,
    // which our CSP blocks; a stored part (method 0) is copied as it is.
    expect(methods).toContain(0);
    expect(methods.every((m) => m === 0)).toBe(true);
  });

  it('T04: refuses a tiny sheet that refers to a far-away cell', () => {
    const xml = sheet([`<row r="1">${cell('A1', 'First name')}</row>`, `<row r="200000">${cell('XFD200000', 'x')}</row>`]);
    expect(() => prepareXlsx(xlsx(xml))).toThrow(/reaches too far/);
    expect(sheetExtent(xml)).toEqual({ rows: 200000, columns: 16384 });
  });

  it('T04: refuses a far-away column even in the first row', () => {
    expect(() => prepareXlsx(xlsx(sheet([`<row r="1">${cell('ZZ1', 'x')}</row>`])))).toThrow(/reaches too far/);
  });

  it('T04: refuses an archive with too many XML parts or too much to unpack', () => {
    const many: Record<string, Uint8Array> = {};
    for (let i = 0; i < 250; i++) many[`xl/extra/part${i}.xml`] = strToU8('<a/>');
    expect(() => prepareXlsx(xlsx(sheet([]), many))).toThrow(/unpacks to more/);
    const big = { 'xl/extra/big.xml': new Uint8Array(21 * 1024 * 1024) };
    expect(() => prepareXlsx(xlsx(sheet([]), big))).toThrow(/unpacks to more/);
  });

  it('says plainly when a file is not a real .xlsx', async () => {
    await expect(readSpreadsheet(asFile(strToU8('not a zip at all')))).rejects.toThrow(/could not be read/);
  });

  it('keeps an ordinary small file as it is', async () => {
    const xml = sheet([`<row r="1">${cell('A1', 'First name')}${cell('B1', 'Surname')}</row>`, `<row r="2">${cell('A2', 'Ada')}${cell('B2', 'Obi')}</row>`]);
    expect(await readSpreadsheet(asFile(xlsx(xml)))).toEqual([
      ['First name', 'Surname'],
      ['Ada', 'Obi'],
    ]);
  });
});
