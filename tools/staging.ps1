# Runs the Zig Turf server as staging (turf.wreseal.com through the Cloudflare tunnel).
# Settings, including PORT, come from Turf-js/.env.staging (the same database and keys the Node
# staging server used). Run:  powershell -File C:\MProjects\Turf\tools\staging.ps1
# Roll back to Node: stop turf-server.exe, then `npm run staging` in C:\MProjects\Turf-js.
# Build first:  zig build server -Doptimize=safe   and   zig build web -Doptimize=small

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$js = Join-Path (Split-Path -Parent $repo) 'Turf-js'
$dir = Join-Path $repo 'zig-out\staging'

# A copy of the server and the zui web app, so rebuilding does not touch the running one.
New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item (Join-Path $repo 'zig-out\bin\turf-server.exe') $dir -Force
if (Test-Path (Join-Path $dir 'web')) { Remove-Item -Recurse -Force (Join-Path $dir 'web') }
Copy-Item -Recurse (Join-Path $repo 'zig-out\web') (Join-Path $dir 'web')

foreach ($line in Get-Content (Join-Path $js '.env.staging')) {
    if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim().Trim('"'), 'Process')
    }
}
$env:TURF_PUBLIC_DIR = Join-Path $dir 'web'
# Push to phones: the Firebase service account, kept outside the repositories.
$fcm = Join-Path (Split-Path -Parent $repo) 'secrets\firebase-service-account.json'
if (Test-Path $fcm) { $env:FCM_SERVICE_ACCOUNT_FILE = $fcm }

Start-Process -FilePath (Join-Path $dir 'turf-server.exe') -WorkingDirectory $dir -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $dir 'server.log') -RedirectStandardError (Join-Path $dir 'server.err.log')
Write-Output "Zig Turf staging started (logs in $dir)"
