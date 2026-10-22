<#
  Pushes the built workflows (n8n/dist) into n8n through the n8n public API.
  Matches by workflow name, updates in place (same id, same webhook URLs), keeps the active state.
  Needs N8N_API_KEY in secrets.local.json.   Usage: powershell -ExecutionPolicy Bypass -File scripts\deploy-n8n.ps1 [-Activate]
#>
param([switch]$Activate)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cfg = Get-Content (Join-Path $root 'config.local.json') -Raw | ConvertFrom-Json
$sec = Get-Content (Join-Path $root 'secrets.local.json') -Raw | ConvertFrom-Json
if (-not $sec.N8N_API_KEY) { throw 'N8N_API_KEY missing in secrets.local.json' }
$H = @{ 'X-N8N-API-KEY' = $sec.N8N_API_KEY }
$B = "$($cfg.N8N_BASE_URL.TrimEnd('/'))/api/v1"

$existing = @{}
(Invoke-RestMethod "$B/workflows?limit=250" -Headers $H).data | ForEach-Object { $existing[$_.name] = $_ }

# GE-99 first so it exists before the others point at it
$files = Get-ChildItem (Join-Path $root 'n8n\dist') -Filter 'GE-*.json' | Sort-Object { if ($_.Name -like 'GE-99*') { 0 } else { 1 } }, Name
foreach ($f in $files) {
  $wf = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  $settings = [ordered]@{ executionOrder = 'v1'; saveDataErrorExecution = 'all'; saveDataSuccessExecution = 'all' }
  if ($wf.settings.errorWorkflow) { $settings.errorWorkflow = $wf.settings.errorWorkflow }
  $body = [ordered]@{ name = $wf.name; nodes = $wf.nodes; connections = $wf.connections; settings = $settings } | ConvertTo-Json -Depth 60
  $bytes = [Text.Encoding]::UTF8.GetBytes($body)
  if ($existing.Contains($wf.name)) {
    $id = $existing[$wf.name].id
    try { $null = Invoke-RestMethod -Method Put "$B/workflows/$id" -Headers $H -ContentType 'application/json; charset=utf-8' -Body $bytes }
    catch { Write-Host ("  FAILED   {0,-34} {1}" -f $wf.name, $_.ErrorDetails.Message) -ForegroundColor Red; continue }
    Write-Host ("  updated  {0,-34} {1}" -f $wf.name, $id)
  } else {
    $r = Invoke-RestMethod -Method Post "$B/workflows" -Headers $H -ContentType 'application/json; charset=utf-8' -Body $bytes
    $id = $r.id
    Write-Host ("  created  {0,-34} {1}" -f $wf.name, $id)
  }
  # GE-99 must be published before other workflows can name it as their error workflow.
  if ($Activate -or $wf.name -like 'GE-99*') {
    try { $null = Invoke-RestMethod -Method Post "$B/workflows/$id/activate" -Headers $H -ContentType 'application/json' -Body '{}'; Write-Host "           active" }
    catch { Write-Host "           NOT activated: $($_.ErrorDetails.Message)" -ForegroundColor Red }
  }
}
