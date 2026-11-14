#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Install the Claude NVR server as a Windows service (run as Administrator).

.DESCRIPTION
  - Installs NSSM (service wrapper) with winget if missing
  - Builds the server (npm run build)
  - Registers service "ClaudeNVR": starts at boot (delayed), restarts on crash,
    stops gracefully (Ctrl+C -> in-progress recording is saved), logs to
    storage\logs\service.log (rotated at 10 MB)

.EXAMPLE
  .\install-service.ps1             # install / reinstall and start
  .\install-service.ps1 -Uninstall  # stop and remove the service
#>
param(
  [string]$ServiceName = 'ClaudeNVR',
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$server = Join-Path $root 'server'
$logDir = Join-Path $root 'storage\logs'

function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}
Refresh-Path

# --- NSSM ---
if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
  Write-Host 'Installing NSSM with winget...'
  winget install --id NSSM.NSSM -e --accept-source-agreements --accept-package-agreements
  Refresh-Path
  if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
    throw 'nssm not found after install. Open a new Administrator PowerShell and run this script again.'
  }
}
$nssm = (Get-Command nssm).Source

# --- remove existing service ---
if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
  Write-Host "Stopping and removing existing service $ServiceName..."
  & $nssm stop $ServiceName | Out-Null
  & $nssm remove $ServiceName confirm | Out-Null
}
if ($Uninstall) { Write-Host 'Uninstalled.'; return }

# --- port check (a dev server started by hand would conflict) ---
if (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue) {
  throw 'Port 8080 is in use (is the server already running in a terminal?). Stop it first.'
}

# --- absolute tool paths (the service runs as LocalSystem, without your user PATH) ---
$node = (Get-Command node).Source
$ffmpeg = (Get-Command ffmpeg).Source
$ffprobe = (Get-Command ffprobe).Source
Write-Host "node:    $node"
Write-Host "ffmpeg:  $ffmpeg"
Write-Host "ffprobe: $ffprobe"

# --- build ---
Write-Host 'Building server...'
Push-Location $server
try {
  npm run build
  if ($LASTEXITCODE -ne 0) { throw 'npm run build failed' }
} finally { Pop-Location }

# --- install ---
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir 'service.log'

& $nssm install $ServiceName $node 'dist\index.js' | Out-Null
& $nssm set $ServiceName AppDirectory $server | Out-Null
& $nssm set $ServiceName DisplayName 'Claude NVR' | Out-Null
& $nssm set $ServiceName Description 'Camera capture, recording and API for the NVR app' | Out-Null
& $nssm set $ServiceName Start SERVICE_DELAYED_AUTO_START | Out-Null
& $nssm set $ServiceName AppEnvironmentExtra "NVR_FFMPEG=$ffmpeg" "NVR_FFPROBE=$ffprobe" | Out-Null
& $nssm set $ServiceName AppStdout $log | Out-Null
& $nssm set $ServiceName AppStderr $log | Out-Null
& $nssm set $ServiceName AppRotateFiles 1 | Out-Null
& $nssm set $ServiceName AppRotateOnline 1 | Out-Null
& $nssm set $ServiceName AppRotateBytes 10485760 | Out-Null
# Graceful stop: Ctrl+C, give the server 15 s to finish the current recording.
& $nssm set $ServiceName AppStopMethodConsole 15000 | Out-Null
& $nssm set $ServiceName AppExit Default Restart | Out-Null
& $nssm set $ServiceName AppRestartDelay 5000 | Out-Null

Write-Host 'Starting service...'
& $nssm start $ServiceName | Out-Null
Start-Sleep -Seconds 8

$svc = Get-Service $ServiceName
Write-Host ''
Write-Host "Service $ServiceName : $($svc.Status)" -ForegroundColor $(if ($svc.Status -eq 'Running') { 'Green' } else { 'Red' })
try {
  $h = Invoke-RestMethod http://127.0.0.1:8080/health -TimeoutSec 5
  Write-Host "Health check: ok=$($h.ok)" -ForegroundColor Green
} catch {
  Write-Host "Health check failed: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host "Log file: $log"
Write-Host 'Last log lines:'
Get-Content $log -Tail 15 -ErrorAction SilentlyContinue
