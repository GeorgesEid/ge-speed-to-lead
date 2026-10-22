// GE-02 · Our calendar only (runs once per contact)
// GHL returns times like "2026-10-22 13:30:00" in the sub-account's own timezone.
// We keep only appointments of the GE calendar and convert their times to UTC.

const CALENDAR_ID = '__GHL_CALENDAR_ID__';
const TZ = '__GHL_TIMEZONE__';

const toUtc = (s) => {
  if (!s) return null;
  const str = String(s);
  const dt = /[TZ+]/.test(str.slice(10))
    ? DateTime.fromISO(str, { setZone: true })
    : DateTime.fromFormat(str, 'yyyy-MM-dd HH:mm:ss', { zone: TZ });
  return dt.isValid ? dt.toUTC().toISO() : null;
};

const contact = $('Pick contacts to check').item.json;
const events = ($json.events || [])
  .filter((e) => e.calendarId === CALENDAR_ID)
  .map((e) => ({
    id: e.id,
    status: e.appointmentStatus || e.appoinmentStatus || e.status || '',
    start_at: toUtc(e.startTime),
    end_at: toUtc(e.endTime),
    deleted: e.deleted === true,
  }))
  .filter((e) => e.id && e.start_at);

return { json: { p: { ...contact, tz: TZ, events } } };
