# Configurar.ps1 - Alexa PC Control: setup assistant + settings panel (WPF, dark Windows 11 look)
#
# First run, or while something essential is missing, a 5-step assistant teaches the setup and
# confirms every step live: account (the agent connects), devices (id format), Alexa (a voice
# command arrives), TV (tested on the real screens) and a final voice test. Afterwards a panel with
# a side menu: Início, Modo Jogo, Computador, Jogos, Conexão.
#
# Live confirmations come from status.json (written by Agente.ps1 only when something changes, so
# "agent stopped" is decided by its pid, never by the file age) and from the list of screens.
# The agent reloads config.json by itself a few seconds after it is saved.
#
# Saved as UTF-8 WITH BOM on purpose: PowerShell 5.1 needs the BOM for the accented strings.
# PowerShell variables are case-insensitive: globals are $App, $Ctl, $Br (never 1-letter names).

[CmdletBinding()]
param(
    [string]$Screenshot,           # debug/docs: render the window to this PNG after a delay and exit
    [int]$ScreenshotDelayMs = 2500,
    [switch]$Demo,                 # docs: made-up screens, keys, games and agent state; never saves or runs anything
    [ValidateSet('', 'wizard1', 'wizard2', 'wizard3', 'wizard4', 'wizard5', 'done', 'home', 'gamemode', 'computer', 'games', 'connection')]
    [string]$Page = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$InstallDir = $PSScriptRoot
$ConfigPath = Join-Path $InstallDir 'config.json'
$StatusPath = Join-Path $InstallDir 'status.json'
$WizardPath = Join-Path $InstallDir 'assistente.json'
$LogPath    = Join-Path $InstallDir 'agente.log'
$AgentPath  = Join-Path $InstallDir 'Agente.ps1'
$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$PortalUrl  = 'https://portal.sinric.pro'
$Version    = 'v1.0'
. (Join-Path $InstallDir 'Config.ps1')
. (Join-Path $InstallDir 'Pc.ps1')
. (Join-Path $InstallDir 'Steam.ps1')

$RxKey    = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$RxSecret = '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}-[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
$RxId     = '^[0-9a-f]{24}$'
$IconFont = 'Segoe Fluent Icons, Segoe MDL2 Assets'
$Devices  = @(
    @{ Role = 'gameMode'; Name = 'Modo Jogo'; Type = 'Switch'; Glyph = 0xE7FC }
    @{ Role = 'computer'; Name = 'Computador'; Type = 'TV'; Glyph = 0xE7F4 }
    @{ Role = 'invisibleMode'; Name = 'Modo Invisível'; Type = 'Switch'; Glyph = 0xED1A }
)
$RoleName    = @{ gameMode = 'Modo Jogo'; computer = 'Computador'; invisibleMode = 'Modo Invisível' }
$AlexaInputs = @('TV', 'HDMI 1', 'HDMI 2', 'AUX 1', 'AUX 2', 'GAME', 'MEDIA PLAYER')
$StepTitles  = @('', 'Conectar ao Sinric Pro', 'Crie os 3 dispositivos no portal', 'Ative o Sinric Pro na Alexa', 'Escolha a TV e teste', 'Fale com a Alexa')

$Conv = New-Object Windows.Media.BrushConverter
function Brush([string]$Hex) { return $Conv.ConvertFromString($Hex) }
function Glyph([int]$Code) { return [string][char]$Code }
$Br = @{
    Text = Brush '#E8ECF1'; Text2 = Brush '#9AA4B2'; Text3 = Brush '#6B7584'; Accent = Brush '#38BDF8'; OnAccent = Brush '#06121C'
    Ok = Brush '#3FB950'; Warn = Brush '#E3B341'; Err = Brush '#F85149'; Neutral = Brush '#6E7681'
    Surface = Brush '#161B22'; Elevated = Brush '#1D242E'; Line = Brush '#262D38'; InputLine = Brush '#2B3340'; Clear = [Windows.Media.Brushes]::Transparent
}

# ====================================================================== data

# Made-up machine for the README screenshots: nothing here comes from the real PC.
function Get-DemoData {
    $cfg = New-ApcDefaultConfig
    $cfg.sinric.appKey = '4f1c2d9e-7a3b-4c8d-9e0f-1a2b3c4d5e6f'
    $cfg.sinric.devices.gameMode = '65a1f0c2d3e4f5a6b7c8d9e0'
    $cfg.sinric.devices.computer = '65a1f0c2d3e4f5a6b7c8d9e1'
    $cfg.sinric.devices.invisibleMode = '65a1f0c2d3e4f5a6b7c8d9e2'
    $cfg.gameMode.tvName = 'SAMSUNG TV'; $cfg.gameMode.tvPath = 'demo-tv'
    $cfg.computer.inputs = @([pscustomobject]@{ input = 'TV'; audioName = '' }, [pscustomobject]@{ input = 'AUX 1'; audioName = 'Fones de ouvido (Headset USB)' })
    $cfg.channels = @(
        [pscustomobject]@{ number = 1; name = 'Hades II'; appId = '1145350'; aliases = @('hades') },
        [pscustomobject]@{ number = 2; name = 'Hollow Knight'; appId = '367520'; aliases = @() },
        [pscustomobject]@{ number = 3; name = 'Stardew Valley'; appId = '413150'; aliases = @('stardew', 'fazendinha') }
    )
    $games = @(@('Balatro', '2379780'), @('Celeste', '504230'), @('Cuphead', '268910'), @('Hades II', '1145350'), @('Hollow Knight', '367520'),
               @('Portal 2', '620'), @('Stardew Valley', '413150'), @('Terraria', '105600')) |
        ForEach-Object { [pscustomobject]@{ Name = $_[0]; AppId = $_[1] } }
    return @{
        Cfg = $cfg; HasSecret = $true; Games = @($games)
        Monitors = @([pscustomobject]@{ Name = 'DELL 27'; DevicePath = 'demo-pc'; Available = $true; Active = $true; Primary = $true; X = 0; Y = 0; Width = 2560; Height = 1440 },
                     [pscustomobject]@{ Name = 'SAMSUNG TV'; DevicePath = 'demo-tv'; Available = $true; Active = $false; Primary = $false; X = 0; Y = 0; Width = 0; Height = 0 })
        Audio = @([pscustomobject]@{ Name = 'Fones de ouvido (Headset USB)'; Id = 'demo-1' },
                  [pscustomobject]@{ Name = 'Alto-falantes (Realtek(R) Audio)'; Id = 'demo-2' },
                  [pscustomobject]@{ Name = 'DELL 27 (NVIDIA High Definition Audio)'; Id = 'demo-3' })
        Wizard = @{ done = $true; alexa = $true; tv = $true; invisible = $true }
    }
}

function Read-WizardState {
    $w = @{ done = $false; alexa = $false; tv = $false; invisible = $false }
    try {
        if (Test-Path $WizardPath) {
            $saved = Get-Content -Raw -Encoding UTF8 $WizardPath | ConvertFrom-Json
            foreach ($k in @($w.Keys)) { if ($null -ne $saved.$k) { $w[$k] = [bool]$saved.$k } }
        }
    } catch { }
    return $w
}

function Save-WizardState {
    if ($Demo) { return }
    try { [IO.File]::WriteAllText($WizardPath, ($App.Data.Wizard | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false))) } catch { }
}

function Get-RealData {
    $cfg = Read-ApcConfig $ConfigPath
    $data = @{ Cfg = $cfg; HasSecret = [bool](Get-ApcSecret $cfg); Monitors = @(); Audio = @(); Games = @(); Wizard = (Read-WizardState) }
    try { $data.Monitors = @(Get-ApcMonitors) } catch { }
    try { $data.Audio = @(Get-ApcAudioDevices) } catch { }
    try { $data.Games = @(Get-ApcSteamGames) } catch { }
    return $data
}

function Update-Monitors { if (-not $Demo) { try { $App.Data.Monitors = @(Get-ApcMonitors) } catch { } } }

# ---------------------------------------------------------------- agent status

function Read-AgentStatus {
    if ($Demo) { return $App.DemoStatus }
    try { if (Test-Path $StatusPath) { return (Get-Content -Raw -Encoding UTF8 $StatusPath | ConvertFrom-Json) } } catch { }
    return $null
}

function Test-AgentAlive($Status) {
    if ($Demo) { return $true }
    if (-not $Status -or -not $Status.pid) { return $false }
    $p = Get-Process -Id ([int]$Status.pid) -ErrorAction SilentlyContinue
    return [bool]($p -and $p.ProcessName -match 'powershell')
}

# Everything the window shows about the agent, decided in one place.
function Get-AgentView {
    $s = Read-AgentStatus
    $view = @{ Status = $s; Key = 'parado'; Label = 'Agente parado'; Sub = 'Ele é quem conversa com a Alexa. Clique em Iniciar.'; Color = '#6E7681' }
    if (-not (Test-AgentAlive $s)) { return $view }
    switch ([string]$s.state) {
        'conectado'    { $view.Key = 'conectado'; $view.Label = 'Conectado'; $view.Sub = 'Alexa  ↔  Sinric Pro  ↔  este PC'; $view.Color = '#3FB950' }
        'desconectado' { $view.Key = 'desconectado'; $view.Label = 'Sem conexão'; $view.Sub = [string]$s.message; $view.Color = '#F85149' }
        'sem-config'   { $view.Key = 'sem-config'; $view.Label = 'Falta configurar'; $view.Sub = [string]$s.message; $view.Color = '#E3B341' }
        default        { $view.Key = 'verificando'; $view.Label = 'Verificando…'; $view.Sub = ''; $view.Color = '#6E7681' }
    }
    return $view
}

function Get-StatusTime($Status, [string]$Field) {
    if (-not $Status -or -not $Status.$Field) { return $null }
    try { return [DateTimeOffset]::Parse([string]$Status.$Field) } catch { return $null }
}

# "gameMode setPowerState {"state":"On"}" -> @{ Role; Action; Value }
function Get-LastCommand($Status) {
    if (-not $Status -or -not $Status.lastCommand) { return $null }
    $parts = ([string]$Status.lastCommand) -split ' ', 3
    $value = $null; if ($parts.Count -gt 2) { try { $value = $parts[2] | ConvertFrom-Json } catch { } }
    return @{ Role = $parts[0]; Action = $parts[1]; Value = $value; Ok = [bool]$Status.lastCommandOk; At = (Get-StatusTime $Status 'lastCommandAt') }
}

function Format-Command($Cmd) {
    if (-not $Cmd) { return '' }
    $what = $Cmd.Action; $v = $Cmd.Value
    switch ($Cmd.Action) {
        'setPowerState' { $what = $(if ($v -and $v.state -eq 'On') { 'ligar' } else { 'desligar' }) }
        'setVolume'     { $what = 'volume em ' + $v.volume }
        'adjustVolume'  { $what = $(if ([int]$v.volume -ge 0) { 'aumentar o volume' } else { 'abaixar o volume' }) }
        'setMute'       { $what = $(if ($v.mute) { 'mudo' } else { 'tirar do mudo' }) }
        'mediaControl'  { $what = 'mídia: ' + $v.control }
        'selectInput'   { $what = 'entrada ' + $v.input }
        'changeChannel' { $what = 'canal ' + $(if ($v.channel.number) { $v.channel.number } else { $v.channel.name }) }
    }
    $role = $RoleName[$Cmd.Role]; if (-not $role) { $role = $Cmd.Role }
    return $role + ' · ' + $what
}

function Format-Ago([DateTimeOffset]$When) {
    $d = [DateTimeOffset]::Now - $When
    if ($d.TotalMinutes -lt 1) { return 'agora' }
    if ($d.TotalHours -lt 1) { return ('há {0} min' -f [int][Math]::Floor($d.TotalMinutes)) }
    if ($d.TotalHours -lt 24) { return ('há {0}h' -f [int][Math]::Floor($d.TotalHours)) }
    return ('há {0} dias' -f [int][Math]::Floor($d.TotalDays))
}

function Restart-Agent {
    if ($Demo) { return }
    try {
        Stop-ScheduledTask -TaskPath '\AlexaPcControl\' -TaskName 'Agente' -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskPath '\AlexaPcControl\' -TaskName 'Agente' -ErrorAction Stop
        Show-Toast 'Iniciando o agente…'
    } catch { Show-Toast 'Não achei o agente instalado. Rode o Instalar.bat de novo.' 'err' }
}

function Open-Log {
    if (-not (Test-Path $LogPath)) { Show-Toast 'O agente ainda não escreveu nada no log.' 'info'; return }
    Start-Process notepad.exe -ArgumentList ('"' + $LogPath + '"')
}

function Open-Portal { Start-Process $PortalUrl }

# ---------------------------------------------------------------- codes typed or pasted

# Strips what usually comes along when copying: spaces, quotes, line breaks, "App Key:" labels.
function ConvertTo-CleanCode([string]$Text) {
    if (-not $Text) { return '' }
    $t = $Text -replace '(?i)^\s*(app\s*key|app\s*secret|device\s*id|id)\s*[:=]\s*', ''
    return ($t -replace '[\s"''`“”‘’]', '')
}

function Test-KeyCode([string]$Text) {
    if (-not $Text) { return @{ State = ''; Msg = '' } }
    if ($Text -match $RxKey) { return @{ State = 'ok'; Msg = '' } }
    if ($Text -match $RxId) { return @{ State = 'err'; Msg = 'Isso parece um ID de dispositivo, não a chave. A chave é mais longa e tem traços.' } }
    if ($Text -match $RxSecret) { return @{ State = 'err'; Msg = 'Isso parece o segredo (App Secret). A chave é o código de cima, mais curto.' } }
    return @{ State = 'err'; Msg = 'Isso não parece uma chave. Ela tem 36 caracteres, com traços (ex.: 4f1c2d9e-7a3b-…).' }
}

function Test-SecretCode([string]$Text, [string]$Key) {
    if (-not $Text) { return @{ State = ''; Msg = '' } }
    if ($Key -and $Text -eq $Key) { return @{ State = 'err'; Msg = 'Você colou o mesmo código nos dois campos. O segredo é o código mais longo, logo abaixo da chave no portal.' } }
    if ($Text -match $RxSecret) { return @{ State = 'ok'; Msg = '' } }
    if ($Text -match $RxKey) { return @{ State = 'err'; Msg = 'Isso parece a chave (App Key). O segredo é o código mais longo, logo abaixo dela.' } }
    return @{ State = 'err'; Msg = 'Cole o segredo completo: ele tem 73 caracteres, com traços.' }
}

function Test-IdCode([string]$Text, [string]$Other) {
    if (-not $Text) { return @{ State = ''; Msg = '' } }
    if ($Text -match $RxKey -or $Text -match $RxSecret -or $Text.Contains('-')) { return @{ State = 'err'; Msg = 'Isso parece a chave do app. Aqui vai o ID do dispositivo: 24 letras e números, sem traços.' } }
    if ($Text -notmatch $RxId) { return @{ State = 'err'; Msg = ('O ID tem 24 letras e números. Esse tem {0}. Copie de novo, inteiro.' -f $Text.Length) } }
    if ($Other) { return @{ State = 'err'; Msg = ('Você já usou este ID no ' + $Other + '. Cada dispositivo tem o seu.') } }
    return @{ State = 'ok'; Msg = '' }
}

# ====================================================================== window

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Alexa PC Control" Width="1000" Height="724"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanMinimize" ShowInTaskbar="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" Foreground="#E8ECF1"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <FontFamily x:Key="Display">Segoe UI Variable Display, Segoe UI</FontFamily>

    <!-- text -->
    <Style x:Key="PageTitle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Display}"/>
      <Setter Property="FontSize" Value="24"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#E8ECF1"/>
    </Style>
    <Style x:Key="PageSub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Foreground" Value="#9AA4B2"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="LineHeight" Value="21"/>
      <Setter Property="Margin" Value="0,6,0,24"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#E8ECF1"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#E8ECF1"/>
      <Setter Property="Margin" Value="0,0,0,7"/>
    </Style>
    <Style x:Key="Help" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#9AA4B2"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="LineHeight" Value="19"/>
    </Style>
    <Style x:Key="FieldErr" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#F85149"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,7,0,0"/>
      <Setter Property="Visibility" Value="Collapsed"/>
    </Style>
    <Style x:Key="Glyph" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <!-- surfaces -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#161B22"/>
      <Setter Property="BorderBrush" Value="#262D38"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="20"/>
    </Style>
    <Style x:Key="Divider" TargetType="Rectangle">
      <Setter Property="Height" Value="1"/>
      <Setter Property="Fill" Value="#262D38"/>
    </Style>

    <!-- buttons -->
    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Background" Value="#38BDF8"/>
      <Setter Property="Foreground" Value="#06121C"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#5CCBFA"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#29A7E0"/></Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#1D242E"/>
                <Setter Property="Foreground" Value="#6B7584"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Secondary" TargetType="Button">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#2B3340"/>
      <Setter Property="Foreground" Value="#E8ECF1"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1D242E"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#3A4452"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#232B36"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- secondary button with a Fluent glyph (Tag) before the text -->
    <Style x:Key="IconSecondary" TargetType="Button" BasedOn="{StaticResource Secondary}">
      <Setter Property="ContentTemplate">
        <Setter.Value>
          <DataTemplate>
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="{Binding Tag, RelativeSource={RelativeSource AncestorType=Button}}" FontFamily="{StaticResource Icons}"
                         FontSize="13" VerticalAlignment="Center" Margin="0,1,9,0"/>
              <TextBlock Text="{Binding}" VerticalAlignment="Center"/>
            </StackPanel>
          </DataTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PasteBtn" TargetType="Button" BasedOn="{StaticResource IconSecondary}">
      <Setter Property="Height" Value="40"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Content" Value="Colar"/>
      <Setter Property="Tag" Value="&#xE77F;"/>
    </Style>
    <Style x:Key="TextBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#38BDF8"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="Transparent" Padding="{TemplateBinding Padding}">
              <TextBlock x:Name="tx" Text="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}" FontWeight="SemiBold"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="tx" Property="TextDecorations" Value="Underline"/>
                <Setter TargetName="tx" Property="Foreground" Value="#7DD3FC"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="TitleBtn" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="44"/>
      <Setter Property="Foreground" Value="#9AA4B2"/>
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="Transparent"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1D242E"/>
                <Setter Property="Foreground" Value="#E8ECF1"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CloseBtn" TargetType="Button" BasedOn="{StaticResource TitleBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="Transparent" CornerRadius="0,11,0,0"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#C42B1C"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Width" Value="36"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Foreground" Value="#6B7584"/>
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="Transparent" CornerRadius="8"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1D242E"/>
                <Setter Property="Foreground" Value="#F85149"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- inputs: Tag = placeholder, Uid = validation state (ok | err) -->
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Height" Value="40"/>
      <Setter Property="Foreground" Value="#E8ECF1"/>
      <Setter Property="Background" Value="#0F1319"/>
      <Setter Property="BorderBrush" Value="#2B3340"/>
      <Setter Property="CaretBrush" Value="#38BDF8"/>
      <Setter Property="SelectionBrush" Value="#38BDF8"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="12,0,34,0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Grid>
              <Border x:Name="ring" CornerRadius="10" Margin="-3" BorderThickness="2" BorderBrush="#5938BDF8" Visibility="Hidden"/>
              <Border x:Name="bd" CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
                <Grid>
                  <TextBlock x:Name="ph" Text="{TemplateBinding Tag}" Foreground="#6B7584" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
                             Margin="13,0,0,1" VerticalAlignment="Center" IsHitTestVisible="False" Visibility="Collapsed"/>
                  <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center" Focusable="False"/>
                  <TextBlock x:Name="ok" Text="&#xE73E;" FontFamily="{StaticResource Icons}" FontSize="13" Foreground="#3FB950"
                             HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,13,0" Visibility="Collapsed"/>
                </Grid>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Text" Value=""><Setter TargetName="ph" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#3A4452"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#38BDF8"/>
                <Setter TargetName="ring" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="Uid" Value="ok">
                <Setter TargetName="ok" Property="Visibility" Value="Visible"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#3FB950"/>
              </Trigger>
              <Trigger Property="Uid" Value="err">
                <Setter TargetName="bd" Property="BorderBrush" Value="#F85149"/>
                <Setter TargetName="ring" Property="BorderBrush" Value="#59F85149"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="InputMono" TargetType="TextBox" BasedOn="{StaticResource Input}">
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style x:Key="SecretInput" TargetType="PasswordBox">
      <Setter Property="Height" Value="40"/>
      <Setter Property="Foreground" Value="#E8ECF1"/>
      <Setter Property="Background" Value="#0F1319"/>
      <Setter Property="BorderBrush" Value="#2B3340"/>
      <Setter Property="CaretBrush" Value="#38BDF8"/>
      <Setter Property="SelectionBrush" Value="#38BDF8"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="12,0,34,0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Grid>
              <Border x:Name="ring" CornerRadius="10" Margin="-3" BorderThickness="2" BorderBrush="#5938BDF8" Visibility="Hidden"/>
              <Border x:Name="bd" CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
                <Grid>
                  <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center" Focusable="False"/>
                  <TextBlock x:Name="ok" Text="&#xE73E;" FontFamily="{StaticResource Icons}" FontSize="13" Foreground="#3FB950"
                             HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,13,0" Visibility="Collapsed"/>
                </Grid>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#3A4452"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#38BDF8"/>
                <Setter TargetName="ring" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="Uid" Value="ok">
                <Setter TargetName="ok" Property="Visibility" Value="Visible"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#3FB950"/>
              </Trigger>
              <Trigger Property="Uid" Value="err">
                <Setter TargetName="bd" Property="BorderBrush" Value="#F85149"/>
                <Setter TargetName="ring" Property="BorderBrush" Value="#59F85149"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- combo box -->
    <Style x:Key="ComboItem" TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#E8ECF1"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="bd" Background="Transparent" CornerRadius="6" Margin="4,1" Padding="10,0" MinHeight="34">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="bd" Property="Background" Value="#262F3B"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1F38BDF8"/>
                <Setter Property="Foreground" Value="#38BDF8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Combo" TargetType="ComboBox">
      <Setter Property="Height" Value="40"/>
      <Setter Property="Foreground" Value="#E8ECF1"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource ComboItem}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="tg" Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="bd" Background="#0F1319" BorderBrush="#2B3340" BorderThickness="1" CornerRadius="8">
                      <TextBlock Text="&#xE70D;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11" Foreground="#9AA4B2"
                                 HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,14,0"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#3A4452"/></Trigger>
                      <Trigger Property="IsChecked" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#38BDF8"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="cp" IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" Margin="13,0,38,0"
                                VerticalAlignment="Center" HorizontalAlignment="Left"/>
              <TextBlock x:Name="ph" Text="{TemplateBinding Tag}" Foreground="#6B7584" Margin="13,0,38,1" VerticalAlignment="Center"
                         IsHitTestVisible="False" Visibility="Collapsed"/>
              <TextBox x:Name="PART_EditableTextBox" Visibility="Hidden" Background="Transparent" BorderThickness="0" Foreground="#E8ECF1"
                       CaretBrush="#38BDF8" FontSize="14" Margin="11,0,38,0" VerticalAlignment="Center" IsReadOnly="{TemplateBinding IsReadOnly}">
                <TextBox.Template><ControlTemplate TargetType="TextBox"><ScrollViewer x:Name="PART_ContentHost"/></ControlTemplate></TextBox.Template>
              </TextBox>
              <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" VerticalOffset="4"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                <Border Background="#1D242E" BorderBrush="#2B3340" BorderThickness="1" CornerRadius="8" Padding="0,4"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="300">
                  <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="SelectedIndex" Value="-1"><Setter TargetName="ph" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsEditable" Value="True">
                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
                <Setter TargetName="cp" Property="Visibility" Value="Hidden"/>
                <Setter TargetName="ph" Property="Visibility" Value="Collapsed"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- toggle switch, Windows 11 style -->
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E8ECF1"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent" MinHeight="58">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <ContentPresenter VerticalAlignment="Center" Margin="0,0,16,0"/>
              <Border x:Name="track" Grid.Column="1" Width="40" Height="20" CornerRadius="10" Background="#2B3340" VerticalAlignment="Center">
                <Ellipse x:Name="knob" Width="12" Height="12" Fill="#9AA4B2" HorizontalAlignment="Left" Margin="4,0"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="track" Property="Background" Value="#3A4452"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#38BDF8"/>
                <Setter TargetName="knob" Property="Fill" Value="#06121C"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- selectable cards -->
    <Style x:Key="RadioCard" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#9AA4B2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid>
              <Border x:Name="bd" Background="#161B22" BorderBrush="#262D38" BorderThickness="1" CornerRadius="10" Padding="16,14">
                <ContentPresenter/>
              </Border>
              <Border x:Name="check" Width="18" Height="18" CornerRadius="9" Background="#38BDF8" HorizontalAlignment="Right" VerticalAlignment="Top"
                      Margin="0,10,10,0" Visibility="Collapsed">
                <TextBlock Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="9" Foreground="#06121C"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#3A4452"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#38BDF8"/>
                <Setter TargetName="bd" Property="Background" Value="#1438BDF8"/>
                <Setter TargetName="check" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="#38BDF8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Height" Value="40"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
      <Setter Property="Foreground" Value="#9AA4B2"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="GroupName" Value="nav"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid>
              <Border x:Name="bd" CornerRadius="8" Background="Transparent"/>
              <Border x:Name="bar" Width="3" Height="16" CornerRadius="2" Background="#38BDF8" HorizontalAlignment="Left" Visibility="Hidden"/>
              <ContentPresenter Margin="14,0,12,0" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#151A21"/>
                <Setter Property="Foreground" Value="#E8ECF1"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1A38BDF8"/>
                <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="#38BDF8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- collapsible section: chevron + header in the accent color -->
    <Style x:Key="Collapse" TargetType="Expander">
      <Setter Property="Foreground" Value="#E8ECF1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Expander">
            <StackPanel>
              <ToggleButton x:Name="hd" Cursor="Hand" Focusable="False" HorizontalAlignment="Left" Content="{TemplateBinding Header}"
                            IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <StackPanel Orientation="Horizontal" Background="Transparent">
                      <TextBlock x:Name="chev" Text="&#xE76C;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="#38BDF8"
                                 VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5"/>
                      <TextBlock x:Name="tx" Text="{TemplateBinding Content}" Foreground="#38BDF8" FontWeight="SemiBold" FontSize="14" Margin="9,0,0,1"/>
                    </StackPanel>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsChecked" Value="True">
                        <Setter TargetName="chev" Property="RenderTransform"><Setter.Value><RotateTransform Angle="90"/></Setter.Value></Setter>
                      </Trigger>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="tx" Property="Foreground" Value="#7DD3FC"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="body" Visibility="Collapsed" Margin="0,14,0,0"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsExpanded" Value="True"><Setter TargetName="body" Property="Visibility" Value="Visible"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- thin scroll bar for every ScrollViewer -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template><ControlTemplate TargetType="Thumb"><Border CornerRadius="3" Background="#2B3340" Margin="2,0"/></ControlTemplate></Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid x:Name="Frame">
    <Border Margin="16" CornerRadius="12" Background="#0F1319">
      <Border.Effect><DropShadowEffect BlurRadius="28" ShadowDepth="6" Direction="270" Opacity="0.55" Color="#000000"/></Border.Effect>
    </Border>
    <Border x:Name="Root" Margin="16" CornerRadius="12" Background="#0F1319" BorderBrush="#262D38" BorderThickness="1">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="44"/><RowDefinition Height="*"/></Grid.RowDefinitions>

        <!-- ============ title bar ============ -->
        <Border x:Name="TitleBar" Background="#0B0E13" CornerRadius="11,11,0,0" BorderBrush="#1B2028" BorderThickness="0,0,0,1">
          <Grid>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
              <Border Width="24" Height="24" CornerRadius="7" Background="#1F38BDF8">
                <TextBlock Text="&#xE7FC;" Style="{StaticResource Glyph}" FontSize="13" Foreground="#38BDF8" HorizontalAlignment="Center"/>
              </Border>
              <TextBlock Text="Alexa PC Control" FontSize="13" FontWeight="SemiBold" Margin="10,0,0,1" VerticalAlignment="Center"/>
              <Border x:Name="DemoChip" Visibility="Collapsed" Margin="10,0,0,0" Padding="8,2" CornerRadius="10" Background="#1FE3B341" VerticalAlignment="Center">
                <TextBlock Text="DEMO" FontSize="11" FontWeight="SemiBold" Foreground="#E3B341"/>
              </Border>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="BtnMin" Style="{StaticResource TitleBtn}" Content="&#xE921;"/>
              <Button x:Name="BtnClose" Style="{StaticResource CloseBtn}" Content="&#xE8BB;"/>
            </StackPanel>
          </Grid>
        </Border>

        <!-- ============ assistant ============ -->
        <Grid x:Name="WizardView" Grid.Row="1">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <Grid x:Name="WizHeader" Margin="40,20,40,0">
            <Grid x:Name="Stepper" HorizontalAlignment="Left"/>
            <TextBlock x:Name="WizStepText" HorizontalAlignment="Right" VerticalAlignment="Top" FontSize="13" Foreground="#9AA4B2" Margin="0,1,0,0"/>
          </Grid>
          <Grid x:Name="WizBody" Grid.Row="1" Margin="40,20,40,0">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <TextBlock x:Name="WizTitle" Style="{StaticResource PageTitle}" Margin="0,0,0,16"/>
            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions><ColumnDefinition Width="318"/><ColumnDefinition Width="41"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel x:Name="WizGuide" Margin="0,0,8,12"/>
              </ScrollViewer>
              <Rectangle Grid.Column="1" Width="1" Fill="#1B2028" HorizontalAlignment="Center" Margin="0,2,0,12"/>
              <ScrollViewer x:Name="WizBenchScroll" Grid.Column="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <Grid Margin="0,0,6,4">

                  <!-- step 1: account -->
                  <StackPanel x:Name="W1Bench">
                    <TextBlock Text="Chave do app (App Key)" Style="{StaticResource FieldLabel}"/>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBox x:Name="W1Key" Style="{StaticResource InputMono}" Tag="Cole aqui a chave"/>
                      <Button x:Name="W1KeyPaste" Grid.Column="2" Style="{StaticResource PasteBtn}"/>
                    </Grid>
                    <TextBlock x:Name="W1KeyMsg" Style="{StaticResource FieldErr}"/>
                    <TextBlock Text="Segredo do app (App Secret)" Style="{StaticResource FieldLabel}" Margin="0,20,0,7"/>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <PasswordBox x:Name="W1Secret" Style="{StaticResource SecretInput}"/>
                      <TextBlock x:Name="W1SecretPh" IsHitTestVisible="False" Margin="13,0,0,1" VerticalAlignment="Center" FontSize="14" Foreground="#6B7584"/>
                      <Button x:Name="W1SecretPaste" Grid.Column="2" Style="{StaticResource PasteBtn}"/>
                    </Grid>
                    <TextBlock x:Name="W1SecretMsg" Style="{StaticResource FieldErr}"/>
                    <Border Margin="0,18,0,0" Padding="12,10" CornerRadius="8" Background="#11151B">
                      <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Text="&#xE72E;" Style="{StaticResource Glyph}" FontSize="14" Foreground="#9AA4B2" VerticalAlignment="Top" Margin="0,2,0,0"/>
                        <TextBlock Grid.Column="1" Style="{StaticResource Help}"
                                   Text="A chave funciona como o “usuário” do seu app e o segredo como a “senha”. Não mostre o segredo pra ninguém."/>
                      </Grid>
                    </Border>
                    <ContentControl x:Name="W1Lc" Margin="0,18,0,0"/>
                  </StackPanel>

                  <!-- step 2: devices -->
                  <StackPanel x:Name="W2Bench" Visibility="Collapsed">
                    <StackPanel x:Name="W2Devices"/>
                    <ContentControl x:Name="W2Lc" Margin="0,2,0,0"/>
                  </StackPanel>

                  <!-- step 3: Alexa -->
                  <StackPanel x:Name="W3Bench" Visibility="Collapsed">
                    <TextBlock Text="Quando você falar, eu escuto aqui." Style="{StaticResource Section}"/>
                    <ContentControl x:Name="W3Lc"/>
                    <Expander x:Name="W3Stuck" Header="Travou? Confira:" Style="{StaticResource Collapse}" Margin="0,20,0,0">
                      <StackPanel x:Name="W3StuckList"/>
                    </Expander>
                  </StackPanel>

                  <!-- step 4: TV -->
                  <StackPanel x:Name="W4Bench" Visibility="Collapsed">
                    <Grid Margin="0,0,0,12">
                      <TextBlock Text="Qual dessas é a sua TV?" Style="{StaticResource Section}" Margin="0"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Button x:Name="W4Identify" Style="{StaticResource TextBtn}" Content="Identificar telas" FontSize="13"/>
                        <Button x:Name="W4Refresh" Style="{StaticResource TextBtn}" Content="Atualizar" FontSize="13" Margin="18,0,0,0"/>
                      </StackPanel>
                    </Grid>
                    <WrapPanel x:Name="W4Screens"/>
                    <ContentControl x:Name="W4Lc" Margin="0,6,0,0"/>
                    <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                      <Button x:Name="W4TestOn" Style="{StaticResource IconSecondary}" Tag="&#xE768;" Content="Testar ligar"/>
                      <Button x:Name="W4TestOff" Style="{StaticResource IconSecondary}" Tag="&#xE71A;" Content="Testar desligar" Margin="10,0,0,0"/>
                    </StackPanel>
                  </StackPanel>

                  <!-- step 5: voice test -->
                  <StackPanel x:Name="W5Bench" Visibility="Collapsed">
                    <TextBlock Text="Fale com a Alexa. Cada comando que chegar aqui fica verde." Style="{StaticResource Section}"/>
                    <ContentControl x:Name="W5Lc1"/>
                    <ContentControl x:Name="W5Lc2" Margin="0,10,0,0"/>
                    <ContentControl x:Name="W5Lc3" Margin="0,10,0,0"/>
                  </StackPanel>
                </Grid>
              </ScrollViewer>
            </Grid>
          </Grid>

          <!-- done -->
          <Grid x:Name="DoneView" Grid.Row="0" Grid.RowSpan="3" Visibility="Collapsed">
            <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Width="460" Margin="0,0,0,24">
              <Border Width="72" Height="72" CornerRadius="36" Background="#1F3FB950" HorizontalAlignment="Center">
                <Border Width="48" Height="48" CornerRadius="24" Background="#3FB950">
                  <TextBlock Text="&#xE73E;" Style="{StaticResource Glyph}" FontSize="22" Foreground="#0F1319" HorizontalAlignment="Center"/>
                </Border>
              </Border>
              <TextBlock Text="Tudo pronto!" Style="{StaticResource PageTitle}" FontSize="28" HorizontalAlignment="Center" Margin="0,22,0,6"/>
              <TextBlock Style="{StaticResource PageSub}" TextAlignment="Center" Margin="0,0,0,22">
                <Run Text="Use quando quiser:  "/><Run Text="“Alexa, liga o modo jogo”" Foreground="#E8ECF1" FontWeight="SemiBold"/>
              </TextBlock>
              <Border Style="{StaticResource Card}" Padding="20,8">
                <StackPanel x:Name="DoneList"/>
              </Border>
              <Button x:Name="DoneOpen" Style="{StaticResource Primary}" Content="Abrir o painel" HorizontalAlignment="Center" Margin="0,26,0,0" Padding="28,0"/>
            </StackPanel>
          </Grid>

          <Border x:Name="WizFooter" Grid.Row="2" Background="#0B0E13" BorderBrush="#1B2028" BorderThickness="0,1,0,0" CornerRadius="0,0,11,11" Height="68">
            <Grid Margin="40,0">
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse x:Name="WizAgentDot" Width="8" Height="8" Fill="#6E7681"/>
                <TextBlock x:Name="WizAgentText" FontSize="13" Foreground="#9AA4B2" Margin="9,0,0,1"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                <Button x:Name="WizSkip" Style="{StaticResource TextBtn}" Content="Pular esta verificação" FontSize="13" Foreground="#9AA4B2"
                        VerticalAlignment="Center" Margin="0,0,22,0" Visibility="Collapsed"/>
                <Button x:Name="WizBack" Style="{StaticResource Secondary}" Content="Voltar" Margin="0,0,10,0"/>
                <Button x:Name="WizNext" Style="{StaticResource Primary}" Content="Continuar" MinWidth="128"/>
              </StackPanel>
            </Grid>
          </Border>
        </Grid>

        <!-- ============ panel ============ -->
        <Grid x:Name="PanelView" Grid.Row="1" Visibility="Collapsed">
          <Grid.ColumnDefinitions><ColumnDefinition Width="216"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Border Background="#0B0E13" CornerRadius="0,0,0,11" BorderBrush="#1B2028" BorderThickness="0,0,1,0">
            <Grid Margin="12,18,12,14">
              <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <StackPanel>
                <RadioButton x:Name="NavHome" Style="{StaticResource Nav}" Tag="home">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE80F;" Style="{StaticResource Glyph}" Width="28"/><TextBlock Text="Início"/></StackPanel>
                </RadioButton>
                <RadioButton x:Name="NavGame" Style="{StaticResource Nav}" Tag="gamemode">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7FC;" Style="{StaticResource Glyph}" Width="28"/><TextBlock Text="Modo Jogo"/>
                    <Ellipse x:Name="NavGameDot" Width="7" Height="7" Fill="#E3B341" Margin="10,1,0,0" Visibility="Collapsed"/></StackPanel>
                </RadioButton>
                <RadioButton x:Name="NavComputer" Style="{StaticResource Nav}" Tag="computer">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7F4;" Style="{StaticResource Glyph}" Width="28"/><TextBlock Text="Computador"/></StackPanel>
                </RadioButton>
                <RadioButton x:Name="NavGames" Style="{StaticResource Nav}" Tag="games">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8FD;" Style="{StaticResource Glyph}" Width="28"/><TextBlock Text="Jogos"/></StackPanel>
                </RadioButton>
                <RadioButton x:Name="NavConn" Style="{StaticResource Nav}" Tag="connection">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE71B;" Style="{StaticResource Glyph}" Width="28"/><TextBlock Text="Conexão"/>
                    <Ellipse x:Name="NavConnDot" Width="7" Height="7" Fill="#E3B341" Margin="10,1,0,0" Visibility="Collapsed"/></StackPanel>
                </RadioButton>
              </StackPanel>
              <Border Grid.Row="1" Background="#11151B" CornerRadius="10" Padding="14,12">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="SideDot" Width="8" Height="8" Fill="#6E7681" VerticalAlignment="Center"/>
                    <TextBlock x:Name="SideState" FontSize="13" FontWeight="SemiBold" Margin="9,0,0,1"/>
                  </StackPanel>
                  <TextBlock x:Name="SideVersion" FontSize="12" Foreground="#6B7584" Margin="17,3,0,0"/>
                </StackPanel>
              </Border>
            </Grid>
          </Border>

          <Grid Grid.Column="1">
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <ScrollViewer x:Name="PageScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <Grid Margin="40,30,34,34">

                <!-- home -->
                <StackPanel x:Name="PgHome">
                  <TextBlock Text="Início" Style="{StaticResource PageTitle}"/>
                  <TextBlock Text="Como está a ligação entre a Alexa e este PC." Style="{StaticResource PageSub}"/>
                  <Border Style="{StaticResource Card}" Padding="24,22">
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <StackPanel>
                        <StackPanel Orientation="Horizontal">
                          <Grid Width="14" Height="14" VerticalAlignment="Center">
                            <Ellipse x:Name="HomeHalo" Width="14" Height="14" Fill="#3FB950" RenderTransformOrigin="0.5,0.5" Opacity="0">
                              <Ellipse.RenderTransform><ScaleTransform x:Name="HomeHaloScale"/></Ellipse.RenderTransform>
                            </Ellipse>
                            <Ellipse x:Name="HomeDot" Width="10" Height="10" Fill="#6E7681"/>
                          </Grid>
                          <TextBlock x:Name="HomeState" FontFamily="{StaticResource Display}" FontSize="22" FontWeight="SemiBold" Margin="12,0,0,2"/>
                        </StackPanel>
                        <TextBlock x:Name="HomeSub" Style="{StaticResource Help}" FontSize="14" Margin="26,4,0,0"/>
                        <TextBlock x:Name="HomeLast" Style="{StaticResource Help}" Margin="26,14,0,0"/>
                      </StackPanel>
                      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
                        <Button x:Name="HomeBtnA" Style="{StaticResource IconSecondary}" Tag="&#xE8A5;" Content="Ver log"/>
                        <Button x:Name="HomeBtnB" Style="{StaticResource Primary}" Margin="10,0,0,0" Visibility="Collapsed"/>
                      </StackPanel>
                    </Grid>
                  </Border>
                  <Border x:Name="HomeWarn" Visibility="Collapsed" Margin="0,12,0,0" Padding="16,12" CornerRadius="10" Background="#1FE3B341" BorderBrush="#66E3B341" BorderThickness="1">
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="&#xE7BA;" Style="{StaticResource Glyph}" Foreground="#E3B341" VerticalAlignment="Top" Margin="0,1,0,0"/>
                      <TextBlock x:Name="HomeWarnText" Grid.Column="1" Style="{StaticResource Help}" Foreground="#E8ECF1"/>
                    </Grid>
                  </Border>
                  <StackPanel x:Name="HomeTodo" Margin="0,28,0,0" Visibility="Collapsed">
                    <TextBlock Text="O que falta" Style="{StaticResource Section}"/>
                    <Border Style="{StaticResource Card}" Padding="20,6"><StackPanel x:Name="HomeTodoList"/></Border>
                  </StackPanel>
                  <TextBlock Text="O que você pode falar" Style="{StaticResource Section}" Margin="0,28,0,12"/>
                  <Border Style="{StaticResource Card}" Padding="20,6"><StackPanel x:Name="HomePhrases"/></Border>
                </StackPanel>

                <!-- game mode -->
                <StackPanel x:Name="PgGame" Visibility="Collapsed">
                  <TextBlock Text="Modo Jogo" Style="{StaticResource PageTitle}"/>
                  <TextBlock Style="{StaticResource PageSub}" Text="“Alexa, liga o modo jogo” prepara tudo pra jogar na TV. Desligar volta tudo como estava."/>
                  <Border Style="{StaticResource Card}">
                    <StackPanel>
                      <Grid Margin="0,0,0,14">
                        <TextBlock Text="Qual é a sua TV?" Style="{StaticResource Section}" Margin="0"/>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                          <Button x:Name="PgIdentify" Style="{StaticResource TextBtn}" Content="Identificar telas" FontSize="13"/>
                          <Button x:Name="PgRefresh" Style="{StaticResource TextBtn}" Content="Atualizar" FontSize="13" Margin="18,0,0,0"/>
                        </StackPanel>
                      </Grid>
                      <WrapPanel x:Name="PgScreens"/>
                      <Rectangle Style="{StaticResource Divider}" Margin="0,8,0,4"/>
                      <CheckBox x:Name="CkPrimary" Style="{StaticResource Switch}">
                        <StackPanel><TextBlock Text="Usar a TV como tela principal"/><TextBlock Style="{StaticResource Help}" Text="Os jogos e a barra de tarefas abrem na TV."/></StackPanel>
                      </CheckBox>
                      <Rectangle Style="{StaticResource Divider}"/>
                      <CheckBox x:Name="CkBigPicture" Style="{StaticResource Switch}">
                        <StackPanel><TextBlock Text="Abrir o Steam em tela cheia (Big Picture)"/><TextBlock Style="{StaticResource Help}" Text="Dá pra navegar só com o controle."/></StackPanel>
                      </CheckBox>
                      <Rectangle Style="{StaticResource Divider}"/>
                      <CheckBox x:Name="CkCloseGame" Style="{StaticResource Switch}">
                        <StackPanel><TextBlock Text="Fechar o jogo ao desligar o Modo Jogo"/><TextBlock Style="{StaticResource Help}" Text="Cuidado: o jogo fecha sem salvar."/></StackPanel>
                      </CheckBox>
                    </StackPanel>
                  </Border>
                  <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                    <Button x:Name="PgTestOn" Style="{StaticResource IconSecondary}" Tag="&#xE768;" Content="Testar ligar"/>
                    <Button x:Name="PgTestOff" Style="{StaticResource IconSecondary}" Tag="&#xE71A;" Content="Testar desligar" Margin="10,0,0,0"/>
                  </StackPanel>
                  <ContentControl x:Name="PgLc" Margin="0,14,0,0" Visibility="Collapsed"/>
                  <Expander Header="Avançado" Style="{StaticResource Collapse}" Margin="0,24,0,0">
                    <Border Style="{StaticResource Card}">
                      <StackPanel>
                        <TextBlock Text="Som da TV" Style="{StaticResource FieldLabel}"/>
                        <ComboBox x:Name="CbTvAudio" Style="{StaticResource Combo}"/>
                        <TextBlock Style="{StaticResource Help}" Margin="0,8,0,0"
                                   Text="No automático, o som vai pra saída com o nome da TV. Ela só aparece no Windows enquanto a TV está ativa."/>
                      </StackPanel>
                    </Border>
                  </Expander>
                </StackPanel>

                <!-- computer -->
                <StackPanel x:Name="PgComputer" Visibility="Collapsed">
                  <TextBlock Text="Computador" Style="{StaticResource PageTitle}"/>
                  <TextBlock Style="{StaticResource PageSub}" Text="O que acontece quando você fala com a Alexa sobre o computador."/>
                  <TextBlock Text="Quando você disser “Alexa, desliga o computador”, o PC deve:" Style="{StaticResource FieldLabel}" Margin="0,0,0,10"/>
                  <UniformGrid Columns="3">
                    <RadioButton x:Name="RbSleep" Style="{StaticResource RadioCard}" GroupName="power" Margin="0,0,8,0">
                      <StackPanel><TextBlock Text="&#xE708;" Style="{StaticResource Glyph}" FontSize="20" HorizontalAlignment="Left"/>
                        <TextBlock Text="Suspender" FontWeight="SemiBold" Foreground="#E8ECF1" Margin="0,12,0,3"/>
                        <TextBlock Text="Dorme rápido e volta em segundos" Style="{StaticResource Help}" FontSize="12"/></StackPanel>
                    </RadioButton>
                    <RadioButton x:Name="RbHibernate" Style="{StaticResource RadioCard}" GroupName="power" Margin="4,0">
                      <StackPanel><TextBlock Text="&#xE74E;" Style="{StaticResource Glyph}" FontSize="20" HorizontalAlignment="Left"/>
                        <TextBlock Text="Hibernar" FontWeight="SemiBold" Foreground="#E8ECF1" Margin="0,12,0,3"/>
                        <TextBlock Text="Guarda tudo e não gasta energia" Style="{StaticResource Help}" FontSize="12"/></StackPanel>
                    </RadioButton>
                    <RadioButton x:Name="RbShutdown" Style="{StaticResource RadioCard}" GroupName="power" Margin="8,0,0,0">
                      <StackPanel><TextBlock Text="&#xE7E8;" Style="{StaticResource Glyph}" FontSize="20" HorizontalAlignment="Left"/>
                        <TextBlock Text="Desligar" FontWeight="SemiBold" Foreground="#E8ECF1" Margin="0,12,0,3"/>
                        <TextBlock Text="Desliga de vez, em 20 segundos" Style="{StaticResource Help}" FontSize="12"/></StackPanel>
                    </RadioButton>
                  </UniformGrid>
                  <Border Style="{StaticResource Card}" Margin="0,16,0,0" Padding="20,14">
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="Volume" FontWeight="SemiBold"/>
                        <TextBlock Style="{StaticResource Help}" Text="Quanto cada “aumenta” ou “abaixa” muda o volume."/>
                      </StackPanel>
                      <TextBox x:Name="TbVolStep" Grid.Column="1" Style="{StaticResource Input}" Width="72" Padding="12,0" TextAlignment="Center" VerticalAlignment="Center"/>
                      <TextBlock Grid.Column="2" Text="%" Foreground="#9AA4B2" Margin="10,0,0,1" VerticalAlignment="Center"/>
                    </Grid>
                  </Border>
                  <Expander Header="Avançado: trocar o som por voz" Style="{StaticResource Collapse}" Margin="0,24,0,0">
                    <Border Style="{StaticResource Card}">
                      <StackPanel>
                        <TextBlock Style="{StaticResource Help}" Margin="0,0,0,16"
                                   Text="Escolha pra onde vai o som quando você disser, por exemplo, “Alexa, muda a entrada do computador para TV”."/>
                        <Grid Margin="0,0,0,8">
                          <Grid.ColumnDefinitions><ColumnDefinition Width="160"/><ColumnDefinition Width="34"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions>
                          <TextBlock Text="Quando eu disser" Style="{StaticResource FieldLabel}" Margin="0"/>
                          <TextBlock Grid.Column="2" Text="Tocar o som em" Style="{StaticResource FieldLabel}" Margin="0"/>
                        </Grid>
                        <StackPanel x:Name="InputRows"/>
                        <Button x:Name="BtnAddInput" Style="{StaticResource IconSecondary}" Tag="&#xE710;" Content="Adicionar" HorizontalAlignment="Left" Margin="0,6,0,0"/>
                      </StackPanel>
                    </Border>
                  </Expander>
                </StackPanel>

                <!-- games -->
                <StackPanel x:Name="PgGames" Visibility="Collapsed">
                  <TextBlock Text="Jogos" Style="{StaticResource PageTitle}"/>
                  <TextBlock Style="{StaticResource PageSub}" Text="Atalhos opcionais: “Alexa, muda o canal do computador para 2” abre o jogo do atalho 2."/>
                  <Border x:Name="GamesCard" Style="{StaticResource Card}" Padding="20,10">
                    <StackPanel x:Name="GameRows"/>
                  </Border>
                  <Border x:Name="GamesEmpty" Style="{StaticResource Card}" Padding="28,30" Visibility="Collapsed">
                    <StackPanel HorizontalAlignment="Center">
                      <Border Width="52" Height="52" CornerRadius="26" Background="#1F38BDF8" HorizontalAlignment="Center">
                        <TextBlock Text="&#xE7FC;" Style="{StaticResource Glyph}" FontSize="22" Foreground="#38BDF8" HorizontalAlignment="Center"/>
                      </Border>
                      <TextBlock Text="Você não precisa disso pra começar." FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,16,0,6"/>
                      <TextBlock Style="{StaticResource Help}" FontSize="14" TextAlignment="Center" MaxWidth="440"
                                 Text="Dá pra falar o nome de qualquer jogo instalado: “Alexa, muda o canal do computador para Hades”. Os atalhos servem pra chamar os favoritos por número."/>
                      <Button x:Name="BtnFirstGame" Style="{StaticResource Primary}" Content="Adicionar primeiro atalho" HorizontalAlignment="Center" Margin="0,20,0,0"/>
                    </StackPanel>
                  </Border>
                  <Grid x:Name="GamesFooter" Margin="0,14,0,0">
                    <Button x:Name="BtnAddGame" Style="{StaticResource IconSecondary}" Tag="&#xE710;" Content="Adicionar jogo" HorizontalAlignment="Left"/>
                    <TextBlock Style="{StaticResource Help}" HorizontalAlignment="Right" VerticalAlignment="Center" Text="Dica: o atalho 0 fecha o jogo aberto."/>
                  </Grid>
                </StackPanel>

                <!-- connection -->
                <StackPanel x:Name="PgConn" Visibility="Collapsed">
                  <Grid>
                    <TextBlock Text="Conexão" Style="{StaticResource PageTitle}"/>
                    <Button x:Name="BtnPortal" Style="{StaticResource IconSecondary}" Tag="&#xE8A7;" Content="Abrir o portal" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                  </Grid>
                  <TextBlock Style="{StaticResource PageSub}" Text="A ligação entre a Alexa e este PC passa pelo Sinric Pro, um serviço gratuito."/>
                  <Border Style="{StaticResource Card}">
                    <StackPanel>
                      <TextBlock Text="Chave do app (App Key)" Style="{StaticResource FieldLabel}"/>
                      <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="PKey" Style="{StaticResource InputMono}" Tag="Cole aqui a chave"/>
                        <Button x:Name="PKeyPaste" Grid.Column="2" Style="{StaticResource PasteBtn}"/>
                      </Grid>
                      <TextBlock x:Name="PKeyMsg" Style="{StaticResource FieldErr}"/>
                      <TextBlock Text="Segredo do app (App Secret)" Style="{StaticResource FieldLabel}" Margin="0,18,0,7"/>
                      <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <PasswordBox x:Name="PSecret" Style="{StaticResource SecretInput}"/>
                        <TextBlock x:Name="PSecretPh" IsHitTestVisible="False" Margin="13,0,0,1" VerticalAlignment="Center" FontSize="14" Foreground="#6B7584"/>
                        <Button x:Name="PSecretPaste" Grid.Column="2" Style="{StaticResource PasteBtn}"/>
                      </Grid>
                      <TextBlock x:Name="PSecretMsg" Style="{StaticResource FieldErr}"/>
                    </StackPanel>
                  </Border>
                  <TextBlock Text="Dispositivos" Style="{StaticResource Section}" Margin="0,26,0,12"/>
                  <Border Style="{StaticResource Card}" Padding="20,6"><StackPanel x:Name="PDevices"/></Border>
                  <Expander Header="Como encontrar essas informações" Style="{StaticResource Collapse}" Margin="0,20,0,0">
                    <StackPanel x:Name="ConnHow"/>
                  </Expander>
                  <Button x:Name="BtnTestConn" Style="{StaticResource IconSecondary}" Tag="&#xE72C;" Content="Testar conexão" HorizontalAlignment="Left" Margin="0,22,0,0"/>
                  <ContentControl x:Name="ConnLc" Margin="0,14,0,0" Visibility="Collapsed"/>
                </StackPanel>
              </Grid>
            </ScrollViewer>

            <Border x:Name="SaveBar" Grid.Row="1" Visibility="Collapsed" Background="#161B22" BorderBrush="#262D38" BorderThickness="0,1,0,0" CornerRadius="0,0,11,0" Padding="40,12,34,12">
              <Grid>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <Ellipse Width="8" Height="8" Fill="#E3B341"/>
                  <TextBlock Text="Você tem alterações não salvas" FontSize="14" Margin="10,0,0,1"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                  <Button x:Name="BtnDiscard" Style="{StaticResource Secondary}" Content="Descartar"/>
                  <Button x:Name="BtnSave" Style="{StaticResource Primary}" Content="Salvar" Margin="10,0,0,0" MinWidth="96"/>
                </StackPanel>
              </Grid>
            </Border>
          </Grid>
        </Grid>

        <!-- ============ overlays ============ -->
        <Border x:Name="Toast" Grid.Row="1" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,86"
                Background="#1D242E" BorderBrush="#2B3340" BorderThickness="1" CornerRadius="10" Padding="16,11">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="ToastIcon" Text="&#xE73E;" Style="{StaticResource Glyph}" FontSize="14" Foreground="#3FB950"/>
            <TextBlock x:Name="ToastText" FontSize="14" Margin="10,0,0,1" MaxWidth="560" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
        <Grid x:Name="Confirm" Grid.Row="0" Grid.RowSpan="2" Visibility="Collapsed" Background="#B3070A0E">
          <Border Style="{StaticResource Card}" Width="440" HorizontalAlignment="Center" VerticalAlignment="Center" Padding="26,24" Background="#1D242E">
            <StackPanel>
              <TextBlock Text="Salvar antes de fechar?" FontFamily="{StaticResource Display}" FontSize="20" FontWeight="SemiBold"/>
              <TextBlock Style="{StaticResource Help}" FontSize="14" Margin="0,8,0,22" Text="Você tem alterações que ainda não foram salvas."/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="CfDiscard" Style="{StaticResource Secondary}" Content="Fechar sem salvar"/>
                <Button x:Name="CfCancel" Style="{StaticResource Secondary}" Content="Cancelar" Margin="10,0,0,0"/>
                <Button x:Name="CfSave" Style="{StaticResource Primary}" Content="Salvar e fechar" Margin="10,0,0,0"/>
              </StackPanel>
            </StackPanel>
          </Border>
        </Grid>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

# ====================================================================== state

$App = @{
    Data = $null; Cfg = $null; DemoStatus = $null; Mode = ''; Step = 0; Page = ''; Loading = $true; Dirty = $false; Closing = $false
    W = @{}; StepOpenedAt = [DateTimeOffset]::Now; Test = $null; ToastUntil = $null; Tick = 0; TodoSig = $null
    GameRowsList = $null; InputRowsList = $null; WizIds = @{}; PanelIds = @{}
    W1Lc = $null; W2Lc = $null; W3Lc = $null; W4Lc = $null; W5Lcs = $null; PgLcObj = $null; ConnLcObj = $null; ConnTestAt = $null; IdentifyWindows = $null
}
$Ctl = @{}

$reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
$Window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($n in @('Frame', 'Root', 'TitleBar', 'DemoChip', 'BtnMin', 'BtnClose',
                 'WizardView', 'WizHeader', 'Stepper', 'WizStepText', 'WizBody', 'WizTitle', 'WizGuide', 'WizBenchScroll',
                 'W1Bench', 'W1Key', 'W1KeyPaste', 'W1KeyMsg', 'W1Secret', 'W1SecretPh', 'W1SecretPaste', 'W1SecretMsg', 'W1Lc',
                 'W2Bench', 'W2Devices', 'W2Lc', 'W3Bench', 'W3Lc', 'W3Stuck', 'W3StuckList',
                 'W4Bench', 'W4Identify', 'W4Refresh', 'W4Screens', 'W4Lc', 'W4TestOn', 'W4TestOff',
                 'W5Bench', 'W5Lc1', 'W5Lc2', 'W5Lc3', 'DoneView', 'DoneList', 'DoneOpen',
                 'WizFooter', 'WizAgentDot', 'WizAgentText', 'WizSkip', 'WizBack', 'WizNext',
                 'PanelView', 'NavHome', 'NavGame', 'NavGameDot', 'NavComputer', 'NavGames', 'NavConn', 'NavConnDot', 'SideDot', 'SideState', 'SideVersion',
                 'PageScroll', 'PgHome', 'HomeHalo', 'HomeHaloScale', 'HomeDot', 'HomeState', 'HomeSub', 'HomeLast', 'HomeBtnA', 'HomeBtnB',
                 'HomeWarn', 'HomeWarnText', 'HomeTodo', 'HomeTodoList', 'HomePhrases',
                 'PgGame', 'PgIdentify', 'PgRefresh', 'PgScreens', 'CkPrimary', 'CkBigPicture', 'CkCloseGame', 'PgTestOn', 'PgTestOff', 'PgLc', 'CbTvAudio',
                 'PgComputer', 'RbSleep', 'RbHibernate', 'RbShutdown', 'TbVolStep', 'InputRows', 'BtnAddInput',
                 'PgGames', 'GamesCard', 'GameRows', 'GamesEmpty', 'BtnFirstGame', 'GamesFooter', 'BtnAddGame',
                 'PgConn', 'BtnPortal', 'PKey', 'PKeyPaste', 'PKeyMsg', 'PSecret', 'PSecretPh', 'PSecretPaste', 'PSecretMsg', 'PDevices', 'ConnHow',
                 'BtnTestConn', 'ConnLc', 'SaveBar', 'BtnDiscard', 'BtnSave', 'Toast', 'ToastIcon', 'ToastText',
                 'Confirm', 'CfDiscard', 'CfCancel', 'CfSave')) {
    $Ctl[$n] = $Window.FindName($n)
    if ($null -eq $Ctl[$n]) { throw "XAML element not found: $n" }
}
$Ctl.SideVersion.Text = 'Alexa PC Control ' + $Version

function Get-Style([string]$Key) { return $Window.FindResource($Key) }

# ====================================================================== building blocks

function New-Text([string]$Text, [double]$Size = 14, [string]$Hex = '#E8ECF1', [string]$Weight = 'Normal') {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = Brush $Hex; $t.FontWeight = $Weight; $t.TextWrapping = 'Wrap'
    return $t
}

function New-GlyphText([int]$Code, [double]$Size = 16, [string]$Hex = '#9AA4B2') {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = Glyph $Code; $t.FontFamily = $IconFont; $t.FontSize = $Size; $t.Foreground = Brush $Hex
    $t.VerticalAlignment = 'Center'; $t.HorizontalAlignment = 'Center'
    return $t
}

function New-Column($Grid, $Width) {
    $cd = New-Object Windows.Controls.ColumnDefinition
    if ($Width -eq '*') { $cd.Width = New-Object Windows.GridLength(1, 'Star') }
    elseif ($Width -eq 'auto') { $cd.Width = [Windows.GridLength]::Auto }
    else { $cd.Width = New-Object Windows.GridLength([double]$Width) }
    $Grid.ColumnDefinitions.Add($cd)
}

# Fills a TextBlock from light markup: **bold**, [[Menu]] as a pill (menu names exactly as on screen), {portal} as a link.
function Set-Rich($TextBlock, [string]$Text) {
    $TextBlock.Inlines.Clear()
    foreach ($part in [regex]::Split($Text, '(\*\*.+?\*\*|\[\[.+?\]\]|\{portal\})')) {
        if (-not $part) { continue }
        if ($part -match '^\*\*(.+)\*\*$') {
            $r = New-Object Windows.Documents.Run $Matches[1]; $r.FontWeight = 'SemiBold'; $r.Foreground = $Br.Text
            $TextBlock.Inlines.Add($r)
        } elseif ($part -match '^\[\[(.+)\]\]$') {
            $pill = New-Object Windows.Controls.Border
            $pill.Background = $Br.Elevated; $pill.BorderBrush = $Br.InputLine; $pill.BorderThickness = 1; $pill.CornerRadius = 6; $pill.Padding = '7,0,7,1'
            $pill.Margin = '1,0,1,0'
            $pt = New-Text $Matches[1] 13 '#E8ECF1' 'SemiBold'; $pt.TextWrapping = 'NoWrap'
            $pill.Child = $pt
            $pill.RenderTransform = New-Object Windows.Media.TranslateTransform(0, 2)
            $ui = New-Object Windows.Documents.InlineUIContainer $pill; $ui.BaselineAlignment = 'Center'
            $TextBlock.Inlines.Add($ui)
        } elseif ($part -eq '{portal}') {
            $b = New-Object Windows.Controls.Button
            $b.Style = Get-Style 'TextBtn'; $b.Content = 'Abrir o portal do Sinric  ↗'; $b.FontSize = 14
            $b.Add_Click({ Open-Portal })
            $ui = New-Object Windows.Documents.InlineUIContainer $b; $ui.BaselineAlignment = 'Center'
            $TextBlock.Inlines.Add($ui)
        } else {
            $TextBlock.Inlines.Add((New-Object Windows.Documents.Run $part))
        }
    }
}

# Left column of a step: why it matters, then numbered instructions.
function Set-Guide([string]$Purpose, [string[]]$Steps, [string]$Heading = 'Faça isto', [string]$Tip = '') {
    $p = $Ctl.WizGuide; $p.Children.Clear()
    [void]$p.Children.Add((New-Text 'PARA QUE SERVE' 11 '#6B7584' 'SemiBold'))
    $why = New-Text '' 14 '#9AA4B2'; $why.LineHeight = 21; $why.Margin = '0,6,0,26'; Set-Rich $why $Purpose
    [void]$p.Children.Add($why)
    [void]$p.Children.Add((New-Text $Heading.ToUpper() 11 '#6B7584' 'SemiBold'))
    $i = 0
    foreach ($s in $Steps) {
        $i++
        $row = New-Object Windows.Controls.Grid; $row.Margin = '0,12,0,0'
        New-Column $row 34; New-Column $row '*'
        $num = New-Object Windows.Controls.Border
        $num.Width = 22; $num.Height = 22; $num.CornerRadius = 11; $num.BorderBrush = $Br.InputLine; $num.BorderThickness = 1
        $num.VerticalAlignment = 'Top'; $num.HorizontalAlignment = 'Left'
        $nt = New-Text ([string]$i) 12 '#9AA4B2' 'SemiBold'; $nt.HorizontalAlignment = 'Center'; $nt.VerticalAlignment = 'Center'; $nt.Margin = '0,0,0,1'
        $num.Child = $nt
        $tx = New-Text '' 14 '#C9D1DB'; $tx.LineHeight = 22; Set-Rich $tx $s
        [Windows.Controls.Grid]::SetColumn($tx, 1)
        [void]$row.Children.Add($num); [void]$row.Children.Add($tx)
        [void]$p.Children.Add($row)
    }
    if ($Tip) {
        $box = New-Object Windows.Controls.Border
        $box.Background = Brush '#11151B'; $box.CornerRadius = 8; $box.Padding = '12,10'; $box.Margin = '0,22,0,0'
        $g = New-Object Windows.Controls.Grid; New-Column $g 26; New-Column $g '*'
        $ic = New-GlyphText 0xE946 14 '#9AA4B2'; $ic.VerticalAlignment = 'Top'; $ic.HorizontalAlignment = 'Left'; $ic.Margin = '0,2,0,0'
        $tt = New-Text '' 13 '#9AA4B2'; $tt.LineHeight = 20; Set-Rich $tt $Tip; [Windows.Controls.Grid]::SetColumn($tt, 1)
        [void]$g.Children.Add($ic); [void]$g.Children.Add($tt); $box.Child = $g
        [void]$p.Children.Add($box)
    }
}

# ---------------------------------------------------------------- live check

$LiveCheckXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        CornerRadius="10" BorderThickness="1" Padding="14,12,14,12" MinHeight="58">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="32"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <Grid Width="20" Height="20" VerticalAlignment="Top" HorizontalAlignment="Left" Margin="0,1,0,0">
      <Path x:Name="spin" Stroke="#9AA4B2" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
            Data="M 10,2 A 8,8 0 1 1 2,10" RenderTransformOrigin="0.5,0.5">
        <Path.RenderTransform><RotateTransform x:Name="rot"/></Path.RenderTransform>
      </Path>
      <Border x:Name="badge" Width="20" Height="20" CornerRadius="10">
        <TextBlock x:Name="glyph" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="#0F1319"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
    </Grid>
    <StackPanel Grid.Column="1" VerticalAlignment="Center">
      <TextBlock x:Name="title" FontSize="14" FontWeight="SemiBold" Foreground="#E8ECF1" TextWrapping="Wrap"/>
      <TextBlock x:Name="body" FontSize="13" Foreground="#9AA4B2" TextWrapping="Wrap" LineHeight="19" Margin="0,3,0,0"/>
      <StackPanel x:Name="more" Visibility="Collapsed" Margin="0,6,0,0"/>
    </StackPanel>
    <StackPanel x:Name="actions" Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0"/>
  </Grid>
</Border>
'@

$LiveLook = @{
    wait = @{ Border = '#2B3340'; Back = '#1D242E'; Badge = ''; Glyph = 0 }
    idle = @{ Border = '#262D38'; Back = '#161B22'; Badge = '#232B36'; Glyph = 0xE946 }
    ok   = @{ Border = '#663FB950'; Back = '#1A3FB950'; Badge = '#3FB950'; Glyph = 0xE73E }
    warn = @{ Border = '#66E3B341'; Back = '#1AE3B341'; Badge = '#E3B341'; Glyph = 0xE7BA }
    err  = @{ Border = '#66F85149'; Back = '#1AF85149'; Badge = '#F85149'; Glyph = 0xE711 }
}

function New-LiveCheck($HostControl) {
    $root = [Windows.Markup.XamlReader]::Parse($LiveCheckXaml)
    $lc = @{ Root = $root; Sig = '' }
    foreach ($n in @('spin', 'rot', 'badge', 'glyph', 'title', 'body', 'more', 'actions')) { $lc[$n] = $root.FindName($n) }
    $anim = New-Object Windows.Media.Animation.DoubleAnimation(0, 360, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(900))))
    $anim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $lc.rot.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $anim)
    $HostControl.Content = $root
    return $lc
}

# $Actions: @(@{ Text; Do = 'portal' | 'restart' | 'log' | 'step1' | 'step3' | 'step4' }), $Detail: raw text behind "Detalhes técnicos"
function Set-LiveCheck($Lc, [string]$State, [string]$Title, [string]$Body = '', $Actions = @(), [string]$Detail = '') {
    $sig = $State + '|' + $Title + '|' + $Body + '|' + (@($Actions | ForEach-Object { $_.Text }) -join ',') + '|' + $Detail
    if ($Lc.Sig -eq $sig) { return }
    $Lc.Sig = $sig
    $look = $LiveLook[$State]
    $Lc.Root.BorderBrush = Brush $look.Border; $Lc.Root.Background = Brush $look.Back
    if ($State -eq 'wait') { $Lc.spin.Visibility = 'Visible'; $Lc.badge.Visibility = 'Collapsed' }
    else {
        $Lc.spin.Visibility = 'Collapsed'; $Lc.badge.Visibility = 'Visible'; $Lc.badge.Background = Brush $look.Badge
        $Lc.glyph.Text = Glyph $look.Glyph
        $Lc.glyph.FontSize = $(if ($State -eq 'err') { 9 } else { 10 })
        $Lc.glyph.Foreground = $(if ($State -eq 'idle') { $Br.Text2 } else { Brush '#0F1319' })
    }
    Set-Rich $Lc.title $Title
    Set-Rich $Lc.body $Body
    $Lc.body.Visibility = $(if ($Body) { 'Visible' } else { 'Collapsed' })
    $Lc.actions.Children.Clear()
    foreach ($a in @($Actions)) {
        if (-not $a) { continue }
        $b = New-Object Windows.Controls.Button
        $b.Style = Get-Style 'Secondary'; $b.Height = 32; $b.Padding = '12,0'; $b.FontSize = 13; $b.Margin = '8,0,0,0'
        $b.Content = $a.Text; $b.Tag = $a.Do
        $b.Add_Click({ Invoke-LiveAction ([string]$this.Tag) })
        [void]$Lc.actions.Children.Add($b)
    }
    $Lc.more.Children.Clear(); $Lc.more.Visibility = 'Collapsed'
    if ($Detail) {
        $exp = New-Object Windows.Controls.Expander
        $exp.Style = Get-Style 'Collapse'; $exp.Header = 'Detalhes técnicos'; $exp.FontSize = 12
        $dt = New-Text $Detail 12 '#9AA4B2'; $dt.FontFamily = 'Cascadia Mono, Consolas'
        $exp.Content = $dt
        [void]$Lc.more.Children.Add($exp); $Lc.more.Visibility = 'Visible'
    }
    $Lc.Root.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation(0.35, 1, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(160))))))
}

function Invoke-LiveAction([string]$What) {
    switch ($What) {
        'portal'  { Open-Portal }
        'restart' { Restart-Agent }
        'log'     { Open-Log }
        'step1'   { Show-Step 1 }
        'step3'   { Show-Step 3 }
        'step4'   { Show-Step 4 }
    }
}

# ---------------------------------------------------------------- toast and field helpers

function Show-Toast([string]$Text, [string]$Kind = 'ok') {
    $Ctl.ToastText.Text = $Text
    switch ($Kind) {
        'err'  { $Ctl.ToastIcon.Text = Glyph 0xE711; $Ctl.ToastIcon.Foreground = $Br.Err }
        'info' { $Ctl.ToastIcon.Text = Glyph 0xE946; $Ctl.ToastIcon.Foreground = $Br.Accent }
        default { $Ctl.ToastIcon.Text = Glyph 0xE73E; $Ctl.ToastIcon.Foreground = $Br.Ok }
    }
    $Ctl.Toast.Visibility = 'Visible'
    $App.ToastUntil = (Get-Date).AddSeconds(3.5)
}

function Get-ClipboardCode { try { return ConvertTo-CleanCode ([Windows.Clipboard]::GetText()) } catch { return '' } }

function Set-FieldState($Box, $Msg, $Result) {
    $Box.Uid = [string]$Result.State
    $Msg.Text = [string]$Result.Msg
    $Msg.Visibility = $(if ($Result.State -eq 'err') { 'Visible' } else { 'Collapsed' })
}

# Cleans a pasted/typed code in place (keeps the caret at the end).
function Set-CleanText($Box) {
    $clean = ConvertTo-CleanCode $Box.Text
    if ($clean -ne $Box.Text) { $Box.Text = $clean; $Box.CaretIndex = $clean.Length }
}

# ---------------------------------------------------------------- device rows (assistant cards and Conexão rows)

function New-DeviceRow($Def, [string]$Context) {
    $grid = New-Object Windows.Controls.Grid
    $wide = $Context -ne 'wizard'
    New-Column $grid $(if ($wide) { 46 } else { 42 }); New-Column $grid '*'; New-Column $grid $(if ($wide) { 290 } else { 0 }); New-Column $grid 8; New-Column $grid 'auto'
    foreach ($k in 1..3) { $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = [Windows.GridLength]::Auto; $grid.RowDefinitions.Add($rd) }

    $icon = New-Object Windows.Controls.Border
    $icon.Width = $(if ($wide) { 34 } else { 30 }); $icon.Height = $icon.Width; $icon.CornerRadius = 8; $icon.Background = Brush '#1438BDF8'; $icon.HorizontalAlignment = 'Left'; $icon.VerticalAlignment = 'Center'
    $icon.Child = New-GlyphText $Def.Glyph 15 '#38BDF8'
    [void]$grid.Children.Add($icon)

    $nm = New-Text $Def.Name 14 '#E8ECF1' 'SemiBold'; $nm.TextWrapping = 'NoWrap'; $nm.VerticalAlignment = 'Center'
    $type = New-Text '' 12 '#9AA4B2'; $type.TextWrapping = 'NoWrap'; $type.VerticalAlignment = 'Center'; Set-Rich $type ('Tipo: **' + $Def.Type + '**')
    $copy = New-Object Windows.Controls.Button
    $copy.Style = Get-Style 'TextBtn'; $copy.Content = 'Copiar nome'; $copy.FontSize = 12; $copy.Tag = $Def.Name; $copy.VerticalAlignment = 'Center'
    $copy.Add_Click({ try { [Windows.Clipboard]::SetText([string]$this.Tag); Show-Toast ('Nome “' + $this.Tag + '” copiado.') } catch { } })
    if ($wide) {
        $names = New-Object Windows.Controls.StackPanel; $names.VerticalAlignment = 'Center'; $names.Margin = '0,0,10,0'
        $sub = New-Object Windows.Controls.StackPanel; $sub.Orientation = 'Horizontal'; $sub.Margin = '0,2,0,0'
        $copy.Margin = '10,0,0,0'
        [void]$sub.Children.Add($type); [void]$sub.Children.Add($copy)
        [void]$names.Children.Add($nm); [void]$names.Children.Add($sub)
    } else {
        # one header line: name, type chip, and the copy link on the right
        $names = New-Object Windows.Controls.Grid; $names.VerticalAlignment = 'Center'
        New-Column $names 'auto'; New-Column $names 'auto'; New-Column $names '*'; New-Column $names 'auto'
        $chip = New-Object Windows.Controls.Border; $chip.Background = $Br.Elevated; $chip.CornerRadius = 9; $chip.Padding = '8,1,8,2'; $chip.Margin = '10,0,0,0'
        $chip.VerticalAlignment = 'Center'; $chip.Child = $type
        [Windows.Controls.Grid]::SetColumn($chip, 1); [Windows.Controls.Grid]::SetColumn($copy, 3)
        [void]$names.Children.Add($nm); [void]$names.Children.Add($chip); [void]$names.Children.Add($copy)
        [Windows.Controls.Grid]::SetColumnSpan($names, 4)
    }
    [Windows.Controls.Grid]::SetColumn($names, 1)
    [void]$grid.Children.Add($names)

    $box = New-Object Windows.Controls.TextBox
    $box.Style = Get-Style 'InputMono'; $box.Tag = 'Cole o ID do dispositivo'; $box.MaxLength = 80; $box.VerticalAlignment = 'Center'
    $paste = New-Object Windows.Controls.Button
    $paste.Style = Get-Style 'PasteBtn'; $paste.VerticalAlignment = 'Center'; $paste.DataContext = $box
    $msg = New-Object Windows.Controls.TextBlock
    $msg.Style = Get-Style 'FieldErr'
    if ($wide) {
        # Conexão page: one line per device, the error under the field
        [Windows.Controls.Grid]::SetColumn($box, 2)
        [Windows.Controls.Grid]::SetColumn($paste, 4)
        [Windows.Controls.Grid]::SetColumn($msg, 1); [Windows.Controls.Grid]::SetColumnSpan($msg, 4); [Windows.Controls.Grid]::SetRow($msg, 1)
        $msg.TextAlignment = 'Right'
    } else {
        # assistant card: the name on top, the id field across the whole card
        [Windows.Controls.Grid]::SetRow($box, 1); [Windows.Controls.Grid]::SetColumnSpan($box, 3); $box.Margin = '0,10,0,0'
        [Windows.Controls.Grid]::SetRow($paste, 1); [Windows.Controls.Grid]::SetColumn($paste, 4); $paste.Margin = '0,10,0,0'
        [Windows.Controls.Grid]::SetRow($msg, 2); [Windows.Controls.Grid]::SetColumnSpan($msg, 5)
    }
    [void]$grid.Children.Add($box); [void]$grid.Children.Add($paste); [void]$grid.Children.Add($msg)

    $paste.Add_Click({ $b = $this.DataContext; $b.Text = Get-ClipboardCode; $b.CaretIndex = $b.Text.Length; [void]$b.Focus() })
    $box.Add_TextChanged({
        if ($App.Loading) { return }
        Set-CleanText $this
        if ($App.Mode -eq 'wizard') { Update-Step2 } else { [void](Update-PanelIds); Set-Dirty $true }
    })
    return @{ Role = $Def.Role; Name = $Def.Name; Grid = $grid; Box = $box; Msg = $msg }
}

# Validates a set of id rows against each other; returns how many are valid.
function Test-IdRows($Rows) {
    $valid = 0
    foreach ($r in $Rows) {
        $other = $null
        foreach ($o in $Rows) { if ($o.Role -ne $r.Role -and $o.Box.Text -and $o.Box.Text -eq $r.Box.Text) { $other = $o.Name; break } }
        $res = Test-IdCode $r.Box.Text $other
        Set-FieldState $r.Box $r.Msg $res
        if ($res.State -eq 'ok') { $valid++ }
    }
    return $valid
}

# ---------------------------------------------------------------- screen cards

function Get-SuggestedTv($Monitors) {
    $others = @($Monitors | Where-Object { -not $_.Primary })
    $brand = @($others | Where-Object { $_.Name -match '(?i)\btv\b|samsung|\blg\b|sony|tcl|philips|hisense|panasonic|toshiba' })
    if ($brand.Count -eq 1) { return $brand[0].DevicePath }
    if ($others.Count -eq 1) { return $others[0].DevicePath }
    return ''
}

function Build-ScreenCards($Wrap, [string]$Group, [string]$Selected, [string]$Suggested, [string]$SavedName) {
    $Wrap.Children.Clear()
    $list = @($App.Data.Monitors)
    if ($Selected -and -not ($list | Where-Object { $_.DevicePath -eq $Selected })) {
        $list += [pscustomobject]@{ Name = $SavedName; DevicePath = $Selected; Available = $false; Active = $false; Primary = $false; Missing = $true }
    }
    $i = 0
    foreach ($m in $list) {
        $i++
        $rb = New-Object Windows.Controls.RadioButton
        $rb.Style = Get-Style 'RadioCard'; $rb.GroupName = $Group; $rb.Width = 178; $rb.Height = 146; $rb.Margin = '0,0,12,12'; $rb.Tag = $m
        $sp = New-Object Windows.Controls.StackPanel

        # a little monitor with its number, like Windows "Identify"
        $draw = New-Object Windows.Controls.Grid; $draw.HorizontalAlignment = 'Left'; $draw.Height = 46; $draw.Width = 64
        $scr = New-Object Windows.Controls.Border
        $scr.Width = 64; $scr.Height = 40; $scr.CornerRadius = 5; $scr.BorderThickness = 2; $scr.VerticalAlignment = 'Top'
        $scr.BorderBrush = $(if ($m.Active) { Brush '#4A5566' } else { Brush '#2B3340' })
        $scr.Background = $(if ($m.Active) { Brush '#1D242E' } else { Brush '#12161C' })
        $num = New-Text ([string]$i) 18 $(if ($m.Active) { '#E8ECF1' } else { '#6B7584' }) 'SemiBold'
        $num.HorizontalAlignment = 'Center'; $num.VerticalAlignment = 'Center'; $num.Margin = '0,0,0,2'
        $scr.Child = $num
        $stand = New-Object Windows.Shapes.Rectangle
        $stand.Width = 20; $stand.Height = 3; $stand.RadiusX = 1.5; $stand.RadiusY = 1.5; $stand.Fill = Brush '#2B3340'; $stand.VerticalAlignment = 'Bottom'
        [void]$draw.Children.Add($scr); [void]$draw.Children.Add($stand)
        [void]$sp.Children.Add($draw)

        $name = New-Text ([string]$m.Name) 14 '#E8ECF1' 'SemiBold'; $name.TextWrapping = 'NoWrap'; $name.TextTrimming = 'CharacterEllipsis'; $name.Margin = '0,10,0,2'
        [void]$sp.Children.Add($name)
        $state = 'Desativada'; $hint = 'use Testar ligar pra ver nela'
        if ($m.Missing) { $state = 'Não encontrada agora'; $hint = 'ligue a TV e clique em Atualizar' }
        elseif (-not $m.Available) { $state = 'Desconectada'; $hint = 'ligue a TV e clique em Atualizar' }
        elseif ($m.Primary) { $state = 'Principal · ativa'; $hint = '' }
        elseif ($m.Active) { $state = 'Ativa'; $hint = '' }
        $st = New-Text $state 12 '#9AA4B2'; $st.TextWrapping = 'NoWrap'
        [void]$sp.Children.Add($st)
        if ($hint) { $h = New-Text $hint 12 '#6B7584'; $h.TextTrimming = 'CharacterEllipsis'; $h.TextWrapping = 'NoWrap'; [void]$sp.Children.Add($h) }
        $holder = New-Object Windows.Controls.Grid
        [void]$holder.Children.Add($sp)
        if ($Suggested -and $m.DevicePath -eq $Suggested) {
            $chip = New-Object Windows.Controls.Border
            $chip.Background = Brush '#1F38BDF8'; $chip.CornerRadius = 9; $chip.Padding = '7,0,7,1'; $chip.HorizontalAlignment = 'Right'; $chip.VerticalAlignment = 'Top'
            $chip.Margin = '0,10,18,0'
            $chip.Child = New-Text 'Sugerida' 11 '#38BDF8' 'SemiBold'
            [void]$holder.Children.Add($chip)
        }
        $rb.Content = $holder
        if ($m.DevicePath -eq $Selected) { $rb.IsChecked = $true }
        $rb.Add_Checked({ Select-Screen ([string]$this.GroupName) $this.Tag })
        [void]$Wrap.Children.Add($rb)
    }
}

function Select-Screen([string]$Group, $Monitor) {
    if ($App.Loading) { return }
    if ($Group -eq 'wiz') {
        $App.W.TvPath = [string]$Monitor.DevicePath; $App.W.TvName = [string]$Monitor.Name; $App.W.TestedOn = $false; $App.W.TestedOff = $false
        Update-Step4
    } else {
        $App.Cfg.gameMode.tvPath = [string]$Monitor.DevicePath; $App.Cfg.gameMode.tvName = [string]$Monitor.Name
        Set-Dirty $true
    }
}

# Big translucent number on every active screen for 3 s (inactive screens show nothing: that is what Testar ligar is for).
function Show-ScreenNumbers {
    if ($Demo -or $Screenshot) { return }
    Update-Monitors
    $src = [Windows.PresentationSource]::FromVisual($Window)
    $sx = 1.0; $sy = 1.0
    if ($src) { $sx = $src.CompositionTarget.TransformFromDevice.M11; $sy = $src.CompositionTarget.TransformFromDevice.M22 }
    $wins = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($m in @($App.Data.Monitors)) {
        $i++
        if (-not $m.Active) { continue }
        $w = New-Object Windows.Window
        $w.WindowStyle = 'None'; $w.AllowsTransparency = $true; $w.Background = $Br.Clear; $w.Topmost = $true; $w.ShowInTaskbar = $false
        $w.ShowActivated = $false; $w.ResizeMode = 'NoResize'; $w.WindowStartupLocation = 'Manual'
        $w.Left = $m.X * $sx; $w.Top = $m.Y * $sy; $w.Width = $m.Width * $sx; $w.Height = $m.Height * $sy
        $card = New-Object Windows.Controls.Border
        $card.Background = Brush '#E60F1319'; $card.BorderBrush = $Br.Accent; $card.BorderThickness = 2; $card.CornerRadius = 28; $card.Padding = '72,10,72,34'
        $card.HorizontalAlignment = 'Center'; $card.VerticalAlignment = 'Center'
        $sp = New-Object Windows.Controls.StackPanel
        $n = New-Text ([string]$i) 180 '#38BDF8' 'SemiBold'; $n.HorizontalAlignment = 'Center'; $n.FontFamily = 'Segoe UI Variable Display, Segoe UI'
        $t = New-Text ([string]$m.Name) 26 '#E8ECF1' 'SemiBold'; $t.HorizontalAlignment = 'Center'
        [void]$sp.Children.Add($n); [void]$sp.Children.Add($t)
        $card.Child = $sp; $w.Content = $card
        $w.Show(); [void]$wins.Add($w)
    }
    if ($wins.Count -eq 0) { Show-Toast 'Nenhuma tela ativa pra mostrar o número.' 'info'; return }
    $App.IdentifyWindows = $wins
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(3)
    $timer.Add_Tick({ $this.Stop(); foreach ($x in @($App.IdentifyWindows)) { try { $x.Close() } catch { } }; $App.IdentifyWindows = $null })
    $timer.Start()
}

# ---------------------------------------------------------------- game mode test (Agente.ps1 -Action, without freezing the window)

function Start-GameModeTest([string]$Action, $Lc, [string]$Context) {
    if ($App.Test -or $Demo) { return }
    $name = $(if ($Context -eq 'wiz') { $App.W.TvName } else { [string]$App.Cfg.gameMode.tvName })
    if ($Action -eq 'GameModeOn') { Set-LiveCheck $Lc 'wait' 'Ligando o Modo Jogo…' 'A imagem pode piscar por um instante.' }
    else { Set-LiveCheck $Lc 'wait' 'Desligando o Modo Jogo…' 'Voltando telas e som como estavam.' }
    $p = Start-Process -FilePath $PowerShell -WindowStyle Hidden -PassThru `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $AgentPath + '" -Action ' + $Action)
    $null = $p.Handle   # keeps the exit code readable after the process ends
    $App.Test = @{ Proc = $p; Action = $Action; Lc = $Lc; Context = $Context; Name = $name; Started = Get-Date }
    Update-TestButtons
}

function Update-TestButtons {
    $busy = [bool]$App.Test
    foreach ($b in @($Ctl.PgTestOn, $Ctl.PgTestOff)) { $b.IsEnabled = -not $busy }
    if ($App.Mode -eq 'wizard' -and $App.Step -eq 4) { Update-Step4 }
}

function Test-GameModeFinished {
    $t = $App.Test
    if (-not $t) { return }
    if (-not $t.Proc.HasExited) {
        if (((Get-Date) - $t.Started).TotalSeconds -gt 90) { try { $t.Proc.Kill() } catch { } } else { return }
    }
    $code = 2; try { $code = $t.Proc.ExitCode } catch { }
    $App.Test = $null
    Update-Monitors
    $tvPath = $(if ($t.Context -eq 'wiz') { $App.W.TvPath } else { [string]$App.Cfg.gameMode.tvPath })
    $tv = @($App.Data.Monitors) | Where-Object { $_.DevicePath -eq $tvPath } | Select-Object -First 1
    $name = $t.Name
    if ($t.Action -eq 'GameModeOn') {
        if ($code -eq 0 -and $tv -and $tv.Active) {
            $title = $(if ($tv.Primary) { 'Funcionou! A **' + $name + '** virou a tela principal.' } else { 'Funcionou! A imagem foi pra **' + $name + '**.' })
            Set-LiveCheck $t.Lc 'ok' $title 'Agora clique em **Testar desligar** pra voltar ao normal.'
            if ($t.Context -eq 'wiz') { $App.W.TestedOn = $true }
        } elseif ($code -le 1) {
            Set-LiveCheck $t.Lc 'warn' ('A tela **' + $name + '** não ligou.') 'Confira se a TV está ligada e na entrada HDMI do PC. Depois teste de novo.' @(@{ Text = 'Ver log'; Do = 'log' })
        } else {
            Set-LiveCheck $t.Lc 'err' 'Não consegui trocar a tela.' 'Veja o log pra saber o motivo.' @(@{ Text = 'Ver log'; Do = 'log' })
        }
    } else {
        if ($code -eq 0) {
            Set-LiveCheck $t.Lc 'ok' 'Tudo voltou como estava.' $(if ($t.Context -eq 'wiz') { 'A TV está configurada. Pode continuar.' } else { '' })
            if ($t.Context -eq 'wiz') {
                $App.W.TestedOff = $true
                if ($App.W.TestedOn) { $App.Data.Wizard.tv = $true; Save-WizardState }
            }
        } else {
            Set-LiveCheck $t.Lc 'err' 'Não consegui voltar as telas.' 'Use Win+P pra escolher a tela e veja o log.' @(@{ Text = 'Ver log'; Do = 'log' })
        }
    }
    Update-TestButtons
}

# ====================================================================== assistant

function Update-Stepper([int]$Step) {
    $g = $Ctl.Stepper; $g.Children.Clear(); $g.ColumnDefinitions.Clear(); $g.RowDefinitions.Clear()
    $r1 = New-Object Windows.Controls.RowDefinition; $r1.Height = [Windows.GridLength]::Auto; $g.RowDefinitions.Add($r1)
    $r2 = New-Object Windows.Controls.RowDefinition; $r2.Height = [Windows.GridLength]::Auto; $g.RowDefinitions.Add($r2)
    $labels = @('Conta', 'Dispositivos', 'Alexa', 'TV', 'Teste')
    for ($i = 0; $i -lt 5; $i++) {
        New-Column $g 18
        $col = $g.ColumnDefinitions.Count - 1
        $n = $i + 1
        $dot = New-Object Windows.Controls.Border
        $dot.Width = 18; $dot.Height = 18; $dot.CornerRadius = 9
        if ($n -lt $Step) {
            $dot.Background = $Br.Accent
            $dot.Child = New-GlyphText 0xE73E 9 '#06121C'
        } elseif ($n -eq $Step) {
            $dot.BorderBrush = $Br.Accent; $dot.BorderThickness = 2
            $in = New-Object Windows.Shapes.Ellipse; $in.Width = 6; $in.Height = 6; $in.Fill = $Br.Accent
            $dot.Child = $in
        } else { $dot.BorderBrush = $Br.InputLine; $dot.BorderThickness = 2 }
        [Windows.Controls.Grid]::SetColumn($dot, $col)
        [void]$g.Children.Add($dot)
        $color = $(if ($n -eq $Step) { '#E8ECF1' } elseif ($n -lt $Step) { '#9AA4B2' } else { '#6B7584' })
        $lb = New-Text $labels[$i] 12 $color $(if ($n -eq $Step) { 'SemiBold' } else { 'Normal' })
        $lb.TextWrapping = 'NoWrap'; $lb.TextAlignment = 'Center'; $lb.Margin = '-44,7,-44,0'
        [Windows.Controls.Grid]::SetColumn($lb, $col); [Windows.Controls.Grid]::SetRow($lb, 1)
        [void]$g.Children.Add($lb)
        if ($i -lt 4) {
            New-Column $g 78
            $line = New-Object Windows.Shapes.Rectangle
            $line.Height = 2; $line.RadiusX = 1; $line.RadiusY = 1; $line.Margin = '8,0,8,0'; $line.VerticalAlignment = 'Center'
            $line.Fill = $(if ($n -lt $Step) { $Br.Accent } else { $Br.InputLine })
            [Windows.Controls.Grid]::SetColumn($line, $g.ColumnDefinitions.Count - 1)
            [void]$g.Children.Add($line)
        }
    }
}

function Get-ResumeStep {
    $c = $App.Data.Cfg
    if (-not ([string]$c.sinric.appKey -match $RxKey) -or -not $App.Data.HasSecret) { return 1 }
    foreach ($d in $Devices) { if (-not ([string]$c.sinric.devices.($d.Role) -match $RxId)) { return 2 } }
    if (-not $c.gameMode.tvPath -and -not $c.gameMode.tvName) { if (-not $App.Data.Wizard.alexa) { return 3 }; return 4 }
    return 0
}

function Show-Step([int]$Step) {
    $App.Mode = 'wizard'; $App.Step = $Step; $App.W = @{}
    $App.StepOpenedAt = [DateTimeOffset]::Now
    $Ctl.PanelView.Visibility = 'Collapsed'; $Ctl.WizardView.Visibility = 'Visible'; $Ctl.DoneView.Visibility = 'Collapsed'
    $Ctl.WizBody.Visibility = 'Visible'; $Ctl.WizFooter.Visibility = 'Visible'; $Ctl.WizHeader.Visibility = 'Visible'
    Update-Stepper $Step
    $Ctl.WizStepText.Text = 'Passo ' + $Step + ' de 5'
    $Ctl.WizTitle.Text = $StepTitles[$Step]
    foreach ($i in 1..5) { $Ctl[('W' + $i + 'Bench')].Visibility = $(if ($i -eq $Step) { 'Visible' } else { 'Collapsed' }) }
    $Ctl.WizBenchScroll.ScrollToTop()
    $Ctl.WizBack.Visibility = $(if ($Step -gt 1) { 'Visible' } else { 'Collapsed' })
    $Ctl.WizSkip.Visibility = 'Collapsed'
    if (-not $Demo) { $App.Data.Cfg = Read-ApcConfig $ConfigPath; $App.Data.HasSecret = [bool](Get-ApcSecret $App.Data.Cfg) }
    $App.Loading = $true
    switch ($Step) { 1 { Enter-Step1 } 2 { Enter-Step2 } 3 { Enter-Step3 } 4 { Enter-Step4 } 5 { Enter-Step5 } }
    $App.Loading = $false
    switch ($Step) { 1 { Update-Step1 } 2 { Update-Step2 } 4 { Update-Step4 } }
    Update-WizardNext
}

function Update-WizardNext {
    if ($App.Mode -ne 'wizard') { return }
    $next = $Ctl.WizNext
    switch ($App.Step) {
        1 { $next.Content = $(if ($App.W.Connected) { 'Continuar' } else { 'Conectar' }); $next.IsEnabled = [bool]($App.W.Connected -or ($App.W.FieldsOk -and -not $App.W.Connecting)) }
        2 { $next.Content = 'Continuar'; $next.IsEnabled = [bool]$App.W.IdsOk }
        3 { $next.Content = 'Continuar'; $next.IsEnabled = [bool]$App.W.Ok }
        4 { $next.Content = 'Continuar'; $next.IsEnabled = [bool]($App.W.TestedOn -and $App.W.TestedOff) }
        5 { $next.Content = 'Concluir'; $next.IsEnabled = [bool]($App.W.C1 -and $App.W.C2) }
    }
}

# ---------------------------------------------------------------- step 1: account

function Enter-Step1 {
    Set-Guide 'Você vai dar ao PC a chave de acesso à sua conta do **Sinric Pro**, o serviço gratuito que liga a Alexa ao seu PC.' @(
        '{portal}',
        'Entre na sua conta (ou crie uma, é grátis).',
        'No menu da esquerda, clique em [[Credentials]].',
        'Copie o **App Key** e o **App Secret** e cole ao lado.'
    )
    $Ctl.W1Key.Text = [string]$App.Data.Cfg.sinric.appKey
    $Ctl.W1Secret.Password = ''
    if (-not $App.W1Lc) { $App.W1Lc = New-LiveCheck $Ctl.W1Lc }
    $App.W.Connected = $false; $App.W.Connecting = $false
    $view = Get-AgentView
    if ($App.Data.HasSecret -and $App.Data.Cfg.sinric.appKey -and $view.Key -eq 'conectado') {
        $App.W.Connected = $true
        Set-LiveCheck $App.W1Lc 'ok' 'Conectado! O seu PC já fala com o Sinric Pro.'
    } else {
        Set-LiveCheck $App.W1Lc 'idle' 'Aguardando você colar os dois códigos.' 'Depois clique em **Conectar**: eu confirmo aqui se deu certo.'
    }
}

function Update-Step1 {
    if ($App.Mode -ne 'wizard' -or $App.Step -ne 1) { return }
    $key = Test-KeyCode $Ctl.W1Key.Text
    Set-FieldState $Ctl.W1Key $Ctl.W1KeyMsg $key
    $typed = $Ctl.W1Secret.Password
    if ($typed) { $sec = Test-SecretCode $typed $Ctl.W1Key.Text; $Ctl.W1SecretPh.Text = '' }
    elseif ($App.Data.HasSecret) { $sec = @{ State = 'ok'; Msg = '' }; $Ctl.W1SecretPh.Text = '•••••••• salvo com segurança no Windows' }
    else { $sec = @{ State = ''; Msg = '' }; $Ctl.W1SecretPh.Text = 'Cole aqui o segredo' }
    Set-FieldState $Ctl.W1Secret $Ctl.W1SecretMsg $sec
    $App.W.FieldsOk = ($key.State -eq 'ok' -and $sec.State -eq 'ok')
    Update-WizardNext
}

function Invoke-Step1Connect {
    if ($Demo) { return }
    $cfg = Read-ApcConfig $ConfigPath
    $newKey = $Ctl.W1Key.Text
    $changed = ($cfg.sinric.appKey -ne $newKey) -or [bool]$Ctl.W1Secret.Password
    $cfg.sinric.appKey = $newKey
    if ($Ctl.W1Secret.Password) { Set-ApcSecret $cfg $Ctl.W1Secret.Password }
    Save-ApcConfig $cfg $ConfigPath
    $App.Data.Cfg = $cfg; $App.Data.HasSecret = $true
    $App.Loading = $true; $Ctl.W1Secret.Password = ''; $App.Loading = $false
    $App.W.Connecting = $true; $App.W.ConnectAt = [DateTimeOffset]::Now; $App.W.KeyChanged = $changed
    Set-LiveCheck $App.W1Lc 'wait' 'Conectando ao Sinric Pro…' 'Isso leva alguns segundos.'
    Update-Step1
}

function Watch-Step1 {
    if (-not $App.W.Connecting) { return }
    $view = Get-AgentView
    $s = $view.Status
    $elapsed = ([DateTimeOffset]::Now - $App.W.ConnectAt).TotalSeconds
    if ($view.Key -eq 'parado') {
        Set-LiveCheck $App.W1Lc 'err' 'O agente não está rodando.' 'Ele é quem conversa com a Alexa. Clique em **Iniciar agente**.' @(@{ Text = 'Iniciar agente'; Do = 'restart' })
        return
    }
    $updated = Get-StatusTime $s 'updated'
    $fresh = $updated -and $updated -gt $App.W.ConnectAt
    if ($view.Key -eq 'conectado') {
        $since = Get-StatusTime $s 'since'
        if (-not $App.W.KeyChanged -or ($since -and $since -gt $App.W.ConnectAt)) {
            $App.W.Connecting = $false; $App.W.Connected = $true
            Set-LiveCheck $App.W1Lc 'ok' 'Conectado! O seu PC já fala com o Sinric Pro.'
            $App.W.AdvanceAt = (Get-Date).AddSeconds(1.2)
            Update-WizardNext
            return
        }
    }
    if ($view.Key -eq 'desconectado' -and $fresh) {
        $msg = [string]$s.message; $detail = [string]$s.detail
        if ($msg -match '(?i)chave') {
            Set-LiveCheck $App.W1Lc 'err' 'O Sinric recusou a chave ou o segredo.' 'Copie os dois de novo em [[Credentials]], sem espaço sobrando. Confira se não trocou um pelo outro.' @(@{ Text = 'Abrir o portal'; Do = 'portal' }) $detail
        } elseif ($msg -match '(?i)internet') {
            Set-LiveCheck $App.W1Lc 'err' 'Não consegui chegar ao Sinric.' 'Parece que o PC está sem internet. Conecte e tente de novo.' @(@{ Text = 'Tentar de novo'; Do = 'restart' }) $detail
        } else {
            Set-LiveCheck $App.W1Lc 'err' 'Não deu pra conectar.' 'Tente de novo. Se continuar, veja o log.' @(@{ Text = 'Tentar de novo'; Do = 'restart' }, @{ Text = 'Ver log'; Do = 'log' }) $detail
        }
        return
    }
    if ($App.W1Lc.Sig -match '^err') { return }
    if ($elapsed -gt 30) {
        Set-LiveCheck $App.W1Lc 'warn' 'Ainda não conectou.' 'Confira a internet e se a chave e o segredo estão certos. O agente continua tentando sozinho.' @(@{ Text = 'Tentar de novo'; Do = 'restart' }, @{ Text = 'Ver log'; Do = 'log' })
    } elseif ($elapsed -gt 15) {
        Set-LiveCheck $App.W1Lc 'wait' 'Está demorando mais que o normal…' 'Se passar de 30 segundos, eu mostro o que verificar.'
    }
}

# ---------------------------------------------------------------- step 2: devices

function Enter-Step2 {
    Set-Guide 'Cada dispositivo é um “botão” que a Alexa enxerga. O ID é o endereço dele.' @(
        '{portal}',
        'Vá em [[Devices]] › [[Add Device]].',
        'Crie um com o **nome** e o **tipo** de cada cartão ao lado.',
        'Copie o **Device ID** e cole no cartão. Repita pros 3.'
    ) 'Faça isto' 'Não achou o ID? Clique no dispositivo na lista de [[Devices]] e copie o **Device ID** (24 letras e números).' 
    $Ctl.W2Devices.Children.Clear()
    $App.WizIds = @{ Rows = @() }
    foreach ($d in $Devices) {
        $row = New-DeviceRow $d 'wizard'
        $card = New-Object Windows.Controls.Border
        $card.Style = Get-Style 'Card'; $card.Padding = '14,11,14,12'; $card.Margin = '0,0,0,8'; $card.CornerRadius = 10
        $card.Child = $row.Grid
        [void]$Ctl.W2Devices.Children.Add($card)
        $row.Box.Text = [string]$App.Data.Cfg.sinric.devices.($d.Role)
        $App.WizIds.Rows += $row
    }
    if (-not $App.W2Lc) { $App.W2Lc = New-LiveCheck $Ctl.W2Lc }
}

function Update-Step2 {
    if ($App.Mode -ne 'wizard' -or $App.Step -ne 2 -or -not $App.WizIds.Rows) { return }
    $valid = Test-IdRows $App.WizIds.Rows
    $missing = @($App.WizIds.Rows | Where-Object { $_.Box.Uid -ne 'ok' } | ForEach-Object { $_.Name })
    $App.W.IdsOk = ($valid -eq 3)
    if ($App.W.IdsOk) {
        Set-LiveCheck $App.W2Lc 'ok' 'Os 3 IDs estão no formato certo.' 'Se eles são mesmo os seus dispositivos, a Alexa confirma no próximo passo.'
    } else {
        $title = $(if ($missing.Count -eq 1) { 'Falta 1 ID: **' + $missing[0] + '**.' } else { 'Faltam ' + $missing.Count + ' IDs: **' + ($missing -join '**, **') + '**.' })
        Set-LiveCheck $App.W2Lc 'idle' $title 'Cada cartão fica verde quando o ID estiver certo.'
    }
    Update-WizardNext
}

function Save-Step2 {
    if ($Demo) { return }
    $cfg = Read-ApcConfig $ConfigPath
    foreach ($r in $App.WizIds.Rows) { $cfg.sinric.devices.($r.Role) = $r.Box.Text }
    Save-ApcConfig $cfg $ConfigPath
    $App.Data.Cfg = $cfg
}

# ---------------------------------------------------------------- step 3: Alexa

function Enter-Step3 {
    Set-Guide 'Ativa o Sinric Pro na sua Alexa e faz ela encontrar os 3 dispositivos.' @(
        'Abra o app da **Alexa** no celular.',
        'Toque em [[Mais]] › [[Skills e jogos]], procure **Sinric Pro** e toque em [[Ativar]]. Entre com a mesma conta do portal.',
        'Diga: **“Alexa, descobrir dispositivos”** e espere uns 45 segundos.',
        'Agora fale o comando que aparece ao lado.'
    ) 'Faça isto (no celular)'
    if (-not $App.W3Lc) { $App.W3Lc = New-LiveCheck $Ctl.W3Lc }
    $App.W.Ok = $false; $App.W.StuckOpened = $false; $App.W.SeenAt = $null
    $Ctl.W3Stuck.IsExpanded = $false
    $list = $Ctl.W3StuckList; $list.Children.Clear()
    $items = @(
        'A skill **Sinric Pro** está **ativada** no app da Alexa e você entrou com a **mesma conta** do portal.',
        'Você disse **“Alexa, descobrir dispositivos”** e esperou uns 45 segundos.',
        'O nome do dispositivo no portal é exatamente **Computador** (tipo **TV**). Se a Alexa disser “não encontrei”, apague o dispositivo no app da Alexa e descubra de novo.',
        'A Alexa respondeu “o computador não está respondendo”? Então o agente está parado ou sem internet: olhe o indicador aqui embaixo.'
    )
    foreach ($it in $items) {
        $g = New-Object Windows.Controls.Grid; $g.Margin = '0,0,0,10'
        New-Column $g 22; New-Column $g '*'
        $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 5; $dot.Height = 5; $dot.Fill = $Br.Text3; $dot.VerticalAlignment = 'Top'; $dot.Margin = '2,8,0,0'; $dot.HorizontalAlignment = 'Left'
        $tx = New-Text '' 13 '#9AA4B2'; $tx.LineHeight = 20; Set-Rich $tx $it; [Windows.Controls.Grid]::SetColumn($tx, 1)
        [void]$g.Children.Add($dot); [void]$g.Children.Add($tx)
        [void]$list.Children.Add($g)
    }
    Set-LiveCheck $App.W3Lc 'wait' 'Esperando você falar…' 'Diga: **“Alexa, aumenta o volume do computador”**.'
}

function Get-NewCommand {
    $cmd = Get-LastCommand (Read-AgentStatus)
    if (-not $cmd -or -not $cmd.At -or $cmd.At -le $App.StepOpenedAt) { return $null }
    if ($App.W.SeenAt -and $cmd.At -le $App.W.SeenAt) { return $null }
    $App.W.SeenAt = $cmd.At
    return $cmd
}

function Watch-Step3 {
    if ($App.W.Ok) { return }
    $elapsed = ([DateTimeOffset]::Now - $App.StepOpenedAt).TotalSeconds
    if ($elapsed -gt 45) { $Ctl.WizSkip.Visibility = 'Visible' }
    $view = Get-AgentView
    if ($view.Key -eq 'parado') {
        Set-LiveCheck $App.W3Lc 'err' 'O agente não está rodando.' 'Ele é quem recebe os comandos da Alexa.' @(@{ Text = 'Iniciar agente'; Do = 'restart' })
        return
    }
    $s = $view.Status
    $updated = Get-StatusTime $s 'updated'
    if ($s -and $s.warning -and $updated -and $updated -gt $App.StepOpenedAt) {
        Set-LiveCheck $App.W3Lc 'err' 'A Alexa chegou, mas o segredo do app não bateu.' 'Volte ao passo 1 e cole o **App Secret** de novo, inteiro.' @(@{ Text = 'Voltar ao passo 1'; Do = 'step1' })
        return
    }
    $cmd = Get-NewCommand
    if ($cmd) {
        if ($cmd.Role -eq 'computer' -and $cmd.Ok) {
            $App.W.Ok = $true; $App.Data.Wizard.alexa = $true; Save-WizardState
            Set-LiveCheck $App.W3Lc 'ok' 'Ouvi a Alexa! Ela já controla o seu computador.' 'O volume mudou. Isso confirma a skill ativada e os dispositivos encontrados.'
            $App.W.AdvanceAt = (Get-Date).AddSeconds(1.6)
        } elseif ($cmd.Role -eq 'computer') {
            Set-LiveCheck $App.W3Lc 'err' 'A Alexa chegou, mas o PC não conseguiu fazer.' 'Veja o log pra saber o motivo.' @(@{ Text = 'Ver log'; Do = 'log' })
        } else {
            Set-LiveCheck $App.W3Lc 'warn' ('Ouvi a Alexa, mas era o **' + $RoleName[$cmd.Role] + '**.') 'Tudo certo com ele. Agora diga **“Alexa, aumenta o volume do computador”** pra confirmar o Computador.'
        }
        Update-WizardNext
        return
    }
    if ($elapsed -gt 20 -and -not $App.W.StuckOpened) {
        $App.W.StuckOpened = $true; $Ctl.W3Stuck.IsExpanded = $true
        Set-LiveCheck $App.W3Lc 'wait' 'Ainda não ouvi nada.' 'Isso é normal se a Alexa ainda está procurando os dispositivos. Veja a lista abaixo.'
    }
}

# ---------------------------------------------------------------- step 4: TV

function Enter-Step4 {
    Set-Guide 'O Modo Jogo precisa saber qual tela é a TV, pra levar o jogo até ela.' @(
        'Ligue a TV no PC (cabo HDMI) e deixe ela ligada, na entrada do PC.',
        'Clique em **Identificar telas**: aparece um número grande em cada tela ligada.',
        'Escolha o cartão da TV.',
        'Clique em **Testar ligar** e depois em **Testar desligar**.'
    )
    Update-Monitors
    if (-not $App.W4Lc) { $App.W4Lc = New-LiveCheck $Ctl.W4Lc }
    $cfg = $App.Data.Cfg
    $App.W.TestedOn = $false; $App.W.TestedOff = $false
    $App.W.TvPath = [string]$cfg.gameMode.tvPath; $App.W.TvName = [string]$cfg.gameMode.tvName
    $suggested = Get-SuggestedTv $App.Data.Monitors
    if (-not $App.W.TvPath -and $suggested) {
        $m = @($App.Data.Monitors) | Where-Object { $_.DevicePath -eq $suggested } | Select-Object -First 1
        $App.W.TvPath = [string]$m.DevicePath; $App.W.TvName = [string]$m.Name
    }
    Build-ScreenCards $Ctl.W4Screens 'wiz' $App.W.TvPath $suggested $App.W.TvName
}

function Update-Step4 {
    if ($App.Mode -ne 'wizard' -or $App.Step -ne 4) { return }
    $count = @($App.Data.Monitors).Count
    $busy = [bool]$App.Test
    $Ctl.W4TestOn.IsEnabled = [bool]($App.W.TvPath -and -not $busy)
    $Ctl.W4TestOff.IsEnabled = [bool]($App.W.TvPath -and -not $busy)
    if (-not $busy -and -not $App.W.TestedOn -and $App.W4Lc.Sig -notmatch '^(warn|err)') {
        if ($count -le 1 -and -not $App.W.TvPath) {
            Set-LiveCheck $App.W4Lc 'warn' 'Só encontrei uma tela.' 'Ligue a TV no PC (cabo HDMI) e clique em **Atualizar**.'
        } elseif (-not $App.W.TvPath) {
            Set-LiveCheck $App.W4Lc 'idle' 'Escolha a tela da TV.'
        } else {
            Set-LiveCheck $App.W4Lc 'idle' ('Tela escolhida: **' + $App.W.TvName + '**.') 'Clique em **Testar ligar** pra ver se funciona.'
        }
    }
    Update-WizardNext
}

function Save-Step4 {
    if ($Demo -or -not $App.W.TvPath) { return }
    $cfg = Read-ApcConfig $ConfigPath
    if ($cfg.gameMode.tvPath -ne $App.W.TvPath) { $cfg.gameMode.tvPath = $App.W.TvPath; $cfg.gameMode.tvName = $App.W.TvName; Save-ApcConfig $cfg $ConfigPath }
    $App.Data.Cfg = $cfg
}

# ---------------------------------------------------------------- step 5: voice test

$VoiceChecks = @(
    @{ Key = 'C1'; Say = '“Alexa, liga o modo jogo”'; Role = 'gameMode'; State = 'On'; Done = 'Funcionou! A TV virou a tela principal e o Steam abriu.' }
    @{ Key = 'C2'; Say = '“Alexa, desliga o modo jogo”'; Role = 'gameMode'; State = 'Off'; Done = 'Funcionou! Tudo voltou como estava.' }
    @{ Key = 'C3'; Say = '“Alexa, liga o modo invisível”'; Role = 'invisibleMode'; State = ''; Done = 'Funcionou! O Modo Invisível respondeu.' }
)

function Get-VoiceTitle([int]$Index) {
    if ($Index -eq 2) { return $VoiceChecks[$Index].Say + '  · opcional' }
    return $VoiceChecks[$Index].Say
}

function Enter-Step5 {
    Set-Guide 'Mostra que o caminho todo funciona: você fala, a Alexa avisa o PC e o PC faz.' @(
        'Fique perto do PC e da TV.',
        'Diga os comandos ao lado, **na ordem**.',
        'Cada um fica verde quando o PC ouvir. O terceiro é opcional.'
    )
    if (-not $App.W5Lcs) { $App.W5Lcs = @((New-LiveCheck $Ctl.W5Lc1), (New-LiveCheck $Ctl.W5Lc2), (New-LiveCheck $Ctl.W5Lc3)) }
    $App.W.SeenAt = $null; $App.W.C1 = $false; $App.W.C2 = $false; $App.W.C3 = $false
    for ($i = 0; $i -lt 3; $i++) {
        if ($i -eq 0) { Set-LiveCheck $App.W5Lcs[$i] 'wait' (Get-VoiceTitle $i) 'Esperando você falar…' }
        else { Set-LiveCheck $App.W5Lcs[$i] 'idle' (Get-VoiceTitle $i) 'Depois do anterior.' }
    }
}

function Watch-Step5 {
    $elapsed = ([DateTimeOffset]::Now - $App.StepOpenedAt).TotalSeconds
    if ($elapsed -gt 45 -and -not ($App.W.C1 -and $App.W.C2)) { $Ctl.WizSkip.Visibility = 'Visible' }
    $expect = -1
    for ($i = 0; $i -lt 3; $i++) { if (-not $App.W[$VoiceChecks[$i].Key]) { $expect = $i; break } }
    $cmd = Get-NewCommand
    if ($cmd) {
        $hit = -1
        for ($i = 0; $i -lt 3; $i++) {
            $vc = $VoiceChecks[$i]
            if ($cmd.Role -ne $vc.Role) { continue }
            if ($vc.State -and (-not $cmd.Value -or $cmd.Value.state -ne $vc.State)) { continue }
            $hit = $i; break
        }
        if ($hit -ge 0) {
            $vc = $VoiceChecks[$hit]
            if ($cmd.Ok) {
                $App.W[$vc.Key] = $true
                Set-LiveCheck $App.W5Lcs[$hit] 'ok' (Get-VoiceTitle $hit) $vc.Done
                if ($hit -eq 2) { $App.Data.Wizard.invisible = $true; Save-WizardState }
            } else {
                Set-LiveCheck $App.W5Lcs[$hit] 'err' (Get-VoiceTitle $hit) 'A Alexa chegou, mas o PC não conseguiu. Veja o log.' @(@{ Text = 'Ver log'; Do = 'log' }, @{ Text = 'Testar pelo botão'; Do = 'step4' })
            }
        } elseif ($expect -ge 0) {
            Set-LiveCheck $App.W5Lcs[$expect] 'warn' (Get-VoiceTitle $expect) ('Ouvi **' + (Format-Command $cmd) + '**, mas eu estava esperando este. Sem problema: diga o comando acima.')
        }
        $next = -1
        for ($i = 0; $i -lt 3; $i++) { if (-not $App.W[$VoiceChecks[$i].Key]) { $next = $i; break } }
        if ($next -ge 0 -and $next -ne $expect) { Set-LiveCheck $App.W5Lcs[$next] 'wait' (Get-VoiceTitle $next) 'Esperando você falar…' }
        Update-WizardNext
        return
    }
    if ($expect -ge 0 -and $elapsed -gt 20 -and $App.W5Lcs[$expect].Sig -match '^wait') {
        Set-LiveCheck $App.W5Lcs[$expect] 'wait' (Get-VoiceTitle $expect) 'Ainda não ouvi esse comando. Fale com calma, com o nome exatamente assim. Se a Alexa disser “não encontrei”, volte ao passo 3.'
    }
}

# ---------------------------------------------------------------- done

function Show-Done {
    $App.Mode = 'done'
    $App.Data.Wizard.done = $true; Save-WizardState
    $Ctl.WizBody.Visibility = 'Collapsed'; $Ctl.WizFooter.Visibility = 'Collapsed'; $Ctl.WizHeader.Visibility = 'Collapsed'
    $Ctl.DoneView.Visibility = 'Visible'
    $list = $Ctl.DoneList; $list.Children.Clear()
    $w = $App.Data.Wizard
    $rows = @(
        @{ Ok = $true; Text = 'Conta do Sinric Pro conectada' }
        @{ Ok = $true; Text = 'Os 3 dispositivos configurados' }
        @{ Ok = [bool]$w.alexa; Text = $(if ($w.alexa) { 'A Alexa já controla o computador' } else { 'A Alexa ainda não foi testada' }) }
        @{ Ok = [bool]$w.tv; Text = $(if ($w.tv) { 'Modo Jogo testado na TV' } else { 'O Modo Jogo ainda não foi testado' }) }
    )
    $i = 0
    foreach ($r in $rows) {
        $i++
        $g = New-Object Windows.Controls.Grid; $g.Height = 46
        New-Column $g 34; New-Column $g '*'
        $badge = New-Object Windows.Controls.Border; $badge.Width = 20; $badge.Height = 20; $badge.CornerRadius = 10; $badge.HorizontalAlignment = 'Left'
        $badge.Background = $(if ($r.Ok) { $Br.Ok } else { $Br.Warn })
        if ($r.Ok) { $badge.Child = New-GlyphText 0xE73E 9 '#0F1319' }
        else { $x = New-Text '!' 12 '#0F1319' 'Bold'; $x.HorizontalAlignment = 'Center'; $x.VerticalAlignment = 'Center'; $badge.Child = $x }
        $tx = New-Text $r.Text 14 $(if ($r.Ok) { '#E8ECF1' } else { '#9AA4B2' }); $tx.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($tx, 1)
        [void]$g.Children.Add($badge); [void]$g.Children.Add($tx)
        [void]$list.Children.Add($g)
        if ($i -lt $rows.Count) { $d = New-Object Windows.Shapes.Rectangle; $d.Style = Get-Style 'Divider'; [void]$list.Children.Add($d) }
    }
}

# ---------------------------------------------------------------- assistant navigation

function Invoke-WizardNext {
    switch ($App.Step) {
        1 { if ($App.W.Connected) { Show-Step 2 } else { Invoke-Step1Connect } }
        2 { Save-Step2; Show-Step 3 }
        3 { Show-Step 4 }
        4 { Save-Step4; Show-Step 5 }
        5 { Show-Done }
    }
}

function Invoke-WizardSkip {
    switch ($App.Step) {
        3 { Show-Step 4 }
        4 { if (-not $App.W.TvPath) { Show-Toast 'Escolha a tela da TV antes de pular.' 'info'; return }; Save-Step4; Show-Step 5 }
        5 { Show-Done }
    }
}

# ====================================================================== panel

function Set-Dirty([bool]$Value) {
    if ($App.Loading -or $App.Mode -ne 'panel') { return }
    $App.Dirty = $Value
    $Ctl.SaveBar.Visibility = $(if ($Value) { 'Visible' } else { 'Collapsed' })
}

function Show-Panel([string]$Page = 'home') {
    $App.Mode = 'panel'
    $Ctl.WizardView.Visibility = 'Collapsed'; $Ctl.PanelView.Visibility = 'Visible'
    if (-not $App.Dirty) {
        if (-not $Demo) { $App.Data.Cfg = Read-ApcConfig $ConfigPath; $App.Data.HasSecret = [bool](Get-ApcSecret $App.Data.Cfg); $App.Data.Wizard = Read-WizardState }
        $App.Cfg = $App.Data.Cfg
        Update-Monitors
        Load-PanelForms
    }
    $App.TodoSig = $null
    Select-Page $Page
}

function Select-Page([string]$Page) {
    $App.Page = $Page
    $map = @{ home = 'PgHome'; gamemode = 'PgGame'; computer = 'PgComputer'; games = 'PgGames'; connection = 'PgConn' }
    $nav = @{ home = 'NavHome'; gamemode = 'NavGame'; computer = 'NavComputer'; games = 'NavGames'; connection = 'NavConn' }
    foreach ($k in $map.Keys) { $Ctl[$map[$k]].Visibility = $(if ($k -eq $Page) { 'Visible' } else { 'Collapsed' }) }
    $was = $App.Loading; $App.Loading = $true; $Ctl[$nav[$Page]].IsChecked = $true; $App.Loading = $was
    $Ctl.PageScroll.ScrollToTop()
    if ($Page -eq 'home') { Update-Home }
}

function Load-PanelForms {
    $App.Loading = $true
    $c = $App.Cfg
    # game mode
    Build-ScreenCards $Ctl.PgScreens 'pg' ([string]$c.gameMode.tvPath) '' ([string]$c.gameMode.tvName)
    $Ctl.CkPrimary.IsChecked = [bool]$c.gameMode.tvPrimary
    $Ctl.CkBigPicture.IsChecked = [bool]$c.gameMode.bigPicture
    $Ctl.CkCloseGame.IsChecked = [bool]$c.gameMode.closeGameOnOff
    Fill-AudioCombo $Ctl.CbTvAudio ([string]$c.gameMode.audioName) 'Automático (o som sai pela TV)'
    # computer
    $Ctl.RbSleep.IsChecked = ($c.computer.powerOff -ne 'hibernate' -and $c.computer.powerOff -ne 'shutdown')
    $Ctl.RbHibernate.IsChecked = ($c.computer.powerOff -eq 'hibernate')
    $Ctl.RbShutdown.IsChecked = ($c.computer.powerOff -eq 'shutdown')
    $Ctl.TbVolStep.Text = [string]$c.computer.volumeStep
    $Ctl.InputRows.Children.Clear(); $App.InputRowsList = New-Object System.Collections.ArrayList
    foreach ($m in @($c.computer.inputs)) { if ($m) { Add-InputRow ([string]$m.input) ([string]$m.audioName) } }
    # games
    $Ctl.GameRows.Children.Clear(); $App.GameRowsList = New-Object System.Collections.ArrayList
    foreach ($ch in @($c.channels | Where-Object { $_ } | Sort-Object { [int]$_.number })) { [void](Add-GameRow ([string]$ch.appId) ([string]$ch.name) (@($ch.aliases) -join ', ')) }
    Update-GamesEmpty
    # connection
    $Ctl.PKey.Text = [string]$c.sinric.appKey
    $Ctl.PSecret.Password = ''
    $Ctl.PDevices.Children.Clear(); $App.PanelIds = @{ Rows = @() }
    $i = 0
    foreach ($d in $Devices) {
        $i++
        $row = New-DeviceRow $d 'panel'
        $row.Grid.Margin = '0,14,0,14'
        $row.Box.Text = [string]$c.sinric.devices.($d.Role)
        [void]$Ctl.PDevices.Children.Add($row.Grid)
        if ($i -lt 3) { $div = New-Object Windows.Shapes.Rectangle; $div.Style = Get-Style 'Divider'; [void]$Ctl.PDevices.Children.Add($div) }
        $App.PanelIds.Rows += $row
    }
    [void](Update-PanelKey); [void](Update-PanelIds)
    $App.Loading = $false
    Update-NavDots
}

function Fill-AudioCombo($Combo, [string]$Selected, [string]$AutoText) {
    $Combo.Items.Clear()
    $auto = New-Object Windows.Controls.ComboBoxItem; $auto.Content = $AutoText; $auto.Tag = ''
    [void]$Combo.Items.Add($auto)
    $found = $false
    foreach ($a in @($App.Data.Audio)) {
        $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = [string]$a.Name; $it.Tag = [string]$a.Name
        [void]$Combo.Items.Add($it)
        if ($a.Name -eq $Selected) { $Combo.SelectedItem = $it; $found = $true }
    }
    if ($Selected -and -not $found) {
        $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $Selected + '  ·  não encontrada agora'; $it.Tag = $Selected
        [void]$Combo.Items.Add($it); $Combo.SelectedItem = $it
    }
    if (-not $Selected) { $Combo.SelectedIndex = 0 }
}

function Add-InputRow([string]$InputName, [string]$AudioName) {
    $g = New-Object Windows.Controls.Grid; $g.Margin = '0,0,0,10'
    New-Column $g 160; New-Column $g 34; New-Column $g '*'; New-Column $g 44
    $cbIn = New-Object Windows.Controls.ComboBox; $cbIn.Style = Get-Style 'Combo'; $cbIn.IsEditable = $true
    foreach ($n in $AlexaInputs) { [void]$cbIn.Items.Add($n) }
    $cbIn.Text = $InputName
    $arrow = New-GlyphText 0xE72A 12 '#6B7584'; [Windows.Controls.Grid]::SetColumn($arrow, 1)
    $cbOut = New-Object Windows.Controls.ComboBox; $cbOut.Style = Get-Style 'Combo'; [Windows.Controls.Grid]::SetColumn($cbOut, 2)
    $autoText = $(if ($InputName -eq 'TV') { 'Automático (som da TV)' } else { 'Escolha uma saída' })
    Fill-AudioCombo $cbOut $AudioName $autoText
    $del = New-Object Windows.Controls.Button; $del.Style = Get-Style 'IconBtn'; $del.Content = Glyph 0xE711; $del.HorizontalAlignment = 'Right'
    [Windows.Controls.Grid]::SetColumn($del, 3)
    [void]$g.Children.Add($cbIn); [void]$g.Children.Add($arrow); [void]$g.Children.Add($cbOut); [void]$g.Children.Add($del)
    $row = @{ Grid = $g; In = $cbIn; Out = $cbOut }
    $del.Tag = $row
    $del.Add_Click({ $r = $this.Tag; $Ctl.InputRows.Children.Remove($r.Grid); $App.InputRowsList.Remove($r); Set-Dirty $true })
    $cbIn.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [Windows.Controls.TextChangedEventHandler]{ Set-Dirty $true })
    $cbOut.Add_SelectionChanged({ Set-Dirty $true })
    [void]$Ctl.InputRows.Children.Add($g)
    [void]$App.InputRowsList.Add($row)
}

function Add-GameRow([string]$AppId, [string]$Name, [string]$Aliases) {
    $g = New-Object Windows.Controls.Grid; $g.Margin = '0,10,0,10'
    New-Column $g 44; New-Column $g '*'; New-Column $g 12; New-Column $g 210; New-Column $g 46
    $badge = New-Object Windows.Controls.Border; $badge.Width = 30; $badge.Height = 30; $badge.CornerRadius = 15; $badge.Background = Brush '#1F38BDF8'
    $badge.HorizontalAlignment = 'Left'
    $num = New-Text '' 13 '#38BDF8' 'SemiBold'; $num.HorizontalAlignment = 'Center'; $num.VerticalAlignment = 'Center'; $num.Margin = '0,0,0,1'
    $badge.Child = $num
    $cb = New-Object Windows.Controls.ComboBox; $cb.Style = Get-Style 'Combo'; $cb.Tag = 'Escolha um jogo'
    [Windows.Controls.Grid]::SetColumn($cb, 1)
    $found = $false
    foreach ($gm in @($App.Data.Games)) {
        $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = [string]$gm.Name; $it.Tag = $gm
        [void]$cb.Items.Add($it)
        if ($AppId -and [string]$gm.AppId -eq $AppId) { $cb.SelectedItem = $it; $found = $true }
    }
    if ($AppId -and -not $found) {
        $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $Name + '  ·  não instalado'; $it.Tag = [pscustomobject]@{ Name = $Name; AppId = $AppId }
        [void]$cb.Items.Add($it); $cb.SelectedItem = $it
    }
    $tb = New-Object Windows.Controls.TextBox; $tb.Style = Get-Style 'Input'; $tb.Tag = 'Apelidos, ex.: hades, hadinho'; $tb.Padding = '12,0'
    $tb.Text = $Aliases; [Windows.Controls.Grid]::SetColumn($tb, 3)
    $del = New-Object Windows.Controls.Button; $del.Style = Get-Style 'IconBtn'; $del.Content = Glyph 0xE711; $del.HorizontalAlignment = 'Right'
    [Windows.Controls.Grid]::SetColumn($del, 4)
    foreach ($el in @($badge, $cb, $tb, $del)) { [void]$g.Children.Add($el) }
    $row = @{ Grid = $g; Num = $num; Game = $cb; Aliases = $tb; Divider = $null }
    $del.Tag = $row
    $del.Add_Click({ Remove-GameRow $this.Tag })
    $cb.Add_SelectionChanged({ Set-Dirty $true })
    $tb.Add_TextChanged({ Set-Dirty $true })
    if ($App.GameRowsList.Count -gt 0) {
        $d = New-Object Windows.Shapes.Rectangle; $d.Style = Get-Style 'Divider'; $row.Divider = $d
        [void]$Ctl.GameRows.Children.Add($d)
    }
    [void]$Ctl.GameRows.Children.Add($g)
    [void]$App.GameRowsList.Add($row)
    Update-GameNumbers
    return $row
}

function Remove-GameRow($Row) {
    $Ctl.GameRows.Children.Remove($Row.Grid)
    if ($Row.Divider) { $Ctl.GameRows.Children.Remove($Row.Divider) }
    $App.GameRowsList.Remove($Row)
    if ($App.GameRowsList.Count -gt 0 -and $App.GameRowsList[0].Divider) { $Ctl.GameRows.Children.Remove($App.GameRowsList[0].Divider); $App.GameRowsList[0].Divider = $null }
    Update-GameNumbers; Update-GamesEmpty; Set-Dirty $true
}

function Update-GameNumbers { $i = 0; foreach ($r in $App.GameRowsList) { $i++; $r.Num.Text = [string]$i } }

function Update-GamesEmpty {
    $has = $App.GameRowsList -and $App.GameRowsList.Count -gt 0
    $Ctl.GamesCard.Visibility = $(if ($has) { 'Visible' } else { 'Collapsed' })
    $Ctl.GamesFooter.Visibility = $(if ($has) { 'Visible' } else { 'Collapsed' })
    $Ctl.GamesEmpty.Visibility = $(if ($has) { 'Collapsed' } else { 'Visible' })
}

function Update-PanelKey {
    $key = Test-KeyCode $Ctl.PKey.Text
    Set-FieldState $Ctl.PKey $Ctl.PKeyMsg $key
    $typed = $Ctl.PSecret.Password
    if ($typed) { $sec = Test-SecretCode $typed $Ctl.PKey.Text; $Ctl.PSecretPh.Text = '' }
    elseif ($App.Data.HasSecret) { $sec = @{ State = 'ok'; Msg = '' }; $Ctl.PSecretPh.Text = '•••••••• salvo com segurança no Windows. Digite só pra trocar.' }
    else { $sec = @{ State = ''; Msg = '' }; $Ctl.PSecretPh.Text = 'Cole aqui o segredo' }
    Set-FieldState $Ctl.PSecret $Ctl.PSecretMsg $sec
    return ($key.State -ne 'err' -and $sec.State -ne 'err')
}

function Update-PanelIds { if ($App.PanelIds.Rows) { return ((Test-IdRows $App.PanelIds.Rows) -eq 3) }; return $false }

function Update-NavDots {
    $c = $App.Data.Cfg
    $connMissing = (-not $c.sinric.appKey) -or (-not $App.Data.HasSecret)
    foreach ($d in $Devices) { if (-not $c.sinric.devices.($d.Role)) { $connMissing = $true } }
    $Ctl.NavConnDot.Visibility = $(if ($connMissing) { 'Visible' } else { 'Collapsed' })
    $Ctl.NavGameDot.Visibility = $(if (-not $c.gameMode.tvPath -and -not $c.gameMode.tvName) { 'Visible' } else { 'Collapsed' })
}

function Collect-PanelForms {
    $c = $App.Cfg
    $c.gameMode.tvPrimary = [bool]$Ctl.CkPrimary.IsChecked
    $c.gameMode.bigPicture = [bool]$Ctl.CkBigPicture.IsChecked
    $c.gameMode.closeGameOnOff = [bool]$Ctl.CkCloseGame.IsChecked
    $c.gameMode.audioName = $(if ($Ctl.CbTvAudio.SelectedItem) { [string]$Ctl.CbTvAudio.SelectedItem.Tag } else { '' })
    $c.computer.powerOff = $(if ($Ctl.RbHibernate.IsChecked) { 'hibernate' } elseif ($Ctl.RbShutdown.IsChecked) { 'shutdown' } else { 'sleep' })
    $step = 0; if ([int]::TryParse($Ctl.TbVolStep.Text.Trim(), [ref]$step)) { $c.computer.volumeStep = [Math]::Max(1, [Math]::Min(50, $step)) }
    $c.computer.inputs = @($App.InputRowsList | Where-Object { $_.In.Text.Trim() } | ForEach-Object {
        [pscustomobject]@{ input = $_.In.Text.Trim(); audioName = $(if ($_.Out.SelectedItem) { [string]$_.Out.SelectedItem.Tag } else { '' }) } })
    $n = 0
    $c.channels = @($App.GameRowsList | Where-Object { $_.Game.SelectedItem } | ForEach-Object {
        $n++; $gm = $_.Game.SelectedItem.Tag
        [pscustomobject]@{ number = $n; name = [string]$gm.Name; appId = [string]$gm.AppId
                           aliases = @($_.Aliases.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } })
    $c.sinric.appKey = $Ctl.PKey.Text
    foreach ($r in $App.PanelIds.Rows) { $c.sinric.devices.($r.Role) = $r.Box.Text }
}

function Save-Panel([switch]$Quiet) {
    if ($Demo) { Set-Dirty $false; return $true }
    if (-not (Update-PanelKey)) { Select-Page 'connection'; Show-Toast 'Confira a chave e o segredo antes de salvar.' 'err'; return $false }
    if (@($App.PanelIds.Rows | Where-Object { $_.Box.Uid -eq 'err' }).Count) { Select-Page 'connection'; Show-Toast 'Tem um ID de dispositivo com problema. Confira em Conexão.' 'err'; return $false }
    Collect-PanelForms
    if ($Ctl.PSecret.Password) { Set-ApcSecret $App.Cfg $Ctl.PSecret.Password }
    try { Save-ApcConfig $App.Cfg $ConfigPath }
    catch { Show-Toast ('Não deu pra salvar: ' + $_.Exception.Message) 'err'; return $false }
    $App.Data.Cfg = $App.Cfg; $App.Data.HasSecret = [bool](Get-ApcSecret $App.Cfg)
    $App.Loading = $true; $Ctl.PSecret.Password = ''; $App.Loading = $false
    [void](Update-PanelKey); Update-NavDots
    $App.Dirty = $false; $Ctl.SaveBar.Visibility = 'Collapsed'; $App.TodoSig = $null
    if (-not $Quiet) {
        if ((Get-AgentView).Key -eq 'parado') { Show-Toast 'Salvo. Inicie o agente pra valer.' 'info' }
        else { Show-Toast 'Salvo. O agente já está usando as novas configurações.' }
    }
    return $true
}

function Undo-Panel {
    $App.Dirty = $false; $Ctl.SaveBar.Visibility = 'Collapsed'
    if (-not $Demo) { $App.Data.Cfg = Read-ApcConfig $ConfigPath }
    $App.Cfg = $App.Data.Cfg
    Load-PanelForms
}

# ---------------------------------------------------------------- home

$Phrases = @(
    @('Alexa, liga o modo jogo', 'TV, som e Big Picture'),
    @('Alexa, desliga o modo jogo', 'volta tudo como estava'),
    @('Alexa, aumenta o volume do computador', 'volume do Windows'),
    @('Alexa, muda o canal do computador para 2', 'abre o jogo do atalho 2'),
    @('Alexa, desliga o computador', 'suspende o PC'),
    @('Alexa, liga o modo invisível', 'invisível na Steam')
)

function Build-Phrases {
    $p = $Ctl.HomePhrases; $p.Children.Clear()
    $i = 0
    foreach ($ph in $Phrases) {
        $i++
        $g = New-Object Windows.Controls.Grid; $g.Height = 46
        New-Column $g 30; New-Column $g '*'; New-Column $g 'auto'
        $ic = New-GlyphText 0xE720 14 '#38BDF8'; $ic.HorizontalAlignment = 'Left'
        $tx = New-Text ('“' + $ph[0] + '”') 14 '#E8ECF1'; $tx.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($tx, 1)
        $ds = New-Text $ph[1] 13 '#6B7584'; $ds.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($ds, 2)
        [void]$g.Children.Add($ic); [void]$g.Children.Add($tx); [void]$g.Children.Add($ds)
        [void]$p.Children.Add($g)
        if ($i -lt $Phrases.Count) { $d = New-Object Windows.Shapes.Rectangle; $d.Style = Get-Style 'Divider'; [void]$p.Children.Add($d) }
    }
}

function Get-TodoItems {
    $c = $App.Data.Cfg; $w = $App.Data.Wizard
    $items = New-Object System.Collections.ArrayList
    if (-not $c.sinric.appKey -or -not $App.Data.HasSecret) { [void]$items.Add(@{ Text = 'Conectar a sua conta do Sinric Pro'; Btn = 'Continuar'; Step = 1 }) }
    elseif (@($Devices | Where-Object { -not $c.sinric.devices.($_.Role) }).Count) { [void]$items.Add(@{ Text = 'Colar os IDs dos 3 dispositivos'; Btn = 'Continuar'; Step = 2 }) }
    else {
        if (-not $w.alexa) { [void]$items.Add(@{ Text = 'A Alexa ainda não foi testada'; Btn = 'Testar agora'; Step = 3 }) }
        if (-not $c.gameMode.tvPath -and -not $c.gameMode.tvName) { [void]$items.Add(@{ Text = 'Escolher qual tela é a TV'; Btn = 'Escolher'; Step = 4 }) }
        elseif (-not $w.tv) { [void]$items.Add(@{ Text = 'O Modo Jogo ainda não foi testado na TV'; Btn = 'Testar agora'; Step = 4 }) }
        if (-not $w.invisible) { [void]$items.Add(@{ Text = 'O Modo Invisível ainda não foi testado'; Btn = 'Testar agora'; Step = 5 }) }
    }
    return , $items
}

function Update-Home {
    $view = Get-AgentView
    $Ctl.HomeDot.Fill = Brush $view.Color; $Ctl.HomeHalo.Fill = Brush $view.Color
    $Ctl.HomeHalo.Visibility = $(if ($view.Key -eq 'conectado') { 'Visible' } else { 'Hidden' })
    $Ctl.HomeState.Text = $view.Label
    $Ctl.HomeSub.Text = $view.Sub
    $cmd = Get-LastCommand $view.Status
    if ($cmd) {
        $ago = ''; if ($cmd.At) { $ago = '  ·  ' + (Format-Ago $cmd.At) }
        Set-Rich $Ctl.HomeLast ('Último comando: **' + (Format-Command $cmd) + '**' + $ago + $(if ($cmd.Ok) { '  ✓' } else { '  ·  falhou' }))
    } else { $Ctl.HomeLast.Text = 'Nenhum comando da Alexa ainda.' }
    $todo = Get-TodoItems
    $needSetup = @($todo | Where-Object { $_.Btn -ne 'Testar agora' }).Count -gt 0
    $b = $Ctl.HomeBtnB
    $b.Visibility = 'Visible'
    if ($view.Key -eq 'parado') { $b.Content = 'Iniciar'; $b.Tag = 'restart' }
    elseif ($needSetup) { $b.Content = 'Continuar configuração'; $b.Tag = 'setup' }
    elseif ($view.Key -eq 'desconectado') { $b.Content = 'Tentar de novo'; $b.Tag = 'restart' }
    else { $b.Visibility = 'Collapsed' }
    $warn = $(if ($view.Status -and $view.Status.warning) { [string]$view.Status.warning } else { '' })
    $Ctl.HomeWarn.Visibility = $(if ($warn) { 'Visible' } else { 'Collapsed' }); $Ctl.HomeWarnText.Text = $warn
    $sig = (@($todo | ForEach-Object { $_.Text }) -join '|')
    if ($App.TodoSig -ne $sig) {
        $App.TodoSig = $sig
        $list = $Ctl.HomeTodoList; $list.Children.Clear()
        $i = 0
        foreach ($t in $todo) {
            $i++
            $g = New-Object Windows.Controls.Grid; $g.Height = 56
            New-Column $g 28; New-Column $g '*'; New-Column $g 'auto'
            $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 8; $dot.Height = 8; $dot.Fill = $Br.Warn; $dot.HorizontalAlignment = 'Left'
            $tx = New-Text $t.Text 14 '#E8ECF1'; $tx.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($tx, 1)
            $bt = New-Object Windows.Controls.Button; $bt.Style = Get-Style 'Secondary'; $bt.Height = 32; $bt.FontSize = 13; $bt.Padding = '12,0'
            $bt.Content = $t.Btn; $bt.Tag = $t.Step; $bt.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($bt, 2)
            $bt.Add_Click({ Show-Step ([int]$this.Tag) })
            [void]$g.Children.Add($dot); [void]$g.Children.Add($tx); [void]$g.Children.Add($bt)
            [void]$list.Children.Add($g)
            if ($i -lt $todo.Count) { $d = New-Object Windows.Shapes.Rectangle; $d.Style = Get-Style 'Divider'; [void]$list.Children.Add($d) }
        }
        $Ctl.HomeTodo.Visibility = $(if ($todo.Count) { 'Visible' } else { 'Collapsed' })
    }
}

# ---------------------------------------------------------------- agent indicators (assistant footer, side menu)

function Update-AgentIndicators {
    $view = Get-AgentView
    $Ctl.WizAgentDot.Fill = Brush $view.Color; $Ctl.SideDot.Fill = Brush $view.Color
    $Ctl.WizAgentText.Text = $(if ($view.Key -eq 'parado') { 'Agente parado' } else { 'Agente: ' + $view.Label.ToLower() })
    $Ctl.SideState.Text = $view.Label
    $Ctl.SideState.Foreground = $(if ($view.Key -eq 'conectado') { $Br.Text } else { Brush $view.Color })
    if ($App.Mode -eq 'panel' -and $App.Page -eq 'home') { Update-Home }
}

function Watch-ConnTest {
    if (-not $App.ConnTestAt -or -not $App.ConnLcObj) { return }
    $view = Get-AgentView; $s = $view.Status
    $since = Get-StatusTime $s 'since'; $updated = Get-StatusTime $s 'updated'
    if ($view.Key -eq 'conectado' -and $since -and $since -gt $App.ConnTestAt) {
        Set-LiveCheck $App.ConnLcObj 'ok' 'Conexão funcionando.' 'O seu PC está falando com o Sinric Pro.'; $App.ConnTestAt = $null
    } elseif ($view.Key -eq 'desconectado' -and $updated -and $updated -gt $App.ConnTestAt) {
        Set-LiveCheck $App.ConnLcObj 'err' 'Não conectou.' ([string]$s.message) @(@{ Text = 'Ver log'; Do = 'log' }) ([string]$s.detail); $App.ConnTestAt = $null
    } elseif (([DateTimeOffset]::Now - $App.ConnTestAt).TotalSeconds -gt 30) {
        Set-LiveCheck $App.ConnLcObj 'warn' 'Ainda não conectou.' 'Confira a internet e a chave. O agente continua tentando sozinho.' @(@{ Text = 'Ver log'; Do = 'log' }); $App.ConnTestAt = $null
    }
}

# ====================================================================== events

$Ctl.TitleBar.Add_MouseLeftButtonDown({ try { $Window.DragMove() } catch { } })
$Ctl.BtnMin.Add_Click({ $Window.WindowState = 'Minimized' })
$Ctl.BtnClose.Add_Click({ $Window.Close() })
$Window.Add_Closing({
    param($sender, $e)
    if ($App.Closing -or -not $App.Dirty -or $App.Mode -ne 'panel') { return }
    $e.Cancel = $true
    $Ctl.Confirm.Visibility = 'Visible'
})
$Ctl.CfCancel.Add_Click({ $Ctl.Confirm.Visibility = 'Collapsed' })
$Ctl.CfDiscard.Add_Click({ $App.Closing = $true; $Window.Close() })
$Ctl.CfSave.Add_Click({ if (Save-Panel -Quiet) { $App.Closing = $true; $Window.Close() } else { $Ctl.Confirm.Visibility = 'Collapsed' } })

# assistant
$Ctl.WizNext.Add_Click({ Invoke-WizardNext })
$Ctl.WizBack.Add_Click({ if ($App.Step -gt 1) { Show-Step ($App.Step - 1) } })
$Ctl.WizSkip.Add_Click({ Invoke-WizardSkip })
$Ctl.DoneOpen.Add_Click({ Show-Panel 'home' })
$Ctl.W1Key.Add_TextChanged({ if (-not $App.Loading) { Set-CleanText $this; $App.W.Connected = $false; $App.W.Connecting = $false }; Update-Step1 })
$Ctl.W1Secret.Add_PasswordChanged({
    if (-not $App.Loading) {
        $clean = ConvertTo-CleanCode $this.Password
        if ($clean -ne $this.Password) { $this.Password = $clean }
        $App.W.Connected = $false; $App.W.Connecting = $false
    }
    Update-Step1
})
$Ctl.W1KeyPaste.Add_Click({ $Ctl.W1Key.Text = Get-ClipboardCode; $Ctl.W1Key.CaretIndex = $Ctl.W1Key.Text.Length })
$Ctl.W1SecretPaste.Add_Click({ $Ctl.W1Secret.Password = Get-ClipboardCode })
$Ctl.W4Identify.Add_Click({ Show-ScreenNumbers })
$Ctl.W4Refresh.Add_Click({
    Update-Monitors
    $App.Loading = $true; Build-ScreenCards $Ctl.W4Screens 'wiz' $App.W.TvPath (Get-SuggestedTv $App.Data.Monitors) $App.W.TvName; $App.Loading = $false
    $App.W4Lc.Sig = ''; Update-Step4
})
$Ctl.W4TestOn.Add_Click({ Save-Step4; Start-GameModeTest 'GameModeOn' $App.W4Lc 'wiz' })
$Ctl.W4TestOff.Add_Click({ Save-Step4; Start-GameModeTest 'GameModeOff' $App.W4Lc 'wiz' })

# panel
foreach ($nav in @($Ctl.NavHome, $Ctl.NavGame, $Ctl.NavComputer, $Ctl.NavGames, $Ctl.NavConn)) {
    $nav.Add_Checked({ if (-not $App.Loading) { Select-Page ([string]$this.Tag) } })
}
$Ctl.HomeBtnA.Add_Click({ Open-Log })
$Ctl.HomeBtnB.Add_Click({
    switch ([string]$this.Tag) {
        'restart' { Restart-Agent }
        'setup'   { $s = Get-ResumeStep; if ($s -lt 1) { $s = 4 }; Show-Step $s }
    }
})
$Ctl.PgIdentify.Add_Click({ Show-ScreenNumbers })
$Ctl.PgRefresh.Add_Click({ Update-Monitors; $App.Loading = $true; Build-ScreenCards $Ctl.PgScreens 'pg' ([string]$App.Cfg.gameMode.tvPath) '' ([string]$App.Cfg.gameMode.tvName); $App.Loading = $false })
$Ctl.PgTestOn.Add_Click({
    if (-not $App.Cfg.gameMode.tvPath -and -not $App.Cfg.gameMode.tvName) { Show-Toast 'Escolha a tela da TV primeiro.' 'info'; return }
    if ($App.Dirty -and -not (Save-Panel -Quiet)) { return }
    if (-not $App.PgLcObj) { $App.PgLcObj = New-LiveCheck $Ctl.PgLc }
    $Ctl.PgLc.Visibility = 'Visible'
    Start-GameModeTest 'GameModeOn' $App.PgLcObj 'pg'
})
$Ctl.PgTestOff.Add_Click({
    if ($App.Dirty -and -not (Save-Panel -Quiet)) { return }
    if (-not $App.PgLcObj) { $App.PgLcObj = New-LiveCheck $Ctl.PgLc }
    $Ctl.PgLc.Visibility = 'Visible'
    Start-GameModeTest 'GameModeOff' $App.PgLcObj 'pg'
})
foreach ($ck in @($Ctl.CkPrimary, $Ctl.CkBigPicture, $Ctl.CkCloseGame)) { $ck.Add_Checked({ Set-Dirty $true }); $ck.Add_Unchecked({ Set-Dirty $true }) }
$Ctl.CbTvAudio.Add_SelectionChanged({ Set-Dirty $true })
foreach ($rb in @($Ctl.RbSleep, $Ctl.RbHibernate, $Ctl.RbShutdown)) { $rb.Add_Checked({ Set-Dirty $true }) }
$Ctl.TbVolStep.Add_TextChanged({ Set-Dirty $true })
$Ctl.BtnAddInput.Add_Click({ Add-InputRow '' ''; Set-Dirty $true })
$Ctl.BtnAddGame.Add_Click({ $r = Add-GameRow '' '' ''; Update-GamesEmpty; Set-Dirty $true; $Window.UpdateLayout(); $r.Game.IsDropDownOpen = $true })
$Ctl.BtnFirstGame.Add_Click({ $r = Add-GameRow '' '' ''; Update-GamesEmpty; Set-Dirty $true; $Window.UpdateLayout(); $r.Game.IsDropDownOpen = $true })
$Ctl.BtnPortal.Add_Click({ Open-Portal })
$Ctl.PKey.Add_TextChanged({ if (-not $App.Loading) { Set-CleanText $this }; [void](Update-PanelKey); Set-Dirty $true })
$Ctl.PSecret.Add_PasswordChanged({
    if (-not $App.Loading) { $clean = ConvertTo-CleanCode $this.Password; if ($clean -ne $this.Password) { $this.Password = $clean } }
    [void](Update-PanelKey); Set-Dirty $true
})
$Ctl.PKeyPaste.Add_Click({ $Ctl.PKey.Text = Get-ClipboardCode; $Ctl.PKey.CaretIndex = $Ctl.PKey.Text.Length })
$Ctl.PSecretPaste.Add_Click({ $Ctl.PSecret.Password = Get-ClipboardCode })
$Ctl.BtnTestConn.Add_Click({
    if ($App.Dirty -and -not (Save-Panel -Quiet)) { return }
    if (-not $App.ConnLcObj) { $App.ConnLcObj = New-LiveCheck $Ctl.ConnLc }
    $Ctl.ConnLc.Visibility = 'Visible'
    $App.ConnTestAt = [DateTimeOffset]::Now
    Restart-Agent
    Set-LiveCheck $App.ConnLcObj 'wait' 'Testando a conexão…' 'O agente reconecta ao Sinric Pro. Leva alguns segundos.'
})
$Ctl.BtnSave.Add_Click({ [void](Save-Panel) })
$Ctl.BtnDiscard.Add_Click({ Undo-Panel })

# how-to on the Conexão page (same words as the assistant)
foreach ($s in @(
    'Entre no {portal} com a sua conta.',
    'Em [[Credentials]], copie o **App Key** e o **App Secret**.',
    'Em [[Devices]], cada dispositivo tem o seu **Device ID**: clique nele e copie (24 letras e números).',
    'Os 3 dispositivos precisam destes nomes e tipos: **Modo Jogo** ([[Switch]]), **Computador** ([[TV]]) e **Modo Invisível** ([[Switch]]).'
)) { $t = New-Text '' 13 '#9AA4B2'; $t.LineHeight = 24; $t.Margin = '0,0,0,4'; Set-Rich $t ('•   ' + $s); [void]$Ctl.ConnHow.Children.Add($t) }

# ====================================================================== timer

$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromSeconds(1)
$Timer.Add_Tick({
    $App.Tick++
    try {
        Update-AgentIndicators
        Test-GameModeFinished
        if (-not $Demo -and $App.Mode -eq 'wizard') {
            switch ($App.Step) { 1 { Watch-Step1 } 3 { Watch-Step3 } 5 { Watch-Step5 } }
            if ($App.W.AdvanceAt -and (Get-Date) -gt $App.W.AdvanceAt) { $App.W.AdvanceAt = $null; Invoke-WizardNext }
        }
        if ($App.Mode -eq 'panel') { Watch-ConnTest }
    } catch { }
    if ($App.ToastUntil -and (Get-Date) -gt $App.ToastUntil) { $App.ToastUntil = $null; $Ctl.Toast.Visibility = 'Collapsed' }
})

# pulse around the green "Conectado" dot
$pulse = New-Object Windows.Media.Animation.DoubleAnimation(1, 2.4, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(1600))))
$pulse.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
$fade = New-Object Windows.Media.Animation.DoubleAnimation(0.55, 0, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(1600))))
$fade.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
$Ctl.HomeHaloScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $pulse)
$Ctl.HomeHaloScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $pulse)
$Ctl.HomeHalo.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)

# ====================================================================== demo states (README screenshots)

function Set-DemoStep([int]$Step) {
    switch ($Step) {
        1 {
            $App.W.Connected = $true
            Update-Step1
            Set-LiveCheck $App.W1Lc 'ok' 'Conectado! O seu PC já fala com o Sinric Pro.'
        }
        2 {
            $App.WizIds.Rows[2].Box.Text = '65a1f0c2d3e4f5'
            Update-Step2
        }
        3 {
            $App.W.Ok = $true
            Set-LiveCheck $App.W3Lc 'ok' 'Ouvi a Alexa! Ela já controla o seu computador.' 'O volume mudou. Isso confirma a skill ativada e os dispositivos encontrados.'
        }
        4 {
            $App.W.TestedOn = $true
            Set-LiveCheck $App.W4Lc 'ok' 'Funcionou! A **SAMSUNG TV** virou a tela principal.' 'Agora clique em **Testar desligar** pra voltar ao normal.'
        }
        5 {
            $App.W.C1 = $true
            Set-LiveCheck $App.W5Lcs[0] 'ok' (Get-VoiceTitle 0) $VoiceChecks[0].Done
            Set-LiveCheck $App.W5Lcs[1] 'wait' (Get-VoiceTitle 1) 'Esperando você falar…'
        }
    }
    Update-WizardNext
}

# ====================================================================== start

if ($Demo) {
    $App.Data = Get-DemoData
    $Ctl.DemoChip.Visibility = 'Visible'
    $App.DemoStatus = [pscustomobject]@{ state = 'conectado'; message = ''; lastCommand = 'gameMode setPowerState {"state":"On"}'
        lastCommandAt = [DateTimeOffset]::Now.AddMinutes(-3).ToString('o'); lastCommandOk = $true; pid = $PID; warning = '' }
    if ($Page -match '^wizard[1-5]$' -or $Page -eq 'done') {
        $App.DemoStatus.lastCommand = $null
        $App.Data.Wizard = @{ done = $false; alexa = $true; tv = $true; invisible = $false }
    }
} else {
    $App.Data = Get-RealData
}
$App.Cfg = $App.Data.Cfg
Build-Phrases

if ($Page -match '^wizard([1-5])$') { $n = [int]$Matches[1]; Show-Step $n; if ($Demo) { Set-DemoStep $n } }
elseif ($Page -eq 'done') { Show-Step 5; Show-Done }
elseif ($Page) { Show-Panel $Page }
else {
    $resume = Get-ResumeStep
    if ($resume -gt 0) { Show-Step $resume } else { Show-Panel 'home' }
}
$App.Loading = $false
Update-AgentIndicators
$Timer.Start()

if ($Screenshot) {
    # render off-screen, without stealing focus; the PNG keeps the rounded corners and the shadow on a transparent background
    $Window.WindowStartupLocation = 'Manual'; $Window.Left = -6000; $Window.Top = 0; $Window.ShowActivated = $false; $Window.ShowInTaskbar = $false
    $shot = New-Object Windows.Threading.DispatcherTimer
    $shot.Interval = [TimeSpan]::FromMilliseconds($ScreenshotDelayMs)
    $shot.Add_Tick({
        $shot.Stop()
        $frame = $Ctl.Frame
        $rtb = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$frame.ActualWidth, [int]$frame.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($frame)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Open($Screenshot, 'Create'); $enc.Save($fs); $fs.Close()
        $App.Closing = $true
        $Window.Close()
    })
    $shot.Start()
}

[void]$Window.ShowDialog()
