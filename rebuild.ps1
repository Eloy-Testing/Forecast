# Bouwt het dashboard opnieuw op uit de ruwe StockItUp-exports in data\.
#
# Gebruik: rechtsklik op dit bestand -> "Run with PowerShell"
#          of in een PowerShell-venster:  .\rebuild.ps1
#
# Stap 1 verwerkt de raw_*.json tot data\dataset.json
# Stap 2 plakt die dataset in template.html en schrijft dashboard.html
#
# -Peildatum is de dag waarop de exports uit StockItUp zijn getrokken. Laat je die weg, dan
# wordt het vandaag; dat klopt alleen als je de data ook vandaag hebt opgehaald.
#   .\rebuild.ps1 -Peildatum 2026-09-14
param([string]$Peildatum = (Get-Date).ToString('yyyy-MM-dd'))
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

Write-Output "1/2  dataset bouwen uit data\raw_*.json  (peildatum $Peildatum) ..."
Push-Location (Join-Path $root 'data')
try { & (Join-Path $root 'scripts\build.ps1') -Peildatum $Peildatum } finally { Pop-Location }

Write-Output ""
Write-Output "2/2  dashboard.html samenstellen ..."
$tpl = [IO.File]::ReadAllText((Join-Path $root 'template.html'))
$dat = ([IO.File]::ReadAllText((Join-Path $root 'data\dataset.json'))).Trim()
if ($tpl -notmatch [regex]::Escape('/*__DATA__*/null')) {
  throw "template.html mist de plek waar de data in moet (/*__DATA__*/null)."
}
$uit = $tpl.Replace('/*__DATA__*/null', $dat)
[IO.File]::WriteAllText((Join-Path $root 'dashboard.html'), $uit, (New-Object Text.UTF8Encoding($false)))

Write-Output ""
Write-Output ("klaar - dashboard.html is {0:N0} KB. Dubbelklik het om te openen." -f ((Get-Item (Join-Path $root 'dashboard.html')).Length/1KB))
