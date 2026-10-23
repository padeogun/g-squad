-- =====================================================================================
-- G-Squad Planner: 17. Anonymised members leave their units (decision of 23 Oct 2026)
-- Before, anonymising (R8, or an erasure request) wiped the person's details but left their
-- unit memberships live, so a Team Lead still saw "Former member" on the team list.
-- app.anonymise is re-created whole from migration 11 with one addition: every live
-- membership is ended. People already anonymised are tidied up the same way below.
-- =====================================================================================

create or replace function app.anonymise(p_person uuid) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  -- Marker read by app.people_guard() so this one update may set anonymised_at.
  perform set_config('gsquad.anonymising', 'on', true);
  update public.people set
    first_name = 'Former', other_names = null, surname = 'member',
    email = null, area = null, marital_status = null,
    birth_day = null, birth_month = null, anniversary_day = null, anniversary_month = null,
    greatness_community_id = null, available_hours_month = null, preferred_times = '{}',
    newsletter_subscribed = false, celebration_opt_in = false,
    status = 'left', date_left = coalesce(date_left, current_date),
    anonymised_at = now()
  where id = p_person and anonymised_at is null;
  delete from public.person_faith where person_id = p_person;
  delete from public.pastoral_notes where person_id = p_person;
  delete from public.one_to_ones where person_id = p_person;
  delete from public.recognitions where person_id = p_person;   -- ASHLIE: free text about the person
  delete from public.holidays where person_id = p_person;
  delete from public.checkin_flags where person_id = p_person;
  delete from public.email_link_tokens where person_id = p_person;
  update public.community_support_roles set person_id = null where person_id = p_person;
  update public.app_users set person_id = null where person_id = p_person;
  -- Decision of 23 Oct 2026: an anonymised person leaves every unit, so "Former member" no
  -- longer appears on any team list. Serving history (assignments) stays as anonymous counts.
  -- SECURITY REVIEW FIX N02: date the end to when the person left (set just above), not to
  -- today. The nightly job (R8) anonymises people a year or more after they left; ending their
  -- membership "today" would record them as serving long after they had gone (accuracy).
  -- greatest() keeps the end on or after the joining date for oddly entered records.
  update public.unit_memberships m
     set status = 'ended',
         ended_on = greatest(m.joined_on, coalesce((select p.date_left from public.people p where p.id = p_person), current_date))
   where m.person_id = p_person and m.status <> 'ended';
  -- SECURITY REVIEW FIX F14: the free-text override reason can describe the person's
  -- circumstances; wipe it with the rest of their personal details.
  update public.assignments set override_reason = null where person_id = p_person and override_reason is not null;
  perform set_config('gsquad.anonymising', 'off', true);
end $$;
-- Not callable by API roles: reached only through public.anonymise_person() and the nightly job.
revoke all on function app.anonymise(uuid) from public, anon, authenticated;
grant execute on function app.anonymise(uuid) to service_role;

-- Backfill: end the live memberships of anyone already anonymised.
-- SECURITY REVIEW FIX N02: as above, the end date is when the person left, not today.
update public.unit_memberships m
   set status = 'ended', ended_on = greatest(m.joined_on, coalesce(p.date_left, current_date))
  from public.people p
 where p.id = m.person_id and p.anonymised_at is not null and m.status <> 'ended';
