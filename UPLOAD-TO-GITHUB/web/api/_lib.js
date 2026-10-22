// Shared server-side helpers. Files starting with "_" are not exposed as endpoints by Vercel.
// All keys come from Vercel environment variables and never reach the browser.

export async function rpc(fn, p) {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error('Server is missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY');
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p }),
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`Supabase ${fn} answered ${r.status}: ${text.slice(0, 200)}`);
  return JSON.parse(text);
}

// POST to one of our n8n webhooks. Intake + send-now are protected by the x-ge-secret header.
export async function toN8n(path, body, { query = '', secret = true } = {}) {
  const base = process.env.N8N_BASE_URL;
  if (!base) throw new Error('Server is missing N8N_BASE_URL');
  const headers = { 'Content-Type': 'application/json' };
  if (secret) headers['x-ge-secret'] = process.env.N8N_WEBHOOK_SECRET || '';
  const r = await fetch(`${base}/webhook/${path}${query}`, { method: 'POST', headers, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`n8n /${path} answered ${r.status}`);
  return r.status;
}

// Log + email the owner. Never throws (we are usually already handling an error).
export async function alertOwner(source, message, details) {
  try { await rpc('ge_log_error', { source, workflow: 'Vercel', message, details, alert: true }); } catch { /* last resort: Vercel logs */ }
  console.error(`[${source}] ${message}`, details);
}

export const isEmail = (s) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(s || '').trim());
export const str = (v, max = 300) => (v === undefined || v === null ? '' : String(v).trim().slice(0, max));
export const isDate = (s) => /^\d{4}-\d{2}-\d{2}$/.test(String(s || '')) && !isNaN(new Date(s));
