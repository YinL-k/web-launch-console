$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $controllerRoot = $PSScriptRoot
    $runtimeRoot = Join-Path $controllerRoot 'runtime'
    $configPath = Join-Path $controllerRoot 'controller-config.json'
    $startScript = Join-Path $controllerRoot 'start-web.ps1'
    $stopScript = Join-Path $controllerRoot 'stop-web.ps1'
    $statusPath = Join-Path $runtimeRoot 'status.json'
    $pidsPath = Join-Path $runtimeRoot 'pids.json'
    $logPath = Join-Path $runtimeRoot 'controller.log'

    $config = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $displayName = if ($config -and $config.displayName) { [string]$config.displayName } else { 'Web Application' }

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Web Launch Console" Width="860" Height="680" MinWidth="760" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#F4F6FA" FontFamily="Segoe UI">
  <Window.Resources>
    <SolidColorBrush x:Key="Ink" Color="#172033"/><SolidColorBrush x:Key="Muted" Color="#667085"/>
    <SolidColorBrush x:Key="Line" Color="#E3E7EF"/><SolidColorBrush x:Key="Blue" Color="#2563EB"/>
    <Style TargetType="Button"><Setter Property="Padding" Value="16,9"/><Setter Property="Background" Value="#2563EB"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderThickness" Value="0"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="Background" Value="#E9EEF9"/><Setter Property="Foreground" Value="#25436F"/></Style>
  </Window.Resources>
  <Grid Margin="30">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="22"/><RowDefinition Height="Auto"/><RowDefinition Height="22"/><RowDefinition Height="*"/><RowDefinition Height="22"/><RowDefinition Height="Auto"/><RowDefinition Height="16"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Grid Grid.Row="0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel><TextBlock Text="Web Launch Console" FontSize="25" FontWeight="SemiBold" Foreground="{StaticResource Ink}"/><TextBlock x:Name="ProjectName" FontSize="14" Foreground="{StaticResource Muted}" Margin="0,5,0,0"/></StackPanel>
      <Border Grid.Column="1" x:Name="OverallBadge" Background="#E9EDF4" CornerRadius="16" Padding="13,7" VerticalAlignment="Center"><StackPanel Orientation="Horizontal"><Ellipse x:Name="OverallDot" Width="8" Height="8" Fill="#98A2B3" Margin="0,0,7,0" VerticalAlignment="Center"/><TextBlock x:Name="OverallText" Text="已停止" FontWeight="SemiBold"/></StackPanel></Border>
    </Grid>
    <Border Grid.Row="2" Background="White" CornerRadius="16" Padding="20" BorderBrush="{StaticResource Line}" BorderThickness="1">
      <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock Text="网页与服务" FontSize="17" FontWeight="SemiBold"/><TextBlock x:Name="Hint" Text="使用本机配置启动网页、附属服务和公网连接。" Foreground="{StaticResource Muted}" Margin="0,5,0,0"/></StackPanel>
        <Button Grid.Column="1" x:Name="StartStopButton" Content="启动" MinWidth="92"/>
      </Grid>
    </Border>
    <ScrollViewer Grid.Row="4" VerticalScrollBarVisibility="Auto"><WrapPanel x:Name="ComponentPanel" Orientation="Horizontal"/></ScrollViewer>
    <Border Grid.Row="6" Background="White" CornerRadius="16" Padding="20" BorderBrush="{StaticResource Line}" BorderThickness="1">
      <StackPanel>
        <TextBlock Text="访问地址" FontSize="17" FontWeight="SemiBold"/>
        <Grid Margin="0,14,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Border Background="#F8F9FB" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="9" Padding="11,8"><TextBox x:Name="UrlBox" Text="等待启动..." IsReadOnly="True" BorderThickness="0" Background="Transparent" FontFamily="Consolas"/></Border>
          <Button Grid.Column="2" x:Name="CopyUrl" Content="复制" IsEnabled="False"/><Button Grid.Column="4" x:Name="OpenUrl" Content="打开" Style="{StaticResource SecondaryButton}" IsEnabled="False"/>
        </Grid>
        <Grid x:Name="PasswordRow" Margin="0,12,0,0" Visibility="Collapsed"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="12"/><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock Text="访问口令" Foreground="{StaticResource Muted}" VerticalAlignment="Center"/><Border Grid.Column="2" Background="#F8F9FB" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="9" Padding="11,8"><TextBlock x:Name="PasswordText" FontFamily="Consolas"/></Border><Button Grid.Column="4" x:Name="CopyPassword" Content="复制口令" Style="{StaticResource SecondaryButton}"/>
        </Grid>
      </StackPanel>
    </Border>
    <Grid Grid.Row="8"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel><TextBlock x:Name="Footer" Text="控制台已就绪。" Foreground="{StaticResource Muted}" FontSize="12"/><TextBlock x:Name="ErrorText" Text="" Foreground="#C43232" FontSize="11" Margin="0,3,0,0" TextWrapping="Wrap"/></StackPanel>
      <Button Grid.Column="1" x:Name="OpenLocal" Content="打开本地" Style="{StaticResource SecondaryButton}" IsEnabled="False"/><Button Grid.Column="3" x:Name="OpenLogs" Content="日志" Style="{StaticResource SecondaryButton}"/>
    </Grid>
  </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $names = @('ProjectName','OverallBadge','OverallDot','OverallText','Hint','StartStopButton','ComponentPanel','UrlBox','CopyUrl','OpenUrl','PasswordRow','PasswordText','CopyPassword','Footer','ErrorText','OpenLocal','OpenLogs')
    foreach ($name in $names) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }
    $ProjectName.Text = $displayName

    $script:cards = @{}
    function Add-ComponentCard([string]$Id, [string]$Name, [string]$Detail) {
        $border = New-Object Windows.Controls.Border
        $border.Width = 245; $border.MinHeight = 105; $border.Margin = '0,0,14,14'; $border.Padding = '17'
        $border.Background = [Windows.Media.Brushes]::White; $border.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#E3E7EF'); $border.BorderThickness = '1'; $border.CornerRadius = '14'
        $stack = New-Object Windows.Controls.StackPanel
        $header = New-Object Windows.Controls.StackPanel; $header.Orientation = 'Horizontal'
        $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 9; $dot.Height = 9; $dot.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString('#98A2B3'); $dot.Margin = '0,0,8,0'; $dot.VerticalAlignment = 'Center'
        $title = New-Object Windows.Controls.TextBlock; $title.Text = $Name; $title.FontWeight = 'SemiBold'; $title.FontSize = 14
        [void]$header.Children.Add($dot); [void]$header.Children.Add($title)
        $status = New-Object Windows.Controls.TextBlock; $status.Text = '未运行'; $status.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#667085'); $status.Margin = '0,10,0,0'
        $detailText = New-Object Windows.Controls.TextBlock; $detailText.Text = $Detail; $detailText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#98A2B3'); $detailText.FontSize = 11; $detailText.Margin = '0,4,0,0'; $detailText.TextTrimming = 'CharacterEllipsis'
        [void]$stack.Children.Add($header); [void]$stack.Children.Add($status); [void]$stack.Children.Add($detailText); $border.Child = $stack
        [void]$ComponentPanel.Children.Add($border)
        $script:cards[$Id] = [pscustomobject]@{ Dot=$dot; Status=$status; Detail=$detailText; Name=$title }
    }

    Add-ComponentCard 'web' $(if ($config -and $config.web -and $config.web.name) { [string]$config.web.name } else { '网页' }) ''
    $serviceIndex = 0
    foreach ($service in @($(if ($config) { $config.services } else { @() }))) {
        $serviceIndex++
        $serviceName = if ($service.name) { [string]$service.name } else { '服务 ' + $serviceIndex }
        $serviceId = ([regex]::Replace($(if ($service.id) { [string]$service.id } else { $serviceName }).ToLowerInvariant(), '[^a-z0-9_-]+', '-')).Trim('-')
        if (-not $serviceId) { $serviceId = 'service-' + $serviceIndex }
        Add-ComponentCard $serviceId $serviceName ([string]$service.healthUrl)
    }
    if ($config -and $config.tunnel -and $config.tunnel.enabled) { Add-ComponentCard 'tunnel' '公网连接' 'Cloudflare' }

    $script:isBusy = $false
    $script:isRunning = $false
    $script:currentUrl = ''
    $script:localUrl = ''
    $script:password = ''

    function Set-Overall([string]$Text, [string]$Color, [bool]$Running) {
        $OverallText.Text = $Text
        $OverallDot.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
        $script:isRunning = $Running
        $StartStopButton.Content = if ($Running) { '停止' } else { '启动' }
    }

    function Set-Card([string]$Id, [string]$State, [bool]$Ready, [string]$Detail) {
        if (-not $script:cards.ContainsKey($Id)) { return }
        $card = $script:cards[$Id]
        $card.Status.Text = $State
        $card.Dot.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString($(if ($Ready) { '#22A06B' } elseif ($State -match '失败') { '#D14343' } elseif ($State -match '启动|连接') { '#E39A28' } else { '#98A2B3' }))
        if ($Detail) { $card.Detail.Text = $Detail }
    }

    function Test-TrackedRunning {
        if (-not (Test-Path -LiteralPath $pidsPath)) { return $false }
        try {
            $items = @(Get-Content -LiteralPath $pidsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            foreach ($item in $items) { if ($item.pid -and (Get-Process -Id ([int]$item.pid) -ErrorAction SilentlyContinue)) { return $true } }
        } catch {}
        return $false
    }

    function Start-Worker([string]$ScriptPath) {
        New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $powershell; $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'; $info.WorkingDirectory = $controllerRoot
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.WindowStyle = 'Hidden'
        return [Diagnostics.Process]::Start($info)
    }

    function Refresh-State {
        $state = $null
        if (Test-Path -LiteralPath $statusPath) {
            try { $state = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        }
        $tracked = Test-TrackedRunning
        if ($state) {
            foreach ($component in @($state.components)) { Set-Card ([string]$component.id) ([string]$component.state) ([bool]$component.ready) ([string]$component.detail) }
            $script:localUrl = [string]$state.localUrl
            $script:currentUrl = if ($state.publicUrl) { [string]$state.publicUrl } else { $script:localUrl }
            $script:password = [string]$state.password
            if ($script:currentUrl) { $UrlBox.Text = $script:currentUrl; $CopyUrl.IsEnabled = $true; $OpenUrl.IsEnabled = $true } else { $UrlBox.Text = '等待启动...'; $CopyUrl.IsEnabled = $false; $OpenUrl.IsEnabled = $false }
            $OpenLocal.IsEnabled = [bool]$script:localUrl
            if ($script:password) { $PasswordText.Text = $script:password; $PasswordRow.Visibility = 'Visible' } else { $PasswordText.Text = ''; $PasswordRow.Visibility = 'Collapsed' }
            $Footer.Text = [string]$state.message
            if ($state.phase -eq 'running' -and $tracked) { Set-Overall '运行中' '#22A06B' $true; $ErrorText.Text = '' }
            elseif ($state.phase -eq 'error') { Set-Overall '启动失败' '#D14343' $false; $ErrorText.Text = [string]$state.message }
            elseif ($state.phase -eq 'starting') { Set-Overall '启动中' '#E39A28' $false }
            else { Set-Overall '已停止' '#98A2B3' $false }
        } elseif ($tracked) { Set-Overall '运行中' '#22A06B' $true }
        else { Set-Overall '已停止' '#98A2B3' $false }
        if (-not $script:isBusy) { $StartStopButton.IsEnabled = $true }
    }

    $StartStopButton.Add_Click({
        if ($script:isBusy) { return }
        if (-not $config) {
            [Windows.MessageBox]::Show('缺少 controller-config.json。请复制配置示例并填写网页目录。','Web Launch Console','OK','Warning') | Out-Null
            return
        }
        $script:isBusy = $true; $StartStopButton.IsEnabled = $false; $ErrorText.Text = ''
        if (Test-TrackedRunning) { $Footer.Text = '正在停止所有受管进程...'; [void](Start-Worker $stopScript) }
        else { $Footer.Text = '正在启动网页与服务...'; [void](Start-Worker $startScript) }
    })
    $CopyUrl.Add_Click({ if ($script:currentUrl) { [Windows.Clipboard]::SetText($script:currentUrl); $Footer.Text = '地址已复制。' } })
    $OpenUrl.Add_Click({ if ($script:currentUrl) { Start-Process $script:currentUrl } })
    $CopyPassword.Add_Click({ if ($script:password) { [Windows.Clipboard]::SetText($script:password); $Footer.Text = '访问口令已复制。' } })
    $OpenLocal.Add_Click({ if ($script:localUrl) { Start-Process $script:localUrl } })
    $OpenLogs.Add_Click({ New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null; Start-Process 'explorer.exe' -ArgumentList ('"' + $runtimeRoot + '"') })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(750)
    $timer.Add_Tick({
        $wasBusy = $script:isBusy
        Refresh-State
        if ($wasBusy) {
            $phase = if (Test-Path -LiteralPath $statusPath) { try { (Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json).phase } catch { '' } } else { '' }
            if ($phase -in @('running','error','stopped')) { $script:isBusy = $false; $StartStopButton.IsEnabled = $true }
        }
    })
    $window.Add_Closed({ $timer.Stop() })
    Refresh-State; $timer.Start(); [void]$window.ShowDialog()
} catch {
    try { [Windows.MessageBox]::Show(('控制台启动失败：' + $_.Exception.Message),'Web Launch Console','OK','Error') | Out-Null } catch {}
    exit 1
}

