# Loom script (max 3 minutes, English)

**Before recording**
- n8n → Credentials → GE Agency Gmail → **Reconnect** (Google testing mode expires after 7 days).
- Open tabs: Dashboard · `/form` · `/lab` (passcode typed) · Gmail · GHL → Opportunities → GE - Speed to Lead ·
  GHL → Calendars · n8n executions.
- Use fresh dot-variants of your Gmail for each lead (`g.eorgeseid7@`, `ge.orgeseid7@`, …); Gmail ignores dots.
- **Never show** n8n credential screens, `secrets.local.json`, `PASTE-THESE.local.txt` or Vercel environment variables.

| Time | Show | Say (short) |
|---|---|---|
| 0:00-0:15 | Dashboard | "The owner's view: in 10 seconds you see referrals bring the cheapest booked calls, and what each source really costs." |
| 0:15-0:45 | `/form` → submit a good-fit lead → Gmail | "A lead opts in. AI qualifies it with a score and a reason, and the booking link arrives in about 5 seconds." Lab: verdict, score, first reply 0.1 min. |
| 0:45-1:10 | Click the link → book on the GHL calendar → GHL Opportunities | "Booked in GHL. GHL moves the deal itself, and within a minute the confirmation goes out and reminders are scheduled." |
| 1:10-1:30 | Reschedule with the link in the confirmation → Lab | **Hard case: reschedule.** "Same appointment, new time: old reminders cancelled, new ones scheduled." |
| 1:30-1:50 | Lab: tick "3 times" → **Good fit** Meta lead → Lab + inbox | **Hard case: same event 3×.** "Meta sent it three times: seen 3×, exactly one email." |
| 1:50-2:10 | GHL Calendars: set an appointment to **No Show** → GHL deal + Lab | "No-show moves the deal and starts a 3-step re-book sequence." |
| 2:10-2:30 | Reply to a lead email from Gmail → Lab + owner email | **Hard case: human reply.** "The lead replied, so every automated email is cancelled and I'm told to answer personally." |
| 2:30-2:55 | Lab: **Tries to trick the AI** · the `[GE] ❌` alert email | **Hard cases: AI + errors.** "Prompt injection doesn't work. Any failure emails me the exact step and shows on the dashboard." |
| 2:55-3:00 | Dashboard | "Every lead replied in seconds, every source measured separately." |

## Forcing a failure for the Loom (then undo it)
In n8n, open GE-02 → node **Read appointments (GHL)** → change the URL ending `/appointments` to `/appointmentsX`
→ save → wait one minute. You get `[GE] ❌ GE-02 GHL Booking Watcher failed at "Read appointments (GHL)"`.
**Change it back and save right away** (it alerts once per failed run, i.e. every minute).
