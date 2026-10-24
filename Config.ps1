# Config.ps1 - config.json schema and defaults, plus the Sinric app secret.
#
# The app secret is what proves a command really came from your Sinric account, so it is never
# stored in plain text: sinric.appSecretProtected holds it encrypted with DPAPI (ConvertFrom-SecureString),
# which only this Windows user on this PC can decrypt.
#
# Dot-sourced by Agente.ps1, Configurar.ps1 and install.ps1.

function New-ApcDefaultConfig {
    return [pscustomobject]@{
        sinric   = [pscustomobject]@{
            appKey = ''; appSecretProtected = ''
            devices = [pscustomobject]@{ gameMode = ''; computer = ''; invisibleMode = '' }
        }
        gameMode = [pscustomobject]@{
            tvName = ''; tvPath = ''          # monitor chosen as the TV (Apc.Monitor Name / DevicePath)
            audioName = ''                    # audio output for the TV; empty = the one named after the TV
            tvPrimary = $true; bigPicture = $true; closeGameOnOff = $false; waitTvSeconds = 30
        }
        computer = [pscustomobject]@{
            powerOff = 'sleep'                # sleep | hibernate | shutdown
            volumeStep = 10
            # Alexa input name -> audio output ("Alexa, muda a entrada do computador para TV")
            inputs = @([pscustomobject]@{ input = 'TV'; audioName = '' }, [pscustomobject]@{ input = 'AUX 1'; audioName = '' })
        }
        # "Alexa, muda o canal do computador para 2" -> @{ number; name; appId; aliases }
        channels = @()
    }
}

# Fills whatever the file lacks with the defaults, recursively, so older files keep working.
function Merge-ApcConfig($Default, $Actual) {
    if ($null -eq $Actual) { return $Default }
    if ($Default -isnot [pscustomobject]) { return $Actual }
    foreach ($p in $Default.PSObject.Properties) {
        $have = $Actual.PSObject.Properties[$p.Name]
        if ($null -eq $have) { $Actual | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
        else { $have.Value = Merge-ApcConfig $p.Value $have.Value }
    }
    return $Actual
}

function Read-ApcConfig([string]$Path) {
    $actual = $null
    if (Test-Path $Path) { $actual = Get-Content -Raw -Encoding UTF8 $Path | ConvertFrom-Json }
    $cfg = Merge-ApcConfig (New-ApcDefaultConfig) $actual
    $cfg.channels = @($cfg.channels); $cfg.computer.inputs = @($cfg.computer.inputs)
    return $cfg
}

function Save-ApcConfig($Cfg, [string]$Path) {
    $json = $Cfg | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Get-ApcSecret($Cfg) {
    $enc = [string]$Cfg.sinric.appSecretProtected
    if (-not $enc) { return '' }
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $enc))
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { return '' }   # encrypted by another user or PC: has to be typed again
}

function Set-ApcSecret($Cfg, [string]$Plain) {
    if (-not $Plain) { $Cfg.sinric.appSecretProtected = ''; return }
    $Cfg.sinric.appSecretProtected = ConvertTo-SecureString $Plain -AsPlainText -Force | ConvertFrom-SecureString
}

# Human-readable reason the agent cannot connect yet, or $null when it can.
function Get-ApcMissingSetup($Cfg) {
    if (-not $Cfg.sinric.appKey) { return 'Falta o App Key do Sinric Pro.' }
    if (-not (Get-ApcSecret $Cfg)) { return 'Falta o App Secret do Sinric Pro.' }
    $d = $Cfg.sinric.devices
    if (-not ($d.gameMode -or $d.computer -or $d.invisibleMode)) { return 'Falta o ID de pelo menos um dispositivo.' }
    return $null
}
