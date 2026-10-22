# Setup, step by step

Anything you create in a shared tool starts with **GE**.

## 0. Accounts
A **new Gmail** for the made-up agency (here `ge.growth.demo@gmail.com`; your own Gmail is the owner and the test
leads), **Supabase**, **Vercel**, **GitHub** (all free), an **OpenAI** API key, your n8n account, GHL sandbox access.

## 1. Supabase
1. New project `ge-speed-to-lead` → **SQL Editor** → paste all of `supabase/schema.sql` → **Run**.
2. New snippet → paste `supabase/sample-history.sql` → **Run** (shows sample leads per source).
3. **Project Settings → API Keys → Legacy API Keys** → copy the `service_role` key (starts with `eyJ`).

## 2. GoHighLevel (no write key needed)
1. **Pipeline** `GE - Speed to Lead`, stages in this order: New Lead, Needs Review, Qualified, Not Qualified,
   Booked, Rescheduled, Showed, No-Show, Cancelled.
2. **Custom fields** (Contact, single line): GE Ref, GE Source, GE Appt Status, GE Appt Start, GE Appt Timezone,
   GE Reschedule Link, GE Cancel Link.
3. **Form** `GE - Booking Form`: First/Last name, Email, Phone (not required), Organization, and GE Ref + GE Source
   as hidden fields. No captcha element.
4. **Calendar** `GE - Strategy Call` (30 min) → Forms: custom form `GE - Booking Form` → Notifications: no email/SMS
   to the contact; turn off "Allow Google/Outlook/iCloud calendar to send invitation emails".
5. **Workflows** (all free triggers/actions), then **Publish** each:
   - `GE - Booked`: Customer booked appointment (calendar = GE - Strategy Call) → Update contact field
     (GE Appt Status `booked`, GE Appt Start, GE Appt Timezone, GE Reschedule Link, GE Cancel Link from Appointment)
     → Create opportunity (GE pipeline, Booked) → Find opportunity (pipeline GE) → Found: Update opportunity
     (stage Booked, "allow previous stage" ON).
   - `GE - Cancelled` / `GE - Showed` / `GE - No-show`: Appointment status (calendar GE, status = Cancelled /
     Showed / No Show) → Update contact field (GE Appt Status) → Find opportunity → Found: Update opportunity
     (stage Cancelled / Showed / No-Show, "allow previous stage" ON).

## 3. Settings files (on your computer, git-ignored)
- `config.local.json` (from `config.example.json`): Supabase URL, agency + owner emails, GHL calendar id + booking
  link, sub-account timezone, the custom field ids of GE Ref / GE Source / GE Reschedule Link / GE Cancel Link.
- `secrets.local.json` (from `secrets.example.json`): Supabase service_role key, the course GHL key (read-only is
  enough), later the n8n API key.

## 4. Setup script
```
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
```
Saves settings + GHL stage ids into Supabase, generates the shared secrets, builds `n8n/dist/`, and writes the values
to paste into n8n and Vercel into `PASTE-THESE.local.txt`.

## 5. n8n
1. Credentials: `GE OpenAI` (OpenAI key) and `GE Agency Gmail` (Gmail OAuth2: Google Cloud project, Gmail API on,
   OAuth client "Web application" with redirect `https://<your-n8n>/rest/oauth2-credential/callback`, test user =
   the agency Gmail; sign in as the agency Gmail).
2. Settings → n8n API → create a key (All scopes) → add `"N8N_API_KEY"` to secrets.local.json.
3. The other three credentials (`GE Supabase`, `GE Webhook Secret`, `GE GHL API`) and their ids can be created through
   the API; put all 5 credential ids and the GE-99 id in config.local.json.
4. Push everything (credentials linked, GE-99 as error workflow, all active):
   ```
   powershell -ExecutionPolicy Bypass -File scripts\deploy-n8n.ps1 -Activate
   ```
   (Manual alternative: import each file in `n8n/dist` into a new empty workflow, select the GE credential on every
   node with a warning, set Settings → Error workflow → GE-99, activate.)

## 6. Vercel
1. Put the contents of `UPLOAD-TO-GITHUB/` in a GitHub repo (never the `*.local.*` files).
2. Vercel → Add New → Project → import the repo → **Root Directory `web`** → Deploy.
3. Settings → Environment Variables: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `N8N_BASE_URL`,
   `N8N_WEBHOOK_SECRET`, `LAB_PASSCODE` (values in PASTE-THESE.local.txt) → **Redeploy**.
4. Put the Vercel URL in `DASHBOARD_URL` in config.local.json and re-run the setup script.

## 7. Smoke test
1. `/form`: submit a good-fit lead with a dot-variant of your Gmail (`y.ourname@gmail.com`) → booking-link email
   within seconds (check Spam the first time and mark "Not spam").
2. Book through the email link → "You're booked" email within a minute, GHL deal in Booked.
3. Reply to that email → owner gets "Automation stopped", pending reminders are cancelled.
4. `/lab`: passcode + the lead's email → the full timeline of events and emails.

## If something goes wrong
- `[GE] ❌ <workflow> failed at "<step>"` email → open the execution link to see the red step.
- Dashboard health line shows open problems; mark them solved in Supabase → `ge_errors` → `resolved = true`.
- Gmail errors after a week → n8n Credentials → GE Agency Gmail → Reconnect (Google "Testing" mode).
