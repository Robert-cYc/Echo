<#
.SYNOPSIS
    Fluent Network Sentinel - Windows 11 Fluent UI 即時網路狀態監控工具 (走勢圖 + 系統匣強化版)
.DESCRIPTION
    PowerShell + WPF 設計的 Windows 11 Fluent UI 網路連線監控程式。
    - 即時延遲走勢迷你圖 (Sparkline) 與網路抖動率 (Jitter) 計算
    - 採用專屬繪製之 16x16 高對比系統匣圖示 (綠/紅/灰動態指示燈號)
    - 採用 WPF Application 獨立訊息迴圈，視窗縮小或關閉時完美常駐於系統匣
    - 支援 Windows 11 原生彈窗通知 (Toast/Balloon)
    - 支援中英文即時動態雙語切換 (繁體中文 / English)
    - 先自動偵測目前作用中的網路介面與網段 (Subnet / Gateway / Local IP)
    - 自動提取當前網段內的閘道、活躍鄰近設備與本機 IP 進行並行 Ping 監控
    - 4 組目標同步即時監控，滿 100 筆自動清除日誌
#>

param(
    [switch]$Startup
)

# 1. 載入 WPF、Windows Forms 與系統繪圖組件
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing, System.Windows.Forms

# 2. 定義非同步 Ping 與 DWM 視窗修飾 C# 類別 (相容 .NET Framework 與 PowerShell 5.1/7+)
$csharpSource = @"
#pragma warning disable 4014
using System;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

public static class DwmHelper {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    public static void ApplyFluentStyling(IntPtr hwnd) {
        try {
            int trueVal = 1;
            // 啟用 Windows 11 深色標題列 (DWMWA_USE_IMMERSIVE_DARK_MODE = 20，舊版 Win10 為 19)
            if (DwmSetWindowAttribute(hwnd, 20, ref trueVal, sizeof(int)) != 0) {
                DwmSetWindowAttribute(hwnd, 19, ref trueVal, sizeof(int));
            }
            // 視窗圓角設定 (DWMWA_WINDOW_CORNER_PREFERENCE = 33, 2 = DWMWCP_ROUND)
            int roundVal = 2;
            DwmSetWindowAttribute(hwnd, 33, ref roundVal, sizeof(int));
        } catch { }
    }
}

public class PingResult {
    public string TargetId { get; set; }
    public string Target { get; set; }
    public string Category { get; set; }
    public bool Success { get; set; }
    public long RoundtripTime { get; set; }
    public string Status { get; set; }
    public DateTime Timestamp { get; set; }
}

public class FastPinger {
    public static async Task<PingResult> PingOnceAsync(string targetId, string target, string category, int timeout) {
        PingResult res = new PingResult();
        res.TargetId = targetId;
        res.Target = target;
        res.Category = category;
        res.Timestamp = DateTime.Now;
        if (string.IsNullOrWhiteSpace(target)) {
            res.Success = false;
            res.RoundtripTime = -1;
            res.Status = "Empty Target";
            return res;
        }
        try {
            using (Ping ping = new Ping()) {
                PingReply reply = await ping.SendPingAsync(target.Trim(), timeout);
                res.Success = (reply.Status == IPStatus.Success);
                res.RoundtripTime = reply.RoundtripTime;
                res.Status = reply.Status.ToString();
            }
        } catch (Exception ex) {
            res.Success = false;
            res.RoundtripTime = -1;
            res.Status = ex.InnerException != null ? ex.InnerException.Message : ex.Message;
        }
        return res;
    }
}

public class PingMonitorRunner {
    private CancellationTokenSource _cts;
    private readonly object _lock = new object();
    private string _internetTarget = "www.google.com";
    private string _localTarget1 = "192.168.1.1";
    private string _localTarget2 = "192.168.1.2";
    private string _localTarget3 = "8.8.8.8";

    public string InternetTarget {
        get { lock(_lock) { return _internetTarget; } }
        set { lock(_lock) { _internetTarget = value; } }
    }
    public string LocalTarget1 {
        get { lock(_lock) { return _localTarget1; } }
        set { lock(_lock) { _localTarget1 = value; } }
    }
    public string LocalTarget2 {
        get { lock(_lock) { return _localTarget2; } }
        set { lock(_lock) { _localTarget2 = value; } }
    }
    public string LocalTarget3 {
        get { lock(_lock) { return _localTarget3; } }
        set { lock(_lock) { _localTarget3 = value; } }
    }

    public int IntervalMs { get; set; }
    public bool IsRunning { get; private set; }

    public event Action<PingResult> OnPingResult;

    public PingMonitorRunner() {
        IntervalMs = 1000;
        IsRunning = false;
    }

    public void Start(Dispatcher dispatcher) {
        if (IsRunning) return;
        IsRunning = true;
        _cts = new CancellationTokenSource();
        CancellationToken token = _cts.Token;

        Task.Run(async () => {
            while (!token.IsCancellationRequested) {
                string t0 = InternetTarget;
                string t1 = LocalTarget1;
                string t2 = LocalTarget2;
                string t3 = LocalTarget3;

                Task<PingResult> task0 = FastPinger.PingOnceAsync("Google", t0, "Internet", 1500);
                Task<PingResult> task1 = FastPinger.PingOnceAsync("Local1", t1, "Local", 1500);
                Task<PingResult> task2 = FastPinger.PingOnceAsync("Local2", t2, "Local", 1500);
                Task<PingResult> task3 = FastPinger.PingOnceAsync("Local3", t3, "Local", 1500);

                await Task.WhenAll(task0, task1, task2, task3);

                if (!token.IsCancellationRequested && dispatcher != null && !dispatcher.HasShutdownStarted) {
                    dispatcher.BeginInvoke(new Action(() => {
                        try {
                            if (OnPingResult != null) {
                                OnPingResult(task0.Result);
                                OnPingResult(task1.Result);
                                OnPingResult(task2.Result);
                                OnPingResult(task3.Result);
                            }
                        } catch { }
                    }));
                }

                try {
                    await Task.Delay(IntervalMs, token);
                } catch (TaskCanceledException) {
                    break;
                }
            }
            IsRunning = false;
        }, token);
    }

    public void Stop() {
        if (_cts != null) {
            _cts.Cancel();
        }
        IsRunning = false;
    }
}
"@

Add-Type -TypeDefinition $csharpSource -ReferencedAssemblies "PresentationFramework", "WindowsBase", "System"

# 3. 智慧網段偵測函式
function Get-CurrentSubnetInfo {
    $info = [PSCustomObject]@{
        InterfaceName = "Wi-Fi / Ethernet"
        LocalIP       = "192.168.1.100"
        Gateway       = "192.168.1.1"
        PrefixLength  = 24
        Subnet        = "192.168.1.0/24"
        Target1       = "192.168.1.1"
        Target2       = "192.168.1.2"
        Target3       = "192.168.1.254"
        Target2Desc   = "網段設備"
        Target3Desc   = "本機網卡"
    }

    try {
        $netConfig = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
        if ($netConfig) {
            $info.InterfaceName = $netConfig.InterfaceAlias
            $ipObj = $netConfig.IPv4Address | Select-Object -First 1
            if ($ipObj) {
                $info.LocalIP = $ipObj.IPAddress
            }
            $gwObj = $netConfig.IPv4DefaultGateway | Select-Object -First 1
            if ($gwObj) {
                $info.Gateway = $gwObj.NextHop
            }

            $netIP = Get-NetIPAddress -InterfaceIndex $netConfig.InterfaceIndex -AddressFamily IPv4 | Where-Object { $_.IPAddress -eq $info.LocalIP } | Select-Object -First 1
            if ($netIP) {
                $info.PrefixLength = $netIP.PrefixLength
            }

            $ipParts = $info.LocalIP.Split('.')
            if ($ipParts.Count -eq 4) {
                $prefix3 = "$($ipParts[0]).$($ipParts[1]).$($ipParts[2])"
                $info.Subnet = "$prefix3.0/$($info.PrefixLength)"
                $info.Target1 = $info.Gateway

                $neighbors = Get-NetNeighbor -InterfaceIndex $netConfig.InterfaceIndex -AddressFamily IPv4 -State Reachable -ErrorAction SilentlyContinue |
                             Where-Object { 
                                 $_.IPAddress -ne $info.Gateway -and 
                                 $_.IPAddress -ne $info.LocalIP -and 
                                 $_.IPAddress -notmatch '^(224\.|239\.|255\.|127\.|169\.254\.)' -and
                                 $_.IPAddress.StartsWith("$prefix3.")
                             }

                $activeNeighbor = ($neighbors | Select-Object -First 1).IPAddress
                if ($activeNeighbor) {
                    $info.Target2 = $activeNeighbor
                    $info.Target2Desc = "網段活躍設備"
                } else {
                    $info.Target2 = "$prefix3.2"
                    $info.Target2Desc = "網段主機 #2"
                }

                if ($info.LocalIP -and $info.LocalIP -ne $info.Target1 -and $info.LocalIP -ne $info.Target2) {
                    $info.Target3 = $info.LocalIP
                    $info.Target3Desc = "本機實體 IP"
                } else {
                    $info.Target3 = "$prefix3.254"
                    $info.Target3Desc = "網段主機 #3"
                }
            }
        }
    } catch { }

    return $info
}

# 執行初次網段偵測
$detectedSubnet = Get-CurrentSubnetInfo

# 4. Windows 11 Fluent UI XAML 定義
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Network Sentinel - Fluent Network Monitor"
        Height="900" Width="860" MinHeight="750" MinWidth="820"
        WindowStartupLocation="CenterScreen"
        Background="#181818"
        Foreground="#EDEDED"
        FontFamily="Segoe UI Variable Text, Segoe UI, Microsoft JhengHei UI">
    
    <Window.Resources>
        <!-- Modern Button Style -->
        <Style x:Key="FluentButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="#2D2D2D"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="#3D3D3D"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="11,4"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" 
                                BorderBrush="{TemplateBinding BorderBrush}" 
                                BorderThickness="{TemplateBinding BorderThickness}" 
                                CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#383838"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#4C4C4C"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#222222"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Opacity" Value="0.5"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Accent Button Style -->
        <Style x:Key="AccentButtonStyle" TargetType="Button" BasedOn="{StaticResource FluentButtonStyle}">
            <Setter Property="Background" Value="#0078D4"/>
            <Setter Property="BorderBrush" Value="#1084D9"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" 
                                BorderBrush="{TemplateBinding BorderBrush}" 
                                BorderThickness="{TemplateBinding BorderThickness}" 
                                CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1A86D9"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#006CBE"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Modern TextBox Style -->
        <Style x:Key="FluentTextBoxStyle" TargetType="TextBox">
            <Setter Property="Background" Value="#232323"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="#3E3E3E"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="CaretBrush" Value="#60CDFF"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="border" Background="{TemplateBinding Background}" 
                                BorderBrush="{TemplateBinding BorderBrush}" 
                                BorderThickness="{TemplateBinding BorderThickness}" 
                                CornerRadius="4">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#555555"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#60CDFF"/>
                                <Setter TargetName="border" Property="BorderThickness" Value="1.5"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Dark Fluent ComboBoxItem Style (黑底白字) -->
        <Style x:Key="FluentComboBoxItemStyle" TargetType="ComboBoxItem">
            <Setter Property="Background" Value="#1E1E1E"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="itemBorder" Background="{TemplateBinding Background}" 
                                Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="itemBorder" Property="Background" Value="#333333"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="itemBorder" Property="Background" Value="#0078D4"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ToggleButton for ComboBox -->
        <ControlTemplate x:Key="ComboBoxToggleButtonTemplate" TargetType="ToggleButton">
            <Border x:Name="templateRoot" Background="#1E1E1E" BorderBrush="#3D3D3D" BorderThickness="1" CornerRadius="4">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="24"/>
                    </Grid.ColumnDefinitions>
                    <Path x:Name="arrow" Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center"
                          Data="M 0 0 L 4 4 L 8 0 Z" Fill="#D0D0D0"/>
                </Grid>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter TargetName="templateRoot" Property="Background" Value="#2A2A2A"/>
                    <Setter TargetName="templateRoot" Property="BorderBrush" Value="#555555"/>
                    <Setter TargetName="arrow" Property="Fill" Value="#FFFFFF"/>
                </Trigger>
                <Trigger Property="IsChecked" Value="True">
                    <Setter TargetName="templateRoot" Property="Background" Value="#252525"/>
                    <Setter TargetName="templateRoot" Property="BorderBrush" Value="#60CDFF"/>
                </Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate>

        <!-- Dark Fluent ComboBox Style -->
        <Style x:Key="FluentComboBoxStyle" TargetType="ComboBox">
            <Setter Property="Background" Value="#1E1E1E"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="#3D3D3D"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="ItemContainerStyle" Value="{StaticResource FluentComboBoxItemStyle}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid x:Name="templateRoot">
                            <ToggleButton x:Name="toggleButton"
                                          Template="{StaticResource ComboBoxToggleButtonTemplate}"
                                          Focusable="false"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
                            <ContentPresenter x:Name="contentPresenter"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                                              Margin="10,4,26,4"
                                              HorizontalAlignment="Left"
                                              VerticalAlignment="Center"
                                              IsHitTestVisible="false"/>
                            <Popup x:Name="PART_Popup"
                                   AllowsTransparency="true"
                                   IsOpen="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                   Placement="Bottom"
                                   PopupAnimation="Slide">
                                <Border x:Name="dropDownBorder"
                                        Background="#1C1C1C"
                                        BorderBrush="#3D3D3D"
                                        BorderThickness="1"
                                        CornerRadius="4"
                                        MinWidth="{Binding ActualWidth, ElementName=templateRoot}"
                                        MaxHeight="220"
                                        Margin="0,2,0,0">
                                    <ScrollViewer x:Name="DropDownScrollViewer">
                                        <Grid x:Name="grid" RenderOptions.ClearTypeHint="Enabled">
                                            <Canvas x:Name="canvas" HorizontalAlignment="Left" Height="0" VerticalAlignment="Top" Width="0">
                                                <Rectangle x:Name="opaqueRect"
                                                           Fill="#1C1C1C"
                                                           Height="{Binding ActualHeight, ElementName=dropDownBorder}"
                                                           Width="{Binding ActualWidth, ElementName=dropDownBorder}"/>
                                            </Canvas>
                                            <ItemsPresenter x:Name="ItemsPresenter" KeyboardNavigation.DirectionalNavigation="Contained"/>
                                        </Grid>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Modern Dark ToolTip Style -->
        <Style TargetType="ToolTip">
            <Setter Property="Background" Value="#202020"/>
            <Setter Property="Foreground" Value="#F0F0F0"/>
            <Setter Property="BorderBrush" Value="#404040"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI, Microsoft JhengHei UI"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToolTip">
                        <Border Background="#202020" BorderBrush="#404040" BorderThickness="1" CornerRadius="6" Padding="14,12" SnapsToDevicePixels="True" TextBlock.Foreground="#F0F0F0" TextBlock.FontSize="12">
                            <Border.Effect>
                                <DropShadowEffect BlurRadius="12" ShadowDepth="2" Opacity="0.6" Color="#000000"/>
                            </Border.Effect>
                            <ContentPresenter/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/> <!-- 0: Header -->
            <RowDefinition Height="Auto"/> <!-- 1: Controls Toolbar -->
            <RowDefinition Height="Auto"/> <!-- 2: Subnet Information Banner -->
            <RowDefinition Height="*"/>    <!-- 3: Cards Area (ScrollViewer) -->
            <RowDefinition Height="165"/>  <!-- 4: Activity Feed -->
        </Grid.RowDefinitions>

        <!-- 0: Header -->
        <Grid Grid.Row="0" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="⚡" FontSize="20" Margin="0,0,8,0" VerticalAlignment="Center" Foreground="#60CDFF"/>
                    <TextBlock Text="Network Sentinel" FontSize="19" FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"/>
                </StackPanel>
                <TextBlock x:Name="TxtHeaderSubtitle" Text="智慧分析目前網段，同步即時監控外部網際網路 (Google) 與 3 組同網段設備 IP" FontSize="12" Foreground="#8E8E8E" Margin="28,2,0,0"/>
            </StackPanel>

            <!-- Overall Status Badge -->
            <Border x:Name="OverallBadge" Grid.Column="1" Background="#163821" BorderBrush="#256938" BorderThickness="1" CornerRadius="14" Padding="12,5" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Ellipse x:Name="OverallDot" Width="8" Height="8" Fill="#4CC2FF" Margin="0,0,8,0"/>
                    <TextBlock x:Name="OverallText" Text="MONITORING ACTIVE (4 TARGETS)" FontSize="11" FontWeight="Bold" Foreground="#D0EEFF"/>
                </StackPanel>
            </Border>
        </Grid>

        <!-- 1: Controls Toolbar (含中英文切換與系統匣控制) -->
        <Border Grid.Row="1" Background="#202020" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="6" Padding="12,6" Margin="0,0,0,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <!-- Interval -->
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,12,0">
                    <TextBlock x:Name="TxtIntervalLabel" Text="偵測間隔:" VerticalAlignment="Center" FontSize="12" Foreground="#B0B0B0" Margin="0,0,6,0"/>
                    <ComboBox x:Name="CmbInterval" Style="{StaticResource FluentComboBoxStyle}" SelectedIndex="0" Width="120" Height="28">
                        <ComboBoxItem x:Name="CmbItem1" Content="1 秒 (1000ms)" Tag="1000"/>
                        <ComboBoxItem x:Name="CmbItem2" Content="2 秒 (2000ms)" Tag="2000"/>
                        <ComboBoxItem x:Name="CmbItem3" Content="3 秒 (3000ms)" Tag="3000"/>
                        <ComboBoxItem x:Name="CmbItem5" Content="5 秒 (5000ms)" Tag="5000"/>
                    </ComboBox>
                </StackPanel>

                <!-- Sound Alert -->
                <CheckBox x:Name="ChkSoundAlert" Grid.Column="1" Content="斷線警報音效" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,10,0" Cursor="Hand"/>

                <!-- Min to Tray Checkbox -->
                <CheckBox x:Name="ChkMinToTray" Grid.Column="2" Content="關閉時縮小至系統匣" IsChecked="True" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,10,0" Cursor="Hand"/>

                <!-- Auto Start Checkbox -->
                <CheckBox x:Name="ChkAutoStart" Grid.Column="3" Content="開機自動啟動" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,10,0" Cursor="Hand"/>

                <!-- Right Action Buttons -->
                <StackPanel Grid.Column="5" Orientation="Horizontal">
                    <Button x:Name="BtnMinimizeTray" Content="📥 縮至系統匣" Style="{StaticResource FluentButtonStyle}" Margin="0,0,6,0" Padding="8,3"/>
                    <Button x:Name="BtnToggleLang" Content="🌐 English" Style="{StaticResource FluentButtonStyle}" Margin="0,0,6,0" Padding="8,3"/>
                    <Button x:Name="BtnPauseResume" Content="暫停偵測" Style="{StaticResource FluentButtonStyle}" Margin="0,0,6,0" Padding="8,3"/>
                    <Button x:Name="BtnResetStats" Content="重置統計" Style="{StaticResource FluentButtonStyle}" Padding="8,3"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- 2: 目前網段資訊橫幅 -->
        <Border Grid.Row="2" Background="#1A2838" BorderBrush="#26486D" BorderThickness="1" CornerRadius="6" Padding="12,6" Margin="0,0,0,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,16,0">
                    <TextBlock Text="🔍" FontSize="13" Margin="0,0,6,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtSubnetLabel" Text="目前網路網段:" FontSize="12" FontWeight="SemiBold" Foreground="#60CDFF" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtSubnetInfo" Text="192.168.1.0/24 (Wi-Fi)" FontSize="12" FontWeight="Bold" Foreground="#FFFFFF" Margin="6,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>

                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock x:Name="TxtLocalHostLabel" Text="本機 IP:" FontSize="11" Foreground="#999999" Margin="0,0,4,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtLocalHostIP" Text="192.168.1.227" FontSize="11" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,0,14,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtGatewayLabel" Text="預設閘道:" FontSize="11" Foreground="#999999" Margin="0,0,4,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtGatewayIP" Text="192.168.1.1" FontSize="11" FontWeight="SemiBold" Foreground="#E0E0E0" VerticalAlignment="Center"/>
                </StackPanel>

                <Button x:Name="BtnRedetectSubnet" Grid.Column="2" Content="🔄 重新辨識網段" Style="{StaticResource FluentButtonStyle}" Padding="10,2" FontSize="11"/>
            </Grid>
        </Border>

        <!-- 3: Cards Area (含 Sparkline 走勢圖) -->
        <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto" Margin="0,0,0,8" Padding="0,0,6,0">
            <StackPanel>
                <!-- Card 0: Internet (Google) -->
                <Border Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="14,9" Margin="0,0,0,9">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Header -->
                        <Grid Grid.Row="0" Margin="0,0,0,6">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Width="30" Height="30" CornerRadius="6" Background="#162E44" Margin="0,0,10,0">
                                <TextBlock Text="🌐" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>

                            <StackPanel Grid.Column="1" VerticalAlignment="Center">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock x:Name="TxtInternetTitle" Text="網際網路 (Internet)" FontSize="13.5" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                                    <Border Background="#1C2F20" BorderBrush="#2F5C37" BorderThickness="1" CornerRadius="4" Margin="8,0,0,0" Padding="5,1">
                                        <TextBlock Text="WAN" FontSize="9" FontWeight="Bold" Foreground="#6CCB5F"/>
                                    </Border>
                                </StackPanel>
                                <TextBlock x:Name="TxtInternetSubtitle" Text="目標主機: www.google.com" FontSize="11" Foreground="#8A8A8A"/>
                            </StackPanel>

                            <Border x:Name="GoogleStatusPill" Grid.Column="3" Background="#163821" BorderBrush="#256938" BorderThickness="1" CornerRadius="10" Padding="10,3" VerticalAlignment="Center">
                                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                    <Ellipse x:Name="GoogleStatusDot" Width="7" Height="7" Fill="#52C41A" Margin="0,0,6,0"/>
                                    <TextBlock x:Name="GoogleStatusText" Text="連線正常 (ONLINE)" FontSize="11" FontWeight="SemiBold" Foreground="#6CCB5F"/>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Metrics Grid -->
                        <Grid Grid.Row="1">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="130"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Background="#1D1D1D" CornerRadius="5" Padding="10,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLatency0" Text="目前延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleLatency" Text="-- ms" FontSize="17" FontWeight="Bold" Foreground="#60CDFF" Margin="0,1,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="5" Padding="8,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblAvg0" Text="平均延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleAvg" Text="-- ms" FontSize="12.5" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="5" Padding="8,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblMinMax0" Text="最小 / 最大" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleMinMax" Text="-- / --" FontSize="11.5" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="5" Padding="8,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLoss0" Text="遺失率 (Lost/Total)" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleLoss" Text="0.0% (0/0)" FontSize="11.5" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="5" Padding="8,5">
                                <StackPanel>
                                    <TextBlock x:Name="LblLastSeen0" Text="最後回應時間" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleLastSeen" Text="等待回應..." FontSize="11" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Sparkline Mini Graph -->
                        <Grid x:Name="GridSparkline0" Grid.Row="2" Margin="0,6,0,0" ToolTipService.ShowDuration="60000" ToolTipService.InitialShowDelay="150">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <TextBlock x:Name="LblSparkline0" Text="即時波動走勢 (最近 300 次):" FontSize="10" Foreground="#777777" VerticalAlignment="Center" Margin="0,0,8,0"/>

                            <Border x:Name="BorderSparkline0" Grid.Column="1" Background="#171717" BorderBrush="#2A2A2A" BorderThickness="1" CornerRadius="4" Height="24" ClipToBounds="True">
                                <Canvas x:Name="CanvasSparkline0" Height="24" ClipToBounds="True">
                                    <Polygon x:Name="FillSparkline0" Fill="#184CC2FF" StrokeThickness="0"/>
                                    <Polyline x:Name="LineSparkline0" Stroke="#60CDFF" StrokeThickness="1.5"/>
                                </Canvas>
                            </Border>

                            <TextBlock x:Name="TxtJitter0" Grid.Column="2" Text="抖動: -- ms" FontSize="10.5" Foreground="#8E8E8E" VerticalAlignment="Center" Margin="8,0,0,0"/>
                        </Grid>
                    </Grid>
                </Border>

                <!-- Card 1: Local Target 1 (Gateway / 路由器) -->
                <Border Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="14,9" Margin="0,0,0,9">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Header & Input Bar -->
                        <Grid Grid.Row="0" Margin="0,0,0,6">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Width="30" Height="30" CornerRadius="6" Background="#3B2614" Margin="0,0,10,0">
                                <TextBlock Text="📡" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>

                            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,12,0">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock x:Name="TxtLocalTitle1" Text="區域設備 #1 (網段預設閘道)" FontSize="13.5" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                                    <Border Background="#332414" BorderBrush="#6B491F" BorderThickness="1" CornerRadius="4" Margin="8,0,0,0" Padding="5,1">
                                        <TextBlock Text="GATEWAY" FontSize="9" FontWeight="Bold" Foreground="#FFB900"/>
                                    </Border>
                                </StackPanel>
                            </StackPanel>

                            <!-- Inline IP Input -->
                            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                                <TextBlock x:Name="TxtLocalIPLabel1" Text="目標 IP:" FontSize="12" Foreground="#A0A0A0" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                <TextBox x:Name="TxtLocalIP1" Width="135" Text="192.168.1.1" Style="{StaticResource FluentTextBoxStyle}" Margin="0,0,6,0"/>
                                <Button x:Name="BtnApplyIP1" Content="套用" Style="{StaticResource AccentButtonStyle}" Padding="10,3"/>
                            </StackPanel>

                            <Border x:Name="LocalStatusPill1" Grid.Column="3" Background="#163821" BorderBrush="#256938" BorderThickness="1" CornerRadius="10" Padding="10,3" VerticalAlignment="Center">
                                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                    <Ellipse x:Name="LocalStatusDot1" Width="7" Height="7" Fill="#52C41A" Margin="0,0,6,0"/>
                                    <TextBlock x:Name="LocalStatusText1" Text="連線正常 (ONLINE)" FontSize="11" FontWeight="SemiBold" Foreground="#6CCB5F"/>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Metrics Grid -->
                        <Grid Grid.Row="1">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="130"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Background="#1D1D1D" CornerRadius="5" Padding="10,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLatency1" Text="目前延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLatency1" Text="-- ms" FontSize="17" FontWeight="Bold" Foreground="#60CDFF" Margin="0,1,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="5" Padding="8,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblAvg1" Text="平均延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalAvg1" Text="-- ms" FontSize="12.5" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="5" Padding="8,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblMinMax1" Text="最小 / 最大" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalMinMax1" Text="-- / --" FontSize="11.5" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="5" Padding="8,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLoss1" Text="遺失率 (Lost/Total)" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLoss1" Text="0.0% (0/0)" FontSize="11.5" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="5" Padding="8,5">
                                <StackPanel>
                                    <TextBlock x:Name="LblLastSeen1" Text="最後回應時間" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLastSeen1" Text="等待回應..." FontSize="11" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Sparkline Mini Graph -->
                        <Grid x:Name="GridSparkline1" Grid.Row="2" Margin="0,6,0,0" ToolTipService.ShowDuration="60000" ToolTipService.InitialShowDelay="150">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <TextBlock x:Name="LblSparkline1" Text="即時波動走勢 (最近 300 次):" FontSize="10" Foreground="#777777" VerticalAlignment="Center" Margin="0,0,8,0"/>

                            <Border x:Name="BorderSparkline1" Grid.Column="1" Background="#171717" BorderBrush="#2A2A2A" BorderThickness="1" CornerRadius="4" Height="24" ClipToBounds="True">
                                <Canvas x:Name="CanvasSparkline1" Height="24" ClipToBounds="True">
                                    <Polygon x:Name="FillSparkline1" Fill="#184CC2FF" StrokeThickness="0"/>
                                    <Polyline x:Name="LineSparkline1" Stroke="#60CDFF" StrokeThickness="1.5"/>
                                </Canvas>
                            </Border>

                            <TextBlock x:Name="TxtJitter1" Grid.Column="2" Text="抖動: -- ms" FontSize="10.5" Foreground="#8E8E8E" VerticalAlignment="Center" Margin="8,0,0,0"/>
                        </Grid>
                    </Grid>
                </Border>

                <!-- Card 2: Local Target 2 (網段活躍設備) -->
                <Border Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="14,9" Margin="0,0,0,9">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Header & Input Bar -->
                        <Grid Grid.Row="0" Margin="0,0,0,6">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Width="30" Height="30" CornerRadius="6" Background="#262D42" Margin="0,0,10,0">
                                <TextBlock Text="💻" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>

                            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,12,0">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock x:Name="TxtLocalTitle2" Text="區域設備 #2 (網段活躍設備)" FontSize="13.5" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                                    <Border Background="#1C263A" BorderBrush="#2D4370" BorderThickness="1" CornerRadius="4" Margin="8,0,0,0" Padding="5,1">
                                        <TextBlock Text="SUBNET #2" FontSize="9" FontWeight="Bold" Foreground="#4CC2FF"/>
                                    </Border>
                                </StackPanel>
                            </StackPanel>

                            <!-- Inline IP Input -->
                            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                                <TextBlock x:Name="TxtLocalIPLabel2" Text="目標 IP:" FontSize="12" Foreground="#A0A0A0" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                <TextBox x:Name="TxtLocalIP2" Width="135" Text="192.168.1.2" Style="{StaticResource FluentTextBoxStyle}" Margin="0,0,6,0"/>
                                <Button x:Name="BtnApplyIP2" Content="套用" Style="{StaticResource AccentButtonStyle}" Padding="10,3"/>
                            </StackPanel>

                            <Border x:Name="LocalStatusPill2" Grid.Column="3" Background="#163821" BorderBrush="#256938" BorderThickness="1" CornerRadius="10" Padding="10,3" VerticalAlignment="Center">
                                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                    <Ellipse x:Name="LocalStatusDot2" Width="7" Height="7" Fill="#52C41A" Margin="0,0,6,0"/>
                                    <TextBlock x:Name="LocalStatusText2" Text="連線正常 (ONLINE)" FontSize="11" FontWeight="SemiBold" Foreground="#6CCB5F"/>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Metrics Grid -->
                        <Grid Grid.Row="1">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="130"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Background="#1D1D1D" CornerRadius="5" Padding="10,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLatency2" Text="目前延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLatency2" Text="-- ms" FontSize="17" FontWeight="Bold" Foreground="#60CDFF" Margin="0,1,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="5" Padding="8,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblAvg2" Text="平均延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalAvg2" Text="-- ms" FontSize="12.5" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="5" Padding="8,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblMinMax2" Text="最小 / 最大" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalMinMax2" Text="-- / --" FontSize="11.5" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="5" Padding="8,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLoss2" Text="遺失率 (Lost/Total)" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLoss2" Text="0.0% (0/0)" FontSize="11.5" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="5" Padding="8,5">
                                <StackPanel>
                                    <TextBlock x:Name="LblLastSeen2" Text="最後回應時間" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLastSeen2" Text="等待回應..." FontSize="11" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Sparkline Mini Graph -->
                        <Grid x:Name="GridSparkline2" Grid.Row="2" Margin="0,6,0,0" ToolTipService.ShowDuration="60000" ToolTipService.InitialShowDelay="150">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <TextBlock x:Name="LblSparkline2" Text="即時波動走勢 (最近 300 次):" FontSize="10" Foreground="#777777" VerticalAlignment="Center" Margin="0,0,8,0"/>

                            <Border x:Name="BorderSparkline2" Grid.Column="1" Background="#171717" BorderBrush="#2A2A2A" BorderThickness="1" CornerRadius="4" Height="24" ClipToBounds="True">
                                <Canvas x:Name="CanvasSparkline2" Height="24" ClipToBounds="True">
                                    <Polygon x:Name="FillSparkline2" Fill="#184CC2FF" StrokeThickness="0"/>
                                    <Polyline x:Name="LineSparkline2" Stroke="#60CDFF" StrokeThickness="1.5"/>
                                </Canvas>
                            </Border>

                            <TextBlock x:Name="TxtJitter2" Grid.Column="2" Text="抖動: -- ms" FontSize="10.5" Foreground="#8E8E8E" VerticalAlignment="Center" Margin="8,0,0,0"/>
                        </Grid>
                    </Grid>
                </Border>

                <!-- Card 3: Local Target 3 (本機實體網卡 IP) -->
                <Border Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="14,9" Margin="0,0,0,4">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Header & Input Bar -->
                        <Grid Grid.Row="0" Margin="0,0,0,6">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Width="30" Height="30" CornerRadius="6" Background="#33213B" Margin="0,0,10,0">
                                <TextBlock Text="🖥️" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>

                            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,12,0">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock x:Name="TxtLocalTitle3" Text="區域設備 #3 (本機網卡實體 IP)" FontSize="13.5" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                                    <Border Background="#291A30" BorderBrush="#593269" BorderThickness="1" CornerRadius="4" Margin="8,0,0,0" Padding="5,1">
                                        <TextBlock Text="SUBNET #3" FontSize="9" FontWeight="Bold" Foreground="#D182FF"/>
                                    </Border>
                                </StackPanel>
                            </StackPanel>

                            <!-- Inline IP Input -->
                            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                                <TextBlock x:Name="TxtLocalIPLabel3" Text="目標 IP:" FontSize="12" Foreground="#A0A0A0" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                <TextBox x:Name="TxtLocalIP3" Width="135" Text="192.168.1.227" Style="{StaticResource FluentTextBoxStyle}" Margin="0,0,6,0"/>
                                <Button x:Name="BtnApplyIP3" Content="套用" Style="{StaticResource AccentButtonStyle}" Padding="10,3"/>
                            </StackPanel>

                            <Border x:Name="LocalStatusPill3" Grid.Column="3" Background="#163821" BorderBrush="#256938" BorderThickness="1" CornerRadius="10" Padding="10,3" VerticalAlignment="Center">
                                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                    <Ellipse x:Name="LocalStatusDot3" Width="7" Height="7" Fill="#52C41A" Margin="0,0,6,0"/>
                                    <TextBlock x:Name="LocalStatusText3" Text="連線正常 (ONLINE)" FontSize="11" FontWeight="SemiBold" Foreground="#6CCB5F"/>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Metrics Grid -->
                        <Grid Grid.Row="1">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="130"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Background="#1D1D1D" CornerRadius="5" Padding="10,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLatency3" Text="目前延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLatency3" Text="-- ms" FontSize="17" FontWeight="Bold" Foreground="#60CDFF" Margin="0,1,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="5" Padding="8,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblAvg3" Text="平均延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalAvg3" Text="-- ms" FontSize="12.5" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="5" Padding="8,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblMinMax3" Text="最小 / 最大" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalMinMax3" Text="-- / --" FontSize="11.5" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="5" Padding="8,5" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLoss3" Text="遺失率 (Lost/Total)" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLoss3" Text="0.0% (0/0)" FontSize="11.5" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="5" Padding="8,5">
                                <StackPanel>
                                    <TextBlock x:Name="LblLastSeen3" Text="最後回應時間" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLastSeen3" Text="等待回應..." FontSize="11" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Sparkline Mini Graph -->
                        <Grid x:Name="GridSparkline3" Grid.Row="2" Margin="0,6,0,0" ToolTipService.ShowDuration="60000" ToolTipService.InitialShowDelay="150">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <TextBlock x:Name="LblSparkline3" Text="即時波動走勢 (最近 300 次):" FontSize="10" Foreground="#777777" VerticalAlignment="Center" Margin="0,0,8,0"/>

                            <Border x:Name="BorderSparkline3" Grid.Column="1" Background="#171717" BorderBrush="#2A2A2A" BorderThickness="1" CornerRadius="4" Height="24" ClipToBounds="True">
                                <Canvas x:Name="CanvasSparkline3" Height="24" ClipToBounds="True">
                                    <Polygon x:Name="FillSparkline3" Fill="#184CC2FF" StrokeThickness="0"/>
                                    <Polyline x:Name="LineSparkline3" Stroke="#60CDFF" StrokeThickness="1.5"/>
                                </Canvas>
                            </Border>

                            <TextBlock x:Name="TxtJitter3" Grid.Column="2" Text="抖動: -- ms" FontSize="10.5" Foreground="#8E8E8E" VerticalAlignment="Center" Margin="8,0,0,0"/>
                        </Grid>
                    </Grid>
                </Border>
            </StackPanel>
        </ScrollViewer>

        <!-- 4: Activity Log -->
        <Border Grid.Row="4" Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="11">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,5">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock x:Name="TxtActivityFeedTitle" Text="📋 即時偵測日誌 (滿 100 筆自動清除)" FontSize="12" FontWeight="SemiBold" Foreground="#D0D0D0"/>
                        <TextBlock x:Name="TxtLogCounter" Text="(最新 100 筆)" FontSize="11" Foreground="#777777" Margin="6,1,0,0"/>
                    </StackPanel>

                    <Button x:Name="BtnClearLog" Grid.Column="1" Content="清除日誌" Style="{StaticResource FluentButtonStyle}" Padding="9,2" FontSize="11"/>
                </Grid>

                <Border Grid.Row="1" Background="#181818" BorderBrush="#2A2A2A" BorderThickness="1" CornerRadius="4">
                    <TextBox x:Name="TxtLog" Background="Transparent" Foreground="#A9D18E" BorderThickness="0"
                             FontFamily="Consolas, Cascadia Code, Courier New" FontSize="11.5"
                             IsReadOnly="True" VerticalScrollBarVisibility="Auto"
                             TextWrapping="NoWrap" Padding="8" AcceptsReturn="True"/>
                </Border>
            </Grid>
        </Border>

    </Grid>
</Window>
"@

# 5. 解析 XAML 生成視窗物件與控制項參照
$window = [Windows.Markup.XamlReader]::Parse($xaml)

# 載入原生高解析應用程式圖示 (工作列 / 視窗標題列 / Alt+Tab)
$icoFile = Join-Path $PSScriptRoot "NetworkSentinel.ico"
if (Test-Path $icoFile) {
    try {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([System.Uri]::new($icoFile))
    } catch { }
}

# 建立 WPF Application 以支援背景常駐與顯式關閉 (Explicit Shutdown)
$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

# 取得控制列項目
$txtHeaderSubtitle = $window.FindName("TxtHeaderSubtitle")
$cmbInterval       = $window.FindName("CmbInterval")
$cmbItem1          = $window.FindName("CmbItem1")
$cmbItem2          = $window.FindName("CmbItem2")
$cmbItem3          = $window.FindName("CmbItem3")
$cmbItem5          = $window.FindName("CmbItem5")
$txtIntervalLabel  = $window.FindName("TxtIntervalLabel")
$chkSoundAlert     = $window.FindName("ChkSoundAlert")
$chkMinToTray      = $window.FindName("ChkMinToTray")
$chkAutoStart      = $window.FindName("ChkAutoStart")
$btnMinimizeTray   = $window.FindName("BtnMinimizeTray")
$btnToggleLang     = $window.FindName("BtnToggleLang")
$btnPauseResume    = $window.FindName("BtnPauseResume")
$btnResetStats     = $window.FindName("BtnResetStats")
$btnClearLog       = $window.FindName("BtnClearLog")

$overallBadge      = $window.FindName("OverallBadge")
$overallDot        = $window.FindName("OverallDot")
$overallText       = $window.FindName("OverallText")

$txtLog            = $window.FindName("TxtLog")
$txtLogCounter     = $window.FindName("TxtLogCounter")
$txtActivityFeedTitle = $window.FindName("TxtActivityFeedTitle")

# 網段資訊橫幅控制項
$txtSubnetLabel    = $window.FindName("TxtSubnetLabel")
$txtSubnetInfo     = $window.FindName("TxtSubnetInfo")
$txtLocalHostLabel = $window.FindName("TxtLocalHostLabel")
$txtLocalHostIP    = $window.FindName("TxtLocalHostIP")
$txtGatewayLabel   = $window.FindName("TxtGatewayLabel")
$txtGatewayIP      = $window.FindName("TxtGatewayIP")
$btnRedetectSubnet = $window.FindName("BtnRedetectSubnet")

# 卡片文字控制項
$txtInternetTitle  = $window.FindName("TxtInternetTitle")
$txtInternetSubtitle= $window.FindName("TxtInternetSubtitle")

$txtLocalTitle1    = $window.FindName("TxtLocalTitle1")
$txtLocalIPLabel1  = $window.FindName("TxtLocalIPLabel1")
$txtLocalIP1       = $window.FindName("TxtLocalIP1")
$btnApplyIP1       = $window.FindName("BtnApplyIP1")

$txtLocalTitle2    = $window.FindName("TxtLocalTitle2")
$txtLocalIPLabel2  = $window.FindName("TxtLocalIPLabel2")
$txtLocalIP2       = $window.FindName("TxtLocalIP2")
$btnApplyIP2       = $window.FindName("BtnApplyIP2")

$txtLocalTitle3    = $window.FindName("TxtLocalTitle3")
$txtLocalIPLabel3  = $window.FindName("TxtLocalIPLabel3")
$txtLocalIP3       = $window.FindName("TxtLocalIP3")
$btnApplyIP3       = $window.FindName("BtnApplyIP3")

# 指標標籤列表
$latencyLabels     = @($window.FindName("LblLatency0"), $window.FindName("LblLatency1"), $window.FindName("LblLatency2"), $window.FindName("LblLatency3"))
$avgLabels         = @($window.FindName("LblAvg0"), $window.FindName("LblAvg1"), $window.FindName("LblAvg2"), $window.FindName("LblAvg3"))
$minMaxLabels      = @($window.FindName("LblMinMax0"), $window.FindName("LblMinMax1"), $window.FindName("LblMinMax2"), $window.FindName("LblMinMax3"))
$lossLabels        = @($window.FindName("LblLoss0"), $window.FindName("LblLoss1"), $window.FindName("LblLoss2"), $window.FindName("LblLoss3"))
$lastSeenLabels    = @($window.FindName("LblLastSeen0"), $window.FindName("LblLastSeen1"), $window.FindName("LblLastSeen2"), $window.FindName("LblLastSeen3"))
$sparklineLabels   = @($window.FindName("LblSparkline0"), $window.FindName("LblSparkline1"), $window.FindName("LblSparkline2"), $window.FindName("LblSparkline3"))

# 走勢圖與抖動指標元素 (供滑鼠暫留顯示 Ping / Jitter 說明 ToolTip)
$sparkElements     = @(
    $window.FindName("GridSparkline0"), $window.FindName("GridSparkline1"), $window.FindName("GridSparkline2"), $window.FindName("GridSparkline3"),
    $window.FindName("BorderSparkline0"), $window.FindName("BorderSparkline1"), $window.FindName("BorderSparkline2"), $window.FindName("BorderSparkline3"),
    $window.FindName("CanvasSparkline0"), $window.FindName("CanvasSparkline1"), $window.FindName("CanvasSparkline2"), $window.FindName("CanvasSparkline3"),
    $window.FindName("LblSparkline0"), $window.FindName("LblSparkline1"), $window.FindName("LblSparkline2"), $window.FindName("LblSparkline3"),
    $window.FindName("TxtJitter0"), $window.FindName("TxtJitter1"), $window.FindName("TxtJitter2"), $window.FindName("TxtJitter3")
)

# 套用初次偵測到的網段資訊
$txtSubnetInfo.Text  = "$($detectedSubnet.Subnet) ($($detectedSubnet.InterfaceName))"
$txtLocalHostIP.Text = $detectedSubnet.LocalIP
$txtGatewayIP.Text   = $detectedSubnet.Gateway

$txtLocalIP1.Text    = $detectedSubnet.Target1
$txtLocalIP2.Text    = $detectedSubnet.Target2
$txtLocalIP3.Text    = $detectedSubnet.Target3

# 6. 目標卡片、歷史走勢 (Sparkline) 與統計物件映射表
function New-TargetStat {
    return [PSCustomObject]@{
        Sent       = 0
        Recv       = 0
        Lost       = 0
        MinTime    = -1
        MaxTime    = -1
        TotalTime  = 0
        LastOnline = $true
    }
}

$statsMap = @{
    "Google" = New-TargetStat
    "Local1" = New-TargetStat
    "Local2" = New-TargetStat
    "Local3" = New-TargetStat
}

# 過去 300 次 Ping 歷史走勢數值佇列
$sparkHistoryMap = @{
    "Google" = [System.Collections.Generic.List[long]]::new()
    "Local1" = [System.Collections.Generic.List[long]]::new()
    "Local2" = [System.Collections.Generic.List[long]]::new()
    "Local3" = [System.Collections.Generic.List[long]]::new()
}
$maxSparkPoints = 300

$cardsMap = @{
    "Google" = @{
        Pill     = $window.FindName("GoogleStatusPill")
        Dot      = $window.FindName("GoogleStatusDot")
        Status   = $window.FindName("GoogleStatusText")
        Latency  = $window.FindName("TxtGoogleLatency")
        Avg      = $window.FindName("TxtGoogleAvg")
        MinMax   = $window.FindName("TxtGoogleMinMax")
        Loss     = $window.FindName("TxtGoogleLoss")
        LastSeen = $window.FindName("TxtGoogleLastSeen")
        Canvas   = $window.FindName("CanvasSparkline0")
        Line     = $window.FindName("LineSparkline0")
        Fill     = $window.FindName("FillSparkline0")
        Jitter   = $window.FindName("TxtJitter0")
        NameZh   = "🌐 Google"
        NameEn   = "🌐 Google"
    }
    "Local1" = @{
        Pill     = $window.FindName("LocalStatusPill1")
        Dot      = $window.FindName("LocalStatusDot1")
        Status   = $window.FindName("LocalStatusText1")
        Latency  = $window.FindName("TxtLocalLatency1")
        Avg      = $window.FindName("TxtLocalAvg1")
        MinMax   = $window.FindName("TxtLocalMinMax1")
        Loss     = $window.FindName("TxtLocalLoss1")
        LastSeen = $window.FindName("TxtLocalLastSeen1")
        Canvas   = $window.FindName("CanvasSparkline1")
        Line     = $window.FindName("LineSparkline1")
        Fill     = $window.FindName("FillSparkline1")
        Jitter   = $window.FindName("TxtJitter1")
        NameZh   = "📡 閘道 #1"
        NameEn   = "📡 Gateway #1"
    }
    "Local2" = @{
        Pill     = $window.FindName("LocalStatusPill2")
        Dot      = $window.FindName("LocalStatusDot2")
        Status   = $window.FindName("LocalStatusText2")
        Latency  = $window.FindName("TxtLocalLatency2")
        Avg      = $window.FindName("TxtLocalAvg2")
        MinMax   = $window.FindName("TxtLocalMinMax2")
        Loss     = $window.FindName("TxtLocalLoss2")
        LastSeen = $window.FindName("TxtLocalLastSeen2")
        Canvas   = $window.FindName("CanvasSparkline2")
        Line     = $window.FindName("LineSparkline2")
        Fill     = $window.FindName("FillSparkline2")
        Jitter   = $window.FindName("TxtJitter2")
        NameZh   = "💻 設備 #2"
        NameEn   = "💻 Subnet #2"
    }
    "Local3" = @{
        Pill     = $window.FindName("LocalStatusPill3")
        Dot      = $window.FindName("LocalStatusDot3")
        Status   = $window.FindName("LocalStatusText3")
        Latency  = $window.FindName("TxtLocalLatency3")
        Avg      = $window.FindName("TxtLocalAvg3")
        MinMax   = $window.FindName("TxtLocalMinMax3")
        Loss     = $window.FindName("TxtLocalLoss3")
        LastSeen = $window.FindName("TxtLocalLastSeen3")
        Canvas   = $window.FindName("CanvasSparkline3")
        Line     = $window.FindName("LineSparkline3")
        Fill     = $window.FindName("FillSparkline3")
        Jitter   = $window.FindName("TxtJitter3")
        NameZh   = "🖥️ 本機 #3"
        NameEn   = "🖥️ Host #3"
    }
}

$logEntries = [System.Collections.Generic.List[string]]::new()
$maxLogLines = 100

# 7. 中英文多國語言字典 (i18n)
$script:currentLang = "zh"

$i18n = @{
    "zh" = @{
        AppTitle         = "Network Sentinel - Fluent Network Monitor"
        HeaderSubtitle   = "智慧分析目前網段，同步即時監控外部網際網路 (Google) 與 3 組同網段設備 IP"
        MonitoringActive = "MONITORING ACTIVE (4 TARGETS)"
        MonitoringPaused = "MONITORING PAUSED"
        IntervalLabel    = "偵測間隔:"
        SoundAlert       = "斷線警報音效"
        MinToTrayChk     = "關閉時縮小至系統匣"
        AutoStartChk     = "開機自動啟動"
        BtnTrayText      = "📥 縮至系統匣"
        Pause            = "暫停偵測"
        Resume           = "繼續偵測"
        ResetStats       = "重置統計"
        ToggleBtnText    = "🌐 English"
        SubnetLabel      = "目前網路網段:"
        HostIPLabel      = "本機 IP:"
        GatewayLabel     = "預設閘道:"
        RefreshSubnet    = "🔄 重新辨識網段"
        InternetTitle    = "網際網路 (Internet)"
        InternetSubtitle = "目標主機: www.google.com"
        TargetIPLabel    = "目標 IP:"
        Apply            = "套用"
        OnlineStatus     = "連線正常 (ONLINE)"
        OfflineStatus    = "目標無回應 (OFFLINE)"
        CurLatency       = "目前延遲"
        AvgLatency       = "平均延遲"
        MinMaxLatency    = "最小 / 最大"
        LossRate         = "遺失率 (Lost/Total)"
        LastSeen         = "最後回應時間"
        Waiting          = "等待回應..."
        SparklineLabel   = "即時波動走勢 (最近 300 次):"
        JitterPrefix     = "抖動:"
        ActivityFeed     = "📋 即時偵測日誌 (滿 100 筆自動清除)"
        ClearLog         = "清除日誌"
        Target1Title     = "區域設備 #1 (網段預設閘道)"
        Target2Title     = "區域設備 #2 ($($detectedSubnet.Target2Desc))"
        Target3Title     = "區域設備 #3 ($($detectedSubnet.Target3Desc))"
        Interval_1s      = "1 秒 (1000ms)"
        Interval_2s      = "2 秒 (2000ms)"
        Interval_3s      = "3 秒 (3000ms)"
        Interval_5s      = "5 秒 (5000ms)"
        LogCountPrefix   = "最新"
        LogCountSuffix   = "筆"
        TrayShow         = "顯示視窗"
        TrayExit         = "結束程式"
        ToastDropTitle   = "⚠️ 網路斷線警報"
        ToastDropMsg     = "已失去連線！請檢查網路設定。"
        ToastRecTitle    = "✅ 網路已恢復連線"
        ToastRecMsg      = "已重新連線成功！"
        SparklineToolTip = @"
1. Ping 值（網路延遲，單位：毫秒 ms）
Ping 代表資料從你的裝置傳送到伺服器、再傳回來的來回時間。數值越低越好。
0 – 20 ms：極佳（適合電競、4K 影音串流）
21 – 50 ms：正常 / 良好（大部分線上遊戲、日常使用都很順暢）
51 – 100 ms：普通（玩快節奏射擊遊戲會有一點點不跟手，但勉強可玩）
100 ms 以上：差 / 爆 Ping（會出現畫面卡頓、角色瞬移、按技能沒反應）

2. Jitter（抖動值，單位：毫秒 ms）
Jitter 代表 Ping 值的穩定度與波動幅度（例如一秒測出來是 20ms，下一秒變 50ms，抖動就是 30ms）。對即時對戰遊戲來說，穩定的高 Ping 比不穩定的低 Ping 更好打。
0 – 5 ms：極佳、極度穩定
5 – 15 ms：正常範圍，波動不明顯
15 ms 以上：開始不穩，容易造成遊戲中「瞬移」、「子彈判定吃掉」或語音斷斷續續
30 ms 以上：嚴重抖動，網路品質不佳
"@
    }
    "en" = @{
        AppTitle         = "Network Sentinel - Fluent Network Monitor"
        HeaderSubtitle   = "Smart subnet discovery, monitoring Internet (Google) & 3 local subnet targets in real-time"
        MonitoringActive = "MONITORING ACTIVE (4 TARGETS)"
        MonitoringPaused = "MONITORING PAUSED"
        IntervalLabel    = "Interval:"
        SoundAlert       = "Alert on Disconnect"
        MinToTrayChk     = "Minimize to Tray on Close"
        AutoStartChk     = "Start with Windows"
        BtnTrayText      = "📥 To Tray"
        Pause            = "Pause"
        Resume           = "Resume"
        ResetStats       = "Reset Stats"
        ToggleBtnText    = "🌐 繁體中文"
        SubnetLabel      = "Detected Subnet:"
        HostIPLabel      = "Host IP:"
        GatewayLabel     = "Default Gateway:"
        RefreshSubnet    = "🔄 Refresh Subnet"
        InternetTitle    = "Internet Connection"
        InternetSubtitle = "Target: www.google.com"
        TargetIPLabel    = "Target IP:"
        Apply            = "Apply"
        OnlineStatus     = "ONLINE"
        OfflineStatus    = "OFFLINE"
        CurLatency       = "Latency"
        AvgLatency       = "Average"
        MinMaxLatency    = "Min / Max"
        LossRate         = "Packet Loss"
        LastSeen         = "Last Seen"
        Waiting          = "Waiting..."
        SparklineLabel   = "Latency Waveform (Last 300):"
        JitterPrefix     = "Jitter:"
        ActivityFeed     = "📋 Activity Feed (Auto-clears at 100)"
        ClearLog         = "Clear Log"
        Target1Title     = "Local #1 (Default Gateway)"
        Target2Title     = "Local #2 (Active Subnet Node)"
        Target3Title     = "Local #3 (Host Adapter IP)"
        Interval_1s      = "1 sec (1000ms)"
        Interval_2s      = "2 sec (2000ms)"
        Interval_3s      = "3 sec (3000ms)"
        Interval_5s      = "5 sec (5000ms)"
        LogCountPrefix   = "Recent"
        LogCountSuffix   = "items"
        TrayShow         = "Show Window"
        TrayExit         = "Exit"
        ToastDropTitle   = "⚠️ Network Disconnection Alert"
        ToastDropMsg     = "connection lost! Please check network settings."
        ToastRecTitle    = "✅ Network Restored"
        ToastRecMsg      = "connection back online!"
        SparklineToolTip = @"
1. Ping (Latency, Unit: ms)
Round-trip time for packets sent to the server and back. Lower is better.
0 – 20 ms: Excellent (Ideal for esports, 4K streaming)
21 – 50 ms: Good / Normal (Smooth for online gaming & daily browsing)
51 – 100 ms: Fair (Slight input lag in fast-paced FPS, but playable)
100+ ms: Poor / Lagging (Stutter, teleporting, delayed inputs)

2. Jitter (Unit: ms)
Variation and stability of Ping latency over time (e.g. 20ms then 50ms = 30ms jitter). A stable ping is preferred over volatile latency.
0 – 5 ms: Excellent, rock solid
5 – 15 ms: Normal, barely noticeable fluctuation
15+ ms: Unstable, causes rubber-banding or audio dropouts
30+ ms: Severe jitter, poor connection quality
"@
    }
}

# 8. 動態繪製 16x16 高對比清晰系統匣圖示
function New-TrayIconGraphic {
    param([string]$state = "Online")
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    # 外圈圓底 (深色背景)
    $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(20, 28, 38))
    $g.FillEllipse($bgBrush, 0, 0, 15, 15)
    
    # Fluent 藍色圓框
    $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(0, 120, 212), 1.5)
    $g.DrawEllipse($ringPen, 1, 1, 13, 13)

    # 中心狀態光點 (綠色正常 / 紅色斷線 / 灰色暫停)
    $color = switch ($state) {
        "Offline" { [System.Drawing.Color]::FromArgb(255, 75, 75) }
        "Paused"  { [System.Drawing.Color]::FromArgb(150, 150, 150) }
        Default   { [System.Drawing.Color]::FromArgb(60, 220, 100) }
    }
    $dotBrush = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($dotBrush, 4, 4, 7, 7)

    $g.Dispose()
    $hIcon = $bmp.GetHicon()
    return [System.Drawing.Icon]::FromHandle($hIcon)
}

# 系統匣 (System Tray NotifyIcon) 初始化
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = New-TrayIconGraphic -state "Online"
$notifyIcon.Text = "Network Sentinel - Fluent Network Monitor"
$notifyIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuShow = $trayMenu.Items.Add("顯示視窗 (Show Window)")
$menuPause= $trayMenu.Items.Add("暫停 / 繼續 (Pause/Resume)")
$trayMenu.Items.Add("-")
$menuExit = $trayMenu.Items.Add("結束程式 (Exit)")
$notifyIcon.ContextMenuStrip = $trayMenu

$script:isExiting = $false

# 完整退出程式邏輯
$ExitApplication = {
    $script:isExiting = $true
    $runner.Stop()
    if ($notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
    $window.Close()
    $app.Shutdown()
}

# 左鍵單擊托盤圖示喚回視窗
$notifyIcon.Add_Click({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $window.Show()
        $window.WindowState = [System.Windows.WindowState]::Normal
        $window.Activate()
    }
})

$menuShow.Add_Click({
    $window.Show()
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Activate()
})

$menuExit.Add_Click({
    & $ExitApplication
})

# 函式：更新系統匣右鍵選單語系
function Update-TrayMenuLanguage {
    $dict = $i18n[$script:currentLang]
    $menuShow.Text = $dict.TrayShow
    $menuPause.Text = if ($runner.IsRunning) { $dict.Pause } else { $dict.Resume }
    $menuExit.Text = $dict.TrayExit
}

# 函式：套用多國語言
function Apply-Language {
    param([string]$lang)
    $script:currentLang = $lang
    $dict = $i18n[$lang]

    $window.Title = $dict.AppTitle
    $txtHeaderSubtitle.Text = $dict.HeaderSubtitle
    $txtIntervalLabel.Text = $dict.IntervalLabel
    $chkSoundAlert.Content = $dict.SoundAlert
    $chkMinToTray.Content  = $dict.MinToTrayChk
    $chkAutoStart.Content  = $dict.AutoStartChk
    $btnMinimizeTray.Content = $dict.BtnTrayText
    $btnToggleLang.Content = $dict.ToggleBtnText
    $btnResetStats.Content = $dict.ResetStats

    if ($runner.IsRunning) {
        $btnPauseResume.Content = $dict.Pause
        $overallText.Text = $dict.MonitoringActive
    } else {
        $btnPauseResume.Content = $dict.Resume
        $overallText.Text = $dict.MonitoringPaused
    }

    $cmbItem1.Content = $dict.Interval_1s
    $cmbItem2.Content = $dict.Interval_2s
    $cmbItem3.Content = $dict.Interval_3s
    $cmbItem5.Content = $dict.Interval_5s

    $txtSubnetLabel.Text = $dict.SubnetLabel
    $txtLocalHostLabel.Text = $dict.HostIPLabel
    $txtGatewayLabel.Text = $dict.GatewayLabel
    $btnRedetectSubnet.Content = $dict.RefreshSubnet

    $txtInternetTitle.Text = $dict.InternetTitle
    $txtInternetSubtitle.Text = $dict.InternetSubtitle

    $txtLocalTitle1.Text = $dict.Target1Title
    $txtLocalTitle2.Text = $dict.Target2Title
    $txtLocalTitle3.Text = $dict.Target3Title

    $txtLocalIPLabel1.Text = $dict.TargetIPLabel
    $txtLocalIPLabel2.Text = $dict.TargetIPLabel
    $txtLocalIPLabel3.Text = $dict.TargetIPLabel

    $btnApplyIP1.Content = $dict.Apply
    $btnApplyIP2.Content = $dict.Apply
    $btnApplyIP3.Content = $dict.Apply

    $latencyLabels   | ForEach-Object { $_.Text = $dict.CurLatency }
    $avgLabels       | ForEach-Object { $_.Text = $dict.AvgLatency }
    $minMaxLabels    | ForEach-Object { $_.Text = $dict.MinMaxLatency }
    $lossLabels      | ForEach-Object { $_.Text = $dict.LossRate }
    $lastSeenLabels  | ForEach-Object { $_.Text = $dict.LastSeen }
    $sparklineLabels | ForEach-Object { $_.Text = $dict.SparklineLabel }

    # 更新趨勢圖與指標 ToolTip 說明
    $sparkElements | ForEach-Object {
        if ($_) {
            $_.ToolTip = $dict.SparklineToolTip
        }
    }

    foreach ($k in $cardsMap.Keys) {
        $c = $cardsMap[$k]
        $st = $statsMap[$k]
        if ($st.LastOnline) {
            $c.Status.Text = $dict.OnlineStatus
        } else {
            $c.Status.Text = $dict.OfflineStatus
        }
    }

    $txtActivityFeedTitle.Text = $dict.ActivityFeed
    $btnClearLog.Content = $dict.ClearLog
    $txtLogCounter.Text = "($($dict.LogCountPrefix) $($logEntries.Count) / $maxLogLines $($dict.LogCountSuffix))"

    Update-TrayMenuLanguage
}

# 程式啟動時立即套用預設繁體中文語系 (初始化所有 UI 標籤、系統匣選單與走勢圖 ToolTip 說明)
Apply-Language -lang "zh"

# 9. 輔助函式：新增日誌 (滿 100 筆後自動清空)
function Add-LogLine {
    param([string]$line)
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $formatted = "[$timestamp] $line"

    if ($logEntries.Count -ge $maxLogLines) {
        $logEntries.Clear()
        $clearNotice = if ($script:currentLang -eq "zh") {
            "[$timestamp] 🧹 【自動清除】日誌已累積滿 $maxLogLines 筆，已自動清空重啟"
        } else {
            "[$timestamp] 🧹 [Auto Clear] Log reached $maxLogLines entries and was automatically cleared"
        }
        $logEntries.Add($clearNotice)
    }

    $logEntries.Add($formatted)
    $txtLog.Text = [string]::Join("`r`n", $logEntries)
    $txtLog.ScrollToEnd()
    $dict = $i18n[$script:currentLang]
    $txtLogCounter.Text = "($($dict.LogCountPrefix) $($logEntries.Count) / $maxLogLines $($dict.LogCountSuffix))"
}

# 輔助函式：重置特定目標統計
function Reset-TargetStats {
    param($stats)
    $stats.Sent = 0
    $stats.Recv = 0
    $stats.Lost = 0
    $stats.MinTime = -1
    $stats.MaxTime = -1
    $stats.TotalTime = 0
}

# 10. Sparkline 即時微型走勢圖繪製函式
function Update-SparklineGraph {
    param([string]$id, [long]$latestRtt, [bool]$isSuccess)
    
    $card = $cardsMap[$id]
    $list = $sparkHistoryMap[$id]

    $valToRecord = if ($isSuccess) { $latestRtt } else { -1 }
    $list.Add($valToRecord)
    if ($list.Count -gt $maxSparkPoints) {
        $list.RemoveAt(0)
    }

    $canvas = $card.Canvas
    $line   = $card.Line
    $fill   = $card.Fill
    $w = $canvas.ActualWidth
    if ($w -le 10) { $w = 340 }
    $h = 24.0

    $validVals = $list | Where-Object { $_ -ge 0 }
    $maxVal = 30.0
    if ($validVals.Count -gt 0) {
        $observedMax = ($validVals | Measure-Object -Maximum).Maximum
        if ($observedMax -gt $maxVal) { $maxVal = [double]$observedMax }
    }

    $pts = New-Object System.Windows.Media.PointCollection
    $fillPts = New-Object System.Windows.Media.PointCollection
    $fillPts.Add((New-Object System.Windows.Point(0, $h)))

    $stepX = if ($list.Count -gt 1) { $w / ($list.Count - 1) } else { $w }

    for ($i = 0; $i -lt $list.Count; $i++) {
        $x = $i * $stepX
        $v = $list[$i]
        $y = if ($v -ge 0) {
            $clamped = [math]::Min($maxVal, $v)
            $h - ($clamped / $maxVal * ($h - 4.0)) - 2.0
        } else {
            $h - 1.0
        }
        $pt = New-Object System.Windows.Point($x, $y)
        $pts.Add($pt)
        $fillPts.Add($pt)
    }
    $fillPts.Add((New-Object System.Windows.Point($w, $h)))

    $line.Points = $pts
    $fill.Points = $fillPts

    # 動態走勢顏色
    if ($latestRtt -ge 0) {
        if ($latestRtt -lt 30) {
            $line.Stroke = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#60CDFF")
            $fill.Fill   = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#184CC2FF")
        } elseif ($latestRtt -lt 100) {
            $line.Stroke = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FFB900")
            $fill.Fill   = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#18FFB900")
        } else {
            $line.Stroke = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FF7043")
            $fill.Fill   = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#18FF7043")
        }
    } else {
        $line.Stroke = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FF5555")
        $fill.Fill   = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#20FF5555")
    }

    # 計算 Jitter 抖動率
    if ($validVals.Count -ge 2) {
        $diffSum = 0
        $diffCount = 0
        for ($j = 1; $j -lt $validVals.Count; $j++) {
            $diffSum += [math]::Abs($validVals[$j] - $validVals[$j - 1])
            $diffCount++
        }
        $jitter = [math]::Round($diffSum / $diffCount, 1)
        $dict = $i18n[$script:currentLang]
        $card.Jitter.Text = "$($dict.JitterPrefix) $jitter ms"
        if ($jitter -lt 3) {
            $card.Jitter.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6CCB5F")
        } elseif ($jitter -lt 15) {
            $card.Jitter.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FFB900")
        } else {
            $card.Jitter.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FF7043")
        }
    }
}

# 輔助顏色畫刷
$brushGreenBg     = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#163821")
$brushGreenBorder = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#256938")
$brushGreenText   = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6CCB5F")
$brushGreenDot    = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#52C41A")

$brushRedBg       = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#3B1A1A")
$brushRedBorder   = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#662424")
$brushRedText     = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FF7B7B")
$brushRedDot      = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FF5555")

$brushCyanText    = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#60CDFF")
$brushAmberText   = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FFB900")
$brushOrangeText  = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FF7043")

# 11. 建立並啟動非同步 Ping Runner (4 目標)
$runner = New-Object PingMonitorRunner
$runner.InternetTarget = "www.google.com"
$runner.LocalTarget1   = $txtLocalIP1.Text
$runner.LocalTarget2   = $txtLocalIP2.Text
$runner.LocalTarget3   = $txtLocalIP3.Text
$runner.IntervalMs     = 1000

# 12. 處理 Ping 回應事件回呼
$runner.add_OnPingResult({
    param([PingResult]$result)
    
    $id = $result.TargetId
    if (-not $statsMap.ContainsKey($id) -or -not $cardsMap.ContainsKey($id)) { return }

    $stats = $statsMap[$id]
    $card  = $cardsMap[$id]
    $stats.Sent++
    $timeStr = (Get-Date $result.Timestamp).ToString("HH:mm:ss")
    $dict = $i18n[$script:currentLang]
    $targetName = if ($script:currentLang -eq "zh") { $card.NameZh } else { $card.NameEn }

    if ($result.Success) {
        $stats.Recv++
        $rtt = $result.RoundtripTime
        $stats.TotalTime += $rtt
        
        if ($stats.MinTime -eq -1 -or $rtt -lt $stats.MinTime) { $stats.MinTime = $rtt }
        if ($rtt -gt $stats.MaxTime) { $stats.MaxTime = $rtt }

        # UI 狀態徽章 (Online)
        $card.Pill.Background  = $brushGreenBg
        $card.Pill.BorderBrush = $brushGreenBorder
        $card.Dot.Fill         = $brushGreenDot
        $card.Status.Text      = $dict.OnlineStatus
        $card.Status.Foreground= $brushGreenText

        $displayRtt = if ($rtt -eq 0) { "< 1 ms" } else { "$rtt ms" }
        $card.Latency.Text = $displayRtt
        if ($rtt -lt 30) {
            $card.Latency.Foreground = $brushCyanText
        } elseif ($rtt -lt 100) {
            $card.Latency.Foreground = $brushAmberText
        } else {
            $card.Latency.Foreground = $brushOrangeText
        }

        $avg = [math]::Round($stats.TotalTime / $stats.Recv, 1)
        $card.Avg.Text      = "$avg ms"
        $card.MinMax.Text   = "$($stats.MinTime) ms / $($stats.MaxTime) ms"
        $card.LastSeen.Text = $timeStr

        # 若原先為斷線，發布連線已恢復通知
        if (-not $stats.LastOnline) {
            $toastTitle = $dict.ToastRecTitle
            $toastMsg = "$targetName [$($result.Target)] $($dict.ToastRecMsg) ($displayRtt)"
            $notifyIcon.ShowBalloonTip(3000, $toastTitle, $toastMsg, [System.Windows.Forms.ToolTipIcon]::Info)
            $notifyIcon.Icon = New-TrayIconGraphic -state "Online"
        }
        $stats.LastOnline   = $true

    } else {
        $stats.Lost++

        # UI 狀態徽章 (Offline)
        $card.Pill.Background  = $brushRedBg
        $card.Pill.BorderBrush = $brushRedBorder
        $card.Dot.Fill         = $brushRedDot
        $card.Status.Text      = $dict.OfflineStatus
        $card.Status.Foreground= $brushRedText

        $card.Latency.Text     = "TIMEOUT"
        $card.Latency.Foreground = $brushRedDot

        # 音效與 Windows 11 原生彈窗通知
        if ($stats.LastOnline) {
            if ($chkSoundAlert.IsChecked) {
                [System.Media.SystemSounds]::Exclamation.Play()
            }
            $toastTitle = $dict.ToastDropTitle
            $toastMsg = "$targetName [$($result.Target)] $($dict.ToastDropMsg)"
            $notifyIcon.ShowBalloonTip(3000, $toastTitle, $toastMsg, [System.Windows.Forms.ToolTipIcon]::Warning)
            $notifyIcon.Icon = New-TrayIconGraphic -state "Offline"
        }
        $stats.LastOnline = $false
    }

    # 繪製更新即時走勢圖 (Sparkline)
    Update-SparklineGraph -id $id -latestRtt $result.RoundtripTime -isSuccess $result.Success

    # 封包遺失率計算
    $lossPct = [math]::Round(($stats.Lost / $stats.Sent) * 100, 1)
    $card.Loss.Text = "$lossPct% ($($stats.Lost)/$($stats.Sent))"
    $card.Loss.Foreground = if ($stats.Lost -eq 0) { $brushGreenText } else { $brushRedText }

    # 更新即時日誌
    $statusMsg = if ($result.Success) {
        $dur = if ($result.RoundtripTime -eq 0) { "< 1ms" } else { "$($result.RoundtripTime)ms" }
        "OK ($dur)"
    } else {
        "FAILED ($($result.Status))"
    }
    Add-LogLine -line "$targetName [$($result.Target)] -> $statusMsg"
})

# 13. 事件：修改與套用 Local IP 1, 2, 3
function Set-LocalTarget {
    param([int]$index, [System.Windows.Controls.TextBox]$box)
    $rawIP = $box.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($rawIP)) {
        $errMsg = if ($script:currentLang -eq "zh") { "請輸入有效的 IP 位址或主機名稱！" } else { "Please enter a valid IP address or hostname!" }
        $errTitle = if ($script:currentLang -eq "zh") { "輸入錯誤" } else { "Input Error" }
        [System.Windows.MessageBox]::Show($errMsg, $errTitle, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $targetKey = "Local$index"
    switch ($index) {
        1 { $runner.LocalTarget1 = $rawIP }
        2 { $runner.LocalTarget2 = $rawIP }
        3 { $runner.LocalTarget3 = $rawIP }
    }

    Reset-TargetStats -stats $statsMap[$targetKey]
    $sparkHistoryMap[$targetKey].Clear()
    $card = $cardsMap[$targetKey]
    $card.Latency.Text  = "-- ms"
    $card.Avg.Text      = "-- ms"
    $card.MinMax.Text   = "-- / --"
    $card.Loss.Text     = "0.0% (0/0)"
    $card.LastSeen.Text = $i18n[$script:currentLang].Waiting
    $card.Jitter.Text   = "$($i18n[$script:currentLang].JitterPrefix) -- ms"

    $logMsg = if ($script:currentLang -eq "zh") { "⚙️ 【設定更新】已變更區網設備 #$index 目標為: $rawIP" } else { "⚙️ [Config Update] Local target #$index updated to: $rawIP" }
    Add-LogLine -line $logMsg
}

$btnApplyIP1.Add_Click({ Set-LocalTarget -index 1 -box $txtLocalIP1 })
$txtLocalIP1.Add_KeyDown({ param($s, $e); if ($e.Key -eq [System.Windows.Input.Key]::Enter) { Set-LocalTarget -index 1 -box $txtLocalIP1 } })

$btnApplyIP2.Add_Click({ Set-LocalTarget -index 2 -box $txtLocalIP2 })
$txtLocalIP2.Add_KeyDown({ param($s, $e); if ($e.Key -eq [System.Windows.Input.Key]::Enter) { Set-LocalTarget -index 2 -box $txtLocalIP2 } })

$btnApplyIP3.Add_Click({ Set-LocalTarget -index 3 -box $txtLocalIP3 })
$txtLocalIP3.Add_KeyDown({ param($s, $e); if ($e.Key -eq [System.Windows.Input.Key]::Enter) { Set-LocalTarget -index 3 -box $txtLocalIP3 } })

# 14. 事件：重新偵測當前網段
$btnRedetectSubnet.Add_Click({
    $newSubnet = Get-CurrentSubnetInfo
    $txtSubnetInfo.Text  = "$($newSubnet.Subnet) ($($newSubnet.InterfaceName))"
    $txtLocalHostIP.Text = $newSubnet.LocalIP
    $txtGatewayIP.Text   = $newSubnet.Gateway

    $txtLocalIP1.Text    = $newSubnet.Target1
    $txtLocalIP2.Text    = $newSubnet.Target2
    $txtLocalIP3.Text    = $newSubnet.Target3

    $runner.LocalTarget1 = $newSubnet.Target1
    $runner.LocalTarget2 = $newSubnet.Target2
    $runner.LocalTarget3 = $newSubnet.Target3

    if ($script:currentLang -eq "zh") {
        if ($newSubnet.Target2Desc) { $txtLocalTitle2.Text = "區域設備 #2 ($($newSubnet.Target2Desc))" }
        if ($newSubnet.Target3Desc) { $txtLocalTitle3.Text = "區域設備 #3 ($($newSubnet.Target3Desc))" }
    } else {
        $txtLocalTitle2.Text = "Local #2 (Active Subnet Node)"
        $txtLocalTitle3.Text = "Local #3 (Host Adapter IP)"
    }

    foreach ($k in @("Local1", "Local2", "Local3")) {
        Reset-TargetStats -stats $statsMap[$k]
        $sparkHistoryMap[$k].Clear()
    }

    $logMsg1 = if ($script:currentLang -eq "zh") { "🔍 【網段重整】成功辨識網段: $($newSubnet.Subnet) ($($newSubnet.InterfaceName))" } else { "🔍 [Subnet Refresh] Subnet discovered: $($newSubnet.Subnet) ($($newSubnet.InterfaceName))" }
    $logMsg2 = if ($script:currentLang -eq "zh") { "📡 已同步更新區網監控目標: $($newSubnet.Target1) / $($newSubnet.Target2) / $($newSubnet.Target3)" } else { "📡 Synchronized local targets: $($newSubnet.Target1) / $($newSubnet.Target2) / $($newSubnet.Target3)" }
    Add-LogLine -line $logMsg1
    Add-LogLine -line $logMsg2
})

# 15. 事件：中英文雙語切換按鈕
$btnToggleLang.Add_Click({
    if ($script:currentLang -eq "zh") {
        Apply-Language -lang "en"
        Add-LogLine -line "🌐 UI language switched to: English"
    } else {
        Apply-Language -lang "zh"
        Add-LogLine -line "🌐 介面語言已切換為: 繁體中文"
    }
})

# 16. 事件：縮小至系統匣按鈕
$btnMinimizeTray.Add_Click({
    $window.Hide()
    $tipTitle = "Network Sentinel"
    $tipMsg   = if ($script:currentLang -eq "zh") { "已縮小至系統匣背景持續監控中（若沒看見可點擊工作列右下角 ^ 展開）。" } else { "Running in background system tray. Click the ^ chevron on the taskbar to restore." }
    $notifyIcon.ShowBalloonTip(2000, $tipTitle, $tipMsg, [System.Windows.Forms.ToolTipIcon]::Info)
})

# 16.1 Windows 開機自動啟動 (Auto-Start) 邏輯
$regRunPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$regRunName = "FluentNetworkSentinel"

function Get-SentinelAutoStartCmd {
    $ps1 = (Join-Path $PSScriptRoot "NetworkSentinel.ps1")
    return "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -Command `"`$p='$ps1'; for(`$i=0;`$i -lt 30;`$i++){ if(Test-Path `$p){ & `$p -Startup; break }; Start-Sleep -Seconds 1 }`""
}

function Test-SentinelAutoStart {
    try {
        $val = (Get-ItemProperty -Path $regRunPath -Name $regRunName -ErrorAction SilentlyContinue).$regRunName
        return [bool]($val)
    } catch {
        return $false
    }
}

function Set-SentinelAutoStart {
    param([bool]$enable)
    if ($enable) {
        $cmd = Get-SentinelAutoStartCmd
        Set-ItemProperty -Path $regRunPath -Name $regRunName -Value $cmd
    } else {
        Remove-ItemProperty -Path $regRunPath -Name $regRunName -ErrorAction SilentlyContinue
    }
}

# 讀取當前 Windows 開機啟動狀態並初始化核取方塊
$chkAutoStart.IsChecked = Test-SentinelAutoStart

$chkAutoStart.Add_Click({
    Set-SentinelAutoStart -enable $chkAutoStart.IsChecked
    if ($chkAutoStart.IsChecked) {
        $msg = if ($script:currentLang -eq "zh") { "⚙️ 【設定更新】已啟用 Windows 開機自動常駐系統匣" } else { "⚙️ [Setting] Auto start with Windows enabled" }
        Add-LogLine -line $msg
    } else {
        $msg = if ($script:currentLang -eq "zh") { "⚙️ 【設定更新】已取消 Windows 開機自動啟動" } else { "⚙️ [Setting] Auto start with Windows disabled" }
        Add-LogLine -line $msg
    }
})

# 17. 事件：偵測間隔變更
$cmbInterval.Add_SelectionChanged({
    $selectedItem = $cmbInterval.SelectedItem
    if ($selectedItem -and $selectedItem.Tag) {
        $newInterval = [int]$selectedItem.Tag
        $runner.IntervalMs = $newInterval
        $logMsg = if ($script:currentLang -eq "zh") { "⚙️ 【設定更新】偵測間隔已調整為: $($newInterval / 1000) 秒" } else { "⚙️ [Config Update] Interval set to: $($newInterval / 1000)s" }
        Add-LogLine -line $logMsg
    }
})

# 18. 事件：暫停 / 繼續偵測
$btnPauseResume.Add_Click({
    $dict = $i18n[$script:currentLang]
    if ($runner.IsRunning) {
        $runner.Stop()
        $btnPauseResume.Content = $dict.Resume
        $overallBadge.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#333333")
        $overallBadge.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#555555")
        $overallDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888888")
        $overallText.Text = $dict.MonitoringPaused
        $overallText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CCCCCC")
        $notifyIcon.Icon = New-TrayIconGraphic -state "Paused"
        $logMsg = if ($script:currentLang -eq "zh") { "⏸️ 【監控暫停】已停止背景偵測" } else { "⏸️ [Paused] Background monitoring paused" }
        Add-LogLine -line $logMsg
    } else {
        $runner.Start($window.Dispatcher)
        $btnPauseResume.Content = $dict.Pause
        $overallBadge.Background = $brushGreenBg
        $overallBadge.BorderBrush = $brushGreenBorder
        $overallDot.Fill = $brushCyanText
        $overallText.Text = $dict.MonitoringActive
        $overallText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#D0EEFF")
        $notifyIcon.Icon = New-TrayIconGraphic -state "Online"
        $logMsg = if ($script:currentLang -eq "zh") { "▶️ 【監控恢復】已恢復背景即時偵測" } else { "▶️ [Resumed] Background monitoring resumed" }
        Add-LogLine -line $logMsg
    }
    Update-TrayMenuLanguage
})

$menuPause.Add_Click({
    $btnPauseResume.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
})

# 19. 事件：重置統計
$btnResetStats.Add_Click({
    foreach ($key in $statsMap.Keys) {
        Reset-TargetStats -stats $statsMap[$key]
        $sparkHistoryMap[$key].Clear()
        $card = $cardsMap[$key]
        $card.Avg.Text    = "-- ms"
        $card.MinMax.Text = "-- / --"
        $card.Loss.Text   = "0.0% (0/0)"
        $card.Jitter.Text = "$($i18n[$script:currentLang].JitterPrefix) -- ms"
        $card.Line.Points.Clear()
        $card.Fill.Points.Clear()
    }
    $logMsg = if ($script:currentLang -eq "zh") { "🔄 【重置統計】所有目標歷史延遲、走勢圖與遺失率計數已歸零" } else { "🔄 [Stats Reset] All latency, waveform & packet loss stats reset" }
    Add-LogLine -line $logMsg
})

# 20. 事件：清除日誌
$btnClearLog.Add_Click({
    $logEntries.Clear()
    $txtLog.Text = ""
    $dict = $i18n[$script:currentLang]
    $txtLogCounter.Text = "($($dict.LogCountPrefix) 0 / $maxLogLines $($dict.LogCountSuffix))"
})

# 21. 視窗狀態變更：縮小時隱藏至系統匣
$window.Add_StateChanged({
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
        if ($chkMinToTray.IsChecked) {
            $window.Hide()
            $tipTitle = "Network Sentinel"
            $tipMsg   = if ($script:currentLang -eq "zh") { "已縮小至系統匣背景持續監控中（若沒看見可點擊工作列右下角 ^ 展開）。" } else { "Running in background system tray. Click the ^ chevron on the taskbar to restore." }
            $notifyIcon.ShowBalloonTip(2000, $tipTitle, $tipMsg, [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
})

# 22. 視窗載入完成套用 Windows 11 Fluent 深色標題列與圓角
$window.Add_SourceInitialized({
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        [DwmHelper]::ApplyFluentStyling($helper.Handle)
    } catch { }
})

# 23. 視窗關閉事件：檢查是否最小化至托盤
$window.Add_Closing({
    param($s, $e)
    if (-not $script:isExiting -and $chkMinToTray.IsChecked) {
        $e.Cancel = $true
        $window.Hide()
        $tipTitle = "Network Sentinel"
        $tipMsg   = if ($script:currentLang -eq "zh") { "已縮小至系統匣背景持續監控中（若沒看見可點擊工作列右下角 ^ 展開）。" } else { "Running in background system tray. Click the ^ chevron on the taskbar to restore." }
        $notifyIcon.ShowBalloonTip(2000, $tipTitle, $tipMsg, [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $script:isExiting = $true
        $runner.Stop()
        if ($notifyIcon) {
            $notifyIcon.Visible = $false
            $notifyIcon.Dispose()
        }
        $app.Shutdown()
    }
})

# 24. 啟動監控並啟動獨立 WPF Application 訊息迴圈
Add-LogLine -line "🚀 Fluent Network Sentinel 已啟動 (Started)"
Add-LogLine -line "🔍 偵測到目前網段: $($detectedSubnet.Subnet) ($($detectedSubnet.InterfaceName))"
Add-LogLine -line "🌐 網際網路目標: www.google.com"
Add-LogLine -line "📡 閘道目標 #1: $($detectedSubnet.Target1)"
Add-LogLine -line "💻 設備目標 #2: $($detectedSubnet.Target2) ($($detectedSubnet.Target2Desc))"
Add-LogLine -line "🖥️ 本機目標 #3: $($detectedSubnet.Target3) ($($detectedSubnet.Target3Desc))"

$runner.Start($window.Dispatcher)

if ($Startup) {
    # Windows 開機自動啟動：直接常駐系統匣背景持續監控
    $startMsg = if ($script:currentLang -eq "zh") { "已於開機自動常駐系統匣背景持續監控中（若沒看見可點擊工作列右下角 ^ 展開）。" } else { "Started in background system tray on Windows startup." }
    $notifyIcon.ShowBalloonTip(3000, "Network Sentinel", $startMsg, [System.Windows.Forms.ToolTipIcon]::Info)
} else {
    $window.Show()
}

$null = $app.Run()
