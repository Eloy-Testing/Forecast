# Injecteert dataset.json in template.html en schrijft de publiceerbare pagina.
$ErrorActionPreference = 'Stop'
$cwd  = (Get-Location).Path
$tmpl = [IO.File]::ReadAllText((Join-Path $cwd 'template.html'))
$json = [IO.File]::ReadAllText((Join-Path $cwd 'dataset.json'))

if ($tmpl -notmatch [regex]::Escape('/*__DATA__*/null')) { throw "placeholder ontbreekt in template.html" }
$out = $tmpl.Replace('/*__DATA__*/null', $json)
[IO.File]::WriteAllText((Join-Path $cwd 'voorraadhorizon.html'), $out)

Write-Output "voorraadhorizon.html: $($out.Length) bytes"
