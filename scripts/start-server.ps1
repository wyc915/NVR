<#
.SYNOPSIS
  Start the NVR server in this window (no Windows service needed).

.DESCRIPTION
  Runs the server in the foreground with its log in this window. Press Ctrl+C to stop:
  a recording in progress is saved first. Closing the window also stops the server.
  The iPhone keeps using the same address (Tailscale serve -> 127.0.0.1:8080).

.EXAMPLE
  .\scripts\start-server.ps1
#>
$ErrorActionPreference = 'Stop'
$server = Join-Path (Split-Path $PSScriptRoot -Parent) 'server'

if (Get-Service ClaudeNVR -ErrorAction SilentlyContinue) {
  Write-Host 'The ClaudeNVR Windows service is still installed. Remove it first (Administrator PowerShell):' -ForegroundColor Yellow
  Write-Host "  $PSScriptRoot\install-service.ps1 -Uninstall" -ForegroundColor Yellow
  exit 1
}
if (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue) {
  Write-Host 'Port 8080 is already in use: the server is probably running in another window.' -ForegroundColor Yellow
  exit 1
}

Push-Location $server
try {
  $Host.UI.RawUI.WindowTitle = 'Claude NVR server (Ctrl+C to stop)'
  npm start
} finally {
  Pop-Location
}
