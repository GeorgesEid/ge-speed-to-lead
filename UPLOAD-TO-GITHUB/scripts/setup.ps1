<#
  One-time setup (safe to re-run). Run AFTER:
    1. supabase/schema.sql was run in the Supabase SQL Editor
    2. the "GE - Speed to Lead" pipeline exists in GHL
    3. config.local.json and secrets.local.json are filled in

  What it does:
    - generates the shared secrets (webhook secret, lab passcode) if missing
    - writes the agency settings into Supabase (ge_settings)
    - reads the GHL pipeline and stores its stage ids in Supabase (ge_ghl_stages)
    - (GHL is only read: deals are moved by the GE workflows inside GHL)
    - builds the n8n workflows (n8n/dist)
    - writes what to paste into n8n and Vercel to PASTE-THESE.local.txt

  Usage:  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cfgPath = Join-Path $root 'config.local.json'
$secPath = Join-Path $root 'secrets.local.json'
foreach ($p in @($cfgPath, $secPath)) { if (-not (Test-Path $p)) { throw "Missing $p (copy the .example.json file and fill it in)" } }
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$sec = Get-Content $secPath -Raw | ConvertFrom-Json

function Say($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Ok($t) { Write-Host "   OK  $t" -ForegroundColor Green }
function Bad($t) { Write-Host "   !!  $t" -ForegroundColor Red }
function NewSecret([int]$n = 32) {
  $b = New-Object byte[] $n; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  ([Convert]::ToBase64String($b) -replace '[+/=]', '').Substring(0, [Math]::Min($n, 40))
}

# ---------------------------------------------------------------- secrets
Say 'Secrets'
$changed = $false
foreach ($k in 'N8N_WEBHOOK_SECRET', 'LAB_PASSCODE') {
  if (-not $sec.$k) {
    $val = if ($k -eq 'LAB_PASSCODE') { 'ge-' + (NewSecret 10).ToLower() } else { NewSecret 32 }
    $sec | Add-Member -NotePropertyName $k -NotePropertyValue $val -Force; $changed = $true; Ok "generated $k"
  } else { Ok "$k already set" }
}
if ($changed) { [IO.File]::WriteAllText($secPath, ($sec | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) }

# ---------------------------------------------------------------- Supabase
Say 'Supabase'
$sb = @{ apikey = $sec.SUPABASE_SERVICE_ROLE_KEY; Authorization = "Bearer $($sec.SUPABASE_SERVICE_ROLE_KEY)" }
try {
  $null = Invoke-RestMethod -Method Post "$($cfg.SUPABASE_URL)/rest/v1/rpc/ge_dashboard" -Headers $sb -ContentType 'application/json' `
    -Body '{"p":{"from":"2026-01-01","to":"2026-01-02"}}'
  Ok 'schema found (ge_dashboard answers)'
} catch { throw "Supabase not ready: run supabase/schema.sql in the SQL Editor first. ($($_.Exception.Message))" }

$base = $cfg.N8N_BASE_URL.TrimEnd('/')
$settings = @(
  @{ key = 'agency_name';   value = $cfg.AGENCY_NAME },
  @{ key = 'sender_name';   value = $cfg.SENDER_NAME },
  @{ key = 'agency_email';  value = $cfg.AGENCY_EMAIL.ToLower() },
  @{ key = 'owner_email';   value = $cfg.OWNER_EMAIL },
  @{ key = 'booking_url';   value = $cfg.BOOKING_URL },
  @{ key = 'dashboard_url'; value = $cfg.DASHBOARD_URL },
  @{ key = 'actions_url';   value = "$base/webhook/ge-owner-action" },
  @{ key = 'calcom_token';  value = $sec.CALCOM_WEBHOOK_TOKEN }
)
$h2 = $sb + @{ Prefer = 'resolution=merge-duplicates,return=minimal' }
Invoke-RestMethod -Method Post "$($cfg.SUPABASE_URL)/rest/v1/ge_settings?on_conflict=key" -Headers $h2 -ContentType 'application/json' `
  -Body (ConvertTo-Json @($settings)) | Out-Null
Ok "saved $($settings.Count) settings"

# ---------------------------------------------------------------- GHL pipeline -> stage ids
Say 'GoHighLevel'
$gh = @{ Authorization = "Bearer $($sec.GHL_API_KEY)"; Version = '2021-07-28' }
$pipes = Invoke-RestMethod "https://services.leadconnectorhq.com/opportunities/pipelines?locationId=$($cfg.GHL_LOCATION_ID)" -Headers $gh
$pipe = $pipes.pipelines | Where-Object { $_.name -eq $cfg.GHL_PIPELINE_NAME } | Select-Object -First 1
if (-not $pipe) { throw "No pipeline named '$($cfg.GHL_PIPELINE_NAME)' in GHL. Create it first (see docs/SETUP.md, step 2)." }
$need = 'New Lead', 'Needs Review', 'Qualified', 'Not Qualified', 'Booked', 'Rescheduled', 'Showed', 'No-Show', 'Cancelled'
$rows = @()
foreach ($s in $need) {
  $st = $pipe.stages | Where-Object { $_.name.Trim() -eq $s } | Select-Object -First 1
  if (-not $st) { Bad "stage '$s' is missing in the GHL pipeline"; continue }
  $rows += @{ stage = $s; pipeline_id = $pipe.id; stage_id = $st.id }
}
if ($rows.Count -ne $need.Count) { throw 'Fix the stage names in GHL (they must match exactly) and run again.' }
Invoke-RestMethod -Method Post "$($cfg.SUPABASE_URL)/rest/v1/ge_ghl_stages?on_conflict=stage" -Headers $h2 -ContentType 'application/json' `
  -Body (ConvertTo-Json @($rows)) | Out-Null
Ok "pipeline '$($pipe.name)' - $($rows.Count) stage ids saved"

# GHL is only READ from n8n (the course key is read-only). GHL moves its own deals with the
# GE workflows on the GE calendar (see docs/SETUP.md, step 2).

# ---------------------------------------------------------------- build workflows
Say 'n8n workflows'
& (Join-Path $PSScriptRoot 'build-workflows.ps1') -Config $cfgPath

# ---------------------------------------------------------------- what to paste where
Say 'Paste these values'
$pasteFile = Join-Path $root 'PASTE-THESE.local.txt'
$paste = @"
 n8n credentials (Settings > Credentials > Add):
   GE Webhook Secret  (Header Auth)   Name: x-ge-secret   Value: $($sec.N8N_WEBHOOK_SECRET)
   GE GHL API         (Header Auth)   Name: Authorization Value: Bearer <the course GHL key, read-only is enough>
   GE Supabase        (Supabase API)  Host: $($cfg.SUPABASE_URL)   Service Role Secret: <service_role key>
   GE OpenAI          (OpenAI)        API key: <your OpenAI key>
   GE Agency Gmail    (Gmail OAuth2)  sign in as $($cfg.AGENCY_EMAIL)


 Vercel > Project > Settings > Environment Variables:
   SUPABASE_URL               $($cfg.SUPABASE_URL)
   SUPABASE_SERVICE_ROLE_KEY  <service_role key>
   N8N_BASE_URL               $base
   N8N_WEBHOOK_SECRET         $($sec.N8N_WEBHOOK_SECRET)
   LAB_PASSCODE               $($sec.LAB_PASSCODE)
"@
[IO.File]::WriteAllText($pasteFile, $paste, (New-Object Text.UTF8Encoding $false))
Ok "written to $pasteFile (open it in Notepad; it is git-ignored and never uploaded)"
