// POST /api/lab  - the Test Lab (lab.html). Protected by LAB_PASSCODE.
// Sends realistic test events through the REAL n8n webhooks, optionally 3 times at once,
// and reads back a lead's timeline so the hard cases can be proven on screen.
// Bookings are real GHL calendar bookings; the lab can force GE-02 to re-check one 3 times at once.
import crypto from 'node:crypto';
import { rpc, toN8n, isEmail, str } from './_lib.js';

const same = (a, b) => {
  const x = Buffer.from(String(a || '')), y = Buffer.from(String(b || ''));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};
const repeat = async (times, fn) => Promise.allSettled(Array.from({ length: times }, fn));

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ ok: false, error: 'POST only' });
  const b = req.body || {};
  if (!process.env.LAB_PASSCODE || !same(b.passcode, process.env.LAB_PASSCODE)) {
    return res.status(401).json({ ok: false, error: 'Wrong passcode.' });
  }
  const times = b.times === 3 ? 3 : 1;

  try {
    if (b.action === 'timeline') {
      if (!isEmail(b.email)) return res.status(400).json({ ok: false, error: 'Enter the lead email.' });
      return res.json({ ok: true, timeline: await rpc('ge_lead_timeline', { email: b.email }) });
    }

    if (b.action === 'meta_lead') {
      if (!isEmail(b.email)) return res.status(400).json({ ok: false, error: 'Enter an email for the test lead.' });
      // Shaped like a real Meta Lead Ads webhook. One leadgen_id shared by all copies = the same event.
      const field = (name, value) => ({ name, values: [str(value, 2000)] });
      const body = {
        object: 'page',
        entry: [{ id: 'GE-TEST-PAGE', time: Math.floor(Date.now() / 1000), changes: [{ field: 'leadgen', value: {
          leadgen_id: 'lab-' + crypto.randomUUID().slice(0, 13),
          form_id: 'GE-FORM-B2B-1', ad_id: 'GE-AD-17', ad_name: 'GE - Free growth plan', campaign_name: 'GE - B2B Lead Gen Oct',
          created_time: Math.floor(Date.now() / 1000),
          field_data: [field('full_name', b.full_name), field('email', b.email), field('phone_number', b.phone),
            field('company_name', b.company), field('company_size', b.company_size), field('monthly_budget', b.monthly_budget),
            field('service_needed', b.service), field('timeline', b.timeline), field('message', b.message)],
        } }] }],
      };
      const results = await repeat(times, () => toN8n('ge-lead-intake', body));
      return res.json({ ok: true, sent: times, accepted: results.filter((r) => r.status === 'fulfilled').length });
    }

    if (b.action === 'booking_check') {
      // Asks GE-02 to re-read this contact's GHL appointments right now (optionally 3 times at once).
      const contactId = str(b.contact_id, 60);
      if (!contactId) return res.status(400).json({ ok: false, error: 'This lead has no GHL contact yet. Book a call first.' });
      const results = await repeat(times, () => toN8n('ge-booking-check', { contact_id: contactId }));
      return res.json({ ok: true, sent: times, accepted: results.filter((r) => r.status === 'fulfilled').length });
    }
    return res.status(400).json({ ok: false, error: 'Unknown action.' });
  } catch (e) {
    console.error(e);
    return res.status(502).json({ ok: false, error: e.message });
  }
}
