// GE-01 · Check the AI answer (runs once per lead)
// The model suggests; these rules decide. If the AI is down or answers nonsense,
// the lead becomes "Needs Review" (polite holding reply + owner alert) instead of being lost.

const lead = $('Register lead').item.json;
const res = $json;

let verdict = null;
let problem = null;
try {
  if (res.error) {
    const e = res.error;
    throw new Error(typeof e === 'string' ? e : (e.message || JSON.stringify(e)).slice(0, 200));
  }
  const content = res.choices?.[0]?.message?.content;
  if (!content) throw new Error('empty answer');
  verdict = JSON.parse(content);
} catch (e) {
  problem = 'AI unavailable (' + e.message + ') - please review manually';
}

const STATUSES = ['Qualified', 'Not Qualified', 'Needs Review'];
let status = 'Needs Review';
let score = 50;
let reason = problem || 'AI answer was not valid - please review manually';
let by = 'fallback';

if (verdict && STATUSES.includes(verdict.status) && Number.isFinite(Number(verdict.score))) {
  status = verdict.status;
  score = Math.max(0, Math.min(100, Math.round(Number(verdict.score))));
  reason = String(verdict.reason || '').replace(/\s+/g, ' ').trim().slice(0, 160) || 'No reason given';
  by = 'ai';

  // Guardrails: status and score must agree, and hard business rules always win.
  if (status === 'Qualified' && score < 70) {
    status = 'Needs Review'; reason = `${reason} (score ${score} is below the 70 needed to auto-qualify)`; by = 'ai+rules';
  }
  if (status === 'Not Qualified' && score > 40) {
    status = 'Needs Review'; reason = `${reason} (borderline score ${score}, human check)`; by = 'ai+rules';
  }
  if (status === 'Qualified' && /under\s*\$?\s*1,?000/i.test(lead.monthly_budget || '')) {
    status = 'Needs Review'; reason = `Budget under $1,000 contradicts the AI verdict. ${reason}`; by = 'ai+rules';
  }
}

return {
  json: {
    lead_id: lead.lead_id,
    qualification: status,
    score,
    reason: reason.slice(0, 200),
    qualified_by: by,
  },
};
