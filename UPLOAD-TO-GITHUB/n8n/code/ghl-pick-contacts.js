// GE-02 · Pick contacts to check
// GHL moves the deals itself (free GHL workflows on the GE calendar). n8n only READS GHL, because
// the course API key is read-only. Each run we check:
//   1. contacts GHL updated in the last 15 minutes that belong to us (GE source / GE Ref field), and
//   2. every contact with a live booking in Supabase (catches reschedules, cancels, showed, no-show).
// The "check now" webhook (Test Lab) checks one contact and records every pass, to prove repeats are harmless.

const FIELD_REF = '__GHL_FIELD_REF__';
const FIELD_SOURCE = '__GHL_FIELD_SOURCE__';
const FIELD_RESCHEDULE = '__GHL_FIELD_RESCHEDULE__';
const FIELD_CANCEL = '__GHL_FIELD_CANCEL__';

const field = (c, id) => ((c.customFields || []).find((f) => f.id === id) || {}).value || '';
const out = new Map();
const add = (id, extra = {}) => {
  if (!id) return;
  out.set(id, { contact_id: id, email: '', name: '', ref: '', reschedule_url: '', cancel_url: '', record_all: false, ...(out.get(id) || {}), ...extra });
};

let manual = null;
try { if ($('Check-now webhook').isExecuted) manual = $('Check-now webhook').first().json.body || {}; } catch (e) { /* schedule run */ }

if (manual) {
  add(String(manual.contact_id || ''), { record_all: true });
} else {
  for (const id of $('Live bookings (Supabase)').first().json.contact_ids || []) add(id);
}

const cutoff = Date.now() - 15 * 60 * 1000;
for (const c of $input.first().json.contacts || []) {
  const mine = String(c.source || '').startsWith('GE') || field(c, FIELD_REF) || field(c, FIELD_SOURCE);
  const recent = new Date(c.dateUpdated || 0).getTime() >= cutoff;
  const details = {
    email: c.email || '',
    name: [c.firstName || c.firstNameLowerCase, c.lastName || c.lastNameLowerCase].filter(Boolean).join(' '),
    ref: field(c, FIELD_REF),
    reschedule_url: field(c, FIELD_RESCHEDULE),
    cancel_url: field(c, FIELD_CANCEL),
  };
  if (out.has(c.id)) add(c.id, details);                 // already on the list: just enrich it
  else if (!manual && mine && recent) add(c.id, details); // new activity on one of our contacts
}

return [...out.values()].map((json) => ({ json }));
