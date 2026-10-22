// Website + referral form. One submission id per page load: a double-click or a retry
// sends the same id, so the system treats it as the same event and never double-replies.
(() => {
  const form = document.getElementById('lead-form');
  const msg = document.getElementById('msg');
  const btn = form.querySelector('button[type=submit]');
  const submissionId = (crypto.randomUUID && crypto.randomUUID()) || String(Date.now()) + Math.random().toString(16).slice(2);
  const params = new URLSearchParams(location.search);

  const show = (kind, text) => { msg.className = 'msg ' + kind; msg.textContent = text; };

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const data = Object.fromEntries(new FormData(form).entries());
    if (!data.first_name || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(data.email || '')) {
      return show('err', 'Please add a first name and a valid email address.');
    }
    if (form.dataset.source === 'referral' && !data.referrer_name) return show('err', 'Please tell us your name.');
    Object.assign(data, {
      source: form.dataset.source, submission_id: submissionId, page: location.pathname,
      utm_source: params.get('utm_source') || '', utm_campaign: params.get('utm_campaign') || '',
    });
    btn.disabled = true;
    show('ok', 'Sending…');
    try {
      const r = await fetch('/api/lead', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
      const out = await r.json().catch(() => ({}));
      if (!r.ok || !out.ok) throw new Error(out.error || 'Something went wrong. Please try again.');
      form.querySelectorAll('input, select, textarea').forEach((el) => { el.disabled = true; });
      show('ok', form.dataset.source === 'referral'
        ? 'Thank you! We just emailed them. You can close this page.'
        : 'Thanks! Check your inbox: you will hear from us within a few minutes.');
    } catch (err) {
      btn.disabled = false;
      show('err', err.message);
    }
  });
})();
