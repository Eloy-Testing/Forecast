# Parseert de uit PDF gehaalde inkooporderregels naar gestructureerde records.
# Ankerpunt is de EAN (13 cijfers); daarvoor staat de SKU, daarna titel, aantal en datum.
$ErrorActionPreference = 'Stop'
$cwd = (Get-Location).Path

$orders = @(
  @{ id=10; naam='Mid September 2026';      eta='2026-09-17'; regels=113; stuks=3836 },
  @{ id=11; naam='Begin October';           eta='2026-10-09'; regels=60;  stuks=4476 },
  @{ id=14; naam='Delivery November';       eta='2026-11-06'; regels=107; stuks=7164 }
)

$KOP = @('SKU','EAN','PRODUCT','AANTAL','BESTELD','VERWACHTE','LEVERING','Totaal')
$alle = New-Object System.Collections.ArrayList

foreach ($o in $orders) {
  $lines = [IO.File]::ReadAllLines((Join-Path $cwd "po-$($o.id).txt"))
  $buf = New-Object System.Collections.ArrayList
  $i = 0; $n = $lines.Count
  $recs = New-Object System.Collections.ArrayList

  while ($i -lt $n) {
    $L = $lines[$i].Trim()
    if ($KOP -contains $L) { $i++; continue }

    # EAN-anker: een cijferregel die volgt op verzamelde SKU-regels. Niet alles is
    # 13 cijfers - 'Microfibre - Dining chair cover - Grey' heeft EAN 3985.
    if ($L -match '^\d{4,14}$' -and (($buf | Where-Object { $_ -ne '' }).Count -gt 0)) {
      $sku = (($buf | Where-Object { $_ -ne '' }) -join ' ').Trim()
      $buf.Clear()
      $ean = $L
      $i++

      # titelregels tot het eerste losse getal: dat is het aantal
      $titel = New-Object System.Collections.ArrayList
      $qty = $null
      while ($i -lt $n) {
        $T = $lines[$i].Trim()
        if ($KOP -contains $T) { $i++; continue }
        if ($T -match '^\d+$' -and [int]$T -lt 100000) { $qty = [int]$T; $i++; break }
        [void]$titel.Add($T); $i++
      }

      # datumregels overslaan (vorm '17-09-' gevolgd door '2026')
      while ($i -lt $n -and ($lines[$i].Trim() -match '^\d{2}-\d{2}-$' -or $lines[$i].Trim() -match '^\d{4}$')) { $i++ }

      if ($qty -ne $null -and $sku) {
        [void]$recs.Add([pscustomobject]@{
          order = $o.id; orderNaam = $o.naam; eta = $o.eta
          sku = $sku; ean = $ean; qty = $qty
          titel = ($titel -join ' ').Trim()
        })
      }
      continue
    }

    [void]$buf.Add($L)
    $i++
  }

  $som = ($recs | Measure-Object -Property qty -Sum).Sum
  $status = if ($som -eq $o.stuks) { 'OK' } else { "AFWIJKING (verwacht $($o.stuks))" }
  Write-Output ("order {0,-3} {1,-22} regels {2,3}/{3,3}  stuks {4,5}  {5}" -f $o.id, $o.naam, $recs.Count, $o.regels, $som, $status)
  foreach ($r in $recs) { [void]$alle.Add($r) }
}

[IO.File]::WriteAllText((Join-Path $cwd 'raw_po_items.json'), ($alle | ConvertTo-Json -Depth 4 -Compress))
Write-Output "totaal $($alle.Count) regels -> raw_po_items.json"
