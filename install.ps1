# install.ps1 - Alexa PC Control
#
# Instala (ou atualiza) em %LOCALAPPDATA%\AlexaPcControl e registra o agente no Agendador de Tarefas
# do Windows: ele sobe escondido quando voce entra no Windows e fica conectado ao Sinric Pro
# esperando os comandos da Alexa. A conexao e so de saida, como uma aba do navegador.
#
# Como usar: extraia o ZIP e de duplo clique em Instalar.bat. Nao precisa de administrador.
# Reinstalar e seguro: o config.json existente (sua configuracao) e mantido.

$InstallDir   = Join-Path $env:LOCALAPPDATA 'AlexaPcControl'
$CoreFiles    = @('Agente.ps1', 'Pc.ps1', 'Steam.ps1', 'Config.ps1')
$Files        = $CoreFiles + @('Configurar.ps1', 'install.ps1', 'uninstall.ps1', 'Instalar.bat', 'Configurar.bat', 'Desinstalar.bat', 'README.md')
$ConfigFile   = 'config.json'
$TaskPath     = '\AlexaPcControl\'
$TaskName     = 'Agente'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Alexa PC Control.lnk'
$PowerShell   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Conhost      = Join-Path $env:SystemRoot 'System32\conhost.exe'

function New-StartMenuShortcut([string]$SteamExe) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($ShortcutPath)
    $lnk.TargetPath = $PowerShell
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $InstallDir 'Configurar.ps1') + '"'
    $lnk.WorkingDirectory = $InstallDir
    $lnk.WindowStyle = 7
    $lnk.Description = 'Configurar o Alexa PC Control'
    if ($SteamExe) { $lnk.IconLocation = $SteamExe + ',0' }
    $lnk.Save()
}

function Register-ApcAgentTask {
    $agent = Join-Path $InstallDir 'Agente.ps1'
    $psArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $agent + '"'
    # conhost --headless roda o PowerShell sem janela nenhuma. So -WindowStyle Hidden nao basta no Windows 11:
    # com o Terminal como padrao, a janela do Terminal abre e fica aberta.
    if ([Environment]::OSVersion.Version.Build -ge 17763 -and (Test-Path $Conhost)) {
        $action = New-ScheduledTaskAction -Execute $Conhost -Argument ('--headless "' + $PowerShell + '" ' + $psArgs) -WorkingDirectory $InstallDir
    } else {
        $action = New-ScheduledTaskAction -Execute $PowerShell -Argument $psArgs -WorkingDirectory $InstallDir
    }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    # roda como voce e so com voce logado: o agente mexe nas suas telas, no seu audio e na sua Steam
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Alexa PC Control: conecta ao Sinric Pro e executa os comandos da Alexa.' -Force | Out-Null
}

function Wait-ApcAgentStatus([int]$Seconds) {
    $statusPath = Join-Path $InstallDir 'status.json'
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $statusPath) {
            try { return (Get-Content -Raw $statusPath | ConvertFrom-Json) } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Install-AlexaPcControl {
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        Write-Host ''
        Write-Host '=== Alexa PC Control - instalacao ==='
        Write-Host ''

        $sourceDir = $null
        if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'Agente.ps1'))) { $sourceDir = (Resolve-Path $PSScriptRoot).Path.TrimEnd('\') }
        if (-not $sourceDir) { throw 'Rode este instalador de dentro da pasta extraida do ZIP (os outros arquivos precisam estar junto).' }
        foreach ($name in $CoreFiles) { if (-not (Test-Path (Join-Path $sourceDir $name))) { throw "Arquivo $name nao encontrado na pasta do instalador. Baixe o ZIP de novo." } }

        . (Join-Path $sourceDir 'Steam.ps1')
        $steamExe = Get-ApcSteamExe
        if (-not $steamExe) { Write-Host 'Aviso: nao achei a Steam instalada neste usuario. Os comandos da Steam (Big Picture, jogos, invisivel) nao vao funcionar.' -ForegroundColor Yellow }

        # o agente antigo precisa sair, senao o codigo novo so carrega no proximo login
        & (Join-Path $sourceDir 'uninstall.ps1') -StopOnly

        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        if ($sourceDir -ne $InstallDir.TrimEnd('\')) {
            Write-Host "Copiando arquivos de $sourceDir ..."
            foreach ($name in ($Files + $ConfigFile)) {
                $src  = Join-Path $sourceDir $name
                $dest = Join-Path $InstallDir $name
                if ($name -eq $ConfigFile -and (Test-Path $dest)) { Write-Host "  $name (mantido, ja existia)"; continue }
                if (-not (Test-Path $src)) { Write-Host "  $name (nao encontrado no pacote, pulado)" -ForegroundColor Yellow; continue }
                Copy-Item -Path $src -Destination $dest -Force
                Write-Host "  $name"
            }
        }
        # arquivo baixado da internet vem marcado; tira a marca pra o Windows nao perguntar toda vez
        Get-ChildItem -Path $InstallDir -File | Unblock-File -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $InstallDir 'status.json') -Force -ErrorAction SilentlyContinue

        Register-ApcAgentTask
        Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
        $status = Wait-ApcAgentStatus 20

        $configurar = Join-Path $InstallDir 'Configurar.ps1'
        $shortcutOk = Test-Path $configurar
        if ($shortcutOk) {
            try { New-StartMenuShortcut $steamExe } catch { $shortcutOk = $false; Write-Host 'Aviso: nao consegui criar o atalho do Menu Iniciar. Use o Configurar.bat.' -ForegroundColor Yellow }
        }

        Write-Host ''
        Write-Host 'Instalado! O agente roda escondido e sobe sozinho quando voce entra no Windows.'
        Write-Host "Pasta: $InstallDir"
        if ($status) {
            switch ([string]$status.state) {
                'conectado'  { Write-Host 'Agente: conectado ao Sinric Pro.' -ForegroundColor Green }
                'sem-config' { Write-Host ('Agente: rodando, falta configurar. ' + $status.message) -ForegroundColor Yellow }
                default      { Write-Host ('Agente: ' + $status.state + ' ' + $status.message) -ForegroundColor Yellow }
            }
        } else {
            Write-Host 'Aviso: o agente ainda nao respondeu. Veja o agente.log na pasta acima.' -ForegroundColor Yellow
        }
        if ($shortcutOk) { Write-Host '  - Menu Iniciar > "Alexa PC Control"  -> janela de configuracao' }
        Write-Host '  - Configurar.bat                     -> janela de configuracao'
        Write-Host '  - Desinstalar.bat                    -> remove tudo'
        Write-Host ''

        $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not $env:APC_NO_UI
        if ($interactive -and (Test-Path $configurar)) {
            Write-Host 'Abrindo a janela de configuracao...'
            Start-Process -FilePath $PowerShell -WindowStyle Minimized `
                -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $configurar + '"')
        }
    } finally {
        $ErrorActionPreference = $previousEap
    }
}

Install-AlexaPcControl
