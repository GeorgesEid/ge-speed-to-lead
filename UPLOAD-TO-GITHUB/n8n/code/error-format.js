// GE-99 · Describe the error
// Every GE workflow points here (Settings → Error workflow), so no failure is silent.

const j = $input.first().json;
const ex = j.execution || {};
const err = ex.error || j.trigger?.error || {};
const wf = j.workflow?.name || 'Unknown workflow';
const node = ex.lastNodeExecuted || err.node?.name || 'unknown step';
const message = String(err.message || err.description || 'Unknown error').slice(0, 900);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.5;color:#1f2933;max-width:560px">
<p><b>${esc(wf)}</b> failed at step <b>${esc(node)}</b>.</p>
<p style="background:#fdf2f2;border-left:4px solid #c81e1e;padding:10px 12px">${esc(message)}</p>
${ex.url ? `<p><a href="${esc(ex.url)}">Open this execution in n8n</a></p>` : ''}
<p style="color:#7b8794;font-size:12px">Execution ${esc(ex.id || '-')} · mode ${esc(ex.mode || '-')} · also logged in Supabase table ge_errors and shown on the dashboard.</p>
</div>`;

return [{
  json: {
    p: {
      source: 'n8n',
      workflow: wf,
      node,
      message,
      details: { execution_id: ex.id || null, url: ex.url || null, mode: ex.mode || null },
    },
    subject: `[GE] ❌ ${wf} failed at "${node}"`,
    html,
  },
}];
