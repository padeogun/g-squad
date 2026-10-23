// -------------------------------------------------------------------------------------
// All routes. Everything except /sign-in sits behind RequireAuth and inside the AppShell.
// Screens not yet built are generated from navigation.ts as ComingSoon pages.
// -------------------------------------------------------------------------------------
import { createBrowserRouter } from 'react-router-dom';
import { RequireAuth } from '../auth/RequireAuth';
import { AppShell } from './AppShell';
import { PLACEHOLDER_ITEMS } from './navigation';
import { SignIn } from '../pages/SignIn';
import { Home } from '../pages/Home';
import { ComingSoon } from '../pages/ComingSoon';
import { NotFound } from '../pages/NotFound';
import { Leaders } from '../pages/admin/Leaders';

export const router = createBrowserRouter([
  { path: '/sign-in', element: <SignIn /> },
  {
    element: <RequireAuth />,
    children: [
      {
        element: <AppShell />,
        children: [
          { index: true, element: <Home /> },
          { path: '/admin/leaders', element: <Leaders /> },
          ...PLACEHOLDER_ITEMS.map((i) => ({
            path: i.path,
            element: <ComingSoon title={i.label} slice={i.slice} />,
          })),
          { path: '*', element: <NotFound /> },
        ],
      },
    ],
  },
]);
