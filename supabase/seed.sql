-- =====================================================================================
-- G-Squad Planner: starting reference data for TEC Manchester.
-- Run once after the migrations (as the service role or in the SQL editor).
-- Units, purposes and people are imported from the G-Squad 2027 Volunteer Model
-- spreadsheet, not seeded here. Names marked "to be confirmed" are placeholders for the
-- owners of each form to replace.
-- =====================================================================================

do $$
declare
  v_church uuid;
begin
  -- The church and its settings (defaults come from the Volunteer Framework).
  insert into public.churches (name, slug)
  values ('The Elevation Church Manchester', 'tec-manchester')
  on conflict (slug) do nothing;
  select id into v_church from public.churches where slug = 'tec-manchester';

  insert into public.church_settings (church_id, labels)
  values (v_church, '{"g_squad":"G-Squad","unit":"unit","service":"service"}')
  on conflict (church_id) do update set labels = excluded.labels   -- the row may already exist (created with the church)
    where public.church_settings.labels = '{}'::jsonb;   -- SECURITY REVIEW FIX I03: a re-run never overwrites the church's own words

  insert into public.sites (church_id, name, area)
  values (v_church, 'University of Salford', 'Salford M6')
  on conflict do nothing;

  -- TECi Stages: the TECi Coordinator names and describes them.
  insert into public.teci_stages (church_id, stage_no, name)
  select v_church, n, 'TECi Stage ' || n || ' (name to be confirmed)'
  from generate_series(1, 5) n
  on conflict do nothing;

  -- Leadership Stages: the starting set from the spec.
  insert into public.leadership_stages (church_id, sort_order, name) values
    (v_church, 1, 'Spotted'), (v_church, 2, 'Developing'), (v_church, 3, 'Ready'), (v_church, 4, 'Leading')
  on conflict do nothing;

  -- Greatness Community Types from the spec: six interest-based and one location-based.
  insert into public.community_types (church_id, name, category) values
    (v_church, 'Business and Career',        'interest'),
    (v_church, 'Health and Sport',           'interest'),
    (v_church, 'Art and Media',              'interest'),
    (v_church, 'Family and Relationship',    'interest'),
    (v_church, 'Faith and Spirituality',     'interest'),
    (v_church, 'Governance and Politics',    'interest'),
    (v_church, 'Geography or Location Based','location')
  on conflict do nothing;

  -- Projects and Events Types: the workbook's event types plus Sunday services, meetings,
  -- prayer and the newsletter.
  insert into public.project_types (church_id, name, default_level, newsletter_tag) values
    (v_church, 'Sunday Service',  'church', null),
    (v_church, 'In-House',        'church', 'EVENT'),
    (v_church, 'Unit-level',      'unit',   'EVENT'),
    (v_church, 'Themed Sunday',   'church', 'SUNDAY'),
    (v_church, 'Outreach',        'church', 'OUTREACH'),
    (v_church, 'Social',          'church', 'SOCIAL'),
    (v_church, 'Meeting',         'church', 'MEETING'),
    (v_church, 'Prayer',          'church', 'PRAYER'),
    (v_church, 'Newsletter',      'church', null)
  on conflict do nothing;

  -- Reusable blocks for the Sunday Service Grid; the Operations Lead pastes in the wording.
  insert into public.reusable_blocks (church_id, name, body) values
    (v_church, 'After Service Notes',  'To be added by the Operations Lead.'),
    (v_church, 'Guest Welcome Script', 'To be added by the Operations Lead.')
  on conflict do nothing;

  -- Core values (ASHLIE), in TEC's own wording from the G-Squad handbook.
  insert into public.core_values (church_id, letter, name, behaviour, sort_order) values
    (v_church, 'A', 'Accountability', 'We serve responsibly: owning our roles, our actions and our commitments without excuses.', 1),
    (v_church, 'S', 'Service',        'We serve faithfully: showing up consistently for God''s people with a willing heart, every time.', 2),
    (v_church, 'H', 'Humility',       'We serve selflessly: never placing personal ambition above the shared mission of the church.', 3),
    (v_church, 'L', 'Love',           'We serve people genuinely: every interaction reflects the love of Christ, not just politeness.', 4),
    (v_church, 'I', 'Integrity',      'We serve transparently: who we are privately matches how we present ourselves publicly.', 5),
    (v_church, 'E', 'Excellence',     'We serve exceptionally: giving our best because God and His people deserve our best always.', 6)
  on conflict do nothing;
end $$;
