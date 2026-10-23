// -------------------------------------------------------------------------------------
// The Sunday Service Grid as a PDF for officiating leaders (spec: "output is the service
// grid PDF"). Built in the browser with jsPDF + jspdf-autotable, loaded only when someone
// presses Download, so the libraries don't slow the rest of the app.
// Colours come from the design system tokens (light theme: print is always light).
// Nothing is sent anywhere: the file is made on the device and saved by the browser.
// -------------------------------------------------------------------------------------
import tokens from '../design-system/tokens.json';
import { endOf, formatDuration, longDate, serviceSpan, toTime, toMinutes } from '../data/sundays';

// Light-theme hex value of a colour token, e.g. tokenHex('navy') -> "#1B4F93".
function tokenHex(name: string): string {
  const t = tokens.color.tokens.find((c) => c.name === name);
  if (!t) throw new Error(`Unknown colour token ${name}`);
  return t.value.light;
}

// "#1B4F93" -> [27, 79, 147] for jsPDF.
function rgb(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

// SECURITY REVIEW FIX Q14: jsPDF's built-in Helvetica only has the Windows-1252 characters.
// One character outside them (common in Yoruba names and words: ọ, ẹ, ṣ, ń) switched jsPDF to
// a two-byte encoding for the WHOLE line, which printed as spaced-out junk, so a leader's name
// or a whole segment became unreadable on the printed grid. Text is now reduced to what the
// font can show: accents the font lacks are dropped (ọ -> o, Ọ́ -> Ó when it exists), and
// anything else becomes "?". (jsPDF already escapes brackets and backslashes, so text cannot
// break out of the PDF string.)
const WIN_ANSI_EXTRA = new Set('€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ');
const printable = (ch: string) => {
  if ([...ch].length !== 1) return false;
  const c = ch.codePointAt(0)!;
  return ch === '\n' || (c >= 0x20 && c <= 0x7e) || (c >= 0xa0 && c <= 0xff) || WIN_ANSI_EXTRA.has(ch);
};
export function pdfSafe(text: string): string {
  // One letter with its accents at a time (ọ́ is o + dot below + acute).
  const letters = text.replace(/\t/g, ' ').normalize('NFD').match(/\P{M}\p{M}*|\p{M}+/gu) ?? [];
  return letters
    .map((letter) => {
      const whole = letter.normalize('NFC');
      if (printable(whole)) return whole;
      // Keep each accent only if the letter with it still exists in the font (ọ́ -> ó, ṣ -> s).
      const [base, ...marks] = [...letter];
      if (!printable(base)) return '?';
      return marks.reduce((kept, m) => (printable((kept + m).normalize('NFC')) ? (kept + m).normalize('NFC') : kept), base);
    })
    .join('');
}

export interface PdfSegment {
  title: string;
  sub_points: string[];
  starts_at: string;
  duration_minutes: number;
  ledBy: string; // already resolved to a name
}

export interface PdfGrid {
  serviceDate: string;
  theme: string | null;
  version: number;
  status: 'draft' | 'finalised' | 'approved';
  segments: PdfSegment[];
  blocks: { name: string; body: string }[];
}

// Builds the PDF and returns it (the caller saves it). Exported for tests.
export async function buildGridPdf(input: PdfGrid) {
  // Q14: every piece of text from the database goes through pdfSafe() before it is printed.
  const grid: PdfGrid = {
    ...input,
    theme: input.theme === null ? null : pdfSafe(input.theme),
    segments: input.segments.map((s) => ({
      ...s,
      title: pdfSafe(s.title),
      sub_points: s.sub_points.map(pdfSafe),
      ledBy: pdfSafe(s.ledBy),
    })),
    blocks: input.blocks.map((b) => ({ name: pdfSafe(b.name), body: pdfSafe(b.body) })),
  };
  const [{ jsPDF }, { default: autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
  const navy = rgb(tokenHex('navy'));
  const ink = rgb(tokenHex('ink'));
  const muted = rgb(tokenHex('ink-muted'));
  const tint = rgb(tokenHex('surface-tint'));

  const doc = new jsPDF({ unit: 'pt', format: 'a4' });
  const pageW = doc.internal.pageSize.getWidth();
  const margin = 40;

  // Header band in TEC navy.
  doc.setFillColor(...navy);
  doc.rect(0, 0, pageW, 78, 'F');
  doc.setTextColor(255, 255, 255);
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(9);
  doc.text('THE ELEVATION CHURCH · MANCHESTER', margin, 28);
  doc.setFontSize(20);
  doc.text('Sunday Service Grid', margin, 54);
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(10);
  doc.text(longDate(grid.serviceDate), pageW - margin, 54, { align: 'right' });

  // Theme, status and timing line.
  const span = serviceSpan(grid.segments);
  doc.setTextColor(...ink);
  let y = 104;
  if (grid.theme) {
    doc.setFont('helvetica', 'bold');
    doc.setFontSize(13);
    doc.text(`Theme: ${grid.theme}`, margin, y);
    y += 18;
  }
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(9);
  doc.setTextColor(...muted);
  const statusText = grid.status === 'approved' ? 'Approved' : grid.status === 'finalised' ? 'Finalised, awaiting approval' : 'Draft';
  doc.text(
    `${statusText} · version ${grid.version}` + (span ? ` · Service ${span.start} – ${span.end} (${formatDuration(span.minutes)})` : ''),
    margin,
    y,
  );

  // The grid itself.
  autoTable(doc, {
    startY: y + 12,
    margin: { left: margin, right: margin },
    head: [['Time', 'Activity', 'Led by', 'Duration']],
    body: grid.segments.map((s) => [
      `${toTime(toMinutes(s.starts_at))} – ${endOf(s)}`,
      [s.title, ...s.sub_points.map((p) => `• ${p}`)].join('\n'),
      s.ledBy,
      `${s.duration_minutes} min`,
    ]),
    styles: { font: 'helvetica', fontSize: 10, textColor: ink, cellPadding: 6, valign: 'top' },
    headStyles: { fillColor: navy, textColor: [255, 255, 255], fontStyle: 'bold' },
    alternateRowStyles: { fillColor: tint },
    columnStyles: { 0: { cellWidth: 82 }, 2: { cellWidth: 120 }, 3: { cellWidth: 60, halign: 'right' } },
  });

  // Attached reusable blocks (e.g. Guest Welcome Script), each under its own heading.
  // jspdf-autotable records where the table ended on the document.
  let by = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 24;
  const pageH = doc.internal.pageSize.getHeight();
  for (const b of grid.blocks) {
    const lines = doc.splitTextToSize(b.body, pageW - margin * 2) as string[];
    if (by + 40 > pageH - margin) {
      doc.addPage();
      by = margin;
    }
    doc.setFont('helvetica', 'bold');
    doc.setFontSize(12);
    doc.setTextColor(...navy);
    doc.text(b.name, margin, by);
    by += 16;
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(10);
    doc.setTextColor(...ink);
    for (const line of lines) {
      if (by > pageH - margin) {
        doc.addPage();
        by = margin;
      }
      doc.text(line, margin, by);
      by += 13;
    }
    by += 12;
  }

  // Footer on every page.
  const pages = doc.getNumberOfPages();
  for (let i = 1; i <= pages; i++) {
    doc.setPage(i);
    doc.setFontSize(8);
    doc.setTextColor(...muted);
    doc.text(`G-Squad Planner · version ${grid.version} · page ${i} of ${pages}`, margin, pageH - 20);
  }
  return doc;
}

// Builds and saves "Service-grid-2026-10-25-v2.pdf".
export async function downloadGridPdf(grid: PdfGrid): Promise<void> {
  const doc = await buildGridPdf(grid);
  doc.save(`Service-grid-${grid.serviceDate}-v${grid.version}.pdf`);
}
