# Agente.ps1 - Alexa PC Control agent: keeps a connection to Sinric Pro and runs what Alexa asks.
#
# Alexa -> Sinric Pro skill -> wss://ws.sinric.pro -> this script -> Windows / Steam.
# The connection is outgoing (like a browser tab), so no port is opened and no admin is needed.
# Every message is signed by Sinric with your app secret (HMAC-SHA256); unsigned or badly
# signed messages are refused.
#
# Three Sinric devices, each with a role:
#   gameMode       Switch  on: extend to the TV, TV as primary, audio on the TV, Big Picture
#                          off: put everything back the way it was
#   computer       TV      power off (sleep/hibernate/shut down), volume, mute, media keys,
#                          input -> default audio output, channel -> Steam game
#   invisibleMode  Switch  Steam friends status invisible / online
#
# Started hidden at logon by the task \AlexaPcControl\Agente. -Action runs one action and exits
# (the config window's test buttons use it).

[CmdletBinding()]
param(
    [ValidateSet('', 'GameModeOn', 'GameModeOff')] [string]$Action = '',
    [string]$Server = 'wss://ws.sinric.pro'
)

$ErrorActionPreference = 'Stop'
$InstallDir = $PSScriptRoot
$ConfigPath = Join-Path $InstallDir 'config.json'
$StatePath  = Join-Path $InstallDir 'estado.json'
$StatusPath = Join-Path $InstallDir 'status.json'
$LogPath    = Join-Path $InstallDir 'agente.log'
$AgentVersion = '1.0.0'

. (Join-Path $InstallDir 'Pc.ps1')
. (Join-Path $InstallDir 'Steam.ps1')
. (Join-Path $InstallDir 'Config.ps1')

$Apc = @{ Cfg = $null; ConfigStamp = $null; Socket = $null; Roles = @{}; Secret = ''; LastTick = Get-Date; Reconnect = $false }

# ---------------------------------------------------------------- log and status

function Write-ApcLog([string]$Text) {
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Text
    if ($Action) { Write-Host $line }
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) { Move-Item $LogPath ($LogPath + '.1') -Force }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Write-ApcStatus([hashtable]$Fields) {
    if ($Action) { return }
    $status = [ordered]@{}
    try { if (Test-Path $StatusPath) { (Get-Content -Raw $StatusPath | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $status[$_.Name] = $_.Value } } } catch { }
    foreach ($k in $Fields.Keys) { $status[$k] = $Fields[$k] }
    $status['pid'] = $PID
    $status['updated'] = (Get-Date).ToString('o')
    try { Set-Content -Path $StatusPath -Value ($status | ConvertTo-Json -Compress) -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- state that survives a restart

function Read-ApcState {
    try { if (Test-Path $StatePath) { return (Get-Content -Raw $StatePath | ConvertFrom-Json) } } catch { }
    return $null
}
function Save-ApcState($State) {
    if ($null -eq $State) { Remove-Item $StatePath -Force -ErrorAction SilentlyContinue; return }
    Set-Content -Path $StatePath -Value ($State | ConvertTo-Json -Depth 5) -Encoding UTF8
}
function Get-ApcBootId { return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o') }

# ---------------------------------------------------------------- game mode

function Get-ApcTv {
    $gm = $Apc.Cfg.gameMode
    if (-not $gm.tvPath -and -not $gm.tvName) { return $null }
    return Find-ApcMonitor $gm.tvPath $gm.tvName
}

function Get-ApcTvAudio([string]$TvName) {
    $name = $Apc.Cfg.gameMode.audioName
    if ($name) { return Find-ApcAudioDevice '' $name }
    return Find-ApcAudioForMonitor $TvName
}

function Enable-ApcGameMode {
    $gm = $Apc.Cfg.gameMode
    if (-not $gm.tvPath -and -not $gm.tvName) { Write-ApcLog 'Modo jogo: nenhuma TV escolhida na configuração.'; Send-ApcEvent 'gameMode' 'setPowerState' @{ state = 'Off' }; return }

    # the TV may still be waking up (a routine can turn it on right before calling this)
    $tv = $null
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, [int]$gm.waitTvSeconds))
    while ($true) {
        $tv = Get-ApcTv
        if ($tv -and $tv.Available) { break }
        if ((Get-Date) -gt $deadline) {
            Write-ApcLog ('Modo jogo: a TV "' + $gm.tvName + '" não apareceu em ' + $gm.waitTvSeconds + 's. Ela está ligada e na entrada do PC?')
            Send-ApcEvent 'gameMode' 'setPowerState' @{ state = 'Off' }
            return
        }
        Start-Sleep -Seconds 1
    }

    $state = Read-ApcState
    if (-not ($state -and $state.gameMode)) {
        # remember how things were, once, so "off" can put them back even after an agent restart
        $primary = Get-ApcMonitors | Where-Object Primary | Select-Object -First 1
        $state = [pscustomobject]@{ gameMode = [pscustomobject]@{
            bootId = Get-ApcBootId; snapshot = [Apc.Display]::Snapshot()
            tvWasActive = [bool]$tv.Active; primaryPath = $(if ($primary) { $primary.DevicePath } else { '' })
            audio = @([Apc.Audio]::DefaultId(0), [Apc.Audio]::DefaultId(1), [Apc.Audio]::DefaultId(2))
        } }
        Save-ApcState $state
    }

    if (-not $tv.Active) {
        $rc = [Apc.Display]::Extend()
        Write-ApcLog ('Modo jogo: telas em estender (' + $rc + ').')
        Start-Sleep -Milliseconds 1500
    }
    if ($gm.tvPrimary) {
        $rc = [Apc.Display]::SetPrimary($tv.DevicePath)
        Write-ApcLog ('Modo jogo: TV como tela principal (' + $rc + ').')
        Start-Sleep -Milliseconds 1000
    }

    # HDMI audio only exists once the screen is active: give it a few seconds to show up
    $audio = $null
    for ($i = 0; $i -lt 10 -and -not $audio; $i++) { $audio = Get-ApcTvAudio $tv.Name; if (-not $audio) { Start-Sleep -Milliseconds 700 } }
    if ($audio) { [Apc.Audio]::SetDefault($audio.Id); Write-ApcLog ('Modo jogo: áudio em ' + $audio.Name + '.') }
    else { Write-ApcLog 'Modo jogo: não achei a saída de áudio da TV; o áudio ficou onde estava.' }

    if ($gm.bigPicture) {
        Invoke-ApcSteam 'steam://open/bigpicture'
        Write-ApcLog 'Modo jogo: Big Picture aberto.'
        Move-ApcBigPictureToTv $tv.DevicePath
    }
}

# Big Picture opens on the primary screen; when the TV is not the primary one, move it there.
function Move-ApcBigPictureToTv([string]$TvPath) {
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        $hwnd = [Apc.Windows]::Find('Big Picture')
        if ($hwnd -ne [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 1500
            $tv = Get-ApcMonitors | Where-Object { $_.DevicePath -eq $TvPath -and $_.Active } | Select-Object -First 1
            if ($tv -and -not [Apc.Windows]::IsInside($hwnd, $tv.X, $tv.Y, $tv.Width, $tv.Height)) {
                [Apc.Windows]::MoveTo($hwnd, $tv.X, $tv.Y, $tv.Width, $tv.Height)
                Write-ApcLog 'Modo jogo: Big Picture movido para a TV.'
            }
            return
        }
        Start-Sleep -Milliseconds 700
    }
}

function Disable-ApcGameMode {
    $gm = $Apc.Cfg.gameMode
    if ($gm.bigPicture) { Invoke-ApcSteam 'steam://close/bigpicture'; Write-ApcLog 'Modo jogo: Big Picture fechado.' }
    if ($gm.closeGameOnOff) { $closed = Stop-ApcGame; if ($closed) { Write-ApcLog ('Modo jogo: ' + $closed + ' fechado.') } }

    $tv = Get-ApcTv
    $saved = $null; $state = Read-ApcState; if ($state) { $saved = $state.gameMode }
    $restored = $false
    if ($saved -and $saved.bootId -eq (Get-ApcBootId)) {
        $rc = [Apc.Display]::Restore($saved.snapshot)
        $restored = $rc -eq 0
        Write-ApcLog ('Modo jogo: telas restauradas (' + $rc + ').')
    }
    if (-not $restored -and $tv) {
        # after a reboot the saved layout no longer applies: rebuild it from what we know
        $primaryPath = ''; if ($saved) { $primaryPath = $saved.primaryPath }
        if (-not $saved -or -not $saved.tvWasActive) { $rc = [Apc.Display]::Deactivate($tv.DevicePath, $primaryPath); Write-ApcLog ('Modo jogo: TV desativada (' + $rc + ').') }
        elseif ($primaryPath) { $rc = [Apc.Display]::SetPrimary($primaryPath); Write-ApcLog ('Modo jogo: tela principal de volta (' + $rc + ').') }
    }

    if ($saved -and $saved.audio) {
        Start-Sleep -Milliseconds 800
        $present = @(Get-ApcAudioDevices | ForEach-Object { $_.Id })
        for ($role = 0; $role -lt 3; $role++) {
            $id = @($saved.audio)[$role]
            if ($id -and $present -contains $id) { [Apc.Audio]::SetDefault($id, $role) }
        }
        Write-ApcLog 'Modo jogo: áudio de volta.'
    }
    Save-ApcState $null
}

# ---------------------------------------------------------------- computer

function Stop-ApcComputer {
    switch ($Apc.Cfg.computer.powerOff) {
        'shutdown' { & shutdown.exe /s /t 20 /c 'Alexa PC Control: desligando em 20 segundos (shutdown /a cancela).' }
        'hibernate' { Add-Type -AssemblyName System.Windows.Forms; [void][Windows.Forms.Application]::SetSuspendState('Hibernate', $false, $false) }
        default { Add-Type -AssemblyName System.Windows.Forms; [void][Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false) }
    }
}

function ConvertTo-ApcInputKey([string]$Text) { return ($Text -replace '[\s_-]', '').ToUpperInvariant() }

function Select-ApcInput([string]$InputName) {
    $want = ConvertTo-ApcInputKey $InputName
    $map = @($Apc.Cfg.computer.inputs) | Where-Object { $_.input -and (ConvertTo-ApcInputKey $_.input) -eq $want } | Select-Object -First 1
    if (-not $map) { return 'A entrada "' + $InputName + '" não está configurada.' }
    $audioName = $map.audioName
    $device = $null
    if ($audioName) { $device = Find-ApcAudioDevice '' $audioName }
    elseif ($want -eq 'TV') { $tv = Get-ApcTv; if ($tv) { $device = Find-ApcAudioForMonitor $tv.Name } }
    if (-not $device) { return 'A saída de áudio da entrada "' + $InputName + '" não está disponível.' }
    [Apc.Audio]::SetDefault($device.Id)
    Write-ApcLog ('Entrada ' + $InputName + ': áudio em ' + $device.Name + '.')
    return $null
}

# ---------------------------------------------------------------- requests

function New-ApcResult($Value, [string]$After = '', $Arg = $null) { return @{ Ok = $true; Value = $Value; Message = 'OK'; After = $After; Arg = $Arg } }
function New-ApcFailure([string]$Message) { return @{ Ok = $false; Value = @{}; Message = $Message; After = ''; Arg = $null } }

function Invoke-ApcRequest([string]$Role, [string]$Name, $Value) {
    switch ($Role + '/' + $Name) {
        'gameMode/setPowerState' {
            if ($Value.state -eq 'On') { return New-ApcResult @{ state = 'On' } 'GameModeOn' }
            return New-ApcResult @{ state = 'Off' } 'GameModeOff'
        }
        'invisibleMode/setPowerState' {
            if ($Value.state -eq 'On') { Set-ApcSteamStatus 'invisible' } else { Set-ApcSteamStatus 'online' }
            return New-ApcResult @{ state = [string]$Value.state }
        }
        'computer/setPowerState' {
            if ($Value.state -eq 'Off') { return New-ApcResult @{ state = 'Off' } 'PowerOff' }
            return New-ApcResult @{ state = 'On' }
        }
        'computer/setVolume' {
            [Apc.Audio]::SetVolume([int]$Value.volume)
            return New-ApcResult @{ volume = [Apc.Audio]::GetVolume() }
        }
        'computer/adjustVolume' {
            $delta = [int]$Value.volume
            if ($Value.volumeDefault) { $step = [int]$Apc.Cfg.computer.volumeStep; if ($step -le 0) { $step = 10 }; $delta = $step * [Math]::Sign($delta) }
            if ([Apc.Audio]::GetMute() -and $delta -gt 0) { [Apc.Audio]::SetMute($false) }
            [Apc.Audio]::SetVolume([Apc.Audio]::GetVolume() + $delta)
            return New-ApcResult @{ volume = [Apc.Audio]::GetVolume() }
        }
        'computer/setMute' {
            [Apc.Audio]::SetMute([bool]$Value.mute)
            return New-ApcResult @{ mute = [bool]$Value.mute }
        }
        'computer/mediaControl' {
            $key = @{ Play = [Apc.Input]::PLAY_PAUSE; Pause = [Apc.Input]::PLAY_PAUSE; Next = [Apc.Input]::NEXT
                      Previous = [Apc.Input]::PREVIOUS; StartOver = [Apc.Input]::PREVIOUS; Stop = [Apc.Input]::STOP }[[string]$Value.control]
            if ($null -eq $key) { return New-ApcFailure ('Controle "' + $Value.control + '" não suportado.') }
            [Apc.Input]::Press($key)
            return New-ApcResult @{ control = [string]$Value.control }
        }
        'computer/selectInput' {
            $err = Select-ApcInput ([string]$Value.input)
            if ($err) { return New-ApcFailure $err }
            return New-ApcResult @{ input = [string]$Value.input }
        }
        'computer/changeChannel' {
            $channel = $Value.channel
            $number = [string]$channel.number; $spoken = [string]$channel.name
            if ($number -eq '0' -or (ConvertTo-ApcSpoken $spoken) -in @('0', 'zero', 'fechar', 'fechar jogo', 'nenhum')) {
                return New-ApcResult @{ channel = @{ name = 'Fechar jogo' } } 'StopGame'
            }
            $game = $null
            if ($number) {
                $c = @($Apc.Cfg.channels) | Where-Object { [string]$_.number -eq $number } | Select-Object -First 1
                if ($c -and $c.appId) { $game = @{ AppId = [string]$c.appId; Name = [string]$c.name } }
            }
            if (-not $game -and $spoken) { $game = Find-ApcGame $spoken $Apc.Cfg.channels }
            if (-not $game) { return New-ApcFailure ('Não achei o jogo "' + $spoken + $number + '".') }
            return New-ApcResult @{ channel = @{ name = $game.Name } } 'StartGame' $game
        }
    }
    return New-ApcFailure ('Ação "' + $Name + '" não suportada por este dispositivo.')
}

function Invoke-ApcAfter([string]$What, $Arg) {
    switch ($What) {
        'GameModeOn'  { Enable-ApcGameMode }
        'GameModeOff' { Disable-ApcGameMode }
        'PowerOff'    { Write-ApcLog ('Computador: ' + $Apc.Cfg.computer.powerOff + '.'); Start-Sleep -Seconds 2; Stop-ApcComputer }
        'StartGame'   { Write-ApcLog ('Abrindo ' + $Arg.Name + ' (' + $Arg.AppId + ').'); Start-ApcGame $Arg.AppId }
        'StopGame'    { $closed = Stop-ApcGame; if ($closed) { Write-ApcLog ($closed + ' fechado.') } else { Write-ApcLog 'Nenhum jogo aberto pra fechar.' } }
    }
}

# ---------------------------------------------------------------- Sinric Pro protocol

function Get-ApcHmac([string]$Text) {
    $h = New-Object System.Security.Cryptography.HMACSHA256 (, [Text.Encoding]::UTF8.GetBytes($Apc.Secret))
    try { return [Convert]::ToBase64String($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) } finally { $h.Dispose() }
}

# The signature covers the payload exactly as sent, so it is sliced out of the raw text, never re-serialized.
function Get-ApcRawPayload([string]$Raw) {
    $begin = $Raw.IndexOf('"payload":')
    if ($begin -lt 0) { return $null }
    $end = $Raw.IndexOf(',"signature"', $begin)
    if ($end -lt 0) { return $null }
    return $Raw.Substring($begin + 10, $end - $begin - 10)
}

function Test-ApcSignature([string]$Raw, $Message) {
    $payload = Get-ApcRawPayload $Raw
    if (-not $payload -or -not $Message.signature -or -not $Message.signature.HMAC) { return $false }
    $expected = [Text.Encoding]::ASCII.GetBytes((Get-ApcHmac $payload))
    $given = [Text.Encoding]::ASCII.GetBytes([string]$Message.signature.HMAC)
    if ($expected.Length -ne $given.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $expected.Length; $i++) { $diff = $diff -bor ($expected[$i] -bxor $given[$i]) }
    return $diff -eq 0
}

function Send-ApcText([string]$Text) {
    $ws = $Apc.Socket
    if (-not $ws -or $ws.State -ne [Net.WebSockets.WebSocketState]::Open) { return }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    [void]$ws.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait(10000)
}

function Send-ApcSigned($Payload) {
    $json = $Payload | ConvertTo-Json -Depth 10 -Compress
    Send-ApcText ('{"header":{"payloadVersion":2,"signatureVersion":1},"payload":' + $json + ',"signature":{"HMAC":"' + (Get-ApcHmac $json) + '"}}')
}

function Send-ApcResponse($Request, [hashtable]$Result) {
    $p = [ordered]@{
        action = [string]$Request.action; clientId = [string]$Request.clientId
        createdAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); deviceId = [string]$Request.deviceId
        message = $Result.Message; replyToken = [string]$Request.replyToken; scope = 'device'
        success = [bool]$Result.Ok; type = 'response'; value = $Result.Value
    }
    if ($Request.instanceId) { $p['instanceId'] = [string]$Request.instanceId }
    Send-ApcSigned $p
}

# Tells Sinric (and the Alexa app) about a change that did not come from Alexa.
function Send-ApcEvent([string]$Role, [string]$Name, [hashtable]$Value) {
    $deviceId = $Apc.Cfg.sinric.devices.$Role
    if (-not $deviceId -or -not $Apc.Socket) { return }
    Send-ApcSigned ([ordered]@{
        action = $Name; cause = @{ type = 'PHYSICAL_INTERACTION' }; createdAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        deviceId = $deviceId; replyToken = [guid]::NewGuid().ToString(); type = 'event'; value = $Value
    })
}

function Invoke-ApcMessage([string]$Raw) {
    $msg = $Raw | ConvertFrom-Json
    if ($null -ne $msg.timestamp) { return }   # clock sync sent right after connecting
    $p = $msg.payload
    if (-not $p -or $p.type -ne 'request') { return }
    if (-not (Test-ApcSignature $Raw $msg)) {
        Write-ApcLog 'Mensagem com assinatura inválida recusada (o App Secret está certo?).'
        Send-ApcResponse $p (New-ApcFailure 'Signature is invalid')
        return
    }
    $role = $Apc.Roles[[string]$p.deviceId]
    if (-not $role) { Send-ApcResponse $p (New-ApcFailure 'Device not configured'); return }

    $summary = $role + ' ' + $p.action + ' ' + ($p.value | ConvertTo-Json -Depth 5 -Compress)
    Write-ApcLog ('Alexa: ' + $summary)
    try { $result = Invoke-ApcRequest $role ([string]$p.action) $p.value }
    catch { $result = New-ApcFailure ('Erro: ' + $_.Exception.Message) }
    if (-not $result.Ok) { Write-ApcLog ('  falhou: ' + $result.Message) }
    Send-ApcResponse $p $result
    Write-ApcStatus @{ lastCommand = $summary; lastCommandAt = (Get-Date).ToString('o'); lastCommandOk = [bool]$result.Ok }

    # slow work runs after answering, so Alexa does not give up waiting
    if ($result.After) {
        try { Invoke-ApcAfter $result.After $result.Arg }
        catch { Write-ApcLog ('  erro em ' + $result.After + ': ' + $_.Exception.Message) }
    }
}

# ---------------------------------------------------------------- connection loop

function Update-ApcConfig {
    $stamp = $null; if (Test-Path $ConfigPath) { $stamp = (Get-Item $ConfigPath).LastWriteTimeUtc }
    if ($Apc.Cfg -and $stamp -eq $Apc.ConfigStamp) { return $false }
    $Apc.Cfg = Read-ApcConfig $ConfigPath
    $Apc.ConfigStamp = $stamp
    $Apc.Secret = Get-ApcSecret $Apc.Cfg
    $Apc.Roles = @{}
    foreach ($role in @('gameMode', 'computer', 'invisibleMode')) {
        $id = [string]$Apc.Cfg.sinric.devices.$role
        if ($id) { $Apc.Roles[$id] = $role }
    }
    return $true
}

function Invoke-ApcIdle {
    $now = Get-Date
    # a gap in the 5 s ticks means the PC slept: the connection is probably dead, start over
    if (($now - $Apc.LastTick).TotalSeconds -gt 40) { Write-ApcLog 'O PC voltou da suspensão; reconectando.'; $Apc.Reconnect = $true }
    $Apc.LastTick = $now
    if (Update-ApcConfig) { Write-ApcLog 'Configuração alterada; reconectando.'; $Apc.Reconnect = $true }
}

function Invoke-ApcSession {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(30)
    $ws.Options.SetRequestHeader('appkey', [string]$Apc.Cfg.sinric.appKey)
    $ws.Options.SetRequestHeader('deviceids', (@($Apc.Roles.Keys) -join ';'))
    $ws.Options.SetRequestHeader('platform', 'PowerShell')
    $ws.Options.SetRequestHeader('SDKVersion', $AgentVersion)
    $ws.Options.SetRequestHeader('restoredevicestates', 'false')
    $Apc.Socket = $ws
    try {
        if (-not $ws.ConnectAsync([Uri]$Server, [Threading.CancellationToken]::None).Wait(20000)) { throw 'tempo esgotado' }
        Write-ApcLog ('Conectado ao Sinric Pro (' + $Apc.Roles.Count + ' dispositivos).')
        Write-ApcStatus @{ state = 'conectado'; message = ''; since = (Get-Date).ToString('o') }
        $Apc.Backoff = 0
        Send-ApcEvent 'computer' 'setPowerState' @{ state = 'On' }

        $buffer = New-Object byte[] 65536
        $segment = [ArraySegment[byte]]::new($buffer)
        $data = New-Object IO.MemoryStream
        $Apc.LastTick = Get-Date; $Apc.Reconnect = $false
        while ($ws.State -eq [Net.WebSockets.WebSocketState]::Open) {
            $task = $ws.ReceiveAsync($segment, [Threading.CancellationToken]::None)
            while (-not $task.Wait(5000)) {
                Invoke-ApcIdle
                if ($Apc.Reconnect) { $ws.Abort(); break }
            }
            if ($Apc.Reconnect -or -not $task.IsCompleted -or $task.IsFaulted -or $task.IsCanceled) { break }
            $r = $task.Result
            if ($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { Write-ApcLog ('O Sinric fechou a conexão: ' + $r.CloseStatusDescription); break }
            $data.Write($buffer, 0, $r.Count)
            if (-not $r.EndOfMessage) { continue }
            $text = [Text.Encoding]::UTF8.GetString($data.ToArray()); $data.SetLength(0)
            try { Invoke-ApcMessage $text } catch { Write-ApcLog ('Erro ao tratar mensagem: ' + $_.Exception.Message) }
            Invoke-ApcIdle
            if ($Apc.Reconnect) { break }
        }
    } finally {
        $Apc.Socket = $null
        try { $ws.Abort(); $ws.Dispose() } catch { }
    }
}

function Get-ApcErrorText($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    return $e.Message
}

function Start-ApcAgent {
    $name = 'Local\AlexaPcControlAgent'
    if ($Server -ne 'wss://ws.sinric.pro') { $name += '-' + ($Server -replace '[^\w]', '_') }   # a test agent next to the real one
    $mutex = New-Object Threading.Mutex($false, $name)
    if (-not $mutex.WaitOne(0)) { Write-ApcLog 'Outro agente já está rodando; saindo.'; return }
    [Apc.Windows]::UsePhysicalPixels()
    Write-ApcLog ('Agente iniciado (v' + $AgentVersion + ', PID ' + $PID + ').')
    $delays = @(2, 5, 10, 20, 30, 60)
    $Apc.Backoff = 0
    while ($true) {
        try {
            [void](Update-ApcConfig)
            $missing = Get-ApcMissingSetup $Apc.Cfg
            if ($missing) {
                Write-ApcStatus @{ state = 'sem-config'; message = $missing }
                Start-Sleep -Seconds 5
                continue
            }
            Invoke-ApcSession
            if ($Apc.Reconnect) { continue }
            Write-ApcStatus @{ state = 'desconectado'; message = 'Conexão caiu; tentando de novo.' }
        } catch {
            $text = Get-ApcErrorText $_
            Write-ApcLog ('Sem conexão com o Sinric Pro: ' + $text)
            Write-ApcStatus @{ state = 'desconectado'; message = $text }
        }
        $wait = $delays[[Math]::Min($Apc.Backoff, $delays.Count - 1)]
        $Apc.Backoff++
        $until = (Get-Date).AddSeconds($wait)
        while ((Get-Date) -lt $until) { Start-Sleep -Seconds 1; Invoke-ApcIdle; if ($Apc.Reconnect) { $Apc.Reconnect = $false; break } }
    }
}

# ---------------------------------------------------------------- entry

if ($Action) {
    [Apc.Windows]::UsePhysicalPixels()
    [void](Update-ApcConfig)
    switch ($Action) {
        'GameModeOn'  { Enable-ApcGameMode }
        'GameModeOff' { Disable-ApcGameMode }
    }
    return
}
Start-ApcAgent
