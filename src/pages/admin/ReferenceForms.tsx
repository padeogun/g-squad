// -------------------------------------------------------------------------------------
// Admin > Reference forms: the index of lists the church keeps (units, roles, stages...).
// Each card links to the generic list-and-edit screen for that form (ReferenceForm.tsx).
// Everyone signed in can read these lists; the card says who looks after each one.
// -------------------------------------------------------------------------------------
import { Link } from 'react-router-dom';
import { TEC } from '../../design-system';
import { FORMS } from '../../data/forms';
import { hasRole, useMe } from '../../auth/useMe';

const { SectionHeading, Card, Chip } = TEC;

export function ReferenceForms() {
  const me = useMe();
  return (
    <>
      <SectionHeading eyebrow="Administration" title="Reference forms" rule>
        The lists the rest of the app uses. Each is kept by one role; everyone else can view it.
      </SectionHeading>
      <div className="app-card-grid">
        {FORMS.map((f) => (
          <Card key={f.id} title={f.title}>
            <p style={{ margin: 0 }}>{f.description}</p>
            <div className="tec-row" style={{ padding: 0 }}>
              <Chip tone={hasRole(me.data, ...f.editRoles) ? 'ok' : 'neutral'}>
                {hasRole(me.data, ...f.editRoles) ? 'You can edit' : `Kept by ${f.owner}`}
              </Chip>
              <Link to={`/admin/forms/${f.id}`}>Open {f.title.toLowerCase()}</Link>
            </div>
          </Card>
        ))}
      </div>
    </>
  );
}
