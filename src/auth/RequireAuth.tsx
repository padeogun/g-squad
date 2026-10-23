// Route guard: shows the sign-in page to anyone without a session.
// This only hides screens; the database's row-level security is what actually protects data.
import { Navigate, Outlet, useLocation } from 'react-router-dom';
import { useAuth } from './AuthProvider';

export function RequireAuth() {
  const { session, loading } = useAuth();
  const location = useLocation();

  if (loading) {
    return (
      <div className="app-loading" role="status">
        Loading…
      </div>
    );
  }
  if (!session) {
    // Remember where they were going, so sign-in can return them there.
    return <Navigate to="/sign-in" replace state={{ from: location.pathname }} />;
  }
  return <Outlet />;
}
