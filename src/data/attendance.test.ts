// Unit tests for the pure helpers behind event check-in and members' facts.
import { describe, expect, it } from 'vitest';
import { attendanceDays, defaultAttendanceDay, engagementFacts } from './attendance';

describe('attendanceDays', () => {
  it('lists each day of a multi-day event that has come', () => {
    expect(attendanceDays('2026-11-20T18:00:00Z', '2026-11-23T20:00:00Z', '2026-11-22')).toEqual(['2026-11-20', '2026-11-21', '2026-11-22']);
  });
  it('is empty for an event still to come', () => {
    expect(attendanceDays('2026-12-01T18:00:00Z', '2026-12-01T20:00:00Z', '2026-11-27')).toEqual([]);
  });
});

describe('defaultAttendanceDay', () => {
  it('opens on today when the event runs today', () => {
    expect(defaultAttendanceDay(['2026-11-26', '2026-11-27'], '2026-11-27')).toBe('2026-11-27');
  });
  it('opens on the last day so far otherwise', () => {
    expect(defaultAttendanceDay(['2026-11-20', '2026-11-21'], '2026-11-27')).toBe('2026-11-21');
  });
});

describe('engagementFacts', () => {
  it('states facts, never a score', () => {
    expect(
      engagementFacts({
        quarter_start: '2026-10-01',
        events_attended: 4,
        maturity_attended: 2,
        events_served: 1,
        committees: 0,
      }),
    ).toEqual(['Attended 4 events, 2 of them prayer, Bible study or discipleship', 'Served at 1 event']);
  });
  it('mentions committees only when there are any', () => {
    expect(
      engagementFacts({
        quarter_start: '2026-10-01',
        events_attended: 1,
        maturity_attended: 0,
        events_served: 0,
        committees: 1,
      }),
    ).toEqual(['Attended 1 event', 'Served at 0 events', 'On 1 planning committee']);
  });
});
