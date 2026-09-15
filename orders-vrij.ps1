# Hoeveel backorder-ORDERS worden verzendbaar na elke container?
#
# Een order telt pas als verzendbaar wanneer elke regel gedekt is: een order met
# vijf regels waarvan er vier binnenkomen blijft gewoon staan.
#
# Aannames, expliciet:
#  - backorders krijgen voorrang op binnenkomende voorraad (zo werkt een magazijn)
#  - oudste order eerst
#  - voorraad wordt alleen toegewezen als de héle order gedekt kan worden; anders
#    blijft hij staan voor een order die wél compleet kan
#  - nieuwe verkoop concurreert hier niet mee (zie de aparte doorrekening daarvoor)
$ErrorActionPreference = 'Stop'
$cwd = (Get-Location).Path

$boRaw   = (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $cwd 'raw_bo_orders.json')))).rows
$stockRaw= (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $cwd 'raw_stock.json')))).rows
$setsRaw =  ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $cwd 'raw_sets.json')))
$prodRaw = (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $cwd 'raw_products.json')))).rows
$poItems =  ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $cwd 'raw_po_items.json')))
$po      =  ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $cwd 'raw_po.json')))

# ---- setsamenstelling (recursief) -------------------------------------------
$children = @{}
foreach ($s in $setsRaw) {
  $p = [int]$s[0]
  if (-not $children.ContainsKey($p)) { $children[$p] = New-Object System.Collections.ArrayList }
  [void]$children[$p].Add(@{ c = [int]$s[1]; q = [int]$s[2] })
}
function Explode([int]$id, [int]$mult, [hashtable]$acc, [int]$diepte) {
  if ($diepte -gt 6) { return }
  if (-not $children.ContainsKey($id)) { $acc[$id] = [int]$acc[$id] + $mult; return }
  foreach ($k in $children[$id]) { Explode $k.c ($mult * $k.q) $acc ($diepte + 1) }
}
function Componenten([int]$id) {
  $acc = @{}; Explode $id 1 $acc 0; return $acc
}

# ---- voorraad nu -------------------------------------------------------------
$voorraad = @{}; $naam = @{}
foreach ($r in $stockRaw) { $voorraad[[int]$r.pid] = [int]$r.v; $naam[[int]$r.pid] = [string]$r.sku }

# ---- containerinhoud per product --------------------------------------------
$eanToPid = @{}
foreach ($p in $prodRaw) {
  $e = ([string]$p.ean).Trim()
  if ($e -and $e -match '^\d+$') {
    if (-not $eanToPid.ContainsKey($e) -or [int]$p.is_set -eq 0) { $eanToPid[$e] = [int]$p.pid }
  }
}
$skuToPid = @{}
foreach ($p in $prodRaw) { $s = [string]$p.sku; if ($s -and -not $skuToPid.ContainsKey($s)) { $skuToPid[$s] = [int]$p.pid } }

$inbound = @{}   # eta -> (pid -> aantal)
foreach ($it in $poItems) {
  $e = ([string]$it.ean).Trim()
  $target = $null
  if ($eanToPid.ContainsKey($e))          { $target = $eanToPid[$e] }
  elseif ($skuToPid.ContainsKey($it.sku)) { $target = $skuToPid[$it.sku] }
  if ($null -eq $target) { continue }
  if (-not $inbound.ContainsKey($it.eta)) { $inbound[$it.eta] = @{} }
  $inbound[$it.eta][$target] = [int]$inbound[$it.eta][$target] + [int]$it.qty
}

# ---- orders opbouwen, oudste eerst ------------------------------------------
$orders = @{}
foreach ($r in $boRaw) {
  $nr = [string]$r.o
  if (-not $orders.ContainsKey($nr)) { $orders[$nr] = [pscustomobject]@{ datum=[string]$r.d; nodig=@{}; stuks=0 } }
  foreach ($c in (Componenten ([int]$r.p)).GetEnumerator()) {
    $orders[$nr].nodig[$c.Key] = [int]$orders[$nr].nodig[$c.Key] + ($c.Value * [int]$r.q)
  }
  $orders[$nr].stuks += [int]$r.q
}
$volgorde = $orders.Keys | Sort-Object { $orders[$_].datum }

# ---- toewijzen ---------------------------------------------------------------
$pool = @{}
foreach ($k in $voorraad.Keys) { $pool[$k] = $voorraad[$k] }
$open = New-Object System.Collections.ArrayList
foreach ($nr in $volgorde) { [void]$open.Add($nr) }

function Toewijzen([hashtable]$pool, $open, $orders) {
  $vrij = New-Object System.Collections.ArrayList
  $nog  = New-Object System.Collections.ArrayList
  foreach ($nr in $open) {
    $kan = $true
    foreach ($c in $orders[$nr].nodig.GetEnumerator()) {
      if ([int]$pool[$c.Key] -lt $c.Value) { $kan = $false; break }
    }
    if ($kan) {
      foreach ($c in $orders[$nr].nodig.GetEnumerator()) { $pool[$c.Key] = [int]$pool[$c.Key] - $c.Value }
      [void]$vrij.Add($nr)
    } else { [void]$nog.Add($nr) }
  }
  return @{ vrij = $vrij; nog = $nog }
}

$fases = @(@{ naam='Nu, met voorraad die er ligt'; eta=$null })
foreach ($c in ($po | Where-Object { $_.detail } | Sort-Object eta)) {
  $fases += @{ naam = $c.naam; eta = $c.eta; stuks = $c.stuks }
}

$totaalOrders = $open.Count
$totaalStuks  = ($orders.Values | Measure-Object -Property stuks -Sum).Sum
Write-Output "backorder nu: $totaalOrders orders, $totaalStuks stuks`n"

$cumulatief = 0
$rijen = New-Object System.Collections.ArrayList
foreach ($f in $fases) {
  if ($f.eta) {
    foreach ($kv in $inbound[$f.eta].GetEnumerator()) { $pool[$kv.Key] = [int]$pool[$kv.Key] + $kv.Value }
  }
  $res = Toewijzen $pool $open $orders
  $vrijNu = $res.vrij.Count
  $stuksNu = 0; foreach ($nr in $res.vrij) { $stuksNu += $orders[$nr].stuks }
  $cumulatief += $vrijNu
  $open = $res.nog
  [void]$rijen.Add([pscustomobject]@{
    fase = $f.naam; eta = if ($f.eta) { $f.eta } else { '-' }
    ordersVrij = $vrijNu; stuksVrij = $stuksNu
    cumulatief = $cumulatief; nogOpen = $open.Count
  })
}

$rijen | Format-Table -AutoSize @{n='Moment';e={$_.fase}}, @{n='ETA';e={$_.eta}},
  @{n='orders verzendbaar';e={$_.ordersVrij}}, @{n='stuks';e={$_.stuksVrij}},
  @{n='cumulatief';e={$_.cumulatief}}, @{n='nog open';e={$_.nogOpen}}

Write-Output ""
Write-Output "na alle containers nog open: $($open.Count) orders van de $totaalOrders"

# welke SKU's houden de resterende orders tegen
$blokkeert = @{}
foreach ($nr in $open) {
  foreach ($c in $orders[$nr].nodig.GetEnumerator()) {
    if ([int]$pool[$c.Key] -lt $c.Value) { $blokkeert[$c.Key] = [int]$blokkeert[$c.Key] + 1 }
  }
}
Write-Output ""
Write-Output "SKU's die de meeste resterende orders tegenhouden:"
$blokkeert.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 12 | ForEach-Object {
  $n = if ($naam.ContainsKey($_.Key) -and $naam[$_.Key]) { $naam[$_.Key] } else { "product $($_.Key)" }
  Write-Output ("  {0,4} orders  {1}" -f $_.Value, $n)
}
