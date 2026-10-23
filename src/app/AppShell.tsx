// -------------------------------------------------------------------------------------
// The signed-in layout: the design system's navy SideNav, a top bar with the user, and
// the current page. SideNav renders plain <a href> links; clicks on them are routed inside
// the app (no full page reload) by onNavClick below.
// -------------------------------------------------------------------------------------
import { useState, type MouseEvent } from 'react';
import { Outlet, useLocation, useNavigate } from 'react-router-dom';
import { TEC, tecMark } from '../design-system';
import { useAuth } from '../auth/AuthProvider';
import { NAV } from './navigation';

const { SideNav, Button } = TEC;

export function AppShell() {
  const { session, signOut } = useAuth();
  const location = useLocation();
  const navigate = useNavigate();

  // Mark the current page in the sidebar.
  const groups = NAV.map((g) => ({
    label: g.label,
    items: g.items.map((i) => ({ label: i.label, href: i.path, current: i.path === location.pathname })),
  }));

  // Phones: the sidebar is folded away behind a Menu button (always shown on desktop).
  const [menuOpen, setMenuOpen] = useState(false);

  // Route same-origin link clicks through the router; leave modified clicks
  // (new tab, new window) and external links to the browser.
  function onNavClick(e: MouseEvent<HTMLDivElement>) {
    const link = (e.target as HTMLElement).closest('a');
    if (!link || e.defaultPrevented || e.button !== 0) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const url = new URL(link.href, window.location.href);
    if (url.origin !== window.location.origin) return;
    e.preventDefault();
    setMenuOpen(false); // close the phone menu once a page is chosen
    navigate(url.pathname);
  }

  return (
    <div className="app-shell">
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      {/* Phone-only bar: app name and the Menu button (hidden on desktop by CSS). */}
      <div className="app-phonebar">
        <img src={tecMark} alt="" width={32} height={32} />
        <span className="app-phonebar-title">G-Squad Planner</span>
        <button
          type="button"
          className="app-menu-button"
          aria-expanded={menuOpen}
          aria-controls="app-nav"
          onClick={() => setMenuOpen((open) => !open)}
        >
          {menuOpen ? 'Close' : 'Menu'}
        </button>
      </div>
      <div id="app-nav" className="app-nav" data-open={menuOpen} onClick={onNavClick}>
        <SideNav logo={tecMark} groups={groups} />
      </div>
      <div className="app-main">
        <main className="app-content" id="main" tabIndex={-1}>
          <div className="app-topbar">
            <span />
            <div className="app-user">
              <span className="type-caption">{session?.user.email}</span>
              <Button variant="quiet" size="sm" onClick={() => void signOut()}>
                Sign out
              </Button>
            </div>
          </div>
          <Outlet />
        </main>
      </div>
    </div>
  );
}
