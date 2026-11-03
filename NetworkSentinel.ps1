<#
.SYNOPSIS
    Fluent Network Sentinel - Windows 11 Fluent UI 即時網路狀態監控工具
.DESCRIPTION
    使用 PowerShell + WPF 設計的 Windows 11 Fluent UI 網路連線監控程式。
    - 持續即時監控外部網際網路 (www.google.com)
    - 持續即時監控區域網路設備 (預設自動抓取 Gateway 或自訂 IP)
    - 支援於 UI 介面即時動態修改目標 Local IP
    - 提供連線延遲 (目前/平均/最小/最大)、封包遺失率、回應歷史日誌
    - 支援調整偵測間隔 (1s ~ 5s)、暫停/繼續、重置統計與斷線音效提示
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
    public string Target { get; set; }
    public string TargetCategory { get; set; } // "Internet" or "Local"
    public bool Success { get; set; }
    public long RoundtripTime { get; set; }
    public string Status { get; set; }
    public DateTime Timestamp { get; set; }
}

public class FastPinger {
    public static async Task<PingResult> PingOnceAsync(string target, string category, int timeout) {
        PingResult res = new PingResult();
        res.Target = target;
        res.TargetCategory = category;
        res.Timestamp = DateTime.Now;
        try {
            using (Ping ping = new Ping()) {
                PingReply reply = await ping.SendPingAsync(target, timeout);
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
    private string _localTarget = "192.168.1.1";
    private string _internetTarget = "www.google.com";

    public string InternetTarget {
        get { lock(_lock) { return _internetTarget; } }
        set { lock(_lock) { _internetTarget = value; } }
    }

    public string LocalTarget {
        get { lock(_lock) { return _localTarget; } }
        set { lock(_lock) { _localTarget = value; } }
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
                string tInternet = InternetTarget;
                string tLocal = LocalTarget;

                Task<PingResult> t1 = FastPinger.PingOnceAsync(tInternet, "Internet", 1500);
                Task<PingResult> t2 = FastPinger.PingOnceAsync(tLocal, "Local", 1500);

                await Task.WhenAll(t1, t2);

                if (!token.IsCancellationRequested && dispatcher != null && !dispatcher.HasShutdownStarted) {
                    dispatcher.BeginInvoke(new Action(() => {
                        try {
                            if (OnPingResult != null) {
                                OnPingResult(t1.Result);
                                OnPingResult(t2.Result);
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

# 3. 自動偵測本機預設閘道 (Default Gateway)，若無則預設 192.168.1.1
$detectedGateway = "192.168.1.1"
try {
    $gwRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gwRoute -and $gwRoute.NextHop -and $gwRoute.NextHop -ne '0.0.0.0') {
        $detectedGateway = $gwRoute.NextHop
    }
} catch { }

# 4. Windows 11 Fluent UI XAML 定義
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Network Sentinel - Fluent Network Monitor"
        Height="840" Width="740" MinHeight="720" MinWidth="680"
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
            <Setter Property="Padding" Value="14,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
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
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="FontSize" Value="13"/>
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
    </Window.Resources>

    <Grid Margin="22">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/> <!-- Header -->
            <RowDefinition Height="Auto"/> <!-- Top Controls Toolbar -->
            <RowDefinition Height="Auto"/> <!-- Internet Card (Google) -->
            <RowDefinition Height="Auto"/> <!-- Local Target Card -->
            <RowDefinition Height="*"/>    <!-- Activity Log -->
        </Grid.RowDefinitions>

        <!-- Header -->
        <Grid Grid.Row="0" Margin="0,0,0,16">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="⚡" FontSize="22" Margin="0,0,8,0" VerticalAlignment="Center" Foreground="#60CDFF"/>
                    <TextBlock Text="Network Sentinel" FontSize="20" FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"/>
                </StackPanel>
                <TextBlock Text="即時監控外部網際網路 (Google) 與內部區域網路設備連線狀態" FontSize="12" Foreground="#8E8E8E" Margin="30,2,0,0"/>
            </StackPanel>

            <!-- Overall Status Badge -->
            <Border x:Name="OverallBadge" Grid.Column="1" Background="#163821" BorderBrush="#256938" BorderThickness="1" CornerRadius="14" Padding="12,5" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Ellipse x:Name="OverallDot" Width="8" Height="8" Fill="#4CC2FF" Margin="0,0,8,0"/>
                    <TextBlock x:Name="OverallText" Text="MONITORING ACTIVE" FontSize="11" FontWeight="Bold" Foreground="#D0EEFF"/>
                </StackPanel>
            </Border>
        </Grid>

        <!-- Controls Toolbar -->
        <Border Grid.Row="1" Background="#202020" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="6" Padding="12,8" Margin="0,0,0,16">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,16,0">
                    <TextBlock Text="偵測間隔:" VerticalAlignment="Center" FontSize="13" Foreground="#B0B0B0" Margin="0,0,8,0"/>
                    <ComboBox x:Name="CmbInterval" SelectedIndex="0" Width="110" Height="28" Background="#262626" Foreground="White" BorderBrush="#3D3D3D">
                        <ComboBoxItem Content="1 秒 (1000ms)" Tag="1000"/>
                        <ComboBoxItem Content="2 秒 (2000ms)" Tag="2000"/>
                        <ComboBoxItem Content="3 秒 (3000ms)" Tag="3000"/>
                        <ComboBoxItem Content="5 秒 (5000ms)" Tag="5000"/>
                    </ComboBox>
                </StackPanel>

                <CheckBox x:Name="ChkSoundAlert" Grid.Column="1" Content="斷線警報音效" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,16,0" Cursor="Hand"/>

                <StackPanel Grid.Column="3" Orientation="Horizontal">
                    <Button x:Name="BtnPauseResume" Content="暫停偵測" Style="{StaticResource FluentButtonStyle}" Margin="0,0,8,0" Padding="12,4"/>
                    <Button x:Name="BtnResetStats" Content="重置統計" Style="{StaticResource FluentButtonStyle}" Padding="12,4"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Card 1: Internet (Google) -->
        <Border Grid.Row="2" Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="16" Margin="0,0,0,14">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- Top row: Icon + Target + Status Pill -->
                <Grid Grid.Row="0" Margin="0,0,0,14">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <Border Grid.Column="0" Width="38" Height="38" CornerRadius="8" Background="#162E44" Margin="0,0,12,0">
                        <TextBlock Text="🌐" FontSize="18" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>

                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="網際網路連線 (Internet)" FontSize="15" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                            <Border Background="#1C2F20" BorderBrush="#2F5C37" BorderThickness="1" CornerRadius="4" Margin="8,0,0,0" Padding="6,1">
                                <TextBlock Text="WAN" FontSize="10" FontWeight="Bold" Foreground="#6CCB5F"/>
                            </Border>
                        </StackPanel>
                        <TextBlock Text="目標主機: www.google.com" FontSize="12" Foreground="#8A8A8A" Margin="0,2,0,0"/>
                    </StackPanel>

                    <!-- Google Status Pill -->
                    <Border x:Name="GoogleStatusPill" Grid.Column="2" Background="#163821" BorderBrush="#256938" BorderThickness="1" CornerRadius="12" Padding="12,4" VerticalAlignment="Center">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Ellipse x:Name="GoogleStatusDot" Width="8" Height="8" Fill="#52C41A" Margin="0,0,6,0"/>
                            <TextBlock x:Name="GoogleStatusText" Text="連線正常 (ONLINE)" FontSize="12" FontWeight="SemiBold" Foreground="#6CCB5F"/>
                        </StackPanel>
                    </Border>
                </Grid>

                <!-- Metrics Grid -->
                <Grid Grid.Row="1">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="145"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <!-- Current Latency (Hero) -->
                    <Border Grid.Column="0" Background="#1D1D1D" CornerRadius="6" Padding="12,8" Margin="0,0,8,0">
                        <StackPanel>
                            <TextBlock Text="目前延遲" FontSize="11" Foreground="#888888"/>
                            <TextBlock x:Name="TxtGoogleLatency" Text="-- ms" FontSize="22" FontWeight="Bold" Foreground="#60CDFF" Margin="0,3,0,0"/>
                        </StackPanel>
                    </Border>

                    <!-- Avg -->
                    <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="6" Padding="10,8" Margin="0,0,8,0">
                        <StackPanel>
                            <TextBlock Text="平均延遲" FontSize="11" Foreground="#888888"/>
                            <TextBlock x:Name="TxtGoogleAvg" Text="-- ms" FontSize="14" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>

                    <!-- Min / Max -->
                    <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="6" Padding="10,8" Margin="0,0,8,0">
                        <StackPanel>
                            <TextBlock Text="最小 / 最大" FontSize="11" Foreground="#888888"/>
                            <TextBlock x:Name="TxtGoogleMinMax" Text="-- / --" FontSize="13" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>

                    <!-- Packet Loss -->
                    <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="6" Padding="10,8" Margin="0,0,8,0">
                        <StackPanel>
                            <TextBlock Text="遺失率 (Lost/Total)" FontSize="11" Foreground="#888888"/>
                            <TextBlock x:Name="TxtGoogleLoss" Text="0.0% (0/0)" FontSize="13" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>

                    <!-- Last Seen -->
                    <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="6" Padding="10,8">
                        <StackPanel>
                            <TextBlock Text="最後回應時間" FontSize="11" Foreground="#888888"/>
                            <TextBlock x:Name="TxtGoogleLastSeen" Text="等待回應..." FontSize="12" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>
                </Grid>
            </Grid>
        </Border>

        <!-- Card 2: Local IP Target -->
        <Border Grid.Row="3" Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="16" Margin="0,0,0,14">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- Top row: Icon + Title + Status Pill -->
                <Grid Grid.Row="0" Margin="0,0,0,10">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <Border Grid.Column="0" Width="38" Height="38" CornerRadius="8" Background="#3B2614" Margin="0,0,12,0">
                        <TextBlock Text="📡" FontSize="18" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>

                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="區域網路設備 (Local Target)" FontSize="15" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                            <Border Background="#332414" BorderBrush="#6B491F" BorderThickness="1" CornerRadius="4" Margin="8,0,0,0" Padding="6,1">
                                <TextBlock Text="LAN" FontSize="10" FontWeight="Bold" Foreground="#FFB900"/>
                            </Border>
                        </StackPanel>
                        <TextBlock x:Name="TxtLocalTargetDesc" Text="支援自訂 Gateway / 路由器 / NAS / 伺服器 IP 位址" FontSize="12" Foreground="#8A8A8A" Margin="0,2,0,0"/>
                    </StackPanel>

                    <!-- Local Status Pill -->
                    <Border x:Name="LocalStatusPill" Grid.Column="2" Background="#163821" BorderBrush="#256938" BorderThickness="1" CornerRadius="12" Padding="12,4" VerticalAlignment="Center">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Ellipse x:Name="LocalStatusDot" Width="8" Height="8" Fill="#52C41A" Margin="0,0,6,0"/>
                            <TextBlock x:Name="LocalStatusText" Text="連線正常 (ONLINE)" FontSize="12" FontWeight="SemiBold" Foreground="#6CCB5F"/>
                        </StackPanel>
                    </Border>
                </Grid>

                <!-- Middle row: IP Edit Bar -->
                <Border Grid.Row="1" Background="#1E1E1E" BorderBrush="#2C2C2C" BorderThickness="1" CornerRadius="6" Padding="10,8" Margin="0,0,0,12">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <TextBlock Grid.Column="0" Text="監控 IP / 主機名稱:" VerticalAlignment="Center" FontSize="13" Foreground="#B0B0B0" Margin="0,0,10,0"/>
                        <TextBox x:Name="TxtLocalIP" Grid.Column="1" Text="192.168.1.1" Style="{StaticResource FluentTextBoxStyle}" Margin="0,0,10,0"/>
                        <Button x:Name="BtnApplyIP" Grid.Column="2" Content="套用新 IP (Enter)" Style="{StaticResource AccentButtonStyle}" Padding="16,6"/>
                    </Grid>
                </Border>

                <!-- Metrics Grid -->
                <Grid Grid.Row="2">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="145"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <!-- Current Latency (Hero) -->
                    <Border Grid.Column="0" Background="#1D1D1D" CornerRadius="6" Padding="12,8" Margin="0,0,8,0">
                        <StackPanel>
                            <TextBlock Text="目前延遲" FontSize="11" Foreground="#888888"/>
                            <TextBlock x:Name="TxtLocalLatency" Text="-- ms" FontSize="22" FontWeight="Bold" Foreground="#60CDFF" Margin="0,3,0,0"/>
                        </StackPanel>
                    </Border>

                    <!-- Avg -->
                    <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="6" Padding="10,8" Margin="0,0,8,0">
                        <StackPanel>
                            <TextBlock Text="平均延遲" FontSize="11" Foreground="#888888"/>
                            <TextBlock x:Name="TxtLocalAvg" Text="-- ms" FontSize="14" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>

                    <!-- Min / Max -->
                    <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="6" Padding="10,8" Margin="0,0,8,0">
                        <StackPanel>
                            <TextBlock Text="最小 / 最大" FontSize="11" Foreground="#888888"/>
                            <TextBlock x:Name="TxtLocalMinMax" Text="-- / --" FontSize="13" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>

                    <!-- Packet Loss -->
                    <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="6" Padding="10,8" Margin="0,0,8,0">
                        <StackPanel>
                            <TextBlock Text="遺失率 (Lost/Total)" FontSize="11" Foreground="#888888"/>
                            <TextBlock x:Name="TxtLocalLoss" Text="0.0% (0/0)" FontSize="13" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>

                    <!-- Last Seen -->
                    <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="6" Padding="10,8">
                        <StackPanel>
                            <TextBlock Text="最後回應時間" FontSize="11" Foreground="#888888"/>
                            <TextBlock x:Name="TxtLocalLastSeen" Text="等待回應..." FontSize="12" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>
                </Grid>
            </Grid>
        </Border>

        <!-- Card 3: Activity Log -->
        <Border Grid.Row="4" Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="14">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,8">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="📋 即時偵測日誌 (Activity Feed)" FontSize="13" FontWeight="SemiBold" Foreground="#D0D0D0"/>
                        <TextBlock x:Name="TxtLogCounter" Text="(最新 100 筆)" FontSize="11" Foreground="#777777" Margin="6,2,0,0"/>
                    </StackPanel>

                    <Button x:Name="BtnClearLog" Grid.Column="1" Content="清除日誌" Style="{StaticResource FluentButtonStyle}" Padding="10,3" FontSize="11"/>
                </Grid>

                <Border Grid.Row="1" Background="#181818" BorderBrush="#2A2A2A" BorderThickness="1" CornerRadius="4">
                    <TextBox x:Name="TxtLog" Background="Transparent" Foreground="#A9D18E" BorderThickness="0"
                             FontFamily="Consolas, Cascadia Code, Courier New" FontSize="12"
                             IsReadOnly="True" VerticalScrollBarVisibility="Auto"
                             TextWrapping="NoWrap" Padding="10" AcceptsReturn="True"/>
                </Border>
            </Grid>
        </Border>

    </Grid>
</Window>
"@

# 5. 解析 XAML 生成視窗物件與控制項參照
$window = [Windows.Markup.XamlReader]::Parse($xaml)

# 取得主要控制項
$txtLocalIP        = $window.FindName("TxtLocalIP")
$btnApplyIP        = $window.FindName("BtnApplyIP")
$txtLocalTargetDesc= $window.FindName("TxtLocalTargetDesc")

$cmbInterval       = $window.FindName("CmbInterval")
$chkSoundAlert     = $window.FindName("ChkSoundAlert")
$btnPauseResume    = $window.FindName("BtnPauseResume")
$btnResetStats     = $window.FindName("BtnResetStats")
$btnClearLog       = $window.FindName("BtnClearLog")

$overallBadge      = $window.FindName("OverallBadge")
$overallDot        = $window.FindName("OverallDot")
$overallText       = $window.FindName("OverallText")

# Google 控制項
$googleStatusPill  = $window.FindName("GoogleStatusPill")
$googleStatusDot   = $window.FindName("GoogleStatusDot")
$googleStatusText  = $window.FindName("GoogleStatusText")
$txtGoogleLatency  = $window.FindName("TxtGoogleLatency")
$txtGoogleAvg      = $window.FindName("TxtGoogleAvg")
$txtGoogleMinMax   = $window.FindName("TxtGoogleMinMax")
$txtGoogleLoss     = $window.FindName("TxtGoogleLoss")
$txtGoogleLastSeen = $window.FindName("TxtGoogleLastSeen")

# Local 控制項
$localStatusPill   = $window.FindName("LocalStatusPill")
$localStatusDot    = $window.FindName("LocalStatusDot")
$localStatusText   = $window.FindName("LocalStatusText")
$txtLocalLatency   = $window.FindName("TxtLocalLatency")
$txtLocalAvg       = $window.FindName("TxtLocalAvg")
$txtLocalMinMax    = $window.FindName("TxtLocalMinMax")
$txtLocalLoss      = $window.FindName("TxtLocalLoss")
$txtLocalLastSeen  = $window.FindName("TxtLocalLastSeen")

$txtLog            = $window.FindName("TxtLog")
$txtLogCounter     = $window.FindName("TxtLogCounter")

# 初始化預設 Gateway
$txtLocalIP.Text = $detectedGateway
$txtLocalTargetDesc.Text = "目前監控目標: $detectedGateway (本機自動偵測之 Default Gateway)"

# 6. 統計數據結構
$googleStats = [PSCustomObject]@{
    Sent       = 0
    Recv       = 0
    Lost       = 0
    MinTime    = -1
    MaxTime    = -1
    TotalTime  = 0
    LastOnline = $true
}

$localStats = [PSCustomObject]@{
    Sent       = 0
    Recv       = 0
    Lost       = 0
    MinTime    = -1
    MaxTime    = -1
    TotalTime  = 0
    LastOnline = $true
}

$logEntries = [System.Collections.Generic.List[string]]::new()
$maxLogLines = 100

# 7. 輔助函式：新增日誌
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
    $txtLogCounter.Text = "($($logEntries.Count) / $maxLogLines 筆)"
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

# 8. 建立並啟動非同步 Ping Runner
$runner = New-Object PingMonitorRunner
$runner.InternetTarget = "www.google.com"
$runner.LocalTarget = $detectedGateway
$runner.IntervalMs = 1000

# 9. 處理 Ping 回應事件回呼
$runner.add_OnPingResult({
    param([PingResult]$result)
    
    $timeStr = (Get-Date $result.Timestamp).ToString("HH:mm:ss")
    
    if ($result.TargetCategory -eq "Internet") {
        $stats = $googleStats
        $stats.Sent++

        if ($result.Success) {
            $stats.Recv++
            $rtt = $result.RoundtripTime
            $stats.TotalTime += $rtt
            
            if ($stats.MinTime -eq -1 -or $rtt -lt $stats.MinTime) { $stats.MinTime = $rtt }
            if ($rtt -gt $stats.MaxTime) { $stats.MaxTime = $rtt }
            
            # UI 狀態徽章 (Online)
            $googleStatusPill.Background = $brushGreenBg
            $googleStatusPill.BorderBrush = $brushGreenBorder
            $googleStatusDot.Fill = $brushGreenDot
            $googleStatusText.Text = "連線正常 (ONLINE)"
            $googleStatusText.Foreground = $brushGreenText

            # 延遲文字與顏色
            $displayRtt = if ($rtt -eq 0) { "< 1 ms" } else { "$rtt ms" }
            $txtGoogleLatency.Text = $displayRtt
            if ($rtt -lt 40) {
                $txtGoogleLatency.Foreground = $brushCyanText
            } elseif ($rtt -lt 120) {
                $txtGoogleLatency.Foreground = $brushAmberText
            } else {
                $txtGoogleLatency.Foreground = $brushOrangeText
            }

            $avg = [math]::Round($stats.TotalTime / $stats.Recv, 1)
            $txtGoogleAvg.Text = "$avg ms"
            $txtGoogleMinMax.Text = "$($stats.MinTime) ms / $($stats.MaxTime) ms"
            $txtGoogleLastSeen.Text = $timeStr
            $stats.LastOnline = $true
        } else {
            $stats.Lost++
            
            # UI 狀態徽章 (Offline)
            $googleStatusPill.Background = $brushRedBg
            $googleStatusPill.BorderBrush = $brushRedBorder
            $googleStatusDot.Fill = $brushRedDot
            $googleStatusText.Text = "連線中斷 (OFFLINE)"
            $googleStatusText.Foreground = $brushRedText

            $txtGoogleLatency.Text = "TIMEOUT"
            $txtGoogleLatency.Foreground = $brushRedDot

            # 音效警報
            if ($chkSoundAlert.IsChecked -and $stats.LastOnline) {
                [System.Media.SystemSounds]::Exclamation.Play()
            }
            $stats.LastOnline = $false
        }

        # 封包遺失率計算
        $lossPct = [math]::Round(($stats.Lost / $stats.Sent) * 100, 1)
        $txtGoogleLoss.Text = "$lossPct% ($($stats.Lost)/$($stats.Sent))"
        $txtGoogleLoss.Foreground = if ($stats.Lost -eq 0) { $brushGreenText } else { $brushRedText }

    } else {
        # Local Target
        $stats = $localStats
        $stats.Sent++

        if ($result.Success) {
            $stats.Recv++
            $rtt = $result.RoundtripTime
            $stats.TotalTime += $rtt
            
            if ($stats.MinTime -eq -1 -or $rtt -lt $stats.MinTime) { $stats.MinTime = $rtt }
            if ($rtt -gt $stats.MaxTime) { $stats.MaxTime = $rtt }

            # UI 狀態徽章 (Online)
            $localStatusPill.Background = $brushGreenBg
            $localStatusPill.BorderBrush = $brushGreenBorder
            $localStatusDot.Fill = $brushGreenDot
            $localStatusText.Text = "連線正常 (ONLINE)"
            $localStatusText.Foreground = $brushGreenText

            $displayRtt = if ($rtt -eq 0) { "< 1 ms" } else { "$rtt ms" }
            $txtLocalLatency.Text = $displayRtt
            if ($rtt -lt 10) {
                $txtLocalLatency.Foreground = $brushCyanText
            } elseif ($rtt -lt 50) {
                $txtLocalLatency.Foreground = $brushAmberText
            } else {
                $txtLocalLatency.Foreground = $brushOrangeText
            }

            $avg = [math]::Round($stats.TotalTime / $stats.Recv, 1)
            $txtLocalAvg.Text = "$avg ms"
            $txtLocalMinMax.Text = "$($stats.MinTime) ms / $($stats.MaxTime) ms"
            $txtLocalLastSeen.Text = $timeStr
            $stats.LastOnline = $true
        } else {
            $stats.Lost++
            
            # UI 狀態徽章 (Offline)
            $localStatusPill.Background = $brushRedBg
            $localStatusPill.BorderBrush = $brushRedBorder
            $localStatusDot.Fill = $brushRedDot
            $localStatusText.Text = "目標無回應 (OFFLINE)"
            $localStatusText.Foreground = $brushRedText

            $txtLocalLatency.Text = "TIMEOUT"
            $txtLocalLatency.Foreground = $brushRedDot

            if ($chkSoundAlert.IsChecked -and $stats.LastOnline) {
                [System.Media.SystemSounds]::Exclamation.Play()
            }
            $stats.LastOnline = $false
        }

        # 封包遺失率計算
        $lossPct = [math]::Round(($stats.Lost / $stats.Sent) * 100, 1)
        $txtLocalLoss.Text = "$lossPct% ($($stats.Lost)/$($stats.Sent))"
        $txtLocalLoss.Foreground = if ($stats.Lost -eq 0) { $brushGreenText } else { $brushRedText }
    }

    # 記錄日誌 (雙方每次 Ping 更新)
    $targetTag = if ($result.TargetCategory -eq "Internet") { "🌐 Google" } else { "📡 $($result.Target)" }
    $statusMsg = if ($result.Success) {
        $dur = if ($result.RoundtripTime -eq 0) { "< 1ms" } else { "$($result.RoundtripTime)ms" }
        "OK ($dur)"
    } else {
        "FAILED ($($result.Status))"
    }
    Add-LogLine -line "$targetTag -> $statusMsg"
})

# 10. 事件：修改與套用 Local IP
$ApplyLocalIPAction = {
    $rawIP = $txtLocalIP.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($rawIP)) {
        [System.Windows.MessageBox]::Show("請輸入有效的 IP 位址或主機名稱！", "輸入錯誤", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $runner.LocalTarget = $rawIP
    Reset-TargetStats -stats $localStats
    
    $txtLocalLatency.Text = "-- ms"
    $txtLocalAvg.Text = "-- ms"
    $txtLocalMinMax.Text = "-- / --"
    $txtLocalLoss.Text = "0.0% (0/0)"
    $txtLocalLastSeen.Text = "重新偵測中..."
    $txtLocalTargetDesc.Text = "目前監控目標: $rawIP (使用者自訂目標)"

    Add-LogLine -line "⚙️ 【設定更新】已變更區域網路監控目標為: $rawIP"
}

$btnApplyIP.Add_Click({
    & $ApplyLocalIPAction
})

$txtLocalIP.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
        & $ApplyLocalIPAction
    }
})

# 11. 事件：偵測間隔變更
$cmbInterval.Add_SelectionChanged({
    $selectedItem = $cmbInterval.SelectedItem
    if ($selectedItem -and $selectedItem.Tag) {
        $newInterval = [int]$selectedItem.Tag
        $runner.IntervalMs = $newInterval
        Add-LogLine -line "⚙️ 【設定更新】偵測間隔已調整為: $($newInterval / 1000) 秒"
    }
})

# 12. 事件：暫停 / 繼續偵測
$btnPauseResume.Add_Click({
    if ($runner.IsRunning) {
        $runner.Stop()
        $btnPauseResume.Content = "繼續偵測"
        $overallBadge.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#333333")
        $overallBadge.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#555555")
        $overallDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888888")
        $overallText.Text = "MONITORING PAUSED"
        $overallText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CCCCCC")
        Add-LogLine -line "⏸️ 【監控暫停】已停止背景偵測"
    } else {
        $runner.Start($window.Dispatcher)
        $btnPauseResume.Content = "暫停偵測"
        $overallBadge.Background = $brushGreenBg
        $overallBadge.BorderBrush = $brushGreenBorder
        $overallDot.Fill = $brushCyanText
        $overallText.Text = "MONITORING ACTIVE"
        $overallText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#D0EEFF")
        Add-LogLine -line "▶️ 【監控恢復】已恢復背景即時偵測"
    }
})

# 13. 事件：重置統計
$btnResetStats.Add_Click({
    Reset-TargetStats -stats $googleStats
    Reset-TargetStats -stats $localStats
    
    $txtGoogleAvg.Text = "-- ms"
    $txtGoogleMinMax.Text = "-- / --"
    $txtGoogleLoss.Text = "0.0% (0/0)"

    $txtLocalAvg.Text = "-- ms"
    $txtLocalMinMax.Text = "-- / --"
    $txtLocalLoss.Text = "0.0% (0/0)"

    Add-LogLine -line "🔄 【重置統計】所有歷史延遲與遺失率計數已歸零"
})

# 14. 事件：清除日誌
$btnClearLog.Add_Click({
    $logEntries.Clear()
    $txtLog.Text = ""
    $txtLogCounter.Text = "(0 / $maxLogLines 筆)"
})

# 15. 視窗載入完成套用 Windows 11 Fluent 深色標題列與圓角
$window.Add_SourceInitialized({
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        [DwmHelper]::ApplyFluentStyling($helper.Handle)
    } catch { }
})

# 16. 視窗關閉時終止背景執行緒
$window.Add_Closing({
    $runner.Stop()
})

# 17. 啟動監控並顯示視窗
Add-LogLine -line "🚀 Fluent Network Sentinel 已啟動"
Add-LogLine -line "🌐 網際網路目標: www.google.com"
Add-LogLine -line "📡 區域網路目標: $detectedGateway"

$runner.Start($window.Dispatcher)
$null = $window.ShowDialog()
