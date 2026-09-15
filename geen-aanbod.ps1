# Lijst de SKU's die besteld zouden moeten worden maar geen leveranciersaanbod
# hebben. Zelfde rekenregel als het dashboard: levertijd 90, dekking 90.
param([int]$Levertijd = 90, [int]$Dekking = 90)
$ErrorActionPreference = 'Stop'
$cwd = (Get-Location).Path
$vandaag = [datetime]'2026-09-14'

$d = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $cwd 'dataset.json')))

# SKU's die StockItUp zelf als "ongeschikt voor inkoopadvies" markeert.
$ongeschikt = @(
  '','Big Brush - LuxeSteam','Froggyroller','Gehoor_Beige','Gehoor_Blauw','Gehoor_Kind_Blauw',
  'Gehoor_Roze','Jacquard- Recliner one seat - Sage','Kam','Knitted -Stoelsokken - Bruin',
  'Knitted -Stoelsokken - Donkergrijs','Knitted -Stoelsokken - Lichtgrijs','Knitted -Stoelsokken - Zwart',
  'LUXESTEAM - PRO','LuxeSteam','Muisstil_Beige_Tobi','Muisstil_Pink_Tobi','Plushy-Green-70x70',
  'Plushy-Green-90x210','Plushy-Green-90x90','Plushy-Lightblue-70x70','Plushy-Lightblue-90x210',
  'Plushy-Lightblue-90x90','Plushy-Lightblue-Pillow','Plushy-Lightgrey-90x180','Plushy-Lightgrey-90x210',
  'Plushy-Lightgrey-90x90','Plushy-Lightgrey-Pillow','Polyester Kussenvulling','Premium Kit Size 1',
  'Premium Kit Size 2','Premium Kit Size 3 L','Premium Kit Size 4','RVS Voerbak','Scissor','Shippig',
  'TextielSpray',"Tobi's House - Hondenvoerbak",'Velvet - Stone Blue - M - Chair',
  'Velvet- Dining chair cover Big Size - Stone Blue','Velvet- Recliner one seat - black','nan'
)

$rijen = New-Object System.Collections.ArrayList
foreach ($r in $d.inkoop) {
  $perDag = $r.q28 / 28.0
  if ($perDag -le 0) { continue }

  # voorraad op de dag dat een order van vandaag zou landen
  $s = $r.voorraad - $r.bo
  $komt = @()
  foreach ($i in @($r.inb)) { if ($i -and $i.eta) { $komt += ,@( ([datetime]$i.eta - $vandaag).Days, [int]$i.qty ) } }
  for ($day = 0; $day -le $Levertijd; $day++) {
    foreach ($k in $komt) { if ($k[0] -eq $day) { $s += $k[1] } }
    $s -= $perDag
    if ($s -lt 0) { $s = 0 }
  }
  $bijAankomst = [math]::Floor($s)
  $tekort = [math]::Ceiling($perDag * $Dekking) - $bijAankomst
  if ($tekort -le 0) { continue }
  if ($r.doos -gt 0 -and $r.prijs -gt 0) { continue }   # heeft wel aanbod

  [void]$rijen.Add([pscustomobject]@{
    SKU        = $r.sku
    id         = $r.pid
    perWeek    = [math]::Round($perDag * 7, 1)
    voorraad   = $r.voorraad
    backorder  = $r.bo
    inkomend   = (@($r.inb) | Measure-Object -Property qty -Sum).Sum
    tekort     = [int]$tekort
    ongeschikt = if ($ongeschikt -contains $r.sku) { 'ja' } else { '-' }
  })
}

$gesorteerd = $rijen | Sort-Object -Property tekort -Descending
$gesorteerd | Format-Table -AutoSize `
  @{n='SKU';e={$_.SKU}}, @{n='id';e={$_.id}}, @{n='p/week';e={$_.perWeek}},
  @{n='vrd';e={$_.voorraad}}, @{n='BO';e={$_.backorder}}, @{n='onderweg';e={$_.inkomend}},
  @{n='tekort';e={$_.tekort}}, @{n='ongeschikt';e={$_.ongeschikt}}

Write-Output ""
Write-Output "SKU's zonder leveranciersaanbod : $($gesorteerd.Count)"
Write-Output "stuks tekort                    : $(($gesorteerd | Measure-Object -Property tekort -Sum).Sum)"
Write-Output "waarvan door StockItUp als ongeschikt gemarkeerd: $(($gesorteerd | Where-Object { $_.ongeschikt -eq 'ja' }).Count)"
