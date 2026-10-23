// SECURITY REVIEW FIX Q14: text printed in the grid PDF must stay readable with the PDF's
// built-in font (Windows-1252 characters only).
import { describe, expect, it } from 'vitest';
import { pdfSafe } from './gridPdf';

describe('pdfSafe', () => {
  it('keeps what the font can print, including the dash, bullet and curly quotes the grid uses', () => {
    expect(pdfSafe('10:00 – 10:25 • “Welcome” · Café (main hall) \\ €5')).toBe('10:00 – 10:25 • “Welcome” · Café (main hall) \\ €5');
    expect(pdfSafe('line one\nline two')).toBe('line one\nline two');
  });

  it('drops only the accents the font lacks from Yoruba text', () => {
    expect(pdfSafe('Olúwadámilọ́lá')).toBe('Olúwadámilólá');
    expect(pdfSafe('Ẹ ṣé o')).toBe('E sé o');
    expect(pdfSafe('Adéọlá Ògúnṣọlá')).toBe('Adéolá Ògúnsolá');
  });

  it('replaces anything else, and turns tabs into spaces', () => {
    expect(pdfSafe('Praise 🙌\tnow')).toBe('Praise ? now');
    expect(pdfSafe('祈祷')).toBe('??');
  });
});
