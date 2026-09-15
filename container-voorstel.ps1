# Beantwoordt vraag 3 uit het inkoopmemo: wat moet er in de container die deze
# week de deur uit gaat, hoeveel per SKU, en wat kost dat.
#
# Aanname: bestellen vandaag => verkoopbaar na LEVERTIJD dagen. Daarna moet de
# voorraad DEKKING dagen meegaan, tot de container daarna binnen is.
param([int]$Levertijd = 90, [int]$Dekking = 90, [int]$Capaciteit = 7200)

$ErrorActionPreference = 'Stop'
$cwd = (Get-Location).Path
$vandaag = [datetime]'2026-09-14'
$aankomst = $vandaag.AddDays($Levertijd)

$d      = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $cwd 'dataset.json')))
$offers = (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $cwd 'raw_offers.json')))).rows

# Beste aanbieding per product: laagste prijs met een bekende dooshoeveelheid.
$aanbod = @{}
foreach ($o in $offers) {
  $prodId = [int]$o.pid
  $prijs = [double]$o.prijs
  if ($prijs -le 0) { continue }
  $huidig = $aanbod[$prodId]
  if ($null -eq $huidig -or $prijs -lt $huidig.prijs) {
    $aanbod[$prodId] = [pscustomobject]@{
      prijs = $prijs
      doos  = if ($null -ne $o.doos -and [int]$o.doos -gt 0) { [int]$o.doos } else { 1 }
      lev   = [string]$o.leverancier
    }
  }
}

$regels = New-Object System.Collections.ArrayList
$geenAanbod = New-Object System.Collections.ArrayList

foreach ($r in $d.inkoop) {
  $perDag = $r.q28 / 28.0
  if ($perDag -le 0) { continue }

  # Voorraad op het moment dat de nieuwe container binnen is, met alles wat
  # er tot dan toe al aankomt. Ondergrens nul: wat je niet hebt verkoop je niet.
  $s = $r.voorraad - $r.bo
  $komt = @()
  foreach ($i in @($r.inb)) { if ($i -and $i.eta) { $komt += ,@( ([datetime]$i.eta - $vandaag).Days, [int]$i.qty ) } }
  for ($day = 0; $day -le $Levertijd; $day++) {
    foreach ($k in $komt) { if ($k[0] -eq $day) { $s += $k[1] } }
    $s -= $perDag
    if ($s -lt 0) { $s = 0 }
  }
  $bijAankomst = [math]::Floor($s)

  $nodig = [math]::Ceiling($perDag * $Dekking) - $bijAankomst
  if ($nodig -le 0) { continue }

  $a = $aanbod[[int]$r.pid]
  if ($null -eq $a) {
    [void]$geenAanbod.Add([pscustomobject]@{ sku=$r.sku; nodig=$nodig; perWeek=[math]::Round($perDag*7,1) })
    continue
  }

  # Afronden op hele dozen.
  $dozen  = [math]::Ceiling($nodig / $a.doos)
  $bestel = $dozen * $a.doos
  $bedrag = [math]::Round($bestel * $a.prijs, 2)

  # Urgentie: hoeveel dagen dekking is er nog op het moment van aankomst.
  # Nul betekent dat de SKU dan al droog staat en er nee verkocht wordt.
  $dagenBijAankomst = if ($perDag -gt 0) { [math]::Round($bijAankomst / $perDag, 1) } else { 999 }

  [void]$regels.Add([pscustomobject]@{
    sku         = $r.sku
    perWeek     = [math]::Round($perDag * 7, 1)
    nu          = $r.voorraad - $r.bo
    bijAankomst = $bijAankomst
    dagenOver   = $dagenBijAankomst
    nodig       = $nodig
    doos        = $a.doos
    dozen       = $dozen
    bestel      = $bestel
    prijs       = $a.prijs
    bedrag      = $bedrag
    leverancier = $a.lev
  })
}

# Meest urgent eerst: wie op de aankomstdatum het langst al droog staat.
$gesorteerd = $regels | Sort-Object -Property @{e='dagenOver'}, @{e='perWeek';Descending=$true}

Write-Output "CONTAINERVOORSTEL - bestellen vandaag $($vandaag.ToString('dd-MM-yyyy')), verkoopbaar rond $($aankomst.ToString('dd-MM-yyyy'))"
Write-Output "Dekking na aankomst: $Dekking dagen | containercapaciteit: $Capaciteit stuks`n"

# Greedy vullen op urgentie tot de container vol is.
$inContainer = New-Object System.Collections.ArrayList
$vol = 0
foreach ($r in $gesorteerd) {
  if ($vol + $r.bestel -gt $Capaciteit) { continue }
  [void]$inContainer.Add($r); $vol += $r.bestel
}

Write-Output "=== WEL MEE IN DEZE CONTAINER (top 25 van $($inContainer.Count) regels) ==="
$inContainer | Select-Object -First 25 | Format-Table -AutoSize `
  @{n='SKU';e={$_.sku.Substring(0,[Math]::Min(40,$_.sku.Length))}},
  @{n='p/wk';e={$_.perWeek}}, @{n='nu';e={$_.nu}}, @{n='dgn over';e={$_.dagenOver}},
  @{n='bestel';e={$_.bestel}}, @{n='doos';e={$_.doos}}, @{n='prijs';e={$_.prijs}}, @{n='bedrag';e={$_.bedrag}}

$stuksC  = ($inContainer | Measure-Object -Property bestel -Sum).Sum
$bedragC = ($inContainer | Measure-Object -Property bedrag -Sum).Sum
$stuks   = ($gesorteerd  | Measure-Object -Property bestel -Sum).Sum
$bedrag  = ($gesorteerd  | Measure-Object -Property bedrag -Sum).Sum

Write-Output ""
Write-Output "IN DEZE CONTAINER : $($inContainer.Count) regels | $stuksC stuks | EUR $([math]::Round($bedragC,0))"
Write-Output "VOLLEDIGE BEHOEFTE: $($gesorteerd.Count) regels | $stuks stuks | EUR $([math]::Round($bedrag,0))"
Write-Output "  => dat is $([math]::Round($stuks/$Capaciteit,1)) containers voor $Dekking dagen dekking"
if ($geenAanbod.Count) {
  Write-Output ""
  Write-Output "GEEN LEVERANCIERSAANBOD ($($geenAanbod.Count) SKU's) - deze kan het systeem niet bestellen:"
  $geenAanbod | Sort-Object -Property nodig -Descending | Select-Object -First 15 |
    Format-Table -AutoSize @{n='SKU';e={$_.sku.Substring(0,[Math]::Min(44,$_.sku.Length))}}, perWeek, nodig
}

$gesorteerd | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 (Join-Path $cwd 'container-voorstel.json')
