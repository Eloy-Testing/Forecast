# Bouwt dataset.json voor het voorraad-dashboard uit de ruwe StockItUp-exports.
#
# -Peildatum is de dag waarop de exports zijn getrokken, NIET de dag waarop je dit script
# draait. Die twee verschillen zodra je een oudere export opnieuw verwerkt, en dan telt de
# projectie dagen verkoop mee die al geweest zijn. Standaard vandaag.
param([string]$Peildatum = (Get-Date).ToString('yyyy-MM-dd'))
$ErrorActionPreference = 'Stop'
$cwd = (Get-Location).Path
if ($Peildatum -notmatch '^\d{4}-\d{2}-\d{2}$') { throw "Peildatum moet jjjj-mm-dd zijn, kreeg '$Peildatum'." }

function Load($name) { ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $cwd $name))) }

$skusRaw  = (Load 'raw_skus.json').rows     # pid, v, q7, q28, q90, bo, sku (alleen verkopende producten)
$stockRaw = (Load 'raw_stock.json').rows    # pid, v, sku                   (alle producten met voorraadregel)
$setsRaw  = Load 'raw_sets.json'            # [parent, child, qty]
$retRaw   = Load 'raw_returns.json'         # [sku, r7, r28, r90]
$prodRaw  = (Load 'raw_products.json').rows # pid, ean, sku, is_set
$offerRaw = (Load 'raw_offers.json').rows   # pid, leverancier, prijs, doos
$poItems  = Load 'raw_po_items.json'        # regels uit de inkooporder-PDF's
$po       = Load 'raw_po.json'
$daily    = Load 'raw_daily.json'

# ---- basis-maps -------------------------------------------------------------
$stock = @{}; $name = @{}
foreach ($r in $stockRaw) { $stock[[int]$r.pid] = [int]$r.v; $name[[int]$r.pid] = [string]$r.sku }

$sales = @{}
foreach ($r in $skusRaw) {
  $prodId = [int]$r.pid
  $sales[$prodId] = [pscustomobject]@{ q7=[int]$r.q7; q28=[int]$r.q28; q90=[int]$r.q90; bo=[int]$r.bo }
  if (-not $name.ContainsKey($prodId))  { $name[$prodId]  = [string]$r.sku }
  if (-not $stock.ContainsKey($prodId)) { $stock[$prodId] = [int]$r.v }
}

# ---- retouren netto verrekenen ----------------------------------------------
# Een retour komt terug op de plank, dus netto vraag = verkoop minus retour.
# Retouren staan op de SKU die de klant kocht - dat kan ook een set zijn - dus
# verrekenen we ze vóór de setdoorrekening, precies als negatieve verkoop.
$skuToPid = @{}
foreach ($k in $name.Keys) { $s = $name[$k]; if ($s -and -not $skuToPid.ContainsKey($s)) { $skuToPid[$s] = $k } }

$retour = @{}; $retOngekoppeld = 0
foreach ($r in $retRaw) {
  $sku = [string]$r[0]
  if ($skuToPid.ContainsKey($sku)) {
    $p = $skuToPid[$sku]
    $retour[$p] = [pscustomobject]@{ r7=[int]$r[1]; r28=[int]$r[2]; r90=[int]$r[3] }
    if ($sales.ContainsKey($p)) {
      $sales[$p].q7  = [math]::Max(0, $sales[$p].q7  - [int]$r[1])
      $sales[$p].q28 = [math]::Max(0, $sales[$p].q28 - [int]$r[2])
      $sales[$p].q90 = [math]::Max(0, $sales[$p].q90 - [int]$r[3])
    }
  } else { $retOngekoppeld += [int]$r[3] }
}

# ---- sets -------------------------------------------------------------------
$children = @{}
foreach ($s in $setsRaw) {
  $p = [int]$s[0]
  if (-not $children.ContainsKey($p)) { $children[$p] = New-Object System.Collections.ArrayList }
  [void]$children[$p].Add(@{ c = [int]$s[1]; q = [int]$s[2] })
}
$isSet = @{}; foreach ($k in $children.Keys) { $isSet[$k] = $true }

# Zet een (mogelijk geneste) set om naar losse componenten met totaalaantal.
function Explode([int]$prodId, [int]$mult, [hashtable]$acc, [int]$depth) {
  if ($depth -gt 6) { return }               # veiligheidsrem tegen cycli
  if (-not $children.ContainsKey($prodId)) { $acc[$prodId] = [int]$acc[$prodId] + $mult; return }
  foreach ($kid in $children[$prodId]) { Explode $kid.c ($mult * $kid.q) $acc ($depth + 1) }
}

$componentsOf = @{}
foreach ($p in $children.Keys) { $acc = @{}; Explode $p 1 $acc 0; $componentsOf[$p] = $acc }

# ---- vraag doorrekenen naar componentniveau ---------------------------------
# Elke setverkoop verbruikt voorraad van de onderdelen; die vraag telt daar op.
$demand = @{}
foreach ($prodId in $sales.Keys) {
  $s = $sales[$prodId]
  if ($isSet.ContainsKey($prodId)) {
    foreach ($c in $componentsOf[$prodId].Keys) {
      $m = $componentsOf[$prodId][$c]
      if (-not $demand.ContainsKey($c)) { $demand[$c] = [pscustomobject]@{ q7=0; q28=0; q90=0; bo=0; viaSets=0 } }
      $demand[$c].q7      += $s.q7  * $m
      $demand[$c].q28     += $s.q28 * $m
      $demand[$c].q90     += $s.q90 * $m
      $demand[$c].bo      += $s.bo  * $m
      $demand[$c].viaSets += $s.q28 * $m
    }
  } else {
    if (-not $demand.ContainsKey($prodId)) { $demand[$prodId] = [pscustomobject]@{ q7=0; q28=0; q90=0; bo=0; viaSets=0 } }
    $demand[$prodId].q7  += $s.q7
    $demand[$prodId].q28 += $s.q28
    $demand[$prodId].q90 += $s.q90
    $demand[$prodId].bo  += $s.bo
  }
}

# ---- inkooporderregels koppelen aan producten -------------------------------
# EAN is de betrouwbaarste sleutel; bij dubbele EAN's wint het niet-set product,
# want een container bevat fysieke artikelen, geen samengestelde sets.
$eanToPid = @{}; $skuToPidP = @{}
foreach ($p in $prodRaw) {
  $e = ([string]$p.ean).Trim()
  if ($e -and $e -match '^\d+$') {
    if (-not $eanToPid.ContainsKey($e) -or [int]$p.is_set -eq 0) { $eanToPid[$e] = [int]$p.pid }
  }
  $s = [string]$p.sku
  if ($s -and -not $skuToPidP.ContainsKey($s)) { $skuToPidP[$s] = [int]$p.pid }
}

$inbound = @{}
$poGekoppeld = 0
$poLos = New-Object System.Collections.ArrayList
foreach ($it in $poItems) {
  $e = ([string]$it.ean).Trim()
  $target = $null
  if ($eanToPid.ContainsKey($e))           { $target = $eanToPid[$e] }
  elseif ($skuToPidP.ContainsKey($it.sku)) { $target = $skuToPidP[$it.sku] }

  if ($null -eq $target) { [void]$poLos.Add("$($it.sku) (EAN $e, $($it.qty) st)"); continue }
  if (-not $inbound.ContainsKey($target)) { $inbound[$target] = New-Object System.Collections.ArrayList }
  [void]$inbound[$target].Add([pscustomobject]@{ eta=$it.eta; qty=[int]$it.qty; order=$it.orderNaam })
  $poGekoppeld += [int]$it.qty
}

# ---- leveranciersaanbod: laagste prijs per product --------------------------
# Bepaalt wat besteld kan worden en in welke dooshoeveelheid. Zonder aanbod kan
# een SKU door geen enkel systeem besteld worden - die markeren we expliciet.
$aanbod = @{}
foreach ($o in $offerRaw) {
  $prijs = [double]$o.prijs
  if ($prijs -le 0) { continue }
  $k = [int]$o.pid
  if (-not $aanbod.ContainsKey($k) -or $prijs -lt $aanbod[$k].prijs) {
    $aanbod[$k] = [pscustomobject]@{
      prijs = $prijs
      doos  = if ($null -ne $o.doos -and [int]$o.doos -gt 0) { [int]$o.doos } else { 1 }
      lev   = [string]$o.leverancier
    }
  }
}

# ---- beschikbaarheid van een set = beperkende component ---------------------
function SetAvailable([int]$prodId) {
  $min = [int]::MaxValue
  foreach ($c in $componentsOf[$prodId].Keys) {
    $m = $componentsOf[$prodId][$c]
    if ($m -le 0) { continue }
    $canMake = [math]::Floor(([int]$stock[$c]) / $m)
    if ($canMake -lt $min) { $min = $canMake }
  }
  if ($min -eq [int]::MaxValue) { return 0 }
  return [int]$min
}

# ---- output: inkoopregels (componentniveau) ---------------------------------
$inkoop = New-Object System.Collections.ArrayList
foreach ($prodId in $demand.Keys) {
  $d = $demand[$prodId]
  if ($d.q90 -le 0) { continue }
  [void]$inkoop.Add([pscustomobject]@{
    pid      = $prodId
    sku      = if ($name.ContainsKey($prodId) -and $name[$prodId]) { $name[$prodId] } else { "(zonder SKU-naam, product $prodId)" }
    voorraad = [int]$stock[$prodId]
    q7       = $d.q7
    q28      = $d.q28
    q90      = $d.q90
    bo       = $d.bo
    viaSets  = $d.viaSets
    inb      = if ($inbound.ContainsKey($prodId)) { @($inbound[$prodId]) } else { @() }
    doos     = if ($aanbod.ContainsKey($prodId)) { $aanbod[$prodId].doos }  else { 0 }
    prijs    = if ($aanbod.ContainsKey($prodId)) { $aanbod[$prodId].prijs } else { 0 }
    lev      = if ($aanbod.ContainsKey($prodId)) { $aanbod[$prodId].lev }   else { "" }
  })
}

# ---- output: verkoopregels (alles wat de klant koopt, incl. sets) -----------
$verkoop = New-Object System.Collections.ArrayList
foreach ($prodId in $sales.Keys) {
  $s = $sales[$prodId]
  if ($s.q90 -le 0) { continue }
  $set = $isSet.ContainsKey($prodId)
  [void]$verkoop.Add([pscustomobject]@{
    pid      = $prodId
    sku      = if ($name.ContainsKey($prodId) -and $name[$prodId]) { $name[$prodId] } else { "(zonder SKU-naam, product $prodId)" }
    voorraad = if ($set) { SetAvailable $prodId } else { [int]$stock[$prodId] }
    isSet    = $set
    q7       = $s.q7
    q28      = $s.q28
    q90      = $s.q90
    bo       = $s.bo
    ret      = if ($retour.ContainsKey($prodId)) { $retour[$prodId].r90 } else { 0 }
    inb      = if ((-not $set) -and $inbound.ContainsKey($prodId)) { @($inbound[$prodId]) } else { @() }
  })
}

# ---- totalen ----------------------------------------------------------------
# Sets tellen niet mee in voorraadtotalen: hun aantal is afgeleid van de
# onderdelen, dus meetellen zou dezelfde fysieke stuks dubbel tellen.
$dood = 0; $doodSkus = 0; $fysiek = 0; $fysiekSkus = 0; $setVoorraad = 0
foreach ($prodId in $stock.Keys) {
  if ($isSet.ContainsKey($prodId)) { $setVoorraad += [int]$stock[$prodId]; continue }
  $fysiek += [int]$stock[$prodId]; $fysiekSkus++
  if ((-not $sales.ContainsKey($prodId)) -and ([int]$stock[$prodId] -gt 0)) {
    $dood += [int]$stock[$prodId]; $doodSkus++
  }
}

$out = [pscustomobject]@{
  gegenereerd       = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  peildatum         = $Peildatum
  totaalVoorraad    = $fysiek
  setVoorraad       = $setVoorraad
  aantalSkus        = $fysiekSkus
  retourOngekoppeld = $retOngekoppeld
  inboundStuks      = $poGekoppeld
  inboundLos        = @($poLos)
  doodStuks         = $dood
  doodSkus          = $doodSkus
  inkoop            = $inkoop
  verkoop           = $verkoop
  po                = '__PO__'
  daily             = '__DAILY__'
}

$json = $out | ConvertTo-Json -Depth 6 -Compress

# PowerShell 5.1 schrijft een lege array als {} en een array met één element als
# een kaal object. De inb-regels zijn plat, dus beide vormen zetten we terug.
$json = $json -replace '"inb":\{\}', '"inb":[]'
$json = [regex]::Replace($json, '"inb":(\{"eta":[^{}]*\})', '"inb":[$1]')

# po en daily komen ongewijzigd uit hun bronbestand. Ze eerst door ConvertFrom-Json
# halen en dan weer terugschrijven levert {"value":[...],"Count":n} op - een bekende
# eigenaardigheid van PowerShell 5.1 - dus plakken we de ruwe JSON er direct in.
$json = $json.Replace('"__PO__"',    ([IO.File]::ReadAllText((Join-Path $cwd 'raw_po.json'))).Trim())
$json = $json.Replace('"__DAILY__"', ([IO.File]::ReadAllText((Join-Path $cwd 'raw_daily.json'))).Trim())

[IO.File]::WriteAllText((Join-Path $cwd 'dataset.json'), $json)

Write-Output "inkoopregels    : $($inkoop.Count)"
Write-Output "verkoopregels   : $($verkoop.Count)"
Write-Output "sets            : $($children.Count)"
Write-Output "fysieke voorraad: $fysiek stuks over $fysiekSkus SKU's (sets apart: $setVoorraad afgeleid)"
Write-Output "dode voorraad   : $dood stuks over $doodSkus SKU's"
Write-Output "retour los      : $retOngekoppeld stuks"
Write-Output "inkomend        : $poGekoppeld stuks over $($inbound.Count) producten"
if ($poLos.Count) { Write-Output "NIET GEKOPPELD  : $($poLos.Count) regels"; foreach ($x in $poLos) { Write-Output "  - $x" } }
Write-Output "dataset.json    : $((Get-Item (Join-Path $cwd 'dataset.json')).Length) bytes"
