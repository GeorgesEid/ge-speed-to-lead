// GE-03 · Collect GHL stop tags
// Any GHL contact tagged "ge-stop-automation" gets paused before we send anything.
// Matched by email (reading GHL works with the course key; writing goes through the GHL workflow).
// If GHL can't be reached we still send (the other stop rules live in Supabase),
// but the watchdog emails the owner about it once an hour.

const r = $input.first().json;
const failed = Boolean(r.error);
const emails = failed ? [] : (r.contacts || []).map((c) => String(c.email || '').trim().toLowerCase()).filter(Boolean);

return [{
  json: {
    p: {
      stop_emails: emails,
      ghl_check_failed: failed,
      ghl_error: failed ? String(r.error?.message || r.error).slice(0, 300) : null,
      limit: 25,
    },
  },
}];
