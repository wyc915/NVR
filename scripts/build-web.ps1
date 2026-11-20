<#
.SYNOPSIS
  Build the Flutter web app with a build ID, so open web apps (e.g. on the iPhone home
  screen) notice the new version and reload themselves.

.EXAMPLE
  .\scripts\build-web.ps1
#>
$ErrorActionPreference = 'Stop'
$app = Join-Path (Split-Path $PSScriptRoot -Parent) 'app'
$id = Get-Date -Format 'yyyyMMdd-HHmmss'

Push-Location $app
try {
  flutter build web --release --no-web-resources-cdn --no-wasm-dry-run "--dart-define=BUILD_ID=$id"
  if ($LASTEXITCODE -ne 0) { throw 'flutter build web failed' }
  # Written last: clients only see the new ID once all files are in place.
  [IO.File]::WriteAllText((Join-Path $app 'build\web\build_id.txt'), $id)
  Write-Host "Built web app $id" -ForegroundColor Green
} finally {
  Pop-Location
}
