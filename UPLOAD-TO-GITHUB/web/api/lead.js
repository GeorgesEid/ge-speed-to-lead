// POST /api/lead  - used by the website form (form.html) and the referral form (refer.html).
// Adds the secret header and forwards to the n8n intake webhook, so the secret stays on the server.
import { toN8n, alertOwner, isEmail, str } from './_lib.js';

const FIELDS = ['first_name', 'last_name', 'email', 'phone', 'company', 'website', 'company_size',
  'monthly_budget', 'service', 'timeline', 'message', 'referrer_name', 'referrer_email', 'referrer_company',
  'utm_source', 'utm_campaign', 'page'];

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ ok: false, error: 'POST only' });
  const b = req.body || {};

  // Honeypot: real people never fill the hidden "company_url" field. Bots get a fake success.
  if (str(b.company_url)) return res.status(200).json({ ok: true });

  if (!isEmail(b.email)) return res.status(400).json({ ok: false, error: 'Please enter a valid email address.' });
  if (!str(b.first_name)) return res.status(400).json({ ok: false, error: 'Please enter your first name.' });

  const payload = {
    source: b.source === 'referral' ? 'referral' : 'website',
    // Generated once when the page loads: a double-click or a retry sends the SAME id, so n8n sees a repeat.
    submission_id: str(b.submission_id, 80) || crypto.randomUUID(),
    submitted_at: new Date().toISOString(),
  };
  for (const f of FIELDS) payload[f] = str(b[f], f === 'message' ? 2000 : 300);

  try {
    await toN8n('ge-lead-intake', payload);
    return res.status(200).json({ ok: true });
  } catch (e) {
    await alertOwner('website-form', `A ${payload.source} form submission could not reach n8n (${e.message})`,
      { email: payload.email, company: payload.company, submission_id: payload.submission_id });
    return res.status(502).json({ ok: false, error: "We couldn't send that just now. Please try again in a minute." });
  }
}
