<#
  Builds the six importable n8n workflows into n8n/dist/ from:
    - n8n/code/*.js            (the JavaScript of every Code node, readable on its own)
    - config.local.json        (non-secret settings: URLs, emails, ids)
  No keys are ever written into the workflows: n8n credentials hold them.

  Usage:  powershell -ExecutionPolicy Bypass -File scripts\build-workflows.ps1
#>
param([string]$Config = (Join-Path $PSScriptRoot '..\config.local.json'))
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path $Config)) { throw "Missing $Config. Copy config.example.json to config.local.json and fill it in." }
$cfg = Get-Content $Config -Raw -Encoding UTF8 | ConvertFrom-Json

function Sub([string]$s) {
  foreach ($p in $cfg.PSObject.Properties) { if ($p.Name -notlike '_*') { $s = $s.Replace("__$($p.Name)__", [string]$p.Value) } }
  $s
}
function Read-Code([string]$file) { Sub (Get-Content (Join-Path $root "n8n\code\$file") -Raw -Encoding UTF8) }
function Guid-For([string]$text) {
  $md5 = [Security.Cryptography.MD5]::Create()
  ([guid]::new($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).ToString()
}

# ------------------------------------------------------------------ builder primitives
$script:wf = ''; $script:nodes = $null; $script:conns = $null

function Start-Wf([string]$name) {
  $script:wf = $name
  $script:nodes = New-Object System.Collections.ArrayList
  $script:conns = [ordered]@{}
}
function Add-Node([string]$name, [string]$type, $ver, [int]$x, [int]$y, $params, $extra = @{}) {
  $node = [ordered]@{
    parameters  = $params
    id          = (Guid-For "$($script:wf)|$name")
    name        = $name
    type        = $type
    typeVersion = $ver
    position    = @($x, $y)
  }
  foreach ($k in $extra.Keys) { $node[$k] = $extra[$k] }
  [void]$script:nodes.Add($node)
}
function Link([string]$from, [string]$to, [int]$out = 0) {
  if (-not $script:conns.Contains($from)) { $script:conns[$from] = [ordered]@{ main = (New-Object System.Collections.ArrayList) } }
  $main = $script:conns[$from].main
  while ($main.Count -le $out) { [void]$main.Add((New-Object System.Collections.ArrayList)) }
  [void]$main[$out].Add([ordered]@{ node = $to; type = 'main'; index = 0 })
}
function Save-Wf([string]$file, [bool]$isErrorWorkflow = $false) {
  $settings = [ordered]@{ executionOrder = 'v1'; saveDataErrorExecution = 'all'; saveDataSuccessExecution = 'all' }
  if (-not $isErrorWorkflow -and $cfg.ERROR_WORKFLOW_ID) { $settings.errorWorkflow = [string]$cfg.ERROR_WORKFLOW_ID }
  $wfObj = [ordered]@{
    name        = $script:wf
    nodes       = $script:nodes
    connections = $script:conns
    settings    = $settings
    pinData     = @{}
    active      = $false
  }
  $json = $wfObj | ConvertTo-Json -Depth 60
  $null = $json | ConvertFrom-Json   # must parse
  # every connection target must be a real node
  $names = $script:nodes | ForEach-Object { $_.name }
  foreach ($k in $script:conns.Keys) {
    if ($names -notcontains $k) { throw "$($script:wf): connection from unknown node '$k'" }
    foreach ($outArr in $script:conns[$k].main) { foreach ($c in $outArr) { if ($names -notcontains $c.node) { throw "$($script:wf): link to unknown node '$($c.node)'" } } }
  }
  $path = Join-Path $root "n8n\dist\$file"
  [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $false))
  Write-Host ("  built {0,-34} {1,2} nodes" -f $file, $script:nodes.Count)
}

# ------------------------------------------------------------------ credentials (matched by name in n8n)
function Cred([string]$type, [string]$name, [string]$cfgKey) {
  $c = [ordered]@{}; $c[$type] = [ordered]@{ id = [string]$cfg.$cfgKey; name = $name }; $c
}
$CRED_SUPABASE = Cred 'supabaseApi'    'GE Supabase'        'CRED_SUPABASE_ID'
$CRED_GHL      = Cred 'httpHeaderAuth' 'GE GHL API'         'CRED_GHL_ID'
$CRED_SECRET   = Cred 'httpHeaderAuth' 'GE Webhook Secret'  'CRED_SECRET_ID'
$CRED_OPENAI   = Cred 'openAiApi'      'GE OpenAI'          'CRED_OPENAI_ID'
$CRED_GMAIL    = Cred 'gmailOAuth2'    'GE Agency Gmail'    'CRED_GMAIL_ID'

$RETRY = @{ retryOnFail = $true; maxTries = 3; waitBetweenTries = 2000 }

# ------------------------------------------------------------------ node helpers
function Add-Rpc([string]$name, [string]$fn, [string]$bodyExpr, [int]$x, [int]$y, $extra = @{}) {
  $e = @{ credentials = $CRED_SUPABASE } + $RETRY
  foreach ($k in $extra.Keys) { $e[$k] = $extra[$k] }
  Add-Node $name 'n8n-nodes-base.httpRequest' 4.2 $x $y ([ordered]@{
      method = 'POST'; url = (Sub "__SUPABASE_URL__/rest/v1/rpc/$fn")
      authentication = 'predefinedCredentialType'; nodeCredentialType = 'supabaseApi'
      sendBody = $true; specifyBody = 'json'; jsonBody = $bodyExpr; options = @{}
    }) $e
}
function Add-Code([string]$name, [string]$file, [int]$x, [int]$y, [bool]$eachItem = $false) {
  $p = [ordered]@{}
  if ($eachItem) { $p.mode = 'runOnceForEachItem' }
  $p.jsCode = Read-Code $file
  Add-Node $name 'n8n-nodes-base.code' 2 $x $y $p
}
function Add-If([string]$name, [string]$boolExpr, [int]$x, [int]$y) {
  Add-Node $name 'n8n-nodes-base.if' 2 $x $y ([ordered]@{
      conditions = [ordered]@{
        options    = [ordered]@{ caseSensitive = $true; leftValue = ''; typeValidation = 'loose' }
        conditions = @([ordered]@{
            id = (Guid-For "$($script:wf)|$name|cond"); leftValue = $boolExpr; rightValue = $true
            operator = [ordered]@{ type = 'boolean'; operation = 'true'; singleValue = $true }
          })
        combinator = 'and'
      }
      options = @{}
    })
}
function Add-Ghl([string]$name, [string]$url, [string]$bodyExpr, [int]$x, [int]$y, $extra = @{}) {
  $e = @{ credentials = $CRED_GHL } + $RETRY
  foreach ($k in $extra.Keys) { $e[$k] = $extra[$k] }
  Add-Node $name 'n8n-nodes-base.httpRequest' 4.2 $x $y ([ordered]@{
      method = 'POST'; url = $url
      authentication = 'genericCredentialType'; genericAuthType = 'httpHeaderAuth'
      sendHeaders = $true; headerParameters = [ordered]@{ parameters = @([ordered]@{ name = 'Version'; value = '2021-07-28' }) }
      sendBody = $true; specifyBody = 'json'; jsonBody = $bodyExpr; options = @{}
    }) $e
}
function Add-Gmail([string]$name, [string]$to, [string]$subject, [string]$html, [int]$x, [int]$y, $extra = @{}) {
  $e = @{ credentials = $CRED_GMAIL }
  foreach ($k in $extra.Keys) { $e[$k] = $extra[$k] }
  Add-Node $name 'n8n-nodes-base.gmail' 2.1 $x $y ([ordered]@{
      resource = 'message'; operation = 'send'
      sendTo = $to; subject = $subject; emailType = 'html'; message = $html
      options = [ordered]@{ appendAttribution = $false; senderName = (Sub '__SENDER_NAME__') }
    }) $e
}
function Add-Webhook([string]$name, [string]$method, [string]$path, [int]$x, [int]$y, [bool]$secret, [string]$responseMode = 'onReceived') {
  $p = [ordered]@{ httpMethod = $method; path = $path }
  if ($secret) { $p.authentication = 'headerAuth' }
  if ($responseMode -ne 'onReceived') { $p.responseMode = $responseMode }
  $p.options = @{}
  $e = @{ webhookId = (Guid-For "$($script:wf)|$name|hook") }
  if ($secret) { $e.credentials = $CRED_SECRET }
  Add-Node $name 'n8n-nodes-base.webhook' 2 $x $y $p $e
}

# The same tail in GE-01/02/04/05: wake the sender, then mirror the lead into GHL.
# The tail shared by GE-01/04/05: wake the sender so emails go out in seconds.
# (No GHL writes from n8n: the course key is read-only. GHL moves its own deals with free GHL
#  workflows on the GE calendar, and GE-02 reads GHL to keep Supabase in step.)
function Add-GhlTail([string]$from, [int]$x, [int]$y) {
  Add-Node 'Send emails now' 'n8n-nodes-base.httpRequest' 4.2 $x $y ([ordered]@{
      method = 'POST'; url = (Sub '__N8N_BASE_URL__/webhook/ge-send-now')
      authentication = 'genericCredentialType'; genericAuthType = 'httpHeaderAuth'
      sendBody = $true; specifyBody = 'json'; jsonBody = '{}'; options = [ordered]@{ timeout = 10000 }
    }) @{ credentials = $CRED_SECRET; executeOnce = $true; onError = 'continueRegularOutput'
          notes = 'Wakes GE-03 so emails go out in seconds. If this fails, GE-03 still sends within 1 minute.' }
  Link $from 'Send emails now'
}

New-Item -ItemType Directory -Force (Join-Path $root 'n8n\dist') | Out-Null
Write-Host 'Building n8n workflows...'

# ================================================================== GE-01 Lead Intake
Start-Wf 'GE-01 Lead Intake'
Add-Webhook 'Lead webhook' 'POST' 'ge-lead-intake' 0 300 $true
Add-Code 'Normalize lead' 'intake-normalize.js' 220 300
Add-If 'Valid lead?' '={{ $json.valid === true }}' 440 300
Add-Rpc 'Register lead' 'ge_intake' '={{ JSON.stringify({ p: $json.lead }) }}' 660 200
Add-If 'Needs AI verdict?' '={{ $json.needs_qualification === true }}' 880 200
Add-Code 'Build AI request' 'intake-build-ai.js' 1100 80 $true
Add-Node 'AI qualify (OpenAI)' 'n8n-nodes-base.httpRequest' 4.2 1320 80 ([ordered]@{
    method = 'POST'; url = 'https://api.openai.com/v1/chat/completions'
    authentication = 'predefinedCredentialType'; nodeCredentialType = 'openAiApi'
    sendBody = $true; specifyBody = 'json'; jsonBody = '={{ JSON.stringify($json.body) }}'
    options = [ordered]@{ timeout = 30000 }
  }) (@{ credentials = $CRED_OPENAI; onError = 'continueRegularOutput'; retryOnFail = $true; maxTries = 3; waitBetweenTries = 3000
         notes = 'If OpenAI fails 3 times the next step marks the lead Needs Review, so it still gets a reply and the owner is alerted.' })
Add-Code 'Check AI answer' 'intake-check-ai.js' 1540 80 $true
Add-Rpc 'Save qualification' 'ge_set_qualification' '={{ JSON.stringify({ p: $json }) }}' 1760 200
Add-GhlTail 'Save qualification' 1980 200
Add-Rpc 'Log invalid lead' 'ge_log_error' `
  "={{ JSON.stringify({ p: { source: 'intake', workflow: 'GE-01 Lead Intake', node: 'Normalize lead', message: 'Lead rejected: ' + `$json.errors.join(', '), details: { raw: `$json.raw_preview } } }) }}" 660 460
Add-Gmail 'Alert owner: invalid lead' (Sub '__OWNER_EMAIL__') `
  "=[GE] ALERT: A lead was rejected: {{ `$('Normalize lead').item.json.errors.join(', ') }}" `
  "=<p>A submission reached the intake webhook but could not be used: <b>{{ `$('Normalize lead').item.json.errors.join(', ') }}</b>.</p><p>What arrived:</p><pre style=`"white-space:pre-wrap;font-size:12px`">{{ `$('Normalize lead').item.json.raw_preview }}</pre><p>It is logged in Supabase (ge_errors). If this was a real person, contact them manually.</p>" 880 460
Link 'Lead webhook' 'Normalize lead'
Link 'Normalize lead' 'Valid lead?'
Link 'Valid lead?' 'Register lead' 0
Link 'Valid lead?' 'Log invalid lead' 1
Link 'Log invalid lead' 'Alert owner: invalid lead'
Link 'Register lead' 'Needs AI verdict?'
Link 'Needs AI verdict?' 'Build AI request' 0
Link 'Needs AI verdict?' 'Save qualification' 1
Link 'Build AI request' 'AI qualify (OpenAI)'
Link 'AI qualify (OpenAI)' 'Check AI answer'
Link 'Check AI answer' 'Save qualification'
Save-Wf 'GE-01-lead-intake.json'

# ================================================================== GE-02 GHL Booking Watcher
Start-Wf 'GE-02 GHL Booking Watcher'
Add-Node 'Every minute' 'n8n-nodes-base.scheduleTrigger' 1.2 0 200 ([ordered]@{
    rule = [ordered]@{ interval = @([ordered]@{ field = 'minutes'; minutesInterval = 1 }) } })
Add-Webhook 'Check-now webhook' 'POST' 'ge-booking-check' 0 420 $true
Add-Rpc 'Live bookings (Supabase)' 'ge_ghl_watchlist' '={{ JSON.stringify({ p: {} }) }}' 220 300 @{ executeOnce = $true }
Add-Ghl 'Recently updated GHL contacts' 'https://services.leadconnectorhq.com/contacts/search' `
  (Sub "={{ JSON.stringify({ locationId: '__GHL_LOCATION_ID__', page: 1, pageLimit: 30, sort: [{ field: 'dateUpdated', direction: 'desc' }] }) }}") 440 300 `
  @{ executeOnce = $true; notes = 'Read-only GHL call: the 30 most recently updated contacts.' }
Add-Code 'Pick contacts to check' 'ghl-pick-contacts.js' 660 300
Add-Node 'Read appointments (GHL)' 'n8n-nodes-base.httpRequest' 4.2 880 300 ([ordered]@{
    method = 'GET'; url = '=https://services.leadconnectorhq.com/contacts/{{ $json.contact_id }}/appointments'
    authentication = 'genericCredentialType'; genericAuthType = 'httpHeaderAuth'
    sendHeaders = $true; headerParameters = [ordered]@{ parameters = @([ordered]@{ name = 'Version'; value = '2021-07-28' }) }
    options = @{}
  }) (@{ credentials = $CRED_GHL } + $RETRY)
Add-Code 'Our calendar only' 'ghl-appts-read.js' 1100 300 $true
Add-Rpc 'Sync booking state' 'ge_ghl_appt_sync' '={{ JSON.stringify({ p: $json.p }) }}' 1320 300 `
  @{ notes = 'Compares GHL appointments with Supabase: new = booked, new time = rescheduled, cancelled / showed / noshow. Same state again = no change.' }
Add-If 'Anything changed?' '={{ Number($json.changed) > 0 }}' 1540 300
Add-GhlTail 'Anything changed?' 1760 300
Link 'Every minute' 'Live bookings (Supabase)'
Link 'Check-now webhook' 'Live bookings (Supabase)'
Link 'Live bookings (Supabase)' 'Recently updated GHL contacts'
Link 'Recently updated GHL contacts' 'Pick contacts to check'
Link 'Pick contacts to check' 'Read appointments (GHL)'
Link 'Read appointments (GHL)' 'Our calendar only'
Link 'Our calendar only' 'Sync booking state'
Link 'Sync booking state' 'Anything changed?'
Save-Wf 'GE-02-ghl-booking-watcher.json'

# ================================================================== GE-03 Email Sender + Watchdog
Start-Wf 'GE-03 Email Sender + Watchdog'
Add-Node 'Every minute' 'n8n-nodes-base.scheduleTrigger' 1.2 0 200 ([ordered]@{
    rule = [ordered]@{ interval = @([ordered]@{ field = 'minutes'; minutesInterval = 1 }) } })
Add-Webhook 'Send-now webhook' 'POST' 'ge-send-now' 0 420 $true
Add-Ghl 'GHL: contacts with stop tag' 'https://services.leadconnectorhq.com/contacts/search' `
  (Sub "={{ JSON.stringify({ locationId: '__GHL_LOCATION_ID__', page: 1, pageLimit: 100, filters: [{ field: 'tags', operator: 'eq', value: 'ge-stop-automation' }] }) }}") 240 300 `
  @{ onError = 'continueRegularOutput'; executeOnce = $true; maxTries = 2 }
Add-Code 'Collect stop tags' 'sender-stop-tags.js' 460 300
Add-Rpc 'Claim due emails' 'ge_sender_tick' '={{ JSON.stringify({ p: $json.p }) }}' 680 300 `
  @{ notes = 'Applies stop tags, runs the watchdog, and atomically claims due emails (FOR UPDATE SKIP LOCKED), so two runs can never send the same email.' }
Add-Code 'Write emails' 'sender-render.js' 900 300
Add-Gmail 'Send email (Gmail)' '={{ $json.to }}' '={{ $json.subject }}' '={{ $json.html }}' 1120 300 `
  @{ onError = 'continueErrorOutput' }
Add-Rpc 'Mark sent' 'ge_mark_sent' `
  "={{ JSON.stringify({ p: { id: `$('Write emails').item.json.id, provider_message_id: `$json.id || '' } }) }}" 1340 200
Add-Rpc 'Mark failed (retry later)' 'ge_mark_failed' `
  "={{ JSON.stringify({ p: { id: `$('Write emails').item.json.id, error: typeof `$json.error === 'string' ? `$json.error : JSON.stringify(`$json.error || 'Gmail send failed') } }) }}" 1340 420
Link 'Every minute' 'GHL: contacts with stop tag'
Link 'Send-now webhook' 'GHL: contacts with stop tag'
Link 'GHL: contacts with stop tag' 'Collect stop tags'
Link 'Collect stop tags' 'Claim due emails'
Link 'Claim due emails' 'Write emails'
Link 'Write emails' 'Send email (Gmail)'
Link 'Send email (Gmail)' 'Mark sent' 0
Link 'Send email (Gmail)' 'Mark failed (retry later)' 1
Save-Wf 'GE-03-email-sender.json'

# ================================================================== GE-04 Human Reply Detector
Start-Wf 'GE-04 Human Reply Detector'
foreach ($t in @(@{ n = 'Gmail: new email in inbox'; l = 'INBOX'; y = 200 }, @{ n = 'Gmail: email sent by a person'; l = 'SENT'; y = 420 })) {
  Add-Node $t.n 'n8n-nodes-base.gmailTrigger' 1.2 0 $t.y ([ordered]@{
      pollTimes = [ordered]@{ item = @([ordered]@{ mode = 'everyMinute' }) }
      simple = $false
      filters = [ordered]@{ labelIds = @($t.l); readStatus = 'both' }
      options = [ordered]@{ downloadAttachments = $false }
    }) @{ credentials = $CRED_GMAIL }
  Link $t.n 'Read email'
}
Add-Code 'Read email' 'reply-read.js' 240 300
Add-Rpc 'Record email' 'ge_human_reply' '={{ JSON.stringify({ p: $json.p }) }}' 460 300 `
  @{ notes = 'Finds the lead (ref L-123 in the subject, else the email address), ignores automated emails, and pauses all automation for that lead.' }
Add-If 'Paused just now?' '={{ $json.paused_now === true }}' 680 300
Add-GhlTail 'Paused just now?' 900 300
Link 'Read email' 'Record email'
Link 'Record email' 'Paused just now?'
Save-Wf 'GE-04-human-reply.json'

# ================================================================== GE-05 Owner Actions
Start-Wf 'GE-05 Owner Actions'
Add-Webhook 'Owner opened a link (GET)' 'GET' 'ge-owner-action' 0 200 $false 'responseNode'
Add-Webhook 'Owner pressed Confirm (POST)' 'POST' 'ge-owner-action' 0 420 $false 'responseNode'
Add-Rpc 'Preview action' 'ge_owner_action' `
  "={{ JSON.stringify({ p: { token: `$json.query.t || '', action: `$json.query.a || '', confirm: false } }) }}" 220 200
Add-Rpc 'Apply action' 'ge_owner_action' `
  "={{ JSON.stringify({ p: { token: (`$json.body && `$json.body.t) || '', action: (`$json.body && `$json.body.a) || '', confirm: true } }) }}" 220 420
Add-Code 'Build page' 'owner-page.js' 440 300 $true
Add-Node 'Show page' 'n8n-nodes-base.respondToWebhook' 1.1 660 300 ([ordered]@{
    respondWith = 'text'; responseBody = '={{ $json.html }}'
    options = [ordered]@{ responseHeaders = [ordered]@{ entries = @([ordered]@{ name = 'Content-Type'; value = 'text/html; charset=utf-8' }) } }
  })
Add-If 'Changed something?' '={{ $json.ok === true && $json.preview !== true && $json.ignored !== true && !!$json.lead_id }}' 880 300
Add-GhlTail 'Changed something?' 1100 300
Link 'Owner opened a link (GET)' 'Preview action'
Link 'Owner pressed Confirm (POST)' 'Apply action'
Link 'Preview action' 'Build page'
Link 'Apply action' 'Build page'
Link 'Build page' 'Show page'
Link 'Show page' 'Changed something?'
Save-Wf 'GE-05-owner-actions.json'

# ================================================================== GE-99 Error Alerts
Start-Wf 'GE-99 Error Alerts'
Add-Node 'When any GE workflow fails' 'n8n-nodes-base.errorTrigger' 1 0 300 @{}
Add-Code 'Describe the error' 'error-format.js' 220 300
Add-Rpc 'Log error in Supabase' 'ge_log_error' '={{ JSON.stringify({ p: $json.p }) }}' 440 300 `
  @{ onError = 'continueRegularOutput'; notes = 'If Supabase itself is down we still send the email.' }
Add-Gmail 'Email the owner' (Sub '__OWNER_EMAIL__') "={{ `$('Describe the error').item.json.subject }}" "={{ `$('Describe the error').item.json.html }}" 660 300 `
  @{ retryOnFail = $true; maxTries = 3; waitBetweenTries = 5000 }
Link 'When any GE workflow fails' 'Describe the error'
Link 'Describe the error' 'Log error in Supabase'
Link 'Log error in Supabase' 'Email the owner'
Save-Wf 'GE-99-error-alerts.json' $true

Write-Host 'Done. Import the files in n8n/dist (n8n -> Workflows -> Import from File).'
