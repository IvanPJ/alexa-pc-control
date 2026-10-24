# uninstall.ps1 - Alexa PC Control: para o agente, remove a tarefa agendada, o atalho e a pasta
# %LOCALAPPDATA%\AlexaPcControl. Se o modo jogo estiver ligado, desliga antes (telas e áudio voltam).
#
# -StopOnly: só para o agente que estiver rodando (o install.ps1 usa antes de copiar os arquivos novos).

param([switch]$StopOnly)

$InstallDir   = Join-Path $env:LOCALAPPDATA 'AlexaPcControl'
$TaskPath     = '\AlexaPcControl\'
$TaskName     = 'Agente'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Alexa PC Control.lnk'
$PowerShell   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ErrorActionPreference = 'SilentlyContinue'

function Stop-ApcAgent {
    Stop-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    # parar a tarefa encerra o conhost; o powershell filho pode sobrar, entao ele e encerrado pelo caminho do script
    $marker = 'AlexaPcControl\Agente.ps1'
    $pids = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        ForEach-Object { [int]$_.ProcessId })
    $statusPath = Join-Path $InstallDir 'status.json'
    if (Test-Path $statusPath) {
        try {
            $statusPid = [int](Get-Content -Raw $statusPath | ConvertFrom-Json).pid
            $p = Get-Process -Id $statusPid -ErrorAction Stop
            if ($p.ProcessName -eq 'powershell') { $pids += $statusPid }
        } catch { }
    }
    $pids = @($pids | Where-Object { $_ -and $_ -ne $PID } | Select-Object -Unique)
    foreach ($id in $pids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    return $pids.Count
}

$stopped = Stop-ApcAgent
if ($StopOnly) {
    if ($stopped) { Write-Host 'Agente anterior parado.' }
    return
}

Write-Host ''
Write-Host '=== Alexa PC Control - desinstalacao ==='
Write-Host ''

# modo jogo ligado: devolve telas e audio antes de apagar o estado salvo
$statePath = Join-Path $InstallDir 'estado.json'
$agent = Join-Path $InstallDir 'Agente.ps1'
if ((Test-Path $statePath) -and (Test-Path $agent)) {
    Write-Host 'O modo jogo estava ligado: desligando (telas e audio voltam como estavam)...'
    & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $agent -Action GameModeOff | Out-Null
}

Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
try {
    $svc = New-Object -ComObject Schedule.Service; $svc.Connect()
    $svc.GetFolder('\').DeleteFolder('AlexaPcControl', 0)
} catch { }
Remove-Item -Path $ShortcutPath -Force
Write-Host 'Agente parado, tarefa agendada e atalho do Menu Iniciar removidos.'

if (Test-Path $InstallDir) {
    # este script pode estar dentro da pasta, entao ela e apagada alguns segundos depois de sair
    Start-Process cmd.exe -ArgumentList "/c timeout /t 3 /nobreak >nul & rmdir /s /q `"$InstallDir`"" -WindowStyle Hidden
    Write-Host "A pasta $InstallDir sera apagada em alguns segundos."
}
Write-Host ''
Write-Host 'Lembrete: os dispositivos continuam no Sinric Pro e no app Alexa. Apague por la se nao for mais usar.'
