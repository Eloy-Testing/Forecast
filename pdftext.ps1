# Haalt tekst uit een PDF met subset-fonts: decodeert <hex> glyph-ID's via de
# ToUnicode-CMap per font. Geen externe tools nodig.
param([Parameter(Mandatory=$true)][string]$Path, [string]$Out, [switch]$Stats)

$ErrorActionPreference = 'Stop'
$bytes = [IO.File]::ReadAllBytes($Path)
$enc   = [Text.Encoding]::GetEncoding(28591)   # latin1: byte == char, offsets kloppen
$raw   = $enc.GetString($bytes)

function Inflate([byte[]]$data) {
  foreach ($skip in @(2,0,1)) {
    if ($data.Length -le $skip) { continue }
    try {
      $ms = New-Object IO.MemoryStream(,([byte[]]$data[$skip..($data.Length-1)]))
      $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Decompress)
      $o  = New-Object IO.MemoryStream
      try { $ds.CopyTo($o) } catch { }
      $ds.Dispose(); $ms.Dispose()
      if ($o.Length -gt 0) { return $o.ToArray() }
    } catch { }
  }
  return @()
}

# ---- objecten indexeren -----------------------------------------------------
$objBody = @{}     # objnummer -> ruwe body (latin1)
$objData = @{}     # objnummer -> gedecomprimeerde streaminhoud
foreach ($m in [regex]::Matches($raw, '(?m)^(\d+)\s+0\s+obj')) {
  $num = [int]$m.Groups[1].Value
  $s   = $m.Index + $m.Length
  $e   = $raw.IndexOf("endobj", $s); if ($e -lt 0) { continue }
  $objBody[$num] = $raw.Substring($s, $e - $s)

  $sm = [regex]::Match($objBody[$num], '(?<!end)stream\r?\n?')
  if ($sm.Success) {
    $b = $s + $sm.Index + $sm.Length
    $se = $raw.IndexOf("endstream", $b)
    if ($se -gt $b) {
      $len = $se - $b
      $chunk = New-Object byte[] $len
      [Array]::Copy($bytes, $b, $chunk, 0, $len)
      # Alleen inflaten als de dict dat declareert: DeflateStream levert op
      # ongecomprimeerde data soms tóch bytes op, en dat vervuilt de inhoud.
      $dict = $objBody[$num].Substring(0, [Math]::Min($sm.Index, $objBody[$num].Length))
      if ($dict -match '/FlateDecode') {
        $inf = Inflate $chunk
        $objData[$num] = if ($inf.Length -gt 0) { $enc.GetString($inf) } else { "" }
      } else {
        $objData[$num] = $enc.GetString($chunk)
      }
    }
  }
}

# ---- ToUnicode-CMaps parsen -------------------------------------------------
function ParseCMap([string]$cmap) {
  $map = @{}
  foreach ($blk in [regex]::Matches($cmap, '(?s)beginbfchar(.*?)endbfchar')) {
    foreach ($p in [regex]::Matches($blk.Groups[1].Value, '<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>')) {
      $src = [Convert]::ToInt32($p.Groups[1].Value, 16)
      $dstHex = $p.Groups[2].Value
      $sb2 = ""
      for ($i=0; $i+3 -lt $dstHex.Length+1; $i+=4) {
        if ($i+4 -le $dstHex.Length) { $sb2 += [char][Convert]::ToInt32($dstHex.Substring($i,4),16) }
      }
      $map[$src] = $sb2
    }
  }
  foreach ($blk in [regex]::Matches($cmap, '(?s)beginbfrange(.*?)endbfrange')) {
    $body = $blk.Groups[1].Value
    # vorm: <lo> <hi> <start>
    foreach ($p in [regex]::Matches($body, '<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>')) {
      $lo = [Convert]::ToInt32($p.Groups[1].Value,16)
      $hi = [Convert]::ToInt32($p.Groups[2].Value,16)
      $st = [Convert]::ToInt32($p.Groups[3].Value,16)
      for ($c=$lo; $c -le $hi -and $c-$lo -lt 65536; $c++) { $map[$c] = [char]($st + ($c-$lo)) }
    }
    # vorm: <lo> <hi> [<a> <b> ...]
    foreach ($p in [regex]::Matches($body, '(?s)<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*\[(.*?)\]')) {
      $lo = [Convert]::ToInt32($p.Groups[1].Value,16)
      $i = 0
      foreach ($q in [regex]::Matches($p.Groups[3].Value, '<([0-9A-Fa-f]+)>')) {
        $h = $q.Groups[1].Value
        $s2 = ""
        for ($k=0; $k+4 -le $h.Length; $k+=4) { $s2 += [char][Convert]::ToInt32($h.Substring($k,4),16) }
        $map[$lo + $i] = $s2; $i++
      }
    }
  }
  return $map
}

# fontnaam (/F6) -> cmap, via /Font << /F6 12 0 R >> in de resources
$fontMap = @{}
foreach ($fm in [regex]::Matches($raw, '(?s)/Font\s*<<(.*?)>>')) {
  foreach ($fr in [regex]::Matches($fm.Groups[1].Value, '/(\w+)\s+(\d+)\s+0\s+R')) {
    $fname = $fr.Groups[1].Value
    $fobj  = [int]$fr.Groups[2].Value
    if (-not $objBody.ContainsKey($fobj)) { continue }
    $tu = [regex]::Match($objBody[$fobj], '/ToUnicode\s+(\d+)\s+0\s+R')
    if (-not $tu.Success) { continue }
    $tuObj = [int]$tu.Groups[1].Value
    if ($objData.ContainsKey($tuObj)) { $fontMap[$fname] = ParseCMap $objData[$tuObj] }
  }
}

# ---- contentstreams decoderen ----------------------------------------------
$lines = New-Object System.Collections.ArrayList
foreach ($num in $objData.Keys) {
  $txt = $objData[$num]
  if ($txt -notmatch '\bT[jJ]\b') { continue }

  $cur = $null
  $line = New-Object Text.StringBuilder

  foreach ($op in [regex]::Matches($txt, '/(\w+)\s+[\d.]+\s+Tf|(-?[\d.]+)\s+(-?[\d.]+)\s+Td|Tm|T\*|<([0-9A-Fa-f]+)>\s*Tj|\[(.*?)\]\s*TJ')) {
    $v = $op.Value
    if ($op.Groups[1].Success) { $cur = $fontMap[$op.Groups[1].Value]; continue }
    if ($v -eq 'Tm' -or $v -eq 'T*') {
      if ($line.Length) { [void]$lines.Add($line.ToString()); $line.Clear() | Out-Null }
      continue
    }
    if ($op.Groups[3].Success) {           # Td: y != 0 betekent nieuwe regel
      # Spaties staan als echte glyph in de CMap, dus alleen op y-sprong afbreken.
      if ([double]$op.Groups[3].Value -ne 0) {
        if ($line.Length) { [void]$lines.Add($line.ToString()); $line.Clear() | Out-Null }
      }
      continue
    }
    $hexes = @()
    if ($op.Groups[4].Success) { $hexes = @($op.Groups[4].Value) }
    elseif ($op.Groups[5].Success) { $hexes = [regex]::Matches($op.Groups[5].Value,'<([0-9A-Fa-f]+)>') | ForEach-Object { $_.Groups[1].Value } }
    foreach ($h in $hexes) {
      for ($i=0; $i+4 -le $h.Length; $i+=4) {
        $code = [Convert]::ToInt32($h.Substring($i,4),16)
        if ($cur -and $cur.ContainsKey($code)) { [void]$line.Append($cur[$code]) }
        elseif ($code -ge 32 -and $code -lt 127) { [void]$line.Append([char]$code) }
      }
    }
  }
  if ($line.Length) { [void]$lines.Add($line.ToString()) }
}

$result = ($lines | ForEach-Object { ($_ -replace '\s+',' ').Trim() } | Where-Object { $_ -ne "" }) -join "`n"

if ($Stats) { foreach($k in $fontMap.Keys){ Write-Output "font $k -> $($fontMap[$k].Count) tekens, code1='$($fontMap[$k][1])'" } }
if ($Stats) { Write-Output "objecten=$($objBody.Count) streams=$($objData.Count) fonts=$($fontMap.Count) regels=$($lines.Count)" }
if ($Out) { [IO.File]::WriteAllText($Out, $result, [Text.Encoding]::UTF8); Write-Output "$Out <- $($result.Length) tekens" }
else { Write-Output $result }
