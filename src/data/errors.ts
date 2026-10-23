// -------------------------------------------------------------------------------------
// Turns database and network errors into sentences a church volunteer can act on.
// The database's own business-rule messages (raised by our triggers) are already plain
// English, so those pass through; technical ones are replaced.
// -------------------------------------------------------------------------------------

interface ErrorLike {
  message?: string;
  code?: string;
  status?: number;
}

export function friendlyError(err: unknown): string {
  const e = (err ?? {}) as ErrorLike;
  const msg = e.message ?? '';
  // 42501 = insufficient privilege: row-level security or one of our guards said no.
  if (e.code === '42501' || /row-level security/i.test(msg)) {
    // Our guards explain themselves ("Only the Resident Pastor can ..."); RLS does not.
    return /row-level security/i.test(msg) || !msg ? "You don't have permission to do that." : msg;
  }
  // 23505 = unique violation, e.g. two units with the same name.
  if (e.code === '23505') return 'That name is already in use. Choose a different one.';
  // 23503 = foreign key: something still uses this record.
  if (e.code === '23503') return "This is still in use elsewhere, so it can't be removed. Switch it off instead.";
  // 23514 = check constraint or a business rule raised by a trigger.
  if (e.code === '23514' || e.code === 'P0001') return msg || 'That value is not allowed.';
  if (/Failed to fetch|NetworkError|Load failed/i.test(msg)) return 'No connection. Check your internet and try again.';
  return msg || 'Something went wrong. Please try again.';
}
