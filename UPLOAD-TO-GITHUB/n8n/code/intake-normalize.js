// GE-01 · Normalize lead
// Turns three different payload shapes into one clean lead:
//   1) Meta Lead Ads webhook  (object:"page", entry[].changes[].value.field_data[])
//   2) Website + referral forms (posted by the Vercel /api/lead endpoint)
//   3) Anything else that has at least a source + email (manual tests)
// One Meta webhook can carry several leads, so this can return several items.

const SOURCES = ['meta', 'website', 'referral'];
const out = [];

const clean = (v, max = 300) => {
  if (v === undefined || v === null) return null;
  const s = String(Array.isArray(v) ? v[0] : v).replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
  return s ? s.slice(0, max) : null;
};

// GHL rejects malformed phone numbers, so we keep only ones we can make E.164.
const phone = (v) => {
  const s = clean(v, 40);
  if (!s) return null;
  const d = s.replace(/\D/g, '');
  if (s.startsWith('+') && d.length >= 8 && d.length <= 15) return '+' + d;
  if (d.length === 10) return '+1' + d;
  if (d.length === 11 && d.startsWith('1')) return '+' + d;
  return null;
};

// GHL also rejects websites that aren't URLs.
const website = (v) => {
  const s = clean(v, 200);
  if (!s) return null;
  if (/^https?:\/\/[^\s.]+\.[^\s]{2,}$/i.test(s)) return s;
  if (/^[\w-]+(\.[\w-]+)+(\/\S*)?$/i.test(s)) return 'https://' + s;
  return null;
};

const splitName = (full) => {
  const parts = (clean(full, 120) || '').split(' ').filter(Boolean);
  return { first: parts[0] || null, last: parts.slice(1).join(' ') || null };
};

const toIso = (t) => {
  if (t === undefined || t === null || t === '') return new Date().toISOString();
  const n = Number(t);
  const d = Number.isFinite(n) ? new Date(n < 1e12 ? n * 1000 : n) : new Date(t);
  return isNaN(d) ? new Date().toISOString() : d.toISOString();
};

function finish(raw, i) {
  const source = clean(raw.source, 20)?.toLowerCase() || null;
  const email = clean(raw.email, 200)?.toLowerCase() || null;
  const lead = {
    source,
    email,
    first_name: clean(raw.first_name, 80),
    last_name: clean(raw.last_name, 80),
    phone: phone(raw.phone),
    company: clean(raw.company, 150),
    website: website(raw.website),
    company_size: clean(raw.company_size, 40),
    monthly_budget: clean(raw.monthly_budget, 40),
    service: clean(raw.service, 80),
    timeline: clean(raw.timeline, 40),
    message: clean(raw.message, 2000),
    opted_in_at: toIso(raw.opted_in_at),
    source_detail: raw.source_detail || {},
    event_key: null,
  };
  // The event key is how repeats are recognised. Real ids first; otherwise email + hour.
  lead.event_key = raw.event_id
    ? `${source}:${raw.event_id}`
    : `${source}:${email}:${lead.opted_in_at.slice(0, 13)}`;

  const errors = [];
  if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) errors.push('missing or invalid email');
  if (!SOURCES.includes(source)) errors.push(`unknown source "${raw.source ?? ''}"`);

  out.push({
    json: { valid: errors.length === 0, errors, lead, raw_preview: JSON.stringify(raw).slice(0, 800) },
    pairedItem: { item: i },
  });
}

$input.all().forEach((item, i) => {
  const body = item.json.body || {};

  if (body.object === 'page' && Array.isArray(body.entry)) {
    let found = 0;
    for (const entry of body.entry) {
      for (const change of entry.changes || []) {
        if (change.field !== 'leadgen') continue;
        found++;
        const v = change.value || {};
        const f = {};
        for (const fd of v.field_data || []) f[fd.name] = Array.isArray(fd.values) ? fd.values[0] : fd.values;
        const name = f.full_name ? splitName(f.full_name) : { first: f.first_name, last: f.last_name };
        finish({
          source: 'meta',
          event_id: v.leadgen_id,
          email: f.email,
          first_name: name.first,
          last_name: name.last,
          phone: f.phone_number || f.phone,
          company: f.company_name || f.company,
          website: f.website,
          company_size: f.company_size,
          monthly_budget: f.monthly_budget,
          service: f.service_needed || f.service,
          timeline: f.timeline,
          message: f.message,
          opted_in_at: v.created_time,
          source_detail: {
            campaign: v.campaign_name || null, ad: v.ad_name || null,
            ad_id: v.ad_id || null, form_id: v.form_id || null, page_id: entry.id || null,
          },
        }, i);
      }
    }
    if (!found) finish({ source: 'meta' }, i); // Meta-shaped but no lead inside → invalid → alert
    return;
  }

  finish({
    source: body.source,
    event_id: body.submission_id,
    email: body.email,
    first_name: body.first_name,
    last_name: body.last_name,
    phone: body.phone,
    company: body.company,
    website: body.website,
    company_size: body.company_size,
    monthly_budget: body.monthly_budget,
    service: body.service,
    timeline: body.timeline,
    message: body.message,
    opted_in_at: body.submitted_at,
    source_detail: {
      page: clean(body.page, 200),
      utm_source: clean(body.utm_source, 100), utm_campaign: clean(body.utm_campaign, 100),
      referrer_name: clean(body.referrer_name, 120), referrer_email: clean(body.referrer_email, 200),
      referrer_company: clean(body.referrer_company, 150),
    },
  }, i);
});

return out;
