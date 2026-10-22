// GE-05 · Owner page
// Opening a link only shows a preview with a Confirm button (email security scanners open links
// automatically - they must never mark someone a no-show). Pressing Confirm POSTs and saves.

const r = $json;
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const color = r.ok === false ? '#c81e1e' : r.preview ? '#1a56db' : '#0e9f6e';
const form = r.preview
  ? `<form method="post" action="">
       <input type="hidden" name="a" value="${esc(r.action)}">
       <input type="hidden" name="t" value="${esc(r.token)}">
       <button type="submit" style="font-size:17px;padding:12px 26px;border:0;border-radius:8px;background:#1a56db;color:#fff;cursor:pointer">Confirm</button>
     </form>`
  : '<p style="color:#52606d">You can close this tab.</p>';

const html = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(r.title)}</title></head>
<body style="font-family:Arial,Helvetica,sans-serif;background:#f5f7fa;margin:0;padding:40px 16px;color:#1f2933">
<div style="max-width:460px;margin:0 auto;background:#fff;border-radius:12px;padding:28px;border-top:6px solid ${color}">
<h1 style="font-size:22px;margin:0 0 12px">${esc(r.title)}</h1>
<p style="font-size:16px;line-height:1.5">${esc(r.message)}</p>
${form}
</div></body></html>`;

return { json: { ...r, html } };
