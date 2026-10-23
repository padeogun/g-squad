// Only allow in-app paths ("/something"), never a full or protocol-relative URL, so a
// crafted link can't use sign-in to send someone to another site (open redirect).
// SECURITY REVIEW FIX J05: also refuse any backslash or control character anywhere.
// Browsers strip tabs and newlines from URLs and treat "\" as "/", so "/<tab>/evil.example"
// or "/\evil.example" would otherwise pass the prefix checks and become "//evil.example".
export function safePath(path: string | undefined): string {
  if (!path || !path.startsWith('/') || path.startsWith('//')) return '/';
  // oxlint-disable-next-line no-control-regex -- matching control characters is the point
  if (/[\\\u0000-\u001f\u007f]/.test(path)) return '/';
  return path;
}
