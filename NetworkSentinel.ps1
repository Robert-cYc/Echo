<#
.SYNOPSIS
    Fluent Network Sentinel - Windows 11 Fluent UI 即時網路狀態監控工具 (中英文切換版)
.DESCRIPTION
    PowerShell + WPF 設計的 Windows 11 Fluent UI 網路連線監控程式。
    - 支援中英文即時動態雙語切換 (繁體中文 / English)
    - 先自動偵測目前作用中的網路介面與網段 (Subnet / Gateway / Local IP)
    - 自動提取當前網段內的閘道、活躍鄰近設備與本機 IP 進行並行 Ping 監控
    - 同步持續監控外部網際網路 (www.google.com)
    - 3 組區域網路設備 IP 均支援隨時自訂修改 (Enter 或點擊套用)
    - 提供連線延遲 (目前/平均/最小/最大)、封包遺失率、回應歷史日誌
    - 支援調整偵測間隔 (1s ~ 5s，黑底白字 Fluent 風格)、暫停/繼續、重置統計、重新偵測網段與斷線音效提示
    - 採用非同步 Background Ping 機制，UI 介面完全不卡頓
#>

# 1. 載入 WPF 與 Windows 系統組件
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

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

            # 分析 IPv4 網段前綴
            $ipParts = $info.LocalIP.Split('.')
            if ($ipParts.Count -eq 4) {
                $prefix3 = "$($ipParts[0]).$($ipParts[1]).$($ipParts[2])"
                $info.Subnet = "$prefix3.0/$($info.PrefixLength)"
                
                # 目標 1：網段預設閘道 (Gateway / 路由器)
                $info.Target1 = $info.Gateway

                # 目標 2：同網段內已探測到的活躍設備 (Neighbor) 或網段 .2
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

                # 目標 3：本機實體 IP 或網段 .254
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
        Height="890" Width="820" MinHeight="740" MinWidth="750"
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
            <Setter Property="Padding" Value="12,5"/>
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
    </Window.Resources>

    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/> <!-- 0: Header -->
            <RowDefinition Height="Auto"/> <!-- 1: Controls Toolbar -->
            <RowDefinition Height="Auto"/> <!-- 2: Subnet Information Banner -->
            <RowDefinition Height="*"/>    <!-- 3: Cards Area (ScrollViewer) -->
            <RowDefinition Height="170"/>  <!-- 4: Activity Feed -->
        </Grid.RowDefinitions>

        <!-- 0: Header -->
        <Grid Grid.Row="0" Margin="0,0,0,12">
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

        <!-- 1: Controls Toolbar (含中英文切換鈕) -->
        <Border Grid.Row="1" Background="#202020" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="6" Padding="12,6" Margin="0,0,0,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <!-- Interval -->
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,16,0">
                    <TextBlock x:Name="TxtIntervalLabel" Text="偵測間隔:" VerticalAlignment="Center" FontSize="12" Foreground="#B0B0B0" Margin="0,0,8,0"/>
                    <ComboBox x:Name="CmbInterval" Style="{StaticResource FluentComboBoxStyle}" SelectedIndex="0" Width="130" Height="28">
                        <ComboBoxItem x:Name="CmbItem1" Content="1 秒 (1000ms)" Tag="1000"/>
                        <ComboBoxItem x:Name="CmbItem2" Content="2 秒 (2000ms)" Tag="2000"/>
                        <ComboBoxItem x:Name="CmbItem3" Content="3 秒 (3000ms)" Tag="3000"/>
                        <ComboBoxItem x:Name="CmbItem5" Content="5 秒 (5000ms)" Tag="5000"/>
                    </ComboBox>
                </StackPanel>

                <!-- Sound Alert -->
                <CheckBox x:Name="ChkSoundAlert" Grid.Column="1" Content="斷線警報音效" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,16,0" Cursor="Hand"/>

                <!-- Right Action Buttons (包含語言切換) -->
                <StackPanel Grid.Column="3" Orientation="Horizontal">
                    <Button x:Name="BtnToggleLang" Content="🌐 English" Style="{StaticResource FluentButtonStyle}" Margin="0,0,8,0" Padding="10,3"/>
                    <Button x:Name="BtnPauseResume" Content="暫停偵測" Style="{StaticResource FluentButtonStyle}" Margin="0,0,8,0" Padding="12,3"/>
                    <Button x:Name="BtnResetStats" Content="重置所有統計" Style="{StaticResource FluentButtonStyle}" Padding="12,3"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- 2: 目前網段資訊橫幅 (Subnet Information Banner) -->
        <Border Grid.Row="2" Background="#1A2838" BorderBrush="#26486D" BorderThickness="1" CornerRadius="6" Padding="12,7" Margin="0,0,0,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <!-- Subnet Info -->
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,16,0">
                    <TextBlock Text="🔍" FontSize="13" Margin="0,0,6,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtSubnetLabel" Text="目前網路網段:" FontSize="12" FontWeight="SemiBold" Foreground="#60CDFF" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtSubnetInfo" Text="192.168.1.0/24 (Wi-Fi)" FontSize="12" FontWeight="Bold" Foreground="#FFFFFF" Margin="6,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>

                <!-- Local IP & Gateway Summary -->
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock x:Name="TxtLocalHostLabel" Text="本機 IP:" FontSize="11" Foreground="#999999" Margin="0,0,4,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtLocalHostIP" Text="192.168.1.227" FontSize="11" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,0,14,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtGatewayLabel" Text="預設閘道:" FontSize="11" Foreground="#999999" Margin="0,0,4,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtGatewayIP" Text="192.168.1.1" FontSize="11" FontWeight="SemiBold" Foreground="#E0E0E0" VerticalAlignment="Center"/>
                </StackPanel>

                <!-- Re-detect Button -->
                <Button x:Name="BtnRedetectSubnet" Grid.Column="2" Content="🔄 重新辨識網段" Style="{StaticResource FluentButtonStyle}" Padding="10,3" FontSize="11"/>
            </Grid>
        </Border>

        <!-- 3: Cards Area (in ScrollViewer) -->
        <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto" Margin="0,0,0,10" Padding="0,0,6,0">
            <StackPanel>
                <!-- Card 0: Internet (Google) -->
                <Border Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,0,0,10">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Header -->
                        <Grid Grid.Row="0" Margin="0,0,0,8">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Width="32" Height="32" CornerRadius="6" Background="#162E44" Margin="0,0,10,0">
                                <TextBlock Text="🌐" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>

                            <StackPanel Grid.Column="1" VerticalAlignment="Center">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock x:Name="TxtInternetTitle" Text="網際網路 (Internet)" FontSize="14" FontWeight="SemiBold" Foreground="#FFFFFF"/>
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
                                <ColumnDefinition Width="135"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Background="#1D1D1D" CornerRadius="5" Padding="10,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLatency0" Text="目前延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleLatency" Text="-- ms" FontSize="18" FontWeight="Bold" Foreground="#60CDFF" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblAvg0" Text="平均延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleAvg" Text="-- ms" FontSize="13" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblMinMax0" Text="最小 / 最大" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleMinMax" Text="-- / --" FontSize="12" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLoss0" Text="遺失率 (Lost/Total)" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleLoss" Text="0.0% (0/0)" FontSize="12" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="5" Padding="8,6">
                                <StackPanel>
                                    <TextBlock x:Name="LblLastSeen0" Text="最後回應時間" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleLastSeen" Text="等待回應..." FontSize="11" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </Grid>
                </Border>

                <!-- Card 1: Local Target 1 (Gateway / 路由器) -->
                <Border Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,0,0,10">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Header & Input Bar -->
                        <Grid Grid.Row="0" Margin="0,0,0,8">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Width="32" Height="32" CornerRadius="6" Background="#3B2614" Margin="0,0,10,0">
                                <TextBlock Text="📡" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>

                            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,12,0">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock x:Name="TxtLocalTitle1" Text="區域設備 #1 (網段預設閘道)" FontSize="14" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                                    <Border Background="#332414" BorderBrush="#6B491F" BorderThickness="1" CornerRadius="4" Margin="8,0,0,0" Padding="5,1">
                                        <TextBlock Text="GATEWAY" FontSize="9" FontWeight="Bold" Foreground="#FFB900"/>
                                    </Border>
                                </StackPanel>
                            </StackPanel>

                            <!-- Inline IP Input -->
                            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                                <TextBlock x:Name="TxtLocalIPLabel1" Text="目標 IP:" FontSize="12" Foreground="#A0A0A0" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                <TextBox x:Name="TxtLocalIP1" Width="140" Text="192.168.1.1" Style="{StaticResource FluentTextBoxStyle}" Margin="0,0,6,0"/>
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
                                <ColumnDefinition Width="135"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Background="#1D1D1D" CornerRadius="5" Padding="10,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLatency1" Text="目前延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLatency1" Text="-- ms" FontSize="18" FontWeight="Bold" Foreground="#60CDFF" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblAvg1" Text="平均延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalAvg1" Text="-- ms" FontSize="13" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblMinMax1" Text="最小 / 最大" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalMinMax1" Text="-- / --" FontSize="12" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLoss1" Text="遺失率 (Lost/Total)" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLoss1" Text="0.0% (0/0)" FontSize="12" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="5" Padding="8,6">
                                <StackPanel>
                                    <TextBlock x:Name="LblLastSeen1" Text="最後回應時間" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLastSeen1" Text="等待回應..." FontSize="11" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </Grid>
                </Border>

                <!-- Card 2: Local Target 2 (網段活躍設備 / 鄰近主機) -->
                <Border Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,0,0,10">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Header & Input Bar -->
                        <Grid Grid.Row="0" Margin="0,0,0,8">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Width="32" Height="32" CornerRadius="6" Background="#262D42" Margin="0,0,10,0">
                                <TextBlock Text="💻" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>

                            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,12,0">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock x:Name="TxtLocalTitle2" Text="區域設備 #2 (網段活躍設備)" FontSize="14" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                                    <Border Background="#1C263A" BorderBrush="#2D4370" BorderThickness="1" CornerRadius="4" Margin="8,0,0,0" Padding="5,1">
                                        <TextBlock Text="SUBNET #2" FontSize="9" FontWeight="Bold" Foreground="#4CC2FF"/>
                                    </Border>
                                </StackPanel>
                            </StackPanel>

                            <!-- Inline IP Input -->
                            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                                <TextBlock x:Name="TxtLocalIPLabel2" Text="目標 IP:" FontSize="12" Foreground="#A0A0A0" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                <TextBox x:Name="TxtLocalIP2" Width="140" Text="192.168.1.2" Style="{StaticResource FluentTextBoxStyle}" Margin="0,0,6,0"/>
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
                                <ColumnDefinition Width="135"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Background="#1D1D1D" CornerRadius="5" Padding="10,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLatency2" Text="目前延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLatency2" Text="-- ms" FontSize="18" FontWeight="Bold" Foreground="#60CDFF" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblAvg2" Text="平均延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalAvg2" Text="-- ms" FontSize="13" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblMinMax2" Text="最小 / 最大" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalMinMax2" Text="-- / --" FontSize="12" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLoss2" Text="遺失率 (Lost/Total)" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLoss2" Text="0.0% (0/0)" FontSize="12" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="5" Padding="8,6">
                                <StackPanel>
                                    <TextBlock x:Name="LblLastSeen2" Text="最後回應時間" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLastSeen2" Text="等待回應..." FontSize="11" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </Grid>
                </Border>

                <!-- Card 3: Local Target 3 (本機實體網卡 IP / 備用設備) -->
                <Border Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,0,0,4">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Header & Input Bar -->
                        <Grid Grid.Row="0" Margin="0,0,0,8">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Width="32" Height="32" CornerRadius="6" Background="#33213B" Margin="0,0,10,0">
                                <TextBlock Text="🖥️" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>

                            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,12,0">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock x:Name="TxtLocalTitle3" Text="區域設備 #3 (本機網卡實體 IP)" FontSize="14" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                                    <Border Background="#291A30" BorderBrush="#593269" BorderThickness="1" CornerRadius="4" Margin="8,0,0,0" Padding="5,1">
                                        <TextBlock Text="SUBNET #3" FontSize="9" FontWeight="Bold" Foreground="#D182FF"/>
                                    </Border>
                                </StackPanel>
                            </StackPanel>

                            <!-- Inline IP Input -->
                            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                                <TextBlock x:Name="TxtLocalIPLabel3" Text="目標 IP:" FontSize="12" Foreground="#A0A0A0" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                <TextBox x:Name="TxtLocalIP3" Width="140" Text="192.168.1.227" Style="{StaticResource FluentTextBoxStyle}" Margin="0,0,6,0"/>
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
                                <ColumnDefinition Width="135"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Background="#1D1D1D" CornerRadius="5" Padding="10,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLatency3" Text="目前延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLatency3" Text="-- ms" FontSize="18" FontWeight="Bold" Foreground="#60CDFF" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblAvg3" Text="平均延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalAvg3" Text="-- ms" FontSize="13" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblMinMax3" Text="最小 / 最大" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalMinMax3" Text="-- / --" FontSize="12" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock x:Name="LblLoss3" Text="遺失率 (Lost/Total)" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLoss3" Text="0.0% (0/0)" FontSize="12" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="5" Padding="8,6">
                                <StackPanel>
                                    <TextBlock x:Name="LblLastSeen3" Text="最後回應時間" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLastSeen3" Text="等待回應..." FontSize="11" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </Grid>
                </Border>
            </StackPanel>
        </ScrollViewer>

        <!-- 4: Activity Log -->
        <Border Grid.Row="4" Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="12">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,6">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock x:Name="TxtActivityFeedTitle" Text="📋 即時偵測日誌 (Activity Feed)" FontSize="12" FontWeight="SemiBold" Foreground="#D0D0D0"/>
                        <TextBlock x:Name="TxtLogCounter" Text="(最新 100 筆)" FontSize="11" Foreground="#777777" Margin="6,1,0,0"/>
                    </StackPanel>

                    <Button x:Name="BtnClearLog" Grid.Column="1" Content="清除日誌" Style="{StaticResource FluentButtonStyle}" Padding="10,2" FontSize="11"/>
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

# 取得控制列項目
$txtHeaderSubtitle = $window.FindName("TxtHeaderSubtitle")
$cmbInterval       = $window.FindName("CmbInterval")
$cmbItem1          = $window.FindName("CmbItem1")
$cmbItem2          = $window.FindName("CmbItem2")
$cmbItem3          = $window.FindName("CmbItem3")
$cmbItem5          = $window.FindName("CmbItem5")
$txtIntervalLabel  = $window.FindName("TxtIntervalLabel")
$chkSoundAlert     = $window.FindName("ChkSoundAlert")
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

# 指標標籤列表 (供語系切換批次處理)
$latencyLabels = @($window.FindName("LblLatency0"), $window.FindName("LblLatency1"), $window.FindName("LblLatency2"), $window.FindName("LblLatency3"))
$avgLabels     = @($window.FindName("LblAvg0"), $window.FindName("LblAvg1"), $window.FindName("LblAvg2"), $window.FindName("LblAvg3"))
$minMaxLabels  = @($window.FindName("LblMinMax0"), $window.FindName("LblMinMax1"), $window.FindName("LblMinMax2"), $window.FindName("LblMinMax3"))
$lossLabels    = @($window.FindName("LblLoss0"), $window.FindName("LblLoss1"), $window.FindName("LblLoss2"), $window.FindName("LblLoss3"))
$lastSeenLabels= @($window.FindName("LblLastSeen0"), $window.FindName("LblLastSeen1"), $window.FindName("LblLastSeen2"), $window.FindName("LblLastSeen3"))

# 套用初次偵測到的網段資訊
$txtSubnetInfo.Text  = "$($detectedSubnet.Subnet) ($($detectedSubnet.InterfaceName))"
$txtLocalHostIP.Text = $detectedSubnet.LocalIP
$txtGatewayIP.Text   = $detectedSubnet.Gateway

$txtLocalIP1.Text    = $detectedSubnet.Target1
$txtLocalIP2.Text    = $detectedSubnet.Target2
$txtLocalIP3.Text    = $detectedSubnet.Target3

# 6. 目標卡片與統計物件映射表
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
        Pause            = "暫停偵測"
        Resume           = "繼續偵測"
        ResetStats       = "重置所有統計"
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
        ActivityFeed     = "📋 即時偵測日誌 (Activity Feed)"
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
    }
    "en" = @{
        AppTitle         = "Network Sentinel - Fluent Network Monitor"
        HeaderSubtitle   = "Smart subnet discovery, monitoring Internet (Google) & 3 local subnet targets in real-time"
        MonitoringActive = "MONITORING ACTIVE (4 TARGETS)"
        MonitoringPaused = "MONITORING PAUSED"
        IntervalLabel    = "Interval:"
        SoundAlert       = "Alert on Disconnect"
        Pause            = "Pause"
        Resume           = "Resume"
        ResetStats       = "Reset All Stats"
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
        ActivityFeed     = "📋 Real-time Activity Feed"
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
    }
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

    # 批次更新指標文字標籤
    $latencyLabels | ForEach-Object { $_.Text = $dict.CurLatency }
    $avgLabels     | ForEach-Object { $_.Text = $dict.AvgLatency }
    $minMaxLabels  | ForEach-Object { $_.Text = $dict.MinMaxLatency }
    $lossLabels    | ForEach-Object { $_.Text = $dict.LossRate }
    $lastSeenLabels| ForEach-Object { $_.Text = $dict.LastSeen }

    # 更新卡片狀態徽章文字
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
}

# 8. 輔助函式：新增日誌
function Add-LogLine {
    param([string]$line)
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $formatted = "[$timestamp] $line"
    $logEntries.Add($formatted)
    if ($logEntries.Count -gt $maxLogLines) {
        $logEntries.RemoveAt(0)
    }
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

# 9. 建立並啟動非同步 Ping Runner (4 目標)
$runner = New-Object PingMonitorRunner
$runner.InternetTarget = "www.google.com"
$runner.LocalTarget1   = $txtLocalIP1.Text
$runner.LocalTarget2   = $txtLocalIP2.Text
$runner.LocalTarget3   = $txtLocalIP3.Text
$runner.IntervalMs     = 1000

# 10. 處理 Ping 回應事件回呼
$runner.add_OnPingResult({
    param([PingResult]$result)
    
    $id = $result.TargetId
    if (-not $statsMap.ContainsKey($id) -or -not $cardsMap.ContainsKey($id)) { return }

    $stats = $statsMap[$id]
    $card  = $cardsMap[$id]
    $stats.Sent++
    $timeStr = (Get-Date $result.Timestamp).ToString("HH:mm:ss")
    $dict = $i18n[$script:currentLang]

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

        if ($chkSoundAlert.IsChecked -and $stats.LastOnline) {
            [System.Media.SystemSounds]::Exclamation.Play()
        }
        $stats.LastOnline = $false
    }

    # 封包遺失率計算
    $lossPct = [math]::Round(($stats.Lost / $stats.Sent) * 100, 1)
    $card.Loss.Text = "$lossPct% ($($stats.Lost)/$($stats.Sent))"
    $card.Loss.Foreground = if ($stats.Lost -eq 0) { $brushGreenText } else { $brushRedText }

    # 更新日誌
    $targetName = if ($script:currentLang -eq "zh") { $card.NameZh } else { $card.NameEn }
    $statusMsg = if ($result.Success) {
        $dur = if ($result.RoundtripTime -eq 0) { "< 1ms" } else { "$($result.RoundtripTime)ms" }
        "OK ($dur)"
    } else {
        "FAILED ($($result.Status))"
    }
    Add-LogLine -line "$targetName [$($result.Target)] -> $statusMsg"
})

# 11. 事件：修改與套用 Local IP 1, 2, 3
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
    $card = $cardsMap[$targetKey]
    $card.Latency.Text  = "-- ms"
    $card.Avg.Text      = "-- ms"
    $card.MinMax.Text   = "-- / --"
    $card.Loss.Text     = "0.0% (0/0)"
    $card.LastSeen.Text = $i18n[$script:currentLang].Waiting

    $logMsg = if ($script:currentLang -eq "zh") { "⚙️ 【設定更新】已變更區網設備 #$index 目標為: $rawIP" } else { "⚙️ [Config Update] Local target #$index updated to: $rawIP" }
    Add-LogLine -line $logMsg
}

# 綁定 Local 1
$btnApplyIP1.Add_Click({ Set-LocalTarget -index 1 -box $txtLocalIP1 })
$txtLocalIP1.Add_KeyDown({ param($s, $e); if ($e.Key -eq [System.Windows.Input.Key]::Enter) { Set-LocalTarget -index 1 -box $txtLocalIP1 } })

# 綁定 Local 2
$btnApplyIP2.Add_Click({ Set-LocalTarget -index 2 -box $txtLocalIP2 })
$txtLocalIP2.Add_KeyDown({ param($s, $e); if ($e.Key -eq [System.Windows.Input.Key]::Enter) { Set-LocalTarget -index 2 -box $txtLocalIP2 } })

# 綁定 Local 3
$btnApplyIP3.Add_Click({ Set-LocalTarget -index 3 -box $txtLocalIP3 })
$txtLocalIP3.Add_KeyDown({ param($s, $e); if ($e.Key -eq [System.Windows.Input.Key]::Enter) { Set-LocalTarget -index 3 -box $txtLocalIP3 } })

# 12. 事件：重新偵測當前網段
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

    # 重置 3 個 Local 目標統計
    Reset-TargetStats -stats $statsMap["Local1"]
    Reset-TargetStats -stats $statsMap["Local2"]
    Reset-TargetStats -stats $statsMap["Local3"]

    $logMsg1 = if ($script:currentLang -eq "zh") { "🔍 【網段重整】成功辨識網段: $($newSubnet.Subnet) ($($newSubnet.InterfaceName))" } else { "🔍 [Subnet Refresh] Subnet discovered: $($newSubnet.Subnet) ($($newSubnet.InterfaceName))" }
    $logMsg2 = if ($script:currentLang -eq "zh") { "📡 已同步更新區網監控目標: $($newSubnet.Target1) / $($newSubnet.Target2) / $($newSubnet.Target3)" } else { "📡 Synchronized local targets: $($newSubnet.Target1) / $($newSubnet.Target2) / $($newSubnet.Target3)" }
    Add-LogLine -line $logMsg1
    Add-LogLine -line $logMsg2
})

# 13. 事件：中英文雙語切換按鈕
$btnToggleLang.Add_Click({
    if ($script:currentLang -eq "zh") {
        Apply-Language -lang "en"
        Add-LogLine -line "🌐 UI language switched to: English"
    } else {
        Apply-Language -lang "zh"
        Add-LogLine -line "🌐 介面語言已切換為: 繁體中文"
    }
})

# 14. 事件：偵測間隔變更
$cmbInterval.Add_SelectionChanged({
    $selectedItem = $cmbInterval.SelectedItem
    if ($selectedItem -and $selectedItem.Tag) {
        $newInterval = [int]$selectedItem.Tag
        $runner.IntervalMs = $newInterval
        $logMsg = if ($script:currentLang -eq "zh") { "⚙️ 【設定更新】偵測間隔已調整為: $($newInterval / 1000) 秒" } else { "⚙️ [Config Update] Interval set to: $($newInterval / 1000)s" }
        Add-LogLine -line $logMsg
    }
})

# 15. 事件：暫停 / 繼續偵測
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
        $logMsg = if ($script:currentLang -eq "zh") { "▶️ 【監控恢復】已恢復背景即時偵測" } else { "▶️ [Resumed] Background monitoring resumed" }
        Add-LogLine -line $logMsg
    }
})

# 16. 事件：重置統計
$btnResetStats.Add_Click({
    foreach ($key in $statsMap.Keys) {
        Reset-TargetStats -stats $statsMap[$key]
        $card = $cardsMap[$key]
        $card.Avg.Text    = "-- ms"
        $card.MinMax.Text = "-- / --"
        $card.Loss.Text   = "0.0% (0/0)"
    }
    $logMsg = if ($script:currentLang -eq "zh") { "🔄 【重置統計】所有目標歷史延遲與遺失率計數已歸零" } else { "🔄 [Stats Reset] All latency & packet loss stats reset" }
    Add-LogLine -line $logMsg
})

# 17. 事件：清除日誌
$btnClearLog.Add_Click({
    $logEntries.Clear()
    $txtLog.Text = ""
    $dict = $i18n[$script:currentLang]
    $txtLogCounter.Text = "($($dict.LogCountPrefix) 0 / $maxLogLines $($dict.LogCountSuffix))"
})

# 18. 視窗載入完成套用 Windows 11 Fluent 深色標題列與圓角
$window.Add_SourceInitialized({
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        [DwmHelper]::ApplyFluentStyling($helper.Handle)
    } catch { }
})

# 19. 視窗關閉時終止背景執行緒
$window.Add_Closing({
    $runner.Stop()
})

# 20. 啟動監控並顯示視窗
Add-LogLine -line "🚀 Fluent Network Sentinel 已啟動 (Started)"
Add-LogLine -line "🔍 偵測到目前網段: $($detectedSubnet.Subnet) ($($detectedSubnet.InterfaceName))"
Add-LogLine -line "🌐 網際網路目標: www.google.com"
Add-LogLine -line "📡 閘道目標 #1: $($detectedSubnet.Target1)"
Add-LogLine -line "💻 設備目標 #2: $($detectedSubnet.Target2) ($($detectedSubnet.Target2Desc))"
Add-LogLine -line "🖥️ 本機目標 #3: $($detectedSubnet.Target3) ($($detectedSubnet.Target3Desc))"

$runner.Start($window.Dispatcher)
$null = $window.ShowDialog()
