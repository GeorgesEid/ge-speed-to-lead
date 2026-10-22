// GE-03 · Write emails
// Every email the system sends is written here - one place to edit the wording.
// Input: the messages Supabase just claimed. Output: one item per email.

const tick = $input.first().json;
const msgs = tick.messages || [];
if (!msgs.length) return [];

const GHL_CALENDARS = 'https://app.gohighlevel.com/v2/location/__GHL_LOCATION_ID__/calendars/view';

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const p = (html) => `<p style="margin:0 0 14px">${html}</p>`;
const btn = (href, label, color = '#1a56db') =>
  `<p style="margin:18px 0"><a href="${esc(href)}" style="display:inline-block;background:${color};color:#ffffff;padding:11px 20px;border-radius:6px;text-decoration:none;font-weight:bold">${esc(label)}</a></p>`;

const when = (b) => {
  if (!b || !b.start_at) return 'your scheduled time';
  const dt = DateTime.fromISO(String(b.start_at), { zone: 'utc' }).setZone(b.tz || 'America/New_York');
  return dt.isValid ? `${dt.toFormat("cccc, LLLL d 'at' h:mm a")} (${dt.offsetNameShort})` : 'your scheduled time';
};

// GHL calendar link, pre-filled. GE Ref + GE Source travel as hidden fields of the booking form, so the
// booking comes back linked to the exact lead. GHL's page turns "+" into a space, so emails with "+"
// are not pre-filled (the lead types it; the GE Ref still links the booking).
const bookingLink = (s, l) => {
  const q = [['first_name', l.first_name], ['last_name', l.last_name], ['ge_ref', l.ref], ['ge_source', l.source]];
  if (l.email && !l.email.includes('+')) q.push(['email', l.email]);
  return `${s.booking_url}?` + q.filter(([, v]) => v).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');
};

const action = (s, a, token) => `${s.actions_url}?a=${a}&t=${token}`;

const layout = (inner, s, footer) =>
  `<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.55;color:#1f2933;max-width:560px">${inner}` +
  `<p style="margin-top:28px;color:#7b8794;font-size:12px">${footer}</p></div>`;

function leadEmail(m) {
  const s = m.settings, l = m.lead, b = m.booking;
  const hi = p(`Hi ${esc(l.first_name || 'there')},`);
  const sign = p(`${esc(s.sender_name)}<br>${esc(s.agency_name)}`);
  const book = btn(bookingLink(s, l), 'Pick a time for your call');
  const manage = !b ? '' : b.reschedule_url
    ? p(`Need to change it? <a href="${esc(b.reschedule_url)}">Reschedule</a>${b.cancel_url ? ` or <a href="${esc(b.cancel_url)}">cancel</a>` : ''}.`)
    : p('Need to change it? Just reply to this email.');
  const video = b && b.video_url ? p(`Video link: <a href="${esc(b.video_url)}">${esc(b.video_url)}</a>`) : '';
  const service = l.service ? ` about ${esc(l.service.toLowerCase())}` : '';

  const T = {
    qualified_booking_link: ['Your strategy call with ' + s.agency_name,
      hi + p(`Thanks for reaching out${service}. From what you shared, it sounds like we can help.`) +
      p('The next step is a free 30-minute strategy call. Pick any time that suits you:') + book +
      p('You will get a confirmation right away and a reminder before the call.') + sign],
    approved_booking_link: ['Next step: your strategy call',
      hi + p('Thanks for your patience. We looked at your details and would love to talk.') +
      p('Pick a time for a free 30-minute strategy call:') + book + sign],
    needs_review_ack: ['Thanks, we got your details',
      hi + p(`Thanks for contacting ${esc(s.agency_name)}${service}.`) +
      p('A strategist is reviewing what you sent and will reply to you personally within one business day.') + sign],
    not_qualified_reply: ['Thanks for reaching out',
      hi + p(`Thank you for thinking of ${esc(s.agency_name)}.`) +
      p('Based on what you shared, we are probably not the right fit right now. We work mostly with B2B companies that invest $3,000 or more a month in growth, and we would rather tell you that honestly than waste your time.') +
      p('If your plans change, just reply to this email and a real person will pick it up.') + sign],
    declined_reply: ['About your enquiry',
      hi + p('Thanks again for your patience while we reviewed your details.') +
      p('We do not think we are the best fit for you right now, and we would rather be honest than take on work we cannot do well.') +
      p('If anything changes, just reply to this email.') + sign],
    book_nudge_1: ['Still up for a quick strategy call?',
      hi + p('Just checking you saw the link for your free strategy call. It takes 30 minutes and you will leave with a clear plan, whether or not we work together.') +
      book + sign],
    book_nudge_2: ['Last note from me',
      hi + p("I don't want to fill your inbox, so this is my last reminder. If growing your pipeline is still on your list, grab a time here:") +
      book + p('If now is not the right time, no problem at all.') + sign],
    booking_confirm: ["You're booked: " + when(b),
      hi + p(`Your strategy call is confirmed for <b>${esc(when(b))}</b>.`) + video +
      p('To get the most out of it, have a rough idea of your monthly marketing budget and your sales goal for the next quarter.') +
      manage + sign],
    reschedule_confirm: ['Your call has moved to ' + when(b),
      hi + p(`No problem, your strategy call is now <b>${esc(when(b))}</b>. The old time is cancelled.`) + video + manage + sign],
    reminder_24h: ['Tomorrow: your strategy call',
      hi + p(`A quick reminder that we are speaking <b>${esc(when(b))}</b>.`) + video + manage + sign],
    reminder_1h: ['Starting in 1 hour',
      hi + p(`Your strategy call starts in about an hour (<b>${esc(when(b))}</b>).`) + video +
      p('See you soon!') + manage + sign],
    cancelled_rebook: ['Your call was cancelled',
      hi + p('Your strategy call has been cancelled. Whenever it suits you, you can pick a new time here:') + book + sign],
    cancel_followup: ['Want to find a new time?',
      hi + p('Following up in case you still want that strategy call. A new time is one click away:') + book + sign],
    noshow_1: ['We missed you today',
      hi + p("We missed you on today's call. No worries, these things happen.") +
      p('Grab another time that works better:') + book + sign],
    noshow_2: ['Still keen to talk?',
      hi + p('Just making sure you saw my last note. Your strategy call is still on the table:') + book + sign],
    noshow_3: ['Closing the loop',
      hi + p("I'll stop following up after this one. If you'd still like to talk, the link below stays open:") + book + sign],
  };

  const t = T[m.template];
  if (!t) throw new Error(`No template called "${m.template}" (message ${m.id})`);
  return {
    subject: `${t[0]} [ref ${l.ref}]`,
    html: layout(t[1], s, `${esc(s.agency_name)} · ref ${esc(l.ref)} · just reply to this email to reach a person`),
  };
}

function ownerEmail(m) {
  const s = m.settings, l = m.lead, b = m.booking, c = m.context || {};
  const whoText = l ? ([l.first_name, l.last_name].filter(Boolean).join(' ') || l.email) + (l.company ? ` (${l.company})` : '') : '';
  const who = esc(whoText);
  const row = (k, v) => v ? `<tr><td style="padding:3px 12px 3px 0;color:#7b8794">${k}</td><td style="padding:3px 0">${esc(v)}</td></tr>` : '';
  const details = l ? `<table style="font-size:14px;margin:8px 0 14px">${
    row('Ref', l.ref) + row('Email', l.email) + row('Phone', l.phone) + row('Source', l.source) +
    row('Company size', l.company_size) + row('Budget', l.monthly_budget) + row('Service', l.service) +
    row('Timeline', l.timeline) + row('Message', l.message) + row('AI score', l.score) + row('Reason', l.reason)}</table>` : '';
  const takeover = l ? btn(action(s, 'takeover', l.owner_token), "I'll handle this lead myself", '#52606d') : '';

  const T = {
    owner_needs_review: [`Needs review: ${whoText}`,
      p(`<b>${who}</b> needs a human decision.`) + details +
      btn(action(s, 'approve', l.owner_token), 'Approve: send booking link', '#0e9f6e') +
      btn(action(s, 'decline', l.owner_token), 'Decline politely', '#c81e1e') + takeover],
    attendance_check: [`Did ${whoText} show up?`,
      p(`Your call with <b>${who}</b> was scheduled for <b>${esc(when(b))}</b>.`) +
      p('Open the appointment in GHL and set its status to <b>Showed</b> or <b>No-show</b>. The deal moves by itself, and no-shows automatically get the re-book emails.') +
      btn(GHL_CALENDARS, 'Open GHL calendar', '#1a56db')],    owner_paused: [`Automation stopped: ${whoText}`,
      p(`All automatic emails to <b>${who}</b> are stopped because <b>${esc(c.reason || l.paused_reason)}</b>.`) +
      p(`${Number(c.cancelled || 0)} scheduled email(s) were cancelled. Please reply to them personally.`) + details],
    owner_alert: [`⚠ ${c.title || 'Problem in Speed-to-Lead'}`,
      p(`<b>${esc(c.title)}</b>`) + p(esc(c.body)) + (l ? details : '') +
      (s.dashboard_url ? p(`<a href="${esc(s.dashboard_url)}">Open the dashboard</a>`) : '')],
  };

  const t = T[m.template];
  if (!t) throw new Error(`No owner template called "${m.template}" (message ${m.id})`);
  return { subject: `[GE] ${t[0]}`, html: layout(t[1], s, 'GE Speed-to-Lead · automatic message to the owner') };
}

return msgs.map((m) => {
  const e = m.to_owner ? ownerEmail(m) : leadEmail(m);
  return { json: { id: m.id, template: m.template, to: m.to_email, subject: e.subject, html: e.html }, pairedItem: { item: 0 } };
});
