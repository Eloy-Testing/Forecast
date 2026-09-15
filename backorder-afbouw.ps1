# Hoeveel van de huidige backorders lost elke aankomende container op?
#
# Twee doorrekeningen naast elkaar:
#   A. kale toewijzing  - containerinhoud tegen de backorder van vandaag, in ETA-volgorde.
#                         Negeert nieuwe verkoop, dus dit is de bovengrens.
#   B. met doorverkoop  - dag voor dag: verkoop erbij, container eraf. Realistisch,
#                         want de voorraad die binnenkomt wordt ook meteen verkocht.
$ErrorActionPreference = 'Stop'
$cwd = (Get-Location).Path
$d   = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $cwd 'dataset.json')))
$peil = [datetime]$d.peildatum

# Containers op volgorde van aankomst; alleen die met inhoud per SKU.
$containers = @(@($d.po) | Where-Object { $_.detail } | Sort-Object eta)

Write-Output "peildatum: $($d.peildatum)"
Write-Output "containers met inhoud per SKU: $($containers.Count)`n"

$boTotaal = 0
foreach ($r in $d.inkoop) { $boTotaal += [int]$r.bo }

# ---------- A. kale toewijzing ----------
$resterend = @{}   # pid -> nog openstaande backorder
foreach ($r in $d.inkoop) { if ($r.bo -gt 0) { $resterend[[int]$r.pid] = [int]$r.bo } }

$rijA = New-Object System.Collections.ArrayList
foreach ($c in $containers) {
  $gedekt = 0; $skusVol = 0; $skusDeels = 0
  foreach ($r in $d.inkoop) {
    $id = [int]$r.pid
    if (-not $resterend.ContainsKey($id) -or $resterend[$id] -le 0) { continue }
    $komt = 0
    foreach ($i in @($r.inb)) { if ($i -and $i.eta -eq $c.eta) { $komt += [int]$i.qty } }
    if ($komt -le 0) { continue }
    $dekt = [math]::Min($komt, $resterend[$id])
    $gedekt += $dekt
    if ($dekt -ge $resterend[$id]) { $skusVol++ } else { $skusDeels++ }
    $resterend[$id] -= $dekt
  }
  [void]$rijA.Add([pscustomobject]@{
    container = $c.naam; eta = $c.eta; stuks = $c.stuks
    dekt = $gedekt; volledig = $skusVol; deels = $skusDeels
  })
}
$naA = 0; foreach ($v in $resterend.Values) { $naA += $v }

Write-Output "=== A. Kale toewijzing (bovengrens, negeert nieuwe verkoop) ==="
$rijA | Format-Table -AutoSize @{n='Container';e={$_.container}}, @{n='ETA';e={$_.eta}},
  @{n='stuks in container';e={$_.stuks}}, @{n='lost backorder op';e={$_.dekt}},
  @{n='SKUs volledig';e={$_.volledig}}, @{n='SKUs deels';e={$_.deels}}
Write-Output "backorder nu        : $boTotaal stuks"
Write-Output "opgelost door alle 3: $($boTotaal - $naA) stuks"
Write-Output "blijft open         : $naA stuks`n"

# ---------- B. met doorverkoop ----------
# Balans per SKU: negatief = backorder. Verkoop verlaagt, container verhoogt.
$saldo = @{}; $perDag = @{}; $inbPer = @{}
foreach ($r in $d.inkoop) {
  $id = [int]$r.pid
  $saldo[$id]  = [double]($r.voorraad - $r.bo)
  $perDag[$id] = $r.q28 / 28.0
  $lijst = @{}
  foreach ($i in @($r.inb)) { if ($i -and $i.eta) {
    $dag = ([datetime]$i.eta - $peil).Days
    if ($dag -lt 0) { $dag = 0 }
    $lijst[$dag] = [int]$lijst[$dag] + [int]$i.qty
  } }
  $inbPer[$id] = $lijst
}

function BackorderNu($saldoMap) {
  $t = 0.0
  foreach ($v in $saldoMap.Values) { if ($v -lt 0) { $t += -$v } }
  return [math]::Round($t, 0)
}

$mijlpalen = @{}
foreach ($c in $containers) { $mijlpalen[([datetime]$c.eta - $peil).Days] = $c }
$laatsteDag = ($mijlpalen.Keys | Measure-Object -Maximum).Maximum

$rijB = New-Object System.Collections.ArrayList
$voor = BackorderNu $saldo
for ($dag = 0; $dag -le $laatsteDag; $dag++) {
  foreach ($id in @($saldo.Keys)) {
    $bij = $inbPer[$id][$dag]
    if ($bij) { $saldo[$id] = $saldo[$id] + $bij }
  }
  if ($mijlpalen.ContainsKey($dag)) {
    $na = BackorderNu $saldo
    [void]$rijB.Add([pscustomobject]@{
      container = $mijlpalen[$dag].naam; eta = $mijlpalen[$dag].eta
      voor = $voor; na = $na; verschil = $voor - $na
    })
    $voor = $na
  }
  foreach ($id in @($saldo.Keys)) { $saldo[$id] = $saldo[$id] - $perDag[$id] }
}

Write-Output "=== B. Met doorverkoop erbij (realistisch) ==="
$rijB | Format-Table -AutoSize @{n='Container';e={$_.container}}, @{n='ETA';e={$_.eta}},
  @{n='backorder ervoor';e={$_.voor}}, @{n='backorder erna';e={$_.na}}, @{n='netto eraf';e={$_.verschil}}
Write-Output "backorder na de laatste container: $(BackorderNu $saldo) stuks"
