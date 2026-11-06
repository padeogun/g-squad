// -------------------------------------------------------------------------------------
// All routes. Everything except /sign-in and /e/<token> (newsletter links) sits behind RequireAuth and inside the AppShell.
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
import { ReferenceForms } from '../pages/admin/ReferenceForms';
import { ReferenceForm } from '../pages/admin/ReferenceForm';
import { Members } from '../pages/people/Members';
import { MemberForm } from '../pages/people/MemberForm';
import { MyUnit } from '../pages/people/MyUnit';
import { Sundays } from '../pages/sunday/Sundays';
import { ServiceGrid } from '../pages/sunday/ServiceGrid';
import { Rota } from '../pages/sunday/Rota';
import { CheckIn } from '../pages/sunday/CheckIn';
import { Capacity } from '../pages/dashboard/Capacity';
import { Teci } from '../pages/people/Teci';
import { ImportMembers } from '../pages/people/ImportMembers';
import { Projects } from '../pages/projects/Projects';
import { NewProject } from '../pages/projects/NewProject';
import { Project } from '../pages/projects/Project';
import { OneToOnes } from '../pages/care/OneToOnes';
import { OneToOneForm } from '../pages/care/OneToOneForm';
import { LeadershipQuestions } from '../pages/care/LeadershipQuestions';
import { Issues } from '../pages/newsletter/Issues';
import { Issue } from '../pages/newsletter/Issue';
import { EmailLink } from '../pages/EmailLink';
import { AuthConfirm } from '../pages/AuthConfirm';

export const router = createBrowserRouter([
  { path: '/sign-in', element: <SignIn /> },
  // Where invitation and sign-in emails land; signs in only when the button is pressed.
  { path: '/auth/confirm', element: <AuthConfirm /> },
  // Slice 6: members' personal newsletter links. Public: members do not sign in.
  { path: '/e/:token', element: <EmailLink /> },
  {
    element: <RequireAuth />,
    children: [
      {
        element: <AppShell />,
        children: [
          { index: true, element: <Home /> },
          { path: '/admin/leaders', element: <Leaders /> },
          { path: '/admin', element: <ReferenceForms /> },
          { path: '/members', element: <Members /> },
          { path: '/members/new', element: <MemberForm /> },
          { path: '/members/import', element: <ImportMembers /> },
          { path: '/members/:id', element: <MemberForm /> },
          { path: '/my-unit', element: <MyUnit /> },
          { path: '/sundays', element: <Sundays /> },
          { path: '/sundays/:gridId', element: <ServiceGrid /> },
          { path: '/rota', element: <Rota /> },
          { path: '/check-in', element: <CheckIn /> },
          { path: '/capacity', element: <Capacity /> },
          { path: '/teci', element: <Teci /> },
          { path: '/projects', element: <Projects /> },
          { path: '/projects/new', element: <NewProject /> },
          { path: '/projects/:id', element: <Project /> },
          { path: '/one-to-ones', element: <OneToOnes /> },
          { path: '/one-to-ones/new', element: <OneToOneForm /> },
          { path: '/one-to-ones/questions', element: <LeadershipQuestions /> },
          { path: '/one-to-ones/:id', element: <OneToOneForm /> },
          { path: '/newsletter', element: <Issues /> },
          { path: '/newsletter/:id', element: <Issue /> },
          { path: '/admin/forms/:formId', element: <ReferenceForm /> },
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
