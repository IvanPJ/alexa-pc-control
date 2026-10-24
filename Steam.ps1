# Steam.ps1 - everything Alexa PC Control asks of Steam goes through steam:// links run by steam.exe.
#
# Deliberately reads ONLY steamapps\*.acf / libraryfolders.vdf and the RunningAppID registry value.
# Never read Steam account/login/user config files: that is what Steam account stealers do,
# and antivirus heuristics flag and delete scripts for it.
#
# Dot-sourced by Agente.ps1 and Configurar.ps1.

function Get-ApcSteamExe {
    try {
        $exe = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamExe -replace '/', '\'
        if ($exe -and (Test-Path $exe)) { return $exe }
    } catch { }
    $fallback = Join-Path ${env:ProgramFiles(x86)} 'Steam\steam.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

# -silent keeps the Steam window closed when the link has to start Steam first
function Invoke-ApcSteam([string]$Uri, [switch]$Silent) {
    $steam = Get-ApcSteamExe
    if (-not $steam) { throw 'Steam não encontrada.' }
    $arguments = @($Uri)
    if ($Silent) { $arguments = @('-silent', $Uri) }
    Start-Process -FilePath $steam -ArgumentList $arguments
}

function Set-ApcSteamStatus([string]$Status) { Invoke-ApcSteam ('steam://friends/status/' + $Status) -Silent }

# Installed games, from the library manifests: @{ AppId; Name; InstallDir; LastPlayed }
function Get-ApcSteamGames {
    try { $root = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath -replace '/', '\' } catch { return @() }
    $libs = @($root)
    $lf = Join-Path $root 'steamapps\libraryfolders.vdf'
    if (Test-Path $lf) { foreach ($m in [regex]::Matches((Get-Content -Raw $lf), '"path"\s*"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') } }
    $list = New-Object System.Collections.ArrayList
    foreach ($lib in ($libs | Select-Object -Unique)) {
        # a library can live on a drive that is not connected right now: skip it quietly
        $apps = [IO.Path]::Combine($lib, 'steamapps')
        if (-not [IO.Directory]::Exists($apps)) { continue }
        foreach ($f in Get-ChildItem $apps -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
            $txt = Get-Content -Raw -Encoding UTF8 $f.FullName
            $id = [regex]::Match($txt, '"appid"\s*"(\d+)"').Groups[1].Value
            $nm = [regex]::Match($txt, '"name"\s*"([^"]+)"').Groups[1].Value
            if (-not $id -or -not $nm -or $nm -match 'Redistributable|Steamworks|Proton|Runtime|Steam Linux') { continue }
            $dir = [regex]::Match($txt, '"installdir"\s*"([^"]+)"').Groups[1].Value
            $lp = [int64]0; $m = [regex]::Match($txt, '"LastPlayed"\s*"(\d+)"'); if ($m.Success) { $lp = [int64]$m.Groups[1].Value }
            [void]$list.Add([pscustomobject]@{ AppId = $id; Name = $nm; InstallDir = [IO.Path]::Combine($apps, 'common', $dir); LastPlayed = $lp })
        }
    }
    return @($list | Sort-Object Name)
}

function Get-ApcRunningAppId {
    try { return [int](Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).RunningAppID } catch { return 0 }
}

function Start-ApcGame([string]$AppId) { Invoke-ApcSteam ('steam://rungameid/' + $AppId) }

# Closes the game Steam says is running: asks its windows to close, then ends whatever is left
# of the processes started from the game folder.
function Stop-ApcGame {
    $appId = Get-ApcRunningAppId
    if (-not $appId) { return $null }
    $game = Get-ApcSteamGames | Where-Object { $_.AppId -eq [string]$appId } | Select-Object -First 1
    if (-not $game) { return $null }
    $prefix = $game.InstallDir.TrimEnd('\') + '\'
    $procs = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch { } }
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline -and @($procs | Where-Object { -not $_.HasExited }).Count) { Start-Sleep -Milliseconds 500 }
    foreach ($p in $procs) { if (-not $p.HasExited) { try { $p.Kill() } catch { } } }
    return $game.Name
}

# ---------------------------------------------------------------- spoken name -> game

# "Elden Ring™: Nightreign" -> "elden ring nightreign"
function ConvertTo-ApcSpoken([string]$Text) {
    if (-not $Text) { return '' }
    $d = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $d.ToCharArray()) {
        $cat = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($cat -eq 'NonSpacingMark') { continue }
        if ([char]::IsLetterOrDigit($ch)) { [void]$sb.Append([char]::ToLowerInvariant($ch)) } else { [void]$sb.Append(' ') }
    }
    # "helldivers dois" / "hades ii" -> "... 2": Alexa may spell numbers out, game titles use digits or roman numerals
    $words = foreach ($w in ($sb.ToString() -split '\s+')) { if (-not $w) { continue }; if ($ApcNumberWords.ContainsKey($w)) { $ApcNumberWords[$w] } else { $w } }
    return @($words) -join ' '
}
$ApcNumberWords = @{
    um = '1'; uma = '1'; dois = '2'; duas = '2'; tres = '3'; quatro = '4'; cinco = '5'; seis = '6'; sete = '7'; oito = '8'; nove = '9'; dez = '10'
    ii = '2'; iii = '3'; iv = '4'; vi = '6'; vii = '7'; viii = '8'; ix = '9'
}

function Get-ApcSimilarity([string]$A, [string]$B) {
    # 0..1, from the edit distance of the two normalized strings
    if ($A -eq $B) { return 1.0 }
    if (-not $A -or -not $B) { return 0.0 }
    $prev = 0..$B.Length
    for ($i = 1; $i -le $A.Length; $i++) {
        $cur = @($i) + (@(0) * $B.Length)
        for ($j = 1; $j -le $B.Length; $j++) {
            $cost = [int]($A[$i - 1] -ne $B[$j - 1])
            $cur[$j] = [Math]::Min([Math]::Min($cur[$j - 1] + 1, $prev[$j] + 1), $prev[$j - 1] + $cost)
        }
        $prev = $cur
    }
    return 1.0 - ($prev[$B.Length] / [Math]::Max($A.Length, $B.Length))
}

# Best match for what Alexa heard among the configured channels (name + nicknames) and then
# every installed game. Returns @{ AppId; Name } or $null when nothing is close enough.
function Find-ApcGame([string]$Spoken, $Channels) {
    $want = ConvertTo-ApcSpoken $Spoken
    if (-not $want) { return $null }
    $candidates = New-Object System.Collections.ArrayList
    foreach ($c in @($Channels)) {
        if (-not $c.appId) { continue }
        foreach ($n in @($c.name) + @($c.aliases)) { if ($n) { [void]$candidates.Add(@{ AppId = [string]$c.appId; Name = [string]$c.name; Key = (ConvertTo-ApcSpoken $n) }) } }
    }
    foreach ($g in Get-ApcSteamGames) { [void]$candidates.Add(@{ AppId = $g.AppId; Name = $g.Name; Key = (ConvertTo-ApcSpoken $g.Name) }) }

    $best = $null; $bestScore = 0.0
    foreach ($c in $candidates) {
        $score = Get-ApcSimilarity $want $c.Key
        # "elden" for "elden ring", "hades" for "hades ii": a whole-word prefix is a strong hint
        if ($c.Key.StartsWith($want + ' ') -or $want.StartsWith($c.Key + ' ')) { $score = [Math]::Max($score, 0.85) }
        if ($score -gt $bestScore) { $best = $c; $bestScore = $score }
    }
    if ($bestScore -lt 0.6) { return $null }
    return @{ AppId = $best.AppId; Name = $best.Name }
}
