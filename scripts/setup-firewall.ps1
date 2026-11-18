#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Windows Firewall rules for Claude NVR (run as Administrator).

.DESCRIPTION
  The web app, API and WebRTC signaling are only reachable through `tailscale serve`
  (HTTPS, proxied to 127.0.0.1:8080), so they need no inbound rule at all.
  The only port that must be reachable from outside is the WebRTC media port:
    UDP 8189  mediamtx.exe  WebRTC media
    TCP 8189  mediamtx.exe  WebRTC media (fallback)
  allowed ONLY for mediamtx.exe and ONLY from Tailscale (+ the local subnet with -AllowLan).
  Re-running replaces the previous rules (group "Claude NVR").

.EXAMPLE
  .\setup-firewall.ps1            # Tailscale only (recommended)
  .\setup-firewall.ps1 -AllowLan  # also allow the local network
#>
param([switch]$AllowLan)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$group = 'Claude NVR'
$node = (Get-Command node).Source
$mtx = Join-Path $root 'mediamtx\mediamtx.exe'

$remote = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48')   # Tailscale IPv4 / IPv6
if ($AllowLan) { $remote += 'LocalSubnet' }

Write-Host "Allowed sources: $($remote -join ', ')"

Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule

$rules = @(
  @{ Name = 'NVR WebRTC media (UDP 8189)'; Program = $mtx; Protocol = 'UDP'; Port = 8189 },
  @{ Name = 'NVR WebRTC media (TCP 8189)'; Program = $mtx; Protocol = 'TCP'; Port = 8189 }
)
foreach ($r in $rules) {
  New-NetFirewallRule -DisplayName $r.Name -Group $group -Direction Inbound -Action Allow `
    -Program $r.Program -Protocol $r.Protocol -LocalPort $r.Port -RemoteAddress $remote `
    -Profile Any | Out-Null
  Write-Host "  + $($r.Name)"
}

# Windows may have created broad "allow" rules when node.exe / mediamtx.exe first
# listened on the network (the "allow access" popup). Those would bypass the
# restrictions above, so offer to disable them.
$broad = Get-NetFirewallApplicationFilter |
  Where-Object { $_.Program -ieq $node -or $_.Program -ieq $mtx } |
  Get-NetFirewallRule |
  Where-Object { $_.Group -ne $group -and $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' }

if ($broad) {
  Write-Host ''
  Write-Host 'Found other inbound ALLOW rules for node.exe / mediamtx.exe (not restricted by source):' -ForegroundColor Yellow
  $broad | ForEach-Object { Write-Host "  - $($_.DisplayName) [$($_.Profile)]" }
  Write-Host 'Note: node.exe rules also affect other Node.js programs you run.'
  $ans = Read-Host 'Disable these rules? (y/N)'
  if ($ans -match '^[yY]') {
    $broad | Disable-NetFirewallRule
    Write-Host 'Disabled.'
  } else {
    Write-Host 'Left unchanged.'
  }
}

Write-Host ''
Write-Host 'Done. Current NVR rules:' -ForegroundColor Green
Get-NetFirewallRule -Group $group | Format-Table DisplayName, Enabled, Profile -AutoSize
