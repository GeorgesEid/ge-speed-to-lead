// GE Speed-to-Lead dashboard. Gets finished numbers from /api/dashboard (no keys here) and draws them.
(() => {
  const SOURCES = {
    meta: { name: 'Meta Ads', color: 'var(--meta)' },
    website: { name: 'Website', color: 'var(--website)' },
    referral: { name: 'Referrals', color: 'var(--referral)' },
  };
  const TZ = 'America/New_York';
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const money = (n) => (n == null ? '–' : '$' + Math.round(n).toLocaleString('en-US'));
  const pct = (a, b) => (b ? Math.round((a / b) * 100) + '%' : '–');
  const div = (a, b) => (b ? a / b : null);
  const mins = (m) => (m == null ? '–' : m < 1 ? Math.round(m * 60) + ' sec' : (Math.round(m * 10) / 10) + ' min');

  let state = { period: 'this_month', sample: true };
  try { const saved = JSON.parse(localStorage.getItem('ge-dash') || '{}'); state = { ...state, ...saved }; } catch {}

  // ---------- dates (New York time, so "this month" matches the owner's calendar)
  function nyToday() { return new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(new Date()); }
  function range(period) {
    const today = nyToday();
    const [y, m] = today.split('-').map(Number);
    const iso = (d) => d.toISOString().slice(0, 10);
    if (period === 'last_month') return [iso(new Date(Date.UTC(y, m - 2, 1))), iso(new Date(Date.UTC(y, m - 1, 0)))];
    if (period === 'last_90') return [iso(new Date(Date.parse(today + 'T00:00:00Z') - 89 * 864e5)), today];
    return [today.slice(0, 8) + '01', today];
  }
  const fmtDay = (s) => new Date(s + 'T12:00:00Z').toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });

  // ---------- derive every metric once
  function derive(s) {
    return {
      ...s,
      ...SOURCES[s.source],
      cpl: div(s.spend, s.leads),
      cpb: div(s.spend, s.booked),
      cps: div(s.spend, s.showed),
      noShowRate: div(s.no_shows, s.showed + s.no_shows),
    };
  }

  // ---------- hero: the 10-second answer
  function renderHero(rows) {
    const ranked = rows.filter((r) => r.cpb != null).sort((a, b) => a.cpb - b.cpb);
    if (!ranked.length) {
      $('hero').innerHTML = `<div><div class="label">Cheapest booked calls</div>
        <div class="answer">No booked calls yet in this period</div>
        <p>Try “Last 90 days”, or include the sample history.</p></div><div></div>`;
      return;
    }
    const best = ranked[0];
    const worst = ranked[ranked.length - 1];
    const times = worst !== best && best.cpb > 0 ? worst.cpb / best.cpb : null;
    const others = rows.filter((r) => r !== best).map((r) =>
      `<div style="margin:4px 0"><span class="swatch" style="background:${r.color}"></span>${esc(r.name)}: <b>${r.cpb == null ? 'no booked calls' : money(r.cpb)}</b>${r.cpb == null ? '' : ' per booked call'}</div>`).join('');
    $('hero').innerHTML = `
      <div>
        <div class="label">Cheapest booked calls</div>
        <div class="answer"><span class="swatch" style="background:${best.color};width:18px;height:18px"></span>${esc(best.name)}: <span class="num">${money(best.cpb)}</span> <span style="font-size:18px;font-weight:600;color:var(--text-2)">per booked call</span></div>
        <p>${times && times >= 1.15 ? `${esc(best.name)} cost <b>${times.toFixed(1)}× less</b> per booked call than ${esc(worst.name)}.` : 'The sources are close - compare cost per show below.'}
           ${best.booked} booked from ${money(best.spend)} spend.</p>
      </div>
      <div style="font-size:15px">${others}</div>`;
  }

  // ---------- tooltip shared by all bars
  const tip = $('tip');
  function bindTips(root) {
    root.querySelectorAll('[data-tip]').forEach((el) => {
      const show = (x, y) => {
        tip.innerHTML = el.dataset.tip;
        tip.classList.add('on');
        const w = tip.offsetWidth, h = tip.offsetHeight;
        tip.style.left = Math.min(window.innerWidth - w - 8, Math.max(8, x + 12)) + 'px';
        tip.style.top = Math.max(8, y - h - 12) + 'px';
      };
      el.addEventListener('mousemove', (e) => show(e.clientX, e.clientY));
      el.addEventListener('mouseleave', () => tip.classList.remove('on'));
      el.addEventListener('focus', () => { const r = el.getBoundingClientRect(); show(r.right, r.top + 8); });
      el.addEventListener('blur', () => tip.classList.remove('on'));
    });
  }

  // ---------- chart: cost per booked call (sorted, color follows the source)
  function renderCpb(rows) {
    const max = Math.max(...rows.map((r) => r.cpb || 0), 1);
    const sorted = [...rows].sort((a, b) => (a.cpb ?? Infinity) - (b.cpb ?? Infinity));
    $('cpb').innerHTML = sorted.map((r) => {
      if (r.cpb == null) {
        return `<div class="bar-row empty"><div class="name">${esc(r.name)}</div><div class="bar-track"><span class="bar-val">No booked calls yet · ${money(r.spend)} spent</span></div></div>`;
      }
      const w = Math.max(1.5, (r.cpb / max) * 78);
      const t = `<b>${esc(r.name)}</b>${money(r.spend)} spend ÷ ${r.booked} booked = ${money(r.cpb)}<br>Per lead ${money(r.cpl)} · per show ${money(r.cps)}`;
      return `<div class="bar-row"><div class="name">${esc(r.name)}</div>
        <div class="bar-track"><div class="bar" tabindex="0" style="width:${w}%;background:${r.color}" data-tip="${esc(t)}" aria-label="${esc(r.name)} ${money(r.cpb)} per booked call"></div>
        <span class="bar-val">${money(r.cpb)} <small>· ${r.booked} booked</small></span></div></div>`;
    }).join('');
    bindTips($('cpb'));
  }

  // ---------- one card per source
  function renderSources(rows, best) {
    $('sources').innerHTML = rows.map((r) => {
      const steps = [['Leads', r.leads], ['Qualified', r.qualified], ['Booked', r.booked], ['Showed', r.showed]];
      const funnel = steps.map(([k, v], i) => {
        const w = r.leads ? Math.max(1, (v / r.leads) * 70) : 0;
        const conv = i === 0 ? '' : ` <small>${pct(v, steps[i - 1][1])} of ${steps[i - 1][0].toLowerCase()}</small>`;
        const t = `<b>${esc(r.name)} · ${k}</b>${v} ${i ? `(${pct(v, r.leads)} of all leads)` : 'leads'}`;
        return `<div class="f-row"><span>${k}</span><div class="f-track"><div class="f-bar" style="width:${w}%" tabindex="0" data-tip="${esc(t)}"></div><span class="f-val">${v}${conv}</span></div></div>`;
      }).join('');
      const fast = r.median_reply_min != null && r.median_reply_min <= 5;
      const isBest = best && r.source === best.source;
      return `<article class="card src-card" style="--c:${r.color}">
        <h3><span class="swatch" style="background:${r.color}"></span>${esc(r.name)}${isBest ? ' <span class="flag good" title="Cheapest booked calls">✓ cheapest</span>' : ''}</h3>
        <div class="muted">${money(r.spend)} spent in this period</div>
        <div class="funnel" aria-label="${esc(r.name)} funnel">${funnel}</div>
        <div class="stats">
          <div class="stat big"><div class="k">Cost per booked call</div><div class="v">${money(r.cpb)}</div></div>
          <div class="stat big"><div class="k">No-show rate</div><div class="v">${r.noShowRate == null ? '–' : Math.round(r.noShowRate * 100) + '%'} <small>${r.no_shows} of ${r.showed + r.no_shows}</small></div></div>
          <div class="stat"><div class="k">Cost per lead</div><div class="v">${money(r.cpl)}</div></div>
          <div class="stat"><div class="k">Cost per show</div><div class="v">${money(r.cps)}</div></div>
          <div class="stat" style="grid-column:1/-1"><div class="k">Minutes from opt-in to first reply (median)</div>
            <div class="v">${mins(r.median_reply_min)} ${r.median_reply_min == null ? '' : fast
              ? '<span class="flag good">✓ under 5 min</span>' : '<span class="flag bad">⚠ over 5 min</span>'}</div>
            <div class="muted">Slowest ${mins(r.slowest_reply_min)} · ${r.replies_over_5_min} over 5 min${r.not_replied ? ` · <b>${r.not_replied} not replied yet</b>` : ''}</div></div>
        </div>
      </article>`;
    }).join('');
    bindTips($('sources'));
  }

  function renderTable(rows) {
    const line = (label, f) => `<tr><td>${label}</td>${rows.map((r) => `<td>${f(r)}</td>`).join('')}</tr>`;
    $('table').innerHTML = `<thead><tr><th>Metric</th>${rows.map((r) => `<th><span class="swatch" style="background:${r.color}"></span>${esc(r.name)}</th>`).join('')}</tr></thead><tbody>
      ${line('Ad spend', (r) => money(r.spend))}
      ${line('Leads', (r) => r.leads)}
      ${line('Qualified', (r) => `${r.qualified} (${pct(r.qualified, r.leads)})`)}
      ${line('Needs review', (r) => r.needs_review)}
      ${line('Not qualified', (r) => r.not_qualified)}
      ${line('Booked', (r) => `${r.booked} (${pct(r.booked, r.qualified)} of qualified)`)}
      ${line('Showed', (r) => `${r.showed} (${pct(r.showed, r.booked)} of booked)`)}
      ${line('No-shows', (r) => r.no_shows)}
      ${line('No-show rate', (r) => (r.noShowRate == null ? '–' : Math.round(r.noShowRate * 100) + '%'))}
      ${line('Cost per lead', (r) => money(r.cpl))}
      ${line('Cost per booked call', (r) => money(r.cpb))}
      ${line('Cost per show', (r) => money(r.cps))}
      ${line('Median minutes to first reply', (r) => mins(r.median_reply_min))}
      ${line('Slowest first reply', (r) => mins(r.slowest_reply_min))}
      ${line('Not replied yet', (r) => r.not_replied)}
    </tbody>`;
  }

  function renderHealth(h) {
    const problems = (h.errors_7d || 0) + (h.emails_failed || 0) + (h.emails_waiting || 0);
    const pill = $('health');
    pill.innerHTML = problems
      ? `<span class="dot" style="background:var(--critical)"></span>⚠ ${problems} issue${problems > 1 ? 's' : ''} need attention`
      : `<span class="dot" style="background:var(--good)"></span>✓ Automation healthy`;
    const last = h.last_live_lead_at ? new Date(h.last_live_lead_at).toLocaleString('en-US', { timeZone: TZ, dateStyle: 'medium', timeStyle: 'short' }) : 'none yet';
    $('health-detail').innerHTML = `<div class="notice ${problems ? 'bad' : ''}">
      <div>${problems ? '⚠' : '✓'}</div>
      <div><b>System health</b> · ${h.errors_7d} unresolved error${h.errors_7d === 1 ? '' : 's'} in the last 7 days
      · ${h.emails_failed} email${h.emails_failed === 1 ? '' : 's'} failed · ${h.emails_waiting} overdue in the queue
      · last real lead: ${esc(last)}${h.direct_bookings ? ` · ${h.direct_bookings} direct booking(s) without a form, not counted above` : ''}
      ${h.last_error ? `<br><span class="muted">Latest: ${esc(h.last_error)}</span>` : ''}</div></div>`;
  }

  let timer = null;
  async function load() {
    const [from, to] = range(state.period);
    $('range').textContent = `${fmtDay(from)} – ${fmtDay(to)}`;
    document.querySelectorAll('#period button').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.p === state.period)));
    $('sample').checked = state.sample;
    try {
      const r = await fetch(`/api/dashboard?from=${from}&to=${to}&sample=${state.sample ? 1 : 0}`);
      const data = await r.json();
      if (!r.ok) throw new Error(data.error || r.status);
      const rows = data.sources.map((s) => derive({ ...s, spend: Number(s.spend), median_reply_min: s.median_reply_min == null ? null : Number(s.median_reply_min), slowest_reply_min: s.slowest_reply_min == null ? null : Number(s.slowest_reply_min) }));
      const best = rows.filter((x) => x.cpb != null).sort((a, b) => a.cpb - b.cpb)[0];
      renderHero(rows);
      renderCpb(rows);
      renderSources(rows, best);
      renderTable(rows);
      renderHealth(data.health || {});
    } catch (e) {
      $('hero').innerHTML = `<div class="notice bad"><div>⚠</div><div><b>Could not load the numbers.</b> ${esc(e.message)}. It will retry automatically.</div></div>`;
    }
    clearTimeout(timer);
    timer = setTimeout(load, 30000);
  }

  const save = () => { try { localStorage.setItem('ge-dash', JSON.stringify(state)); } catch {} };
  document.querySelectorAll('#period button').forEach((b) => b.addEventListener('click', () => { state.period = b.dataset.p; save(); load(); }));
  $('sample').addEventListener('change', (e) => { state.sample = e.target.checked; save(); load(); });
  load();
})();
