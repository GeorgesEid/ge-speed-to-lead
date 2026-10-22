# dev/server.ps1 - LOCAL TESTING ONLY (never deployed).
# Serves the project on http://localhost:5178 so the browser can run dev/harness.html
# (tests for every n8n Code node) and preview the dashboard in web/.
# If secrets.local.json exists, /api/dashboard is answered from Supabase here on the
# server side, so the service key never reaches the browser.
param([int]$Port = $(if ($env:PORT) { [int]$env:PORT } else { 5178 }))
Add-Type -AssemblyName System.Web
$root = Split-Path $PSScriptRoot -Parent
$secretsFile = Join-Path $root 'secrets.local.json'
$cfgFile = Join-Path $root 'config.local.json'
$types = @{ '.html'='text/html; charset=utf-8'; '.js'='text/javascript; charset=utf-8'; '.css'='text/css; charset=utf-8'; '.json'='application/json'; '.svg'='image/svg+xml' }
$l = [System.Net.HttpListener]::new(); $l.Prefixes.Add("http://localhost:$Port/"); $l.Start()
Write-Host "Dev server on http://localhost:$Port"
while ($l.IsListening) {
  $ctx = $l.GetContext(); $req = $ctx.Request; $res = $ctx.Response
  try {
    $path = $req.Url.AbsolutePath
    if ($path -eq '/api/dashboard') {
      if (-not (Test-Path $secretsFile) -or -not (Test-Path $cfgFile)) {
        # No Supabase yet: serve mock numbers so the page can be previewed.
        $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'mock-dashboard.json')); $res.ContentType = 'application/json'
        $res.OutputStream.Write($bytes, 0, $bytes.Length); $res.Close(); continue
      }
      $sec = Get-Content $secretsFile -Raw | ConvertFrom-Json; $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
      $q = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
      $body = @{ p = @{ from = $q['from']; to = $q['to']; include_sample = ($q['sample'] -ne '0') } } | ConvertTo-Json -Depth 5
      $h = @{ apikey = $sec.SUPABASE_SERVICE_ROLE_KEY; Authorization = "Bearer $($sec.SUPABASE_SERVICE_ROLE_KEY)" }
      $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$($cfg.SUPABASE_URL)/rest/v1/rpc/ge_dashboard" -Headers $h -Body $body -ContentType 'application/json'
      $bytes = [Text.Encoding]::UTF8.GetBytes($r.Content); $res.ContentType = 'application/json'
    } else {
      if ($path -eq '/') { $path = '/web/index.html' }
      if ($path -notmatch '^/(web|dev|n8n/code)/') { $path = '/web' + $path }
      $full = [IO.Path]::GetFullPath((Join-Path $root ($path.TrimStart('/'))))
      if (-not $full.StartsWith($root) -or $full -match 'local\.json$' -or -not (Test-Path $full -PathType Leaf)) { $res.StatusCode = 404; $bytes = [Text.Encoding]::UTF8.GetBytes('not found') }
      else { $bytes = [IO.File]::ReadAllBytes($full); $res.ContentType = $types[[IO.Path]::GetExtension($full)] }
    }
    $res.AddHeader('Cache-Control', 'no-store')
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
  } catch { $res.StatusCode = 500; $m = [Text.Encoding]::UTF8.GetBytes("$_"); $res.OutputStream.Write($m, 0, $m.Length) }
  finally { $res.Close() }
}
