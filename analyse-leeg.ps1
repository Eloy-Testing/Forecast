# Beantwoordt vraag 1 en 2 uit het inkoopmemo: welke SKU's staan droog tot de
# derde container, wat verkopen ze per week, wat is de marge en wat kost het.
$ErrorActionPreference = 'Stop'
$cwd = (Get-Location).Path
$vandaag = [datetime]'2026-09-14'

$d      = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $cwd 'dataset.json')))
$prijs  = (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $cwd 'raw_prijzen.json')))).rows

$pr = @{}
foreach ($p in $prijs) {
  $inkoop  = [double]$p.inkoop
  $verkoop = [double]$p.verkoop
  $pr[[int]$p.pid] = [pscustomobject]@{ inkoop=$inkoop; verkoop=$verkoop; moq=[int]$p.moq }
}

# Lege SKU's zonder aanvulling vóór de novembercontainer.
$rijen = New-Object System.Collections.ArrayList
foreach ($r in $d.inkoop) {
  if (($r.voorraad - $r.bo) -gt 0) { continue }
  if ($r.q28 -le 0) { continue }
  $etas = @(@($r.inb) | Where-Object { $_ -and $_.eta } | Sort-Object eta)
  $eerste = if ($etas.Count) { $etas[0].eta } else { $null }
  if ($eerste -and $eerste -lt '2026-11-06') { continue }

  $perWeek = [math]::Round($r.q28 / 4.0, 1)
  $p = $pr[[int]$r.pid]
  $marge = if ($p -and $p.verkoop -gt 0 -and $p.inkoop -gt 0) { [math]::Round($p.verkoop - $p.inkoop, 2) } else { $null }

  # Weken zonder voorraad: tot de ETA, of - als er niets onderweg is - tot een
  # nieuwe container binnen zou zijn (90 dagen levertijd vanaf vandaag).
  if ($eerste) {
    $weken = [math]::Round((([datetime]$eerste - $vandaag).Days) / 7.0, 1)
    $tot   = $eerste
  } else {
    $weken = [math]::Round(90 / 7.0, 1)
    $tot   = 'geen order'
  }

  $kost = if ($marge) { [math]::Round($weken * $perWeek * $marge, 0) } else { $null }

  [void]$rijen.Add([pscustomobject]@{
    SKU      = $r.sku
    backorder= $r.bo
    perWeek  = $perWeek
    inkoop   = if ($p) { $p.inkoop } else { $null }
    verkoop  = if ($p) { [math]::Round($p.verkoop,2) } else { $null }
    marge    = $marge
    inbStuks = (@($r.inb) | Measure-Object -Property qty -Sum).Sum
    terugOp  = $tot
    weken    = $weken
    kost     = $kost
  })
}

$gesorteerd = $rijen | Sort-Object -Property @{e={ if ($null -eq $_.kost) { -1 } else { $_.kost } }; Descending=$true}

$gesorteerd | Format-Table -AutoSize @{n='SKU';e={$_.SKU.Substring(0,[Math]::Min(42,$_.SKU.Length))}},
  @{n='BO';e={$_.backorder}}, @{n='p/wk';e={$_.perWeek}}, @{n='inkoop';e={$_.inkoop}},
  @{n='verkoop';e={$_.verkoop}}, @{n='marge';e={$_.marge}}, @{n='komt';e={$_.inbStuks}},
  @{n='terug op';e={$_.terugOp}}, @{n='wkn';e={$_.weken}}, @{n='kost EUR';e={$_.kost}}

$totaal = ($gesorteerd | Where-Object { $null -ne $_.kost } | Measure-Object -Property kost -Sum).Sum
$zonder = ($gesorteerd | Where-Object { $null -eq $_.kost }).Count
Write-Output ""
Write-Output "SKU's           : $($gesorteerd.Count)"
Write-Output "gemiste marge   : EUR $([math]::Round($totaal,0))"
Write-Output "zonder prijsdata: $zonder SKU's (marge onbekend, niet meegerekend)"

$gesorteerd | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 (Join-Path $cwd 'analyse-leeg.json')
