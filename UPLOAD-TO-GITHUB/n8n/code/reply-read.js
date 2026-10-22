// GE-04 · Read email
// Works for both Gmail triggers: INBOX (a lead wrote to us) and SENT (someone on the team wrote to a lead).
// Supabase decides whether it is a real human email and which lead it belongs to.

const AGENCY = '__AGENCY_EMAIL__'.toLowerCase();

const addr = (f) => {
  if (!f) return '';
  if (typeof f === 'string') {
    const m = f.match(/<([^>]+)>/);
    return (m ? m[1] : f).trim().toLowerCase();
  }
  if (Array.isArray(f.value) && f.value[0]) return String(f.value[0].address || '').toLowerCase();
  if (f.text) return addr(f.text);
  return '';
};

return $input.all().map((item, i) => {
  const j = item.json;
  const from = addr(j.from ?? j.From);
  const to = addr(j.to ?? j.To);
  const labels = j.labelIds || (j.labels || []).map((l) => l.id || l.name) || [];
  const direction = labels.includes('SENT') || from === AGENCY ? 'outbound' : 'inbound';
  return {
    json: {
      p: {
        direction,
        from_email: from,
        to_email: to,
        subject: String(j.subject ?? j.Subject ?? ''),
        message_id: String(j.id || j.messageId || ''),
      },
    },
    pairedItem: { item: i },
  };
});
