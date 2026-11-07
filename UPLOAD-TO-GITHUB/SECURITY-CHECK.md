# Security check: GE Speed-to-Lead

**Run on 7 November 2026, against the live system. Result: 24 / 24 checks passed.**

The check is automated (a PowerShell script on the builder's laptop). It knows the real values of every key the
project uses (it reads them from the git-ignored `secrets.local.json`, never prints them) and searches for each one,
plus 8 generic key formats, everywhere the public could look.

## Where the keys live (and where they never go)

| Key | Lives only in | Never in |
|---|---|---|
| Supabase `service_role` key | n8n credential "GE Supabase" · Vercel environment variable | browser code, GitHub, workflow JSON |
| OpenAI API key | n8n credential "GE OpenAI" | anywhere else |
| Gmail OAuth (Google client secret + token) | n8n credential "GE Agency Gmail" | anywhere else |
| GHL API key (course key, read-only) | n8n credential "GE GHL API" | anywhere else |
| n8n webhook secret (`x-ge-secret`) | n8n credential "GE Webhook Secret" · Vercel environment variable | browser code, GitHub |
| Test Lab passcode | Vercel environment variable | browser code, GitHub |

The browser only ever talks to `/api/*` server functions on Vercel; those add the keys on the server side.
Exported n8n workflows contain credential **names and ids only**, which are useless without the n8n account.

## 1. Leak scans: no key anywhere public

| Where | Real keys found | Key-shaped strings found* |
|---|---|---|
| Everything published to GitHub (45 files) | 0 | 0 |
| The 6 exported n8n workflows (`n8n/dist/*.json`) | 0 | 0 |
| The live website: 4 pages + 3 scripts + stylesheet a visitor's browser downloads | 0 | 0 |

\* Formats searched: JWT `eyJ…` (Supabase / n8n), GHL `pit-…`, OpenAI `sk-…`, Supabase `sb_secret_…`,
Google `AIza…`, Google OAuth `GOCSPX-…`, GitHub `ghp_…`, Slack `xox…`.

| Check | Result |
|---|---|
| No `*.local.*` or `.env` files in the GitHub upload | PASS |
| `.gitignore` blocks `*.local.json`, `*.local.txt`, `.env*` | PASS |
| Server code (`/api/_lib.js`) cannot be downloaded from the site | PASS (404) |
| `/secrets.local.json`, `/config.local.json`, `/.env`, `/PASTE-THESE.local.txt` are not served | PASS (404 each) |

## 2. Access control: nobody gets in without the secret

| Check | Result |
|---|---|
| n8n lead-intake webhook, no secret header | PASS (403) |
| n8n lead-intake webhook, wrong secret | PASS (403) |
| n8n "send now" webhook, no secret | PASS (403) |
| n8n "booking check" webhook, no secret | PASS (403) |
| Owner action link with a fake token | PASS ("Link not valid", nothing changes) |
| Owner links only preview on open; changes need a Confirm (POST), so email scanners can't trigger them | by design |
| Test Lab with a wrong passcode | PASS (401) |
| Supabase table read without a key | PASS (401) |
| Supabase function call without a key | PASS (401) |
| Supabase row-level security on every table; functions executable by `service_role` only | by design (`supabase/schema.sql`) |

## 3. Privacy and input checks

| Check | Result |
|---|---|
| Public dashboard API returns only per-source totals: no emails, no names | PASS |
| Website form API rejects an invalid email | PASS (400) |
| Bots filling the hidden honeypot field get a fake "OK" and nothing is created | PASS |
| Lead text is passed to the AI as data; "ignore your instructions" attempts are judged on the facts | PASS (live test: Not Qualified 20) |
| All test data is made up; test emails only go to the builder's own Gmail (dot-variants) | by design |

## Not shown in the Loom
n8n credential screens, `secrets.local.json`, `PASTE-THESE.local.txt` and Vercel environment-variable values.
