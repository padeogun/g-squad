// -------------------------------------------------------------------------------------
// Runs before the Supabase client starts (imported first in main.tsx).
//
// A Supabase invitation link returns to the app with the session tokens in the address
// (#access_token=...&type=invite). The app only accepts sign-in links that carry a one-time
// code (PKCE), so those tokens are thrown away here, unused: they never sit in the address
// bar, browser history or Netlify logs. The invite has still done its job (it confirmed the
// email address), so the sign-in page then shows a welcome and asks for a sign-in link.
// -------------------------------------------------------------------------------------

const FLAG = 'gsquad-invite-accepted';

const hash = window.location.hash;
if (/[#&](access_token|refresh_token|type=invite|error_description)=/.test(hash)) {
  const invited = /[#&]type=(invite|signup)\b/.test(hash);
  // Drop the fragment without adding a history entry.
  window.history.replaceState(null, '', window.location.pathname + window.location.search);
  try {
    if (invited) sessionStorage.setItem(FLAG, '1');
  } catch {
    // Storage blocked (private mode): the welcome line just won't show.
  }
}

// Read once by the sign-in page; cleared so it shows a single time.
export function takeInviteWelcome(): boolean {
  try {
    const v = sessionStorage.getItem(FLAG) === '1';
    sessionStorage.removeItem(FLAG);
    return v;
  } catch {
    return false;
  }
}
