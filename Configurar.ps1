# Configurar.ps1 - Alexa PC Control desktop UI (cyberpunk neon, same look as Steam Status Scheduler)
#
# Native WPF window (ships with every Windows 10/11, no extra runtime) to edit the installed
# config.json: Sinric Pro keys and device ids, the game mode (which screen is the TV and its audio),
# what "turn off the computer" means, Alexa inputs -> audio outputs and channels -> Steam games.
# Shows the agent state (status.json, written by Agente.ps1) and runs the game mode test.
# The agent reloads config.json by itself a few seconds after it is saved.
#
# Saved as UTF-8 WITH BOM on purpose: PowerShell 5.1 needs the BOM for the accented strings.
# PowerShell variables are case-insensitive: globals are $App, $Ctl, $Br (never 1-letter names).

[CmdletBinding()]
param(
    [string]$Screenshot,           # debug: render the window to this PNG after a delay and exit
    [int]$ScreenshotDelayMs = 2500,
    [switch]$Demo                  # docs: made-up screens, audio, games and keys instead of the real ones
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Drawing

$InstallDir = $PSScriptRoot
$ConfigPath = Join-Path $InstallDir 'config.json'
$StatusPath = Join-Path $InstallDir 'status.json'
$LogPath    = Join-Path $InstallDir 'agente.log'
$AgentPath  = Join-Path $InstallDir 'Agente.ps1'
$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Version    = 'v1.0'
. (Join-Path $InstallDir 'Config.ps1')
. (Join-Path $InstallDir 'Pc.ps1')
. (Join-Path $InstallDir 'Steam.ps1')

$PowerOffs   = @('sleep', 'hibernate', 'shutdown')
$PowerOffPt  = @{ sleep = 'SUSPENDER'; hibernate = 'HIBERNAR'; shutdown = 'DESLIGAR' }
$AlexaInputs = @('TV', 'HDMI 1', 'HDMI 2', 'AUX 1', 'AUX 2', 'GAME', 'MEDIA PLAYER')
$RolePt      = @{ gameMode = 'MODO JOGO'; computer = 'COMPUTADOR'; invisibleMode = 'MODO INVISÍVEL' }

$Conv = New-Object Windows.Media.BrushConverter
function Brush([string]$Hex) { return $Conv.ConvertFromString($Hex) }
function Color([string]$Hex) { return [Windows.Media.ColorConverter]::ConvertFromString($Hex) }
$Br = @{
    Pink = Brush '#FF2BD6'; Cyan = Brush '#00F0FF'; Yellow = Brush '#F5FF3B'; Red = Brush '#FF3B5C'
    Text = Brush '#F2E9FF'; Dim = Brush '#8A78B0'; Faint = Brush '#4A3A6B'; Dark = Brush '#0A0014'
}

# ====================================================================== data

# Made-up machine for the README screenshot: nothing here comes from the real PC.
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
        Monitors = @([pscustomobject]@{ Name = 'LG ULTRAGEAR'; DevicePath = 'demo-pc'; Available = $true; Active = $true; Primary = $true },
                     [pscustomobject]@{ Name = 'SAMSUNG TV'; DevicePath = 'demo-tv'; Available = $true; Active = $false; Primary = $false })
        Audio = @([pscustomobject]@{ Name = 'Fones de ouvido (Headset USB)'; Id = 'demo-1' },
                  [pscustomobject]@{ Name = 'Alto-falantes (Realtek(R) Audio)'; Id = 'demo-2' },
                  [pscustomobject]@{ Name = 'LG ULTRAGEAR (NVIDIA High Definition Audio)'; Id = 'demo-3' })
        Status = [pscustomobject]@{ state = 'conectado'; message = ''; lastCommand = 'gameMode setPowerState {"state":"On"}'
                                    lastCommandAt = (Get-Date).AddMinutes(-3).ToString('o'); lastCommandOk = $true; pid = $PID }
    }
}

function Get-RealData {
    $cfg = Read-ApcConfig $ConfigPath
    $data = @{ Cfg = $cfg; HasSecret = [bool](Get-ApcSecret $cfg); Monitors = @(); Audio = @(); Games = @(); Status = $null }
    try { $data.Monitors = @(Get-ApcMonitors) } catch { }
    try { $data.Audio = @(Get-ApcAudioDevices) } catch { }
    try { $data.Games = @(Get-ApcSteamGames) } catch { }
    return $data
}

function Read-AgentStatus {
    if ($Demo) { return $App.Data.Status }
    try { if (Test-Path $StatusPath) { return (Get-Content -Raw -Encoding UTF8 $StatusPath | ConvertFrom-Json) } } catch { }
    return $null
}

function Test-AgentAlive($Status) {
    if ($Demo) { return $true }
    if (-not $Status -or -not $Status.pid) { return $false }
    $p = Get-Process -Id ([int]$Status.pid) -ErrorAction SilentlyContinue
    return [bool]($p -and $p.ProcessName -match 'powershell')
}

function Format-Ago([datetime]$When) {
    $d = (Get-Date) - $When
    if ($d.TotalMinutes -lt 1) { return 'agora' }
    if ($d.TotalHours -lt 1) { return ('há {0} min' -f [int][Math]::Floor($d.TotalMinutes)) }
    if ($d.TotalHours -lt 24) { return ('há {0}h' -f [int][Math]::Floor($d.TotalHours)) }
    if ($d.TotalDays -lt 2) { return 'ontem' }
    return ('há {0} dias' -f [int][Math]::Floor($d.TotalDays))
}

# "gameMode setPowerState {"state":"On"}" -> "MODO JOGO · ligar"
function Format-LastCommand($Status) {
    if (-not $Status -or -not $Status.lastCommand) { return 'nenhum comando da Alexa ainda' }
    $parts = ([string]$Status.lastCommand) -split ' ', 3
    $role = $RolePt[$parts[0]]; if (-not $role) { $role = $parts[0] }
    $what = $parts[1]
    $v = $null; if ($parts.Count -gt 2) { try { $v = $parts[2] | ConvertFrom-Json } catch { } }
    if ($v) {
        switch ($parts[1]) {
            'setPowerState' { $what = $(if ($v.state -eq 'On') { 'ligar' } else { 'desligar' }) }
            'setVolume'     { $what = 'volume ' + $v.volume }
            'adjustVolume'  { $what = 'volume ' + ('{0:+#;-#;0}' -f [int]$v.volume) }
            'setMute'       { $what = $(if ($v.mute) { 'mudo' } else { 'tirar do mudo' }) }
            'mediaControl'  { $what = 'mídia ' + $v.control }
            'selectInput'   { $what = 'entrada ' + $v.input }
            'changeChannel' { $what = 'canal ' + $(if ($v.channel.number) { $v.channel.number } else { $v.channel.name }) }
        }
    }
    $ago = ''; try { $ago = '  ·  ' + (Format-Ago ([datetime]$Status.lastCommandAt)) } catch { }
    $ok = $(if ($Status.lastCommandOk) { '  ✓' } else { '  ✗ falhou' })
    return 'último comando:  ' + $role + ' · ' + $what + $ago + $ok
}

# ====================================================================== window

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Alexa PC Control" Width="1200" Height="860"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanMinimize" ShowInTaskbar="True"
        FontFamily="Bahnschrift" FontSize="13" Foreground="#F2E9FF"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#00F0FF"/>
      <Setter Property="BorderBrush" Value="#00F0FF"/>
      <Setter Property="Background" Value="#1A00F0FF"/>
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="Margin" Value="0,0,12,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform><SkewTransform AngleX="-14"/></Border.RenderTransform>
              <ContentPresenter x:Name="cp" HorizontalAlignment="Center" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
                <ContentPresenter.RenderTransform><SkewTransform AngleX="14"/></ContentPresenter.RenderTransform>
              </ContentPresenter>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{Binding BorderBrush, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter TargetName="cp" Property="TextElement.Foreground" Value="#0A0014"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.75"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.3"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#FF2BD6"/>
      <Setter Property="BorderBrush" Value="#FF2BD6"/>
      <Setter Property="Foreground" Value="#0A0014"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Padding" Value="26,8"/>
    </Style>
    <Style x:Key="BtnIcon" TargetType="Button">
      <Setter Property="Foreground" Value="#8A78B0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="Transparent" Width="34" Height="26">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#33FF2BD6"/>
                <Setter Property="Foreground" Value="#FF2BD6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Chip" TargetType="ToggleButton">
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="bd" Background="#0FFFFFFF" BorderBrush="#3A2A55" BorderThickness="1" Padding="10,6" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform><SkewTransform AngleX="-14"/></Border.RenderTransform>
              <ContentPresenter x:Name="cp" TextElement.Foreground="{TemplateBinding BorderBrush}" HorizontalAlignment="Center" RenderTransformOrigin="0.5,0.5">
                <ContentPresenter.RenderTransform><SkewTransform AngleX="14"/></ContentPresenter.RenderTransform>
              </ContentPresenter>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{Binding BorderBrush, RelativeSource={RelativeSource TemplatedParent}}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{Binding BorderBrush, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{Binding BorderBrush, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter TargetName="cp" Property="TextElement.Foreground" Value="#0A0014"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Tb" TargetType="TextBox">
      <Setter Property="Background" Value="#0F0620"/>
      <Setter Property="Foreground" Value="#F2E9FF"/>
      <Setter Property="BorderBrush" Value="#3A2A55"/>
      <Setter Property="BorderThickness" Value="0,0,0,2"/>
      <Setter Property="CaretBrush" Value="#00F0FF"/>
      <Setter Property="SelectionBrush" Value="#FF2BD6"/>
      <Setter Property="Padding" Value="8,0"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#5A4A85"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#00F0FF"/>
                <Setter TargetName="bd" Property="Background" Value="#160A2E"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Pb" TargetType="PasswordBox">
      <Setter Property="Background" Value="#0F0620"/>
      <Setter Property="Foreground" Value="#F2E9FF"/>
      <Setter Property="BorderBrush" Value="#3A2A55"/>
      <Setter Property="BorderThickness" Value="0,0,0,2"/>
      <Setter Property="CaretBrush" Value="#00F0FF"/>
      <Setter Property="SelectionBrush" Value="#FF2BD6"/>
      <Setter Property="Padding" Value="8,0"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#5A4A85"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#00F0FF"/>
                <Setter TargetName="bd" Property="Background" Value="#160A2E"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CbToggle" TargetType="ToggleButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="bd" Background="#0F0620" BorderBrush="#3A2A55" BorderThickness="0,0,0,2">
              <Path x:Name="arrow" Data="M0,0 L9,0 L4.5,5 Z" Fill="#00F0FF" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,11,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#5A4A85"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#FF2BD6"/>
                <Setter TargetName="bd" Property="Background" Value="#160A2E"/>
                <Setter TargetName="arrow" Property="Fill" Value="#FF2BD6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Cb" TargetType="ComboBox">
      <Setter Property="Foreground" Value="#F2E9FF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="MaxDropDownHeight" Value="300"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="tg" Style="{StaticResource CbToggle}" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
              <ContentPresenter x:Name="cp" IsHitTestVisible="False" Margin="10,0,30,0" VerticalAlignment="Center" HorizontalAlignment="Left"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <TextBox x:Name="PART_EditableTextBox" Visibility="Hidden" Background="Transparent" BorderThickness="0" Margin="6,0,30,0"
                       VerticalAlignment="Center" Foreground="#F2E9FF" CaretBrush="#00F0FF" SelectionBrush="#FF2BD6"
                       FontFamily="Bahnschrift" FontSize="13" IsReadOnly="{TemplateBinding IsReadOnly}"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True"
                     Focusable="False" PopupAnimation="Fade">
                <Border Background="#F2140726" BorderBrush="#FF2BD6" BorderThickness="1" Margin="0,2,0,0"
                        MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEditable" Value="True">
                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
                <Setter TargetName="cp" Property="Visibility" Value="Hidden"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#F2E9FF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="bd" Background="Transparent" Padding="10,7">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Foreground" Value="#00F0FF"/>
              </Trigger>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#33FF2BD6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Ck" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#F2E9FF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,22,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="16" Height="16" BorderBrush="#5A4A85" BorderThickness="1" Background="#0F0620" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
                <Border.RenderTransform><SkewTransform AngleX="-14"/></Border.RenderTransform>
                <Rectangle x:Name="mark" Width="8" Height="8" Fill="#00F0FF" Visibility="Collapsed">
                  <Rectangle.Effect><DropShadowEffect Color="#00F0FF" BlurRadius="8" ShadowDepth="0" Opacity="1"/></Rectangle.Effect>
                </Rectangle>
              </Border>
              <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="box" Property="BorderBrush" Value="#00F0FF"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="mark" Property="Visibility" Value="Visible"/>
                <Setter TargetName="box" Property="BorderBrush" Value="#00F0FF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="5"/>
      <Setter Property="MinWidth" Value="5"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True" Orientation="{TemplateBinding Orientation}">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border Background="#88FF2BD6"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Hud" TargetType="ContentControl">
      <Setter Property="Padding" Value="18,14"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContentControl">
            <Grid>
              <Border Background="#B3140726" BorderBrush="#33FF2BD6" BorderThickness="1"/>
              <Path Data="M0,14 L0,0 L14,0" Stroke="#00F0FF" StrokeThickness="2" HorizontalAlignment="Left" VerticalAlignment="Top"/>
              <Path Data="M0,0 L14,0 L14,14" Stroke="#00F0FF" StrokeThickness="2" HorizontalAlignment="Right" VerticalAlignment="Top"/>
              <Path Data="M0,0 L0,14 L14,14" Stroke="#FF2BD6" StrokeThickness="2" HorizontalAlignment="Left" VerticalAlignment="Bottom"/>
              <Path Data="M14,0 L14,14 L0,14" Stroke="#FF2BD6" StrokeThickness="2" HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
              <ContentPresenter Margin="{TemplateBinding Padding}"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="#8A78B0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="10,0,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <TextBlock x:Name="tx" Text="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="tx" Property="Foreground" Value="#00F0FF"/>
                <Setter TargetName="tx" Property="TextDecorations" Value="Underline"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="H" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#F2E9FF"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8A78B0"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,10,0,4"/>
    </Style>
    <Style x:Key="Say" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8A78B0"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontStyle" Value="Italic"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="DevName" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="DevType" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8A78B0"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Margin" Value="0,2,0,0"/>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" Margin="16" BorderBrush="#99FF2BD6" BorderThickness="1">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop Color="#120024" Offset="0"/>
        <GradientStop Color="#0A0014" Offset="0.55"/>
        <GradientStop Color="#05000E" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Border.Effect><DropShadowEffect Color="#FF2BD6" BlurRadius="30" ShadowDepth="0" Opacity="0.45"/></Border.Effect>
    <Grid ClipToBounds="True">
      <Rectangle IsHitTestVisible="False" Opacity="0.5">
        <Rectangle.Fill>
          <DrawingBrush TileMode="Tile" Viewport="0,0,36,36" ViewportUnits="Absolute">
            <DrawingBrush.Drawing>
              <GeometryDrawing>
                <GeometryDrawing.Pen><Pen Brush="#14FF2BD6" Thickness="1"/></GeometryDrawing.Pen>
                <GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,36,36"/></GeometryDrawing.Geometry>
              </GeometryDrawing>
            </DrawingBrush.Drawing>
          </DrawingBrush>
        </Rectangle.Fill>
      </Rectangle>

      <Grid Margin="22,14,22,18">
        <Grid.RowDefinitions><RowDefinition Height="44"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

        <!-- ============ TITLE ============ -->
        <Grid x:Name="TitleBar" Background="Transparent">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Rectangle Width="6" Height="22" Fill="#FF2BD6" Margin="0,0,10,0">
              <Rectangle.Effect><DropShadowEffect Color="#FF2BD6" BlurRadius="12" ShadowDepth="0" Opacity="1"/></Rectangle.Effect>
            </Rectangle>
            <TextBlock FontSize="21" FontWeight="Bold" VerticalAlignment="Center">
              <TextBlock.Effect><DropShadowEffect Color="#00F0FF" BlurRadius="14" ShadowDepth="0" Opacity="0.7"/></TextBlock.Effect>
              <Run Text="ALEXA" Foreground="#FFFFFF"/><Run Text="//" Foreground="#FF2BD6"/><Run Text="PC" Foreground="#00F0FF"/>
            </TextBlock>
            <TextBlock x:Name="VersionText" Text="CONTROL" Foreground="#8A78B0" FontSize="12" Margin="12,6,0,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="DemoTag" Text="DEMO" Foreground="#F5FF3B" FontSize="11" FontWeight="Bold" Margin="12,6,0,0" VerticalAlignment="Center" Visibility="Collapsed"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <TextBlock Text="&#9698;&#9700;" Foreground="#FF2BD6" Margin="0,0,10,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="Clock" Text="--:--:--" FontFamily="Cascadia Mono, Consolas" Foreground="#00F0FF" Margin="0,0,20,0" VerticalAlignment="Center"/>
            <Button x:Name="BtnMin" Content="&#8212;" Style="{StaticResource BtnIcon}"/>
            <Button x:Name="BtnClose" Content="&#10005;" Style="{StaticResource BtnIcon}"/>
          </StackPanel>
          <Rectangle Height="1" VerticalAlignment="Bottom">
            <Rectangle.Fill>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                <GradientStop Color="#FF2BD6" Offset="0"/><GradientStop Color="#00F0FF" Offset="0.5"/><GradientStop Color="#00FF2BD6" Offset="1"/>
              </LinearGradientBrush>
            </Rectangle.Fill>
          </Rectangle>
        </Grid>

        <Grid Grid.Row="1" Margin="0,16,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="450"/><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

          <!-- ============ LEFT ============ -->
          <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto" Padding="0,0,4,0">
            <StackPanel>
              <ContentControl Style="{StaticResource Hud}">
                <StackPanel>
                  <Grid>
                    <TextBlock Style="{StaticResource H}"><Run Text="01 " Foreground="#FF2BD6"/><Run Text="//  SINRIC PRO"/></TextBlock>
                    <Button x:Name="BtnPortal" Content="abrir portal do Sinric &#8599;" Style="{StaticResource Link}" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,2,0,0"/>
                  </Grid>
                  <TextBlock Text="a ponte entre a Alexa e este PC. copie de Credentials e Devices no portal." Style="{StaticResource Say}" FontStyle="Normal"/>
                  <TextBlock Text="APP KEY" Style="{StaticResource Label}"/>
                  <TextBox x:Name="TbAppKey" Style="{StaticResource Tb}"/>
                  <TextBlock Text="APP SECRET" Style="{StaticResource Label}"/>
                  <Grid>
                    <PasswordBox x:Name="PbSecret" Style="{StaticResource Pb}"/>
                    <TextBlock x:Name="SecretHint" IsHitTestVisible="False" Foreground="#5A4A85" FontSize="12" Margin="10,0,0,2" VerticalAlignment="Center"/>
                  </Grid>
                  <TextBlock Text="ID DE CADA DISPOSITIVO" Style="{StaticResource Label}" Margin="0,16,0,2"/>
                  <Grid Margin="0,6,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="128"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Text="MODO JOGO" Style="{StaticResource DevName}" Foreground="#FF2BD6"/>
                      <TextBlock Text="tipo: Interruptor" Style="{StaticResource DevType}"/>
                    </StackPanel>
                    <TextBox x:Name="TbDevGame" Grid.Column="1" Style="{StaticResource Tb}"/>
                  </Grid>
                  <Grid Margin="0,8,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="128"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Text="COMPUTADOR" Style="{StaticResource DevName}" Foreground="#00F0FF"/>
                      <TextBlock Text="tipo: TV" Style="{StaticResource DevType}"/>
                    </StackPanel>
                    <TextBox x:Name="TbDevComputer" Grid.Column="1" Style="{StaticResource Tb}"/>
                  </Grid>
                  <Grid Margin="0,8,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="128"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Text="MODO INVISÍVEL" Style="{StaticResource DevName}" Foreground="#F5FF3B"/>
                      <TextBlock Text="tipo: Interruptor" Style="{StaticResource DevType}"/>
                    </StackPanel>
                    <TextBox x:Name="TbDevInvisible" Grid.Column="1" Style="{StaticResource Tb}"/>
                  </Grid>
                  <TextBlock Text="diga: Alexa, liga o modo invisível" Style="{StaticResource Say}" Margin="128,8,0,0"/>
                </StackPanel>
              </ContentControl>

              <ContentControl Style="{StaticResource Hud}" Margin="0">
                <StackPanel>
                  <TextBlock Style="{StaticResource H}"><Run Text="03 " Foreground="#FF2BD6"/><Run Text="//  COMPUTADOR"/></TextBlock>
                  <TextBlock Text="diga: Alexa, desliga o computador  ·  aumenta o volume do computador  ·  pausa o computador" Style="{StaticResource Say}"/>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="96"/></Grid.ColumnDefinitions>
                    <StackPanel>
                      <TextBlock Text="QUANDO PEDIR PRA DESLIGAR" Style="{StaticResource Label}" Margin="0,12,0,6"/>
                      <StackPanel x:Name="PowerPanel" Orientation="Horizontal" Margin="4,0,0,0"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2">
                      <TextBlock Text="PASSO DO VOLUME" Style="{StaticResource Label}" Margin="0,12,0,4"/>
                      <TextBox x:Name="TbVolStep" Style="{StaticResource Tb}" TextAlignment="Center"/>
                    </StackPanel>
                  </Grid>
                  <Grid Margin="0,16,0,6">
                    <TextBlock Text="ENTRADA DA ALEXA  &#8594;  SAÍDA DE ÁUDIO" Style="{StaticResource Label}" Margin="0"/>
                    <Button x:Name="BtnAddInput" Content="+ entrada" Style="{StaticResource Link}" HorizontalAlignment="Right"/>
                  </Grid>
                  <StackPanel x:Name="InputList"/>
                  <TextBlock Text="diga: Alexa, muda a entrada do computador para TV" Style="{StaticResource Say}" Margin="0,2,0,0"/>
                </StackPanel>
              </ContentControl>
            </StackPanel>
          </ScrollViewer>

          <!-- ============ RIGHT ============ -->
          <Grid Grid.Column="2">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>

            <ContentControl Style="{StaticResource Hud}" Padding="18,12">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center">
                  <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="StDot" Width="10" Height="10" Fill="#8A78B0" Margin="0,0,10,0" VerticalAlignment="Center">
                      <Ellipse.Effect><DropShadowEffect x:Name="StGlow" Color="#8A78B0" BlurRadius="12" ShadowDepth="0" Opacity="1"/></Ellipse.Effect>
                    </Ellipse>
                    <TextBlock x:Name="StText" Text="VERIFICANDO..." FontWeight="Bold" FontSize="17" VerticalAlignment="Center"/>
                    <TextBlock x:Name="StSub" Text="" Foreground="#8A78B0" FontSize="12" Margin="14,3,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="330"/>
                  </StackPanel>
                  <TextBlock x:Name="StLast" Text="" Foreground="#8A78B0" FontSize="11" Margin="20,5,0,0" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                  <Button x:Name="BtnStart" Content="INICIAR" Style="{StaticResource Btn}" BorderBrush="#F5FF3B" Foreground="#F5FF3B" Background="#1AF5FF3B" Visibility="Collapsed"/>
                  <Button x:Name="BtnLog" Content="LOG" Style="{StaticResource Btn}" Margin="0"/>
                </StackPanel>
              </Grid>
            </ContentControl>

            <ContentControl Grid.Row="1" Style="{StaticResource Hud}">
              <StackPanel>
                <Grid>
                  <TextBlock Style="{StaticResource H}"><Run Text="02 " Foreground="#FF2BD6"/><Run Text="//  MODO JOGO"/></TextBlock>
                  <TextBlock Text="diga: Alexa, liga o modo jogo" Style="{StaticResource Say}" HorizontalAlignment="Right" Margin="0,2,0,0"/>
                </Grid>
                <TextBlock Text="estende as telas, põe a TV como principal com o áudio nela e abre o Big Picture. desligar volta tudo como estava." Style="{StaticResource Say}" FontStyle="Normal"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Text="TELA DA TV" Style="{StaticResource Label}"/>
                    <ComboBox x:Name="CbTv" Style="{StaticResource Cb}"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <TextBlock Text="SAÍDA DE ÁUDIO DA TV" Style="{StaticResource Label}"/>
                    <ComboBox x:Name="CbTvAudio" Style="{StaticResource Cb}"/>
                  </StackPanel>
                </Grid>
                <WrapPanel Margin="2,16,0,0">
                  <CheckBox x:Name="CkPrimary" Content="TV vira a tela principal" Style="{StaticResource Ck}"/>
                  <CheckBox x:Name="CkBigPicture" Content="Abrir o Big Picture" Style="{StaticResource Ck}"/>
                  <CheckBox x:Name="CkCloseGame" Content="Fechar o jogo ao desligar" Style="{StaticResource Ck}" Margin="0"/>
                </WrapPanel>
                <Grid Margin="0,16,0,0">
                  <TextBlock Text="o teste usa a configuração salva" Style="{StaticResource Say}" VerticalAlignment="Center"/>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                    <Button x:Name="BtnTestOn" Content="TESTAR LIGAR" Style="{StaticResource Btn}"/>
                    <Button x:Name="BtnTestOff" Content="TESTAR DESLIGAR" Style="{StaticResource Btn}" BorderBrush="#FF2BD6" Foreground="#FF2BD6" Background="#1AFF2BD6" Margin="0"/>
                  </StackPanel>
                </Grid>
              </StackPanel>
            </ContentControl>

            <ContentControl Grid.Row="2" Style="{StaticResource Hud}" Margin="0">
              <Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid>
                  <TextBlock Style="{StaticResource H}"><Run Text="04 " Foreground="#FF2BD6"/><Run Text="//  JOGOS (CANAIS)"/></TextBlock>
                  <TextBlock Text="diga: Alexa, muda o canal do computador para 2" Style="{StaticResource Say}" HorizontalAlignment="Right" Margin="0,2,0,0"/>
                </Grid>
                <Grid Grid.Row="1" Margin="0,2,0,6">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="58"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="180"/><ColumnDefinition Width="34"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="CANAL" Style="{StaticResource Label}" Margin="0"/>
                  <TextBlock Grid.Column="2" Text="JOGO" Style="{StaticResource Label}" Margin="0"/>
                  <TextBlock Grid.Column="4" Text="APELIDOS (separe com vírgula)" Style="{StaticResource Label}" Margin="0"/>
                </Grid>
                <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
                  <StackPanel x:Name="ChannelList"/>
                </ScrollViewer>
                <TextBlock x:Name="ChannelEmpty" Grid.Row="2" Text="nenhum canal ainda. clique em + CANAL." Foreground="#5A4A85" VerticalAlignment="Top" Margin="0,8,0,0"/>
                <Grid Grid.Row="3" Margin="0,10,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Text="Pode falar o nome de qualquer jogo instalado, mesmo fora da lista. Canal 0 fecha o jogo aberto." Style="{StaticResource Say}" FontStyle="Normal" VerticalAlignment="Center" Margin="0,0,12,0"/>
                  <Button x:Name="BtnAddChannel" Grid.Column="1" Content="+ CANAL" Style="{StaticResource Btn}" Margin="0"/>
                </Grid>
              </Grid>
            </ContentControl>
          </Grid>
        </Grid>

        <!-- ============ FOOTER ============ -->
        <Grid Grid.Row="2" Margin="0,14,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Button x:Name="BtnSave" Content="SALVAR" Style="{StaticResource BtnPrimary}" Margin="6,0,18,0"/>
          <TextBlock x:Name="MsgText" Grid.Column="1" Text="" Foreground="#8A78B0" TextWrapping="Wrap" VerticalAlignment="Center" FontSize="12"/>
        </Grid>
      </Grid>

      <Rectangle IsHitTestVisible="False" Opacity="0.18">
        <Rectangle.Fill>
          <DrawingBrush TileMode="Tile" Viewport="0,0,3,3" ViewportUnits="Absolute">
            <DrawingBrush.Drawing>
              <GeometryDrawing Brush="#000000"><GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,3,1"/></GeometryDrawing.Geometry></GeometryDrawing>
            </DrawingBrush.Drawing>
          </DrawingBrush>
        </Rectangle.Fill>
      </Rectangle>

      <Border x:Name="Toast" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,40"
              Background="#F00A0014" BorderBrush="#FF2BD6" BorderThickness="1" Padding="22,10" RenderTransformOrigin="0.5,0.5">
        <Border.RenderTransform><SkewTransform AngleX="-12"/></Border.RenderTransform>
        <Border.Effect><DropShadowEffect x:Name="ToastGlow" Color="#FF2BD6" BlurRadius="24" ShadowDepth="0" Opacity="0.9"/></Border.Effect>
        <TextBlock x:Name="ToastText" Text="" FontWeight="Bold" FontSize="14" RenderTransformOrigin="0.5,0.5">
          <TextBlock.RenderTransform><SkewTransform AngleX="12"/></TextBlock.RenderTransform>
        </TextBlock>
      </Border>
    </Grid>
  </Border>
</Window>
'@

# ====================================================================== build window

if ($Demo) { $Data = Get-DemoData } else { $Data = Get-RealData }
$App = @{
    Data = $Data; Cfg = $Data.Cfg; Dirty = $false; Loading = $true; Closing = $false
    PowerOff = 'sleep'; InputRows = New-Object System.Collections.ArrayList; ChannelRows = New-Object System.Collections.ArrayList
    ToastUntil = $null; Tick = 0
}
$Ctl = @{}

$reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
$Window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($n in @('Root','TitleBar','VersionText','DemoTag','Clock','BtnMin','BtnClose',
                 'BtnPortal','TbAppKey','PbSecret','SecretHint','TbDevGame','TbDevComputer','TbDevInvisible',
                 'PowerPanel','TbVolStep','BtnAddInput','InputList',
                 'StDot','StGlow','StText','StSub','StLast','BtnStart','BtnLog',
                 'CbTv','CbTvAudio','CkPrimary','CkBigPicture','CkCloseGame','BtnTestOn','BtnTestOff',
                 'ChannelList','ChannelEmpty','BtnAddChannel','BtnSave','MsgText','Toast','ToastGlow','ToastText')) {
    $Ctl[$n] = $Window.FindName($n)
    if ($null -eq $Ctl[$n]) { throw "XAML element not found: $n" }
}
$Ctl.VersionText.Text = 'CONTROL  ' + $Version
if ($Demo) { $Ctl.DemoTag.Visibility = 'Visible' }

try {
    $steamExe = Get-ApcSteamExe
    if ($steamExe) {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($steamExe)
        $Window.Icon = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    }
} catch { }

# ---------------------------------------------------------------- ui helpers

function Show-Toast([string]$Text, [string]$Hex = '#FF2BD6') {
    $Ctl.ToastText.Text = $Text
    $Ctl.ToastText.Foreground = Brush '#FFFFFF'
    $Ctl.Toast.BorderBrush = Brush $Hex
    $Ctl.ToastGlow.Color = Color $Hex
    $Ctl.Toast.Visibility = 'Visible'
    $Ctl.Toast.BeginAnimation([Windows.UIElement]::OpacityProperty, [Windows.Media.Animation.DoubleAnimation]::new(0, 1, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(180))))
    $App.ToastUntil = (Get-Date).AddMilliseconds(2800)
}
function Set-Msg([string]$Text, [string]$Hex = '#8A78B0') { $Ctl.MsgText.Text = $Text; $Ctl.MsgText.Foreground = Brush $Hex }
function Set-Dirty([bool]$Value) {
    if ($App.Loading) { return }
    $App.Dirty = $Value
    if ($Value) {
        $fx = [Windows.Media.Effects.DropShadowEffect]::new()
        $fx.Color = Color '#FF2BD6'; $fx.BlurRadius = 22; $fx.ShadowDepth = 0; $fx.Opacity = 1
        $Ctl.BtnSave.Effect = $fx
        $Ctl.BtnSave.Content = 'SALVAR  *'
        Set-Msg 'alterações não salvas.' '#FF2BD6'
    } else {
        $Ctl.BtnSave.Effect = $null
        $Ctl.BtnSave.Content = 'SALVAR'
    }
}
function New-Chip([string]$Text, $Tag, [string]$Hex) {
    $t = New-Object Windows.Controls.Primitives.ToggleButton
    $t.Style = $Window.FindResource('Chip')
    $t.Content = $Text; $t.Tag = $Tag
    $t.BorderBrush = Brush $Hex
    return $t
}
function New-ComboItem([string]$Text, $Tag, [string]$Hex = '') {
    $i = New-Object Windows.Controls.ComboBoxItem
    $i.Content = $Text; $i.Tag = $Tag
    if ($Hex) { $i.Foreground = Brush $Hex }
    return $i
}
function New-Combo {
    $c = New-Object Windows.Controls.ComboBox
    $c.Style = $Window.FindResource('Cb')
    return $c
}
function New-TextBox([string]$Text) {
    $t = New-Object Windows.Controls.TextBox
    $t.Style = $Window.FindResource('Tb')
    $t.Text = $Text
    return $t
}
function Add-Columns($Grid, [object[]]$Widths) {
    foreach ($w in $Widths) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        if ($w -eq '*') { $cd.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) } else { $cd.Width = [Windows.GridLength]::new([double]$w) }
        [void]$Grid.ColumnDefinitions.Add($cd)
    }
}
function Add-At($Grid, $Child, [int]$Column) { [Windows.Controls.Grid]::SetColumn($Child, $Column); [void]$Grid.Children.Add($Child) }
function Select-ByTag($Combo, $Tag) {
    foreach ($i in $Combo.Items) { if ([string]$i.Tag -eq [string]$Tag) { $Combo.SelectedItem = $i; return } }
    $Combo.SelectedIndex = 0
}

# ---------------------------------------------------------------- status

function Set-StatusLook([string]$Text, [string]$Hex, [string]$Sub) {
    $Ctl.StText.Text = $Text
    $Ctl.StText.Foreground = Brush $Hex
    $Ctl.StDot.Fill = Brush $Hex
    $Ctl.StGlow.Color = Color $Hex
    $Ctl.StSub.Text = $Sub
    $Ctl.StSub.ToolTip = $Sub
}

function Update-Status {
    $st = Read-AgentStatus
    $alive = Test-AgentAlive $st
    $Ctl.BtnStart.Visibility = $(if ($alive) { 'Collapsed' } else { 'Visible' })
    if (-not $alive) { Set-StatusLook 'AGENTE PARADO' '#FF3B5C' 'o agente não está rodando. clique em INICIAR.' }
    elseif ($st.state -eq 'conectado') { Set-StatusLook 'CONECTADO' '#00F0FF' 'Alexa  ↔  Sinric Pro  ↔  este PC' }
    elseif ($st.state -eq 'sem-config') { Set-StatusLook 'FALTA CONFIGURAR' '#F5FF3B' ([string]$st.message) }
    else { Set-StatusLook 'DESCONECTADO' '#FF3B5C' ([string]$st.message) }
    $Ctl.StLast.Text = Format-LastCommand $st
}

# ---------------------------------------------------------------- form: sinric + game mode

function Update-SecretHint {
    if ($Ctl.PbSecret.Password) { $Ctl.SecretHint.Text = ''; return }
    if ($App.Data.HasSecret) { $Ctl.SecretHint.Text = '•••• salvo (protegido no Windows). digite só pra trocar' }
    else { $Ctl.SecretHint.Text = 'cole aqui o App Secret' }
}

function Format-Monitor($Monitor) {
    $where = 'desconectada'
    if ($Monitor.Active) { $where = 'ativa'; if ($Monitor.Primary) { $where = 'ativa, principal' } }
    elseif ($Monitor.Available) { $where = 'conectada, desativada' }
    return $Monitor.Name + '   · ' + $where
}

function Fill-TvCombos {
    $gm = $App.Cfg.gameMode
    $Ctl.CbTv.Items.Clear()
    [void]$Ctl.CbTv.Items.Add((New-ComboItem '(escolha a tela da TV)' '' '#8A78B0'))
    $found = $false
    foreach ($m in $App.Data.Monitors) {
        [void]$Ctl.CbTv.Items.Add((New-ComboItem (Format-Monitor $m) $m.DevicePath))
        if ($gm.tvPath -and $m.DevicePath -eq $gm.tvPath) { $found = $true }
    }
    if ($gm.tvPath -and -not $found) { [void]$Ctl.CbTv.Items.Add((New-ComboItem ($gm.tvName + '   · não encontrada agora') $gm.tvPath '#8A78B0')) }
    Select-ByTag $Ctl.CbTv $gm.tvPath

    $Ctl.CbTvAudio.Items.Clear()
    [void]$Ctl.CbTvAudio.Items.Add((New-ComboItem '(automático: áudio com o nome da TV)' ''))
    $names = @($App.Data.Audio | ForEach-Object { $_.Name })
    foreach ($n in $names) { [void]$Ctl.CbTvAudio.Items.Add((New-ComboItem $n $n)) }
    if ($gm.audioName -and $names -notcontains $gm.audioName) { [void]$Ctl.CbTvAudio.Items.Add((New-ComboItem ($gm.audioName + '   · não conectada') $gm.audioName '#8A78B0')) }
    Select-ByTag $Ctl.CbTvAudio $gm.audioName
}

function Update-PowerChips {
    foreach ($chip in $Ctl.PowerPanel.Children) { $chip.IsChecked = ($chip.Tag -eq $App.PowerOff) }
}

# ---------------------------------------------------------------- form: inputs

function Get-InputEmptyLabel([string]$InputName) {
    if (($InputName -replace '\s', '').ToUpperInvariant() -eq 'TV') { return '(automático: áudio da TV)' }
    return '(escolha uma saída)'
}

function Add-InputRow([string]$InputName, [string]$AudioName) {
    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = [Windows.Thickness]::new(0, 0, 0, 6)
    Add-Columns $grid @(112, 26, '*', 34)

    $cbIn = New-Combo
    $cbIn.IsEditable = $true
    foreach ($n in $AlexaInputs) { [void]$cbIn.Items.Add($n) }
    $cbIn.Text = $InputName

    $arrow = New-Object Windows.Controls.TextBlock
    $arrow.Text = [string][char]0x2192; $arrow.Foreground = $Br.Pink; $arrow.FontSize = 15
    $arrow.HorizontalAlignment = 'Center'; $arrow.VerticalAlignment = 'Center'

    $cbAu = New-Combo
    $empty = New-ComboItem (Get-InputEmptyLabel $InputName) '' '#8A78B0'
    [void]$cbAu.Items.Add($empty)
    $names = @($App.Data.Audio | ForEach-Object { $_.Name })
    foreach ($n in $names) { [void]$cbAu.Items.Add((New-ComboItem $n $n)) }
    if ($AudioName -and $names -notcontains $AudioName) { [void]$cbAu.Items.Add((New-ComboItem ($AudioName + '   · não conectada') $AudioName '#8A78B0')) }
    Select-ByTag $cbAu $AudioName

    $del = New-Object Windows.Controls.Button
    $del.Style = $Window.FindResource('BtnIcon'); $del.Content = [string][char]0x2715; $del.ToolTip = 'remover'

    Add-At $grid $cbIn 0; Add-At $grid $arrow 1; Add-At $grid $cbAu 2; Add-At $grid $del 3
    $row = @{ Grid = $grid; Input = $cbIn; Audio = $cbAu; Empty = $empty }
    $cbIn.Tag = $row; $cbAu.Tag = $row; $del.Tag = $row
    [void]$App.InputRows.Add($row)
    [void]$Ctl.InputList.Children.Add($grid)

    $cbIn.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [Windows.Controls.TextChangedEventHandler]{
        param($sender, $e)
        $r = $sender.Tag
        $r.Empty.Content = Get-InputEmptyLabel $e.OriginalSource.Text
        if ($r.Audio.SelectedItem -eq $r.Empty) { $was = $App.Loading; $App.Loading = $true; $r.Audio.SelectedIndex = -1; $r.Audio.SelectedIndex = 0; $App.Loading = $was }
        Set-Dirty $true
    })
    $cbAu.Add_SelectionChanged({ Set-Dirty $true })
    $del.Add_Click({
        $r = $this.Tag
        $Ctl.InputList.Children.Remove($r.Grid)
        $App.InputRows.Remove($r)
        Set-Dirty $true
    })
}

# ---------------------------------------------------------------- form: channels

function Update-ChannelEmpty { $Ctl.ChannelEmpty.Visibility = $(if ($App.ChannelRows.Count) { 'Collapsed' } else { 'Visible' }) }

function Add-ChannelRow($Number, [string]$AppId, [string]$Name, [string]$Aliases) {
    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = [Windows.Thickness]::new(0, 0, 0, 6)
    Add-Columns $grid @(58, 10, '*', 10, 180, 34)

    $tbNum = New-TextBox ([string]$Number)
    $tbNum.TextAlignment = 'Center'; $tbNum.Foreground = $Br.Cyan; $tbNum.FontWeight = 'Bold'

    $cbGame = New-Combo
    [void]$cbGame.Items.Add((New-ComboItem '(escolha o jogo)' '' '#8A78B0'))
    $ids = @()
    foreach ($g in $App.Data.Games) { [void]$cbGame.Items.Add((New-ComboItem $g.Name ([string]$g.AppId))); $ids += [string]$g.AppId }
    if ($AppId -and $ids -notcontains $AppId) { [void]$cbGame.Items.Add((New-ComboItem ($Name + '   · não instalado') $AppId '#8A78B0')) }
    Select-ByTag $cbGame $AppId

    $tbAlias = New-TextBox $Aliases
    $tbAlias.FontFamily = 'Bahnschrift'

    $del = New-Object Windows.Controls.Button
    $del.Style = $Window.FindResource('BtnIcon'); $del.Content = [string][char]0x2715; $del.ToolTip = 'remover'

    Add-At $grid $tbNum 0; Add-At $grid $cbGame 2; Add-At $grid $tbAlias 4; Add-At $grid $del 5
    $row = @{ Grid = $grid; Number = $tbNum; Game = $cbGame; Aliases = $tbAlias }
    $del.Tag = $row
    [void]$App.ChannelRows.Add($row)
    [void]$Ctl.ChannelList.Children.Add($grid)
    Update-ChannelEmpty

    $tbNum.Add_TextChanged({ Set-Dirty $true })
    $cbGame.Add_SelectionChanged({ Set-Dirty $true })
    $tbAlias.Add_TextChanged({ Set-Dirty $true })
    $del.Add_Click({
        $r = $this.Tag
        $Ctl.ChannelList.Children.Remove($r.Grid)
        $App.ChannelRows.Remove($r)
        Update-ChannelEmpty
        Set-Dirty $true
    })
    return $row
}

# ---------------------------------------------------------------- load / save

function Load-Form {
    $App.Loading = $true
    $c = $App.Cfg
    $Ctl.TbAppKey.Text = [string]$c.sinric.appKey
    $Ctl.PbSecret.Password = ''
    $Ctl.TbDevGame.Text = [string]$c.sinric.devices.gameMode
    $Ctl.TbDevComputer.Text = [string]$c.sinric.devices.computer
    $Ctl.TbDevInvisible.Text = [string]$c.sinric.devices.invisibleMode
    Update-SecretHint

    Fill-TvCombos
    $Ctl.CkPrimary.IsChecked = [bool]$c.gameMode.tvPrimary
    $Ctl.CkBigPicture.IsChecked = [bool]$c.gameMode.bigPicture
    $Ctl.CkCloseGame.IsChecked = [bool]$c.gameMode.closeGameOnOff

    $App.PowerOff = [string]$c.computer.powerOff
    if ($PowerOffs -notcontains $App.PowerOff) { $App.PowerOff = 'sleep' }
    Update-PowerChips
    $Ctl.TbVolStep.Text = [string]$c.computer.volumeStep

    $Ctl.InputList.Children.Clear(); $App.InputRows.Clear()
    foreach ($i in @($c.computer.inputs)) { if ($i) { Add-InputRow ([string]$i.input) ([string]$i.audioName) } }

    $Ctl.ChannelList.Children.Clear(); $App.ChannelRows.Clear()
    foreach ($ch in @($c.channels | Sort-Object { [int]$_.number })) {
        if ($ch) { [void](Add-ChannelRow $ch.number ([string]$ch.appId) ([string]$ch.name) ((@($ch.aliases) | Where-Object { $_ }) -join ', ')) }
    }
    Update-ChannelEmpty
    # $App.Loading stays on until the window is rendered: templates applied late still fire change events
}

# Reads the form into $App.Cfg. Returns an error message, or $null when it can be saved.
function Read-Form {
    $c = $App.Cfg
    $step = 0
    if (-not [int]::TryParse($Ctl.TbVolStep.Text.Trim(), [ref]$step) -or $step -lt 1 -or $step -gt 50) { return 'O passo do volume precisa ser um número de 1 a 50.' }

    $channels = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($r in $App.ChannelRows) {
        $num = 0
        if (-not [int]::TryParse($r.Number.Text.Trim(), [ref]$num) -or $num -lt 1 -or $num -gt 999) { return 'O número do canal precisa ser de 1 a 999 (o 0 é reservado pra fechar o jogo).' }
        if ($seen.ContainsKey($num)) { return ('O canal ' + $num + ' aparece duas vezes.') }
        $seen[$num] = $true
        $item = $r.Game.SelectedItem
        if (-not $item -or -not $item.Tag) { return ('Escolha o jogo do canal ' + $num + '.') }
        $name = [string]$item.Content -replace '   · não instalado$', ''
        $aliases = @($r.Aliases.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        [void]$channels.Add([pscustomobject]@{ number = $num; name = $name; appId = [string]$item.Tag; aliases = $aliases })
    }

    $inputs = New-Object System.Collections.ArrayList
    foreach ($r in $App.InputRows) {
        $name = $r.Input.Text.Trim()
        if (-not $name) { continue }
        $audio = ''; if ($r.Audio.SelectedItem) { $audio = [string]$r.Audio.SelectedItem.Tag }
        [void]$inputs.Add([pscustomobject]@{ input = $name.ToUpperInvariant(); audioName = $audio })
    }

    $c.sinric.appKey = $Ctl.TbAppKey.Text.Trim()
    $c.sinric.devices.gameMode = $Ctl.TbDevGame.Text.Trim()
    $c.sinric.devices.computer = $Ctl.TbDevComputer.Text.Trim()
    $c.sinric.devices.invisibleMode = $Ctl.TbDevInvisible.Text.Trim()
    if ($Ctl.PbSecret.Password) { Set-ApcSecret $c $Ctl.PbSecret.Password.Trim() }

    $tv = $Ctl.CbTv.SelectedItem
    if ($tv -and $tv.Tag) {
        $c.gameMode.tvPath = [string]$tv.Tag
        $m = $App.Data.Monitors | Where-Object { $_.DevicePath -eq $tv.Tag } | Select-Object -First 1
        if ($m) { $c.gameMode.tvName = [string]$m.Name }
    } else { $c.gameMode.tvPath = ''; $c.gameMode.tvName = '' }
    $c.gameMode.audioName = $(if ($Ctl.CbTvAudio.SelectedItem) { [string]$Ctl.CbTvAudio.SelectedItem.Tag } else { '' })
    $c.gameMode.tvPrimary = [bool]$Ctl.CkPrimary.IsChecked
    $c.gameMode.bigPicture = [bool]$Ctl.CkBigPicture.IsChecked
    $c.gameMode.closeGameOnOff = [bool]$Ctl.CkCloseGame.IsChecked

    $c.computer.powerOff = $App.PowerOff
    $c.computer.volumeStep = $step
    $c.computer.inputs = @($inputs)
    $c.channels = @($channels | Sort-Object number)
    return $null
}

function Save-Form {
    $err = Read-Form
    if ($err) { Show-Toast $err '#FF3B5C'; Set-Msg $err '#FF3B5C'; return $false }
    if ($Demo) { Set-Dirty $false; Show-Toast 'modo demo: nada foi salvo' '#F5FF3B'; return $true }
    try { Save-ApcConfig $App.Cfg $ConfigPath }
    catch { Show-Toast ('não deu pra salvar: ' + $_.Exception.Message) '#FF3B5C'; return $false }
    if ($Ctl.PbSecret.Password) { $App.Data.HasSecret = $true }
    $App.Loading = $true; $Ctl.PbSecret.Password = ''; $App.Loading = $false
    Update-SecretHint
    Set-Dirty $false
    $missing = Get-ApcMissingSetup $App.Cfg
    if ($missing) { Set-Msg ('salvo. ' + $missing) '#F5FF3B' } else { Set-Msg 'salvo. o agente recarrega a configuração em até 5 s.' '#00F0FF' }
    Show-Toast 'configuração salva' '#00F0FF'
    return $true
}

function Start-GameModeTest([string]$Which) {
    if ($Demo) { Show-Toast 'modo demo: nada foi executado' '#F5FF3B'; return }
    if ($App.Dirty) { [void][Windows.MessageBox]::Show('Salve as alterações antes de testar: o teste usa a configuração salva.', 'Alexa PC Control', 'OK', 'Information'); return }
    if (-not $App.Cfg.gameMode.tvPath -and -not $App.Cfg.gameMode.tvName) { Show-Toast 'escolha a tela da TV e salve antes' '#F5FF3B'; return }
    Start-Process -FilePath $PowerShell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $AgentPath + '"'), '-Action', $Which)
    if ($Which -eq 'GameModeOn') { Show-Toast 'ligando o modo jogo...' '#00F0FF' } else { Show-Toast 'desligando o modo jogo...' '#FF2BD6' }
}

# ---------------------------------------------------------------- events

$Ctl.TitleBar.Add_MouseLeftButtonDown({ try { $Window.DragMove() } catch { } })
$Ctl.BtnMin.Add_Click({ $Window.WindowState = 'Minimized' })
$Ctl.BtnClose.Add_Click({ $Window.Close() })
$Window.Add_Closing({
    if ($App.Dirty -and -not $App.Closing) {
        $r = [Windows.MessageBox]::Show('Tem alterações não salvas. Salvar antes de sair?', 'Alexa PC Control', 'YesNoCancel', 'Question')
        if ($r -eq 'Cancel') { $args[1].Cancel = $true; return }
        if ($r -eq 'Yes' -and -not (Save-Form)) { $args[1].Cancel = $true; return }
    }
    $App.Closing = $true
})

$Ctl.BtnPortal.Add_Click({ Start-Process 'https://portal.sinric.pro' })
$Ctl.BtnLog.Add_Click({
    if ($Demo) { Show-Toast 'modo demo: sem log' '#F5FF3B'; return }
    if (Test-Path $LogPath) { Start-Process notepad.exe -ArgumentList ('"' + $LogPath + '"') } else { Show-Toast 'o agente ainda não escreveu nenhum log' '#F5FF3B' }
})
$Ctl.BtnStart.Add_Click({
    if ($Demo) { return }
    try {
        Start-ScheduledTask -TaskPath '\AlexaPcControl\' -TaskName 'Agente' -ErrorAction Stop
        Show-Toast 'iniciando o agente...' '#00F0FF'
    } catch { Show-Toast 'tarefa do agente não encontrada: rode o Instalar.bat de novo' '#FF3B5C' }
})
$Ctl.BtnSave.Add_Click({ [void](Save-Form) })
$Ctl.BtnTestOn.Add_Click({ Start-GameModeTest 'GameModeOn' })
$Ctl.BtnTestOff.Add_Click({ Start-GameModeTest 'GameModeOff' })
$Ctl.BtnAddInput.Add_Click({ Add-InputRow '' ''; Set-Dirty $true })
$Ctl.BtnAddChannel.Add_Click({
    $next = 1
    foreach ($r in $App.ChannelRows) { $n = 0; if ([int]::TryParse($r.Number.Text, [ref]$n) -and $n -ge $next) { $next = $n + 1 } }
    $row = Add-ChannelRow $next '' '' ''
    Set-Dirty $true
    $Window.UpdateLayout()
    $row.Grid.BringIntoView()
    $row.Game.IsDropDownOpen = $true
})

foreach ($tb in @($Ctl.TbAppKey, $Ctl.TbDevGame, $Ctl.TbDevComputer, $Ctl.TbDevInvisible, $Ctl.TbVolStep)) { $tb.Add_TextChanged({ Set-Dirty $true }) }
$Ctl.PbSecret.Add_PasswordChanged({ Update-SecretHint; Set-Dirty $true })
foreach ($cb in @($Ctl.CbTv, $Ctl.CbTvAudio)) { $cb.Add_SelectionChanged({ Set-Dirty $true }) }
foreach ($ck in @($Ctl.CkPrimary, $Ctl.CkBigPicture, $Ctl.CkCloseGame)) { $ck.Add_Checked({ Set-Dirty $true }); $ck.Add_Unchecked({ Set-Dirty $true }) }

foreach ($p in $PowerOffs) {
    $chip = New-Chip $PowerOffPt[$p] $p '#00F0FF'
    $chip.Add_Click({ $App.PowerOff = $this.Tag; Update-PowerChips; Set-Dirty $true })
    [void]$Ctl.PowerPanel.Children.Add($chip)
}

$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromSeconds(1)
$Timer.Add_Tick({
    $App.Tick++
    $Ctl.Clock.Text = (Get-Date).ToString('HH:mm:ss')
    if ($App.Tick % 2 -eq 0) { Update-Status }
    if ($App.ToastUntil -and (Get-Date) -gt $App.ToastUntil) { $App.ToastUntil = $null; $Ctl.Toast.Visibility = 'Collapsed' }
})

Load-Form
Update-Status
$Ctl.Clock.Text = (Get-Date).ToString('HH:mm:ss')
$missing = Get-ApcMissingSetup $App.Cfg
if ($Demo) { $missing = $null }
if ($missing) { Set-Msg ('pra começar: ' + $missing.Substring(0, 1).ToLower() + $missing.Substring(1)) '#F5FF3B' } else { Set-Msg 'o agente recarrega a configuração sozinho depois de salvar.' }
$Timer.Start()
$Window.Add_ContentRendered({
    [void]$Window.Dispatcher.BeginInvoke([Action]{ $App.Loading = $false; Set-Dirty $false }, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
})

if ($Screenshot) {
    # render off-screen, without stealing focus
    $Window.WindowStartupLocation = 'Manual'; $Window.Left = -6000; $Window.Top = 0; $Window.ShowActivated = $false; $Window.ShowInTaskbar = $false
    $shot = New-Object Windows.Threading.DispatcherTimer
    $shot.Interval = [TimeSpan]::FromMilliseconds($ScreenshotDelayMs)
    $shot.Add_Tick({
        $shot.Stop()
        $root = $Ctl.Root
        $wd = [int]$root.ActualWidth + 32; $ht = [int]$root.ActualHeight + 32
        $rtb = [Windows.Media.Imaging.RenderTargetBitmap]::new($wd, $ht, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $dv = New-Object Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.DrawRectangle([Windows.Media.Brushes]::Black, $null, [Windows.Rect]::new(0, 0, $wd, $ht))
        $dc.DrawRectangle([Windows.Media.VisualBrush]::new($root), $null, [Windows.Rect]::new(16, 16, $root.ActualWidth, $root.ActualHeight))
        $dc.Close()
        $rtb.Render($dv)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Open($Screenshot, 'Create'); $enc.Save($fs); $fs.Close()
        $App.Dirty = $false; $App.Closing = $true
        $Window.Close()
    })
    $shot.Start()
}

[void]$Window.ShowDialog()
