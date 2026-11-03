<#
.SYNOPSIS
    Fluent Network Sentinel - Windows 11 Fluent UI 即時網路狀態監控工具 (4 目標版本)
.DESCRIPTION
    PowerShell + WPF 設計的 Windows 11 Fluent UI 網路連線監控程式。
    - 持續即時監控外部網際網路 (www.google.com)
    - 同步即時監控 3 組區域網路設備 IP (預設自動偵測 Gateway，各組均允許於 UI 隨時獨立修改)
    - 提供連線延遲 (目前/平均/最小/最大)、封包遺失率、回應歷史日誌
    - 支援調整偵測間隔 (1s ~ 5s，黑底白字 Fluent 風格)、暫停/繼續、重置統計與斷線音效提示
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

# 3. 自動偵測本機預設閘道 (Default Gateway)
$detectedGateway = "192.168.1.1"
try {
    $gwRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gwRoute -and $gwRoute.NextHop -and $gwRoute.NextHop -ne '0.0.0.0') {
        $detectedGateway = $gwRoute.NextHop
    }
} catch { }

# 計算推薦的次要區域 IP (同網段 .2 與 .254)
$defaultLocal2 = "192.168.1.2"
$defaultLocal3 = "8.8.8.8"
try {
    $ipParts = $detectedGateway.Split('.')
    if ($ipParts.Count -eq 4) {
        $prefix = "$($ipParts[0]).$($ipParts[1]).$($ipParts[2])"
        $defaultLocal2 = "$prefix.2"
        $defaultLocal3 = "$prefix.254"
    }
} catch { }

# 4. Windows 11 Fluent UI XAML 定義
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Network Sentinel - Fluent Network Monitor"
        Height="870" Width="810" MinHeight="720" MinWidth="740"
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

        <!-- ToggleButton for ComboBox (黑底白字與箭頭) -->
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

        <!-- Dark Fluent ComboBox Style (偵測間隔：完全黑底白字風格) -->
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
            <RowDefinition Height="Auto"/> <!-- Header -->
            <RowDefinition Height="Auto"/> <!-- Controls Toolbar -->
            <RowDefinition Height="*"/>    <!-- Cards Area (ScrollViewer) -->
            <RowDefinition Height="175"/>  <!-- Activity Feed -->
        </Grid.RowDefinitions>

        <!-- Header -->
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
                <TextBlock Text="即時監控外部網際網路 (Google) 與 3 組區域網路設備 IP 連線狀態" FontSize="12" Foreground="#8E8E8E" Margin="28,2,0,0"/>
            </StackPanel>

            <!-- Overall Status Badge -->
            <Border x:Name="OverallBadge" Grid.Column="1" Background="#163821" BorderBrush="#256938" BorderThickness="1" CornerRadius="14" Padding="12,5" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Ellipse x:Name="OverallDot" Width="8" Height="8" Fill="#4CC2FF" Margin="0,0,8,0"/>
                    <TextBlock x:Name="OverallText" Text="MONITORING ACTIVE (4 TARGETS)" FontSize="11" FontWeight="Bold" Foreground="#D0EEFF"/>
                </StackPanel>
            </Border>
        </Grid>

        <!-- Controls Toolbar (偵測間隔設定) -->
        <Border Grid.Row="1" Background="#202020" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="6" Padding="12,6" Margin="0,0,0,12">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,16,0">
                    <TextBlock Text="偵測間隔:" VerticalAlignment="Center" FontSize="12" Foreground="#B0B0B0" Margin="0,0,8,0"/>
                    <!-- 偵測間隔 ComboBox: 完全黑底白字風格 -->
                    <ComboBox x:Name="CmbInterval" Style="{StaticResource FluentComboBoxStyle}" SelectedIndex="0" Width="125" Height="28">
                        <ComboBoxItem Content="1 秒 (1000ms)" Tag="1000"/>
                        <ComboBoxItem Content="2 秒 (2000ms)" Tag="2000"/>
                        <ComboBoxItem Content="3 秒 (3000ms)" Tag="3000"/>
                        <ComboBoxItem Content="5 秒 (5000ms)" Tag="5000"/>
                    </ComboBox>
                </StackPanel>

                <CheckBox x:Name="ChkSoundAlert" Grid.Column="1" Content="斷線警報音效" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,16,0" Cursor="Hand"/>

                <StackPanel Grid.Column="3" Orientation="Horizontal">
                    <Button x:Name="BtnPauseResume" Content="暫停偵測" Style="{StaticResource FluentButtonStyle}" Margin="0,0,8,0" Padding="12,3"/>
                    <Button x:Name="BtnResetStats" Content="重置所有統計" Style="{StaticResource FluentButtonStyle}" Padding="12,3"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Cards Area (in ScrollViewer) -->
        <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" Margin="0,0,0,10" Padding="0,0,6,0">
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
                                    <TextBlock Text="網際網路 (Internet)" FontSize="14" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                                    <Border Background="#1C2F20" BorderBrush="#2F5C37" BorderThickness="1" CornerRadius="4" Margin="8,0,0,0" Padding="5,1">
                                        <TextBlock Text="WAN" FontSize="9" FontWeight="Bold" Foreground="#6CCB5F"/>
                                    </Border>
                                </StackPanel>
                                <TextBlock Text="目標主機: www.google.com" FontSize="11" Foreground="#8A8A8A"/>
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
                                    <TextBlock Text="目前延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleLatency" Text="-- ms" FontSize="18" FontWeight="Bold" Foreground="#60CDFF" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock Text="平均延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleAvg" Text="-- ms" FontSize="13" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock Text="最小 / 最大" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleMinMax" Text="-- / --" FontSize="12" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock Text="遺失率 (Lost/Total)" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleLoss" Text="0.0% (0/0)" FontSize="12" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="5" Padding="8,6">
                                <StackPanel>
                                    <TextBlock Text="最後回應時間" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtGoogleLastSeen" Text="等待回應..." FontSize="11" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </Grid>
                </Border>

                <!-- Card 1: Local Target 1 (Gateway) -->
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
                                    <TextBlock Text="區域設備 #1 (Gateway)" FontSize="14" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                                    <Border Background="#332414" BorderBrush="#6B491F" BorderThickness="1" CornerRadius="4" Margin="8,0,0,0" Padding="5,1">
                                        <TextBlock Text="LAN 1" FontSize="9" FontWeight="Bold" Foreground="#FFB900"/>
                                    </Border>
                                </StackPanel>
                            </StackPanel>

                            <!-- Inline IP Input -->
                            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                                <TextBlock Text="目標 IP:" FontSize="12" Foreground="#A0A0A0" VerticalAlignment="Center" Margin="0,0,6,0"/>
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
                                    <TextBlock Text="目前延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLatency1" Text="-- ms" FontSize="18" FontWeight="Bold" Foreground="#60CDFF" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock Text="平均延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalAvg1" Text="-- ms" FontSize="13" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock Text="最小 / 最大" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalMinMax1" Text="-- / --" FontSize="12" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock Text="遺失率 (Lost/Total)" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLoss1" Text="0.0% (0/0)" FontSize="12" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="5" Padding="8,6">
                                <StackPanel>
                                    <TextBlock Text="最後回應時間" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLastSeen1" Text="等待回應..." FontSize="11" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </Grid>
                </Border>

                <!-- Card 2: Local Target 2 -->
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
                                    <TextBlock Text="區域設備 #2 (NAS / Switch)" FontSize="14" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                                    <Border Background="#1C263A" BorderBrush="#2D4370" BorderThickness="1" CornerRadius="4" Margin="8,0,0,0" Padding="5,1">
                                        <TextBlock Text="LAN 2" FontSize="9" FontWeight="Bold" Foreground="#4CC2FF"/>
                                    </Border>
                                </StackPanel>
                            </StackPanel>

                            <!-- Inline IP Input -->
                            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                                <TextBlock Text="目標 IP:" FontSize="12" Foreground="#A0A0A0" VerticalAlignment="Center" Margin="0,0,6,0"/>
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
                                    <TextBlock Text="目前延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLatency2" Text="-- ms" FontSize="18" FontWeight="Bold" Foreground="#60CDFF" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock Text="平均延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalAvg2" Text="-- ms" FontSize="13" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock Text="最小 / 最大" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalMinMax2" Text="-- / --" FontSize="12" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock Text="遺失率 (Lost/Total)" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLoss2" Text="0.0% (0/0)" FontSize="12" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="5" Padding="8,6">
                                <StackPanel>
                                    <TextBlock Text="最後回應時間" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLastSeen2" Text="等待回應..." FontSize="11" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </Grid>
                </Border>

                <!-- Card 3: Local Target 3 -->
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
                                    <TextBlock Text="區域設備 #3 (DNS / Server)" FontSize="14" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                                    <Border Background="#291A30" BorderBrush="#593269" BorderThickness="1" CornerRadius="4" Margin="8,0,0,0" Padding="5,1">
                                        <TextBlock Text="LAN 3" FontSize="9" FontWeight="Bold" Foreground="#D182FF"/>
                                    </Border>
                                </StackPanel>
                            </StackPanel>

                            <!-- Inline IP Input -->
                            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                                <TextBlock Text="目標 IP:" FontSize="12" Foreground="#A0A0A0" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                <TextBox x:Name="TxtLocalIP3" Width="140" Text="8.8.8.8" Style="{StaticResource FluentTextBoxStyle}" Margin="0,0,6,0"/>
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
                                    <TextBlock Text="目前延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLatency3" Text="-- ms" FontSize="18" FontWeight="Bold" Foreground="#60CDFF" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock Text="平均延遲" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalAvg3" Text="-- ms" FontSize="13" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock Text="最小 / 最大" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalMinMax3" Text="-- / --" FontSize="12" FontWeight="SemiBold" Foreground="#E0E0E0" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="3" Background="#1D1D1D" CornerRadius="5" Padding="8,6" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock Text="遺失率 (Lost/Total)" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLoss3" Text="0.0% (0/0)" FontSize="12" FontWeight="SemiBold" Foreground="#6CCB5F" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="4" Background="#1D1D1D" CornerRadius="5" Padding="8,6">
                                <StackPanel>
                                    <TextBlock Text="最後回應時間" FontSize="10" Foreground="#888888"/>
                                    <TextBlock x:Name="TxtLocalLastSeen3" Text="等待回應..." FontSize="11" FontWeight="SemiBold" Foreground="#B0B0B0" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </Grid>
                </Border>
            </StackPanel>
        </ScrollViewer>

        <!-- Activity Log -->
        <Border Grid.Row="3" Background="#242424" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="12">
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
                        <TextBlock Text="📋 即時偵測日誌 (Activity Feed)" FontSize="12" FontWeight="SemiBold" Foreground="#D0D0D0"/>
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

# 取得主要控制項
$cmbInterval       = $window.FindName("CmbInterval")
$chkSoundAlert     = $window.FindName("ChkSoundAlert")
$btnPauseResume    = $window.FindName("BtnPauseResume")
$btnResetStats     = $window.FindName("BtnResetStats")
$btnClearLog       = $window.FindName("BtnClearLog")

$overallBadge      = $window.FindName("OverallBadge")
$overallDot        = $window.FindName("OverallDot")
$overallText       = $window.FindName("OverallText")

$txtLog            = $window.FindName("TxtLog")
$txtLogCounter     = $window.FindName("TxtLogCounter")

# 初始化 3 組 Local IP 輸入框與按鈕
$txtLocalIP1       = $window.FindName("TxtLocalIP1")
$btnApplyIP1       = $window.FindName("BtnApplyIP1")
$txtLocalIP1.Text  = $detectedGateway

$txtLocalIP2       = $window.FindName("TxtLocalIP2")
$btnApplyIP2       = $window.FindName("BtnApplyIP2")
$txtLocalIP2.Text  = $defaultLocal2

$txtLocalIP3       = $window.FindName("TxtLocalIP3")
$btnApplyIP3       = $window.FindName("BtnApplyIP3")
$txtLocalIP3.Text  = $defaultLocal3

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
        Name     = "🌐 Google"
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
        Name     = "📡 區網 #1"
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
        Name     = "💻 區網 #2"
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
        Name     = "🖥️ 區網 #3"
    }
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

# 8. 建立並啟動非同步 Ping Runner (4 目標)
$runner = New-Object PingMonitorRunner
$runner.InternetTarget = "www.google.com"
$runner.LocalTarget1   = $txtLocalIP1.Text
$runner.LocalTarget2   = $txtLocalIP2.Text
$runner.LocalTarget3   = $txtLocalIP3.Text
$runner.IntervalMs     = 1000

# 9. 處理 Ping 回應事件回呼
$runner.add_OnPingResult({
    param([PingResult]$result)
    
    $id = $result.TargetId
    if (-not $statsMap.ContainsKey($id) -or -not $cardsMap.ContainsKey($id)) { return }

    $stats = $statsMap[$id]
    $card  = $cardsMap[$id]
    $stats.Sent++
    $timeStr = (Get-Date $result.Timestamp).ToString("HH:mm:ss")

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
        $card.Status.Text      = "連線正常 (ONLINE)"
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
        $card.Status.Text      = "目標無回應 (OFFLINE)"
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
    $statusMsg = if ($result.Success) {
        $dur = if ($result.RoundtripTime -eq 0) { "< 1ms" } else { "$($result.RoundtripTime)ms" }
        "OK ($dur)"
    } else {
        "FAILED ($($result.Status))"
    }
    Add-LogLine -line "$($card.Name) [$($result.Target)] -> $statusMsg"
})

# 10. 事件：修改與套用 Local IP 1, 2, 3
function Set-LocalTarget {
    param([int]$index, [System.Windows.Controls.TextBox]$box)
    $rawIP = $box.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($rawIP)) {
        [System.Windows.MessageBox]::Show("請輸入有效的 IP 位址或主機名稱！", "輸入錯誤", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
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
    $card.LastSeen.Text = "重新偵測中..."

    Add-LogLine -line "⚙️ 【設定更新】已變更區網設備 #$index 目標為: $rawIP"
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
        $overallText.Text = "MONITORING ACTIVE (4 TARGETS)"
        $overallText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#D0EEFF")
        Add-LogLine -line "▶️ 【監控恢復】已恢復背景即時偵測"
    }
})

# 13. 事件：重置統計
$btnResetStats.Add_Click({
    foreach ($key in $statsMap.Keys) {
        Reset-TargetStats -stats $statsMap[$key]
        $card = $cardsMap[$key]
        $card.Avg.Text    = "-- ms"
        $card.MinMax.Text = "-- / --"
        $card.Loss.Text   = "0.0% (0/0)"
    }
    Add-LogLine -line "🔄 【重置統計】所有目標歷史延遲與遺失率計數已歸零"
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
Add-LogLine -line "🚀 Fluent Network Sentinel 已啟動 (4 組目標同步監控)"
Add-LogLine -line "🌐 網際網路目標: www.google.com"
Add-LogLine -line "📡 區域目標 #1: $($txtLocalIP1.Text)"
Add-LogLine -line "💻 區域目標 #2: $($txtLocalIP2.Text)"
Add-LogLine -line "🖥️ 區域目標 #3: $($txtLocalIP3.Text)"

$runner.Start($window.Dispatcher)
$null = $window.ShowDialog()
