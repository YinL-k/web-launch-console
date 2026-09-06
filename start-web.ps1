$ErrorActionPreference = 'Stop'

$controllerRoot = $PSScriptRoot
$runtimeRoot = Join-Path $controllerRoot 'runtime'
$configPath = Join-Path $controllerRoot 'controller-config.json'
$statusPath = Join-Path $runtimeRoot 'status.json'
$pidsPath = Join-Path $runtimeRoot 'pids.json'
$urlPath = Join-Path $runtimeRoot 'public-url.txt'
$logPath = Join-Path $runtimeRoot 'controller.log'
$componentOrder = New-Object System.Collections.ArrayList
$componentState = @{}
$started = New-Object System.Collections.ArrayList
$globalEnvironment = @{}
$generatedValues = @{}
$script:accessPassword = ''

function Write-Log([string]$Area, [string]$Text) {
    try { Add-Content -LiteralPath $logPath -Value ((Get-Date -Format 'HH:mm:ss') + ' [' + $Area + '] ' + $Text) -Encoding UTF8 } catch {}
}

function Resolve-ConfigPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
    return [IO.Path]::GetFullPath((Join-Path $controllerRoot $Value))
}

function Convert-ToSafeId([string]$Value, [int]$Index) {
    $id = ([regex]::Replace(([string]$Value).ToLowerInvariant(), '[^a-z0-9_-]+', '-')).Trim('-')
    if (-not $id) { $id = 'service-' + $Index }
    return $id
}

function Set-Component([string]$Id, [string]$Name, [string]$State, [bool]$Ready, [string]$Detail) {
    if (-not $componentState.ContainsKey($Id)) { [void]$componentOrder.Add($Id) }
    $componentState[$Id] = [ordered]@{ id=$Id; name=$Name; state=$State; ready=$Ready; detail=$Detail }
}

function Write-State([string]$Phase, [string]$Message, [string]$PublicUrl = $null) {
    try {
        $components = @($componentOrder | ForEach-Object { $componentState[[string]$_] })
        $state = [ordered]@{
            phase = $Phase
            message = $Message
            publicUrl = $PublicUrl
            localUrl = $script:localUrl
            password = $script:accessPassword
            components = $components
            updated = (Get-Date).ToString('o')
        }
        [IO.File]::WriteAllText($statusPath, ($state | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    } catch {}
}

function Save-Pids {
    [IO.File]::WriteAllText($pidsPath, (@($started) | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
}

function Stop-ProcessTree([int]$ProcessId) {
    if ($ProcessId -le 0 -or $ProcessId -eq $PID) { return }
    $treeIds = New-Object System.Collections.ArrayList
    $pending = New-Object System.Collections.Queue
    $pending.Enqueue($ProcessId)
    while ($pending.Count -gt 0) {
        $current = [int]$pending.Dequeue()
        if ($treeIds -contains $current) { continue }
        [void]$treeIds.Add($current)
        foreach ($child in @(Get-CimInstance Win32_Process -Filter ('ParentProcessId = ' + $current) -ErrorAction SilentlyContinue)) { $pending.Enqueue([int]$child.ProcessId) }
    }
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    try {
        if (Test-Path -LiteralPath $taskkill) {
            $killer = Start-Process -FilePath $taskkill -ArgumentList @('/PID',[string]$ProcessId,'/T','/F') -Wait -PassThru -WindowStyle Hidden
            Write-Log 'CLEANUP' ('taskkill pid=' + $ProcessId + ' exit=' + $killer.ExitCode)
        }
    } catch {}
    $treeIds = @($treeIds)
    [array]::Reverse($treeIds)
    foreach ($id in $treeIds) { Stop-Process -Id ([int]$id) -Force -ErrorAction SilentlyContinue }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $remaining = @($treeIds | Where-Object { Get-Process -Id ([int]$_) -ErrorAction SilentlyContinue })
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }
}

function Clear-TrackedProcesses {
    if (-not (Test-Path -LiteralPath $pidsPath)) { return }
    try {
        $raw = Get-Content -LiteralPath $pidsPath -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            foreach ($item in @($raw | ConvertFrom-Json)) {
                if ($item.pid) { Stop-ProcessTree ([int]$item.pid) }
            }
        }
    } catch { Write-Log 'CLEANUP' $_.Exception.Message }
    Remove-Item -LiteralPath $pidsPath -Force -ErrorAction SilentlyContinue
}

function Read-EnvFile([string]$Path) {
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { throw ('Environment file was not found: ' + $Path) }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed.StartsWith('export ')) { $trimmed = $trimmed.Substring(7).Trim() }
        $parts = $trimmed -split '=', 2
        if ($parts.Count -ne 2) { continue }
        $key = $parts[0].Trim()
        $value = $parts[1].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ($key -match '^[A-Za-z_][A-Za-z0-9_]*$') { $result[$key] = $value }
    }
    return $result
}

function New-RandomValue {
    $bytes = New-Object byte[] 48
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function Expand-ConfigValue([string]$Value, [hashtable]$CurrentEnvironment) {
    if ($Value -match '^\$\{random:([A-Za-z0-9_-]+)\}$') {
        $key = $matches[1]
        if (-not $generatedValues.ContainsKey($key)) { $generatedValues[$key] = New-RandomValue }
        return [string]$generatedValues[$key]
    }
    if ($Value -match '^\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}$') {
        $key = $matches[1]
        if ($CurrentEnvironment.ContainsKey($key)) { return [string]$CurrentEnvironment[$key] }
        return [Environment]::GetEnvironmentVariable($key)
    }
    return $Value
}

function Add-ObjectEnvironment([hashtable]$Target, $Object) {
    if (-not $Object) { return }
    foreach ($property in $Object.PSObject.Properties) {
        $Target[[string]$property.Name] = Expand-ConfigValue ([string]$property.Value) $Target
    }
}

function Add-EnvironmentFiles([hashtable]$Target, $Files) {
    if ($null -eq $Files) { return }
    foreach ($file in @($Files)) {
        if ([string]::IsNullOrWhiteSpace([string]$file)) { continue }
        $resolved = Resolve-ConfigPath ([string]$file)
        foreach ($entry in (Read-EnvFile $resolved).GetEnumerator()) { $Target[$entry.Key] = $entry.Value }
    }
}

function Remove-EnvironmentKeys([hashtable]$Target, $Keys) {
    foreach ($key in @($Keys)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$key)) { $Target.Remove([string]$key) }
    }
}

function Quote-Argument([string]$Value) {
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Start-ManagedProcess([string]$Id, [string]$Name, [string]$Command, $Arguments, [string]$WorkingDirectory, [hashtable]$Environment) {
    $commandInfo = Get-Command $Command -ErrorAction SilentlyContinue
    $executable = if ($commandInfo) { $commandInfo.Source } elseif (Test-Path -LiteralPath $Command) { (Resolve-Path -LiteralPath $Command).Path } else { throw ('Command was not found: ' + $Command) }
    $workDir = Resolve-ConfigPath $WorkingDirectory
    if (-not $workDir) { $workDir = $controllerRoot }
    if (-not (Test-Path -LiteralPath $workDir -PathType Container)) { throw ('Working directory was not found: ' + $workDir) }

    $outPath = Join-Path $runtimeRoot ($Id + '.out.log')
    $errorPath = Join-Path $runtimeRoot ($Id + '.error.log')
    Remove-Item -LiteralPath $outPath,$errorPath -Force -ErrorAction SilentlyContinue
    $saved = @{}
    $existing = [Environment]::GetEnvironmentVariables('Process')
    try {
        foreach ($entry in $Environment.GetEnumerator()) {
            $saved[$entry.Key] = [pscustomobject]@{ Exists=$existing.Contains($entry.Key); Value=[Environment]::GetEnvironmentVariable($entry.Key, 'Process') }
            [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
        }
        $argumentLine = (@($Arguments) | ForEach-Object { Quote-Argument ([string]$_) }) -join ' '
        $process = Start-Process -FilePath $executable -ArgumentList $argumentLine -WorkingDirectory $workDir -PassThru -WindowStyle Hidden -RedirectStandardOutput $outPath -RedirectStandardError $errorPath
    } finally {
        foreach ($entry in $saved.GetEnumerator()) {
            if ($entry.Value.Exists) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value.Value, 'Process') }
            else { [Environment]::SetEnvironmentVariable($entry.Key, $null, 'Process') }
        }
    }
    [void]$started.Add([ordered]@{ id=$Id; name=$Name; pid=$process.Id; outLog=$outPath; errorLog=$errorPath })
    Save-Pids
    Write-Log 'START' ($Name + ' pid=' + $process.Id)
    return $process
}

function Wait-Http([string]$Uri, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 2
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) { return $true }
        } catch {}
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Test-HttpReady([string]$Uri) {
    if ([string]::IsNullOrWhiteSpace($Uri)) { return $false }
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 2
        return $response.StatusCode -ge 200 -and $response.StatusCode -lt 400
    } catch { return $false }
}

function Read-PublicUrl([string[]]$Files, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        foreach ($file in $Files) {
            if (-not (Test-Path -LiteralPath $file)) { continue }
            try {
                $text = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
                $match = [regex]::Match(([string]$text), 'https://[a-z0-9-]+\.trycloudflare\.com')
                if ($match.Success) { return $match.Value }
            } catch {}
        }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
Clear-TrackedProcesses
Get-ChildItem -LiteralPath $runtimeRoot -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Write-Log 'START' 'Starting Web Launch Console.'

try {
    if (-not (Test-Path -LiteralPath $configPath)) { throw 'controller-config.json is missing. Copy controller-config.example.json and edit it first.' }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $displayName = if ($config.displayName) { [string]$config.displayName } else { 'Web Application' }
    if (-not $config.web) { throw 'The web configuration is missing.' }

    Add-EnvironmentFiles $globalEnvironment $config.environmentFiles
    Add-ObjectEnvironment $globalEnvironment $config.environment
    if ($config.web.accessPasswordEnv) {
        $passwordName = [string]$config.web.accessPasswordEnv
        if ($globalEnvironment.ContainsKey($passwordName)) { $script:accessPassword = [string]$globalEnvironment[$passwordName] }
        else { $script:accessPassword = [Environment]::GetEnvironmentVariable($passwordName) }
    }

    $webName = if ($config.web.name) { [string]$config.web.name } else { '网页' }
    Set-Component 'web' $webName '正在启动' $false ''
    $serviceIndex = 0
    foreach ($service in @($config.services)) {
        $serviceIndex++
        $serviceName = if ($service.name) { [string]$service.name } else { '服务 ' + $serviceIndex }
        $serviceId = Convert-ToSafeId $(if ($service.id) { [string]$service.id } else { $serviceName }) $serviceIndex
        if ($componentState.ContainsKey($serviceId)) { throw ('Duplicate component id: ' + $serviceId) }
        Set-Component $serviceId $serviceName '等待启动' $false ''
    }
    if ($config.tunnel -and $config.tunnel.enabled) { Set-Component 'tunnel' '公网连接' '等待启动' $false 'Cloudflare' }
    Write-State 'starting' ('正在启动 ' + $displayName + '...')

    $mode = if ($config.web.mode) { ([string]$config.web.mode).ToLowerInvariant() } else { 'static' }
    if ($mode -eq 'static') {
        $webRoot = Resolve-ConfigPath ([string]$config.web.root)
        if (-not (Test-Path -LiteralPath $webRoot -PathType Container)) { throw ('Web root was not found: ' + $webRoot) }
        $port = if ($config.web.port) { [int]$config.web.port } else { 8088 }
        $hostName = if ($config.web.host) { [string]$config.web.host } else { '127.0.0.1' }
        $script:localUrl = 'http://' + $hostName + ':' + $port
        $healthUrl = $script:localUrl + '/_launcher/health'
        $webEnvironment = @{}
        foreach ($entry in $globalEnvironment.GetEnumerator()) { $webEnvironment[$entry.Key] = $entry.Value }
        $webEnvironment['WEB_LAUNCH_ROOT'] = $webRoot
        $webEnvironment['WEB_LAUNCH_PORT'] = [string]$port
        $webEnvironment['WEB_LAUNCH_HOST'] = $hostName
        $webEnvironment['WEB_LAUNCH_SPA_FALLBACK'] = $(if ($config.web.spaFallback -eq $false) { 'false' } else { 'true' })
        $webEnvironment['WEB_LAUNCH_PASSWORD'] = $script:accessPassword
        $webEnvironment['WEB_LAUNCH_SESSION_TOKEN'] = New-Guid | ForEach-Object { $_.ToString('N') }
        if (Test-HttpReady $healthUrl) { throw ('The web health URL is already responding before launch: ' + $healthUrl) }
        $webProcess = Start-ManagedProcess 'web' $webName 'node' @((Join-Path $controllerRoot 'web-host.mjs')) $controllerRoot $webEnvironment
    } elseif ($mode -eq 'command') {
        if (-not $config.web.command) { throw 'web.command is required in command mode.' }
        $script:localUrl = [string]$config.web.url
        $healthUrl = if ($config.web.healthUrl) { [string]$config.web.healthUrl } else { $script:localUrl }
        $webEnvironment = @{}
        foreach ($entry in $globalEnvironment.GetEnumerator()) { $webEnvironment[$entry.Key] = $entry.Value }
        Add-EnvironmentFiles $webEnvironment $config.web.environmentFiles
        Add-ObjectEnvironment $webEnvironment $config.web.environment
        Remove-EnvironmentKeys $webEnvironment $config.web.unsetEnvironment
        if (-not $config.web.allowExisting -and (Test-HttpReady $healthUrl)) { throw ('The web health URL is already responding before launch: ' + $healthUrl) }
        $webProcess = Start-ManagedProcess 'web' $webName ([string]$config.web.command) $config.web.args ([string]$config.web.workingDirectory) $webEnvironment
    } else { throw ('Unsupported web mode: ' + $mode) }

    $webTimeout = if ($config.web.healthTimeoutSeconds) { [int]$config.web.healthTimeoutSeconds } else { 30 }
    if (-not (Wait-Http $healthUrl $webTimeout)) { throw ($webName + ' did not become ready: ' + $healthUrl) }
    if ($webProcess.HasExited) { throw ($webName + ' exited before it became ready.') }
    Set-Component 'web' $webName '运行中' $true $script:localUrl
    Write-State 'starting' ($webName + ' 已就绪，正在启动附属服务...')

    $serviceIndex = 0
    foreach ($service in @($config.services)) {
        $serviceIndex++
        $serviceName = if ($service.name) { [string]$service.name } else { '服务 ' + $serviceIndex }
        $serviceId = Convert-ToSafeId $(if ($service.id) { [string]$service.id } else { $serviceName }) $serviceIndex
        Set-Component $serviceId $serviceName '正在启动' $false ''
        Write-State 'starting' ('正在启动 ' + $serviceName + '...')
        $serviceEnvironment = @{}
        foreach ($entry in $globalEnvironment.GetEnumerator()) { $serviceEnvironment[$entry.Key] = $entry.Value }
        Add-EnvironmentFiles $serviceEnvironment $service.environmentFiles
        Add-ObjectEnvironment $serviceEnvironment $service.environment
        Remove-EnvironmentKeys $serviceEnvironment $service.unsetEnvironment
        if (-not $service.allowExisting -and $service.healthUrl -and (Test-HttpReady ([string]$service.healthUrl))) { throw ($serviceName + ' health URL is already responding before launch: ' + [string]$service.healthUrl) }
        $serviceProcess = Start-ManagedProcess $serviceId $serviceName ([string]$service.command) $service.args ([string]$service.workingDirectory) $serviceEnvironment
        $serviceHealth = [string]$service.healthUrl
        if ($serviceHealth) {
            $timeout = if ($service.healthTimeoutSeconds) { [int]$service.healthTimeoutSeconds } else { 60 }
            if (-not (Wait-Http $serviceHealth $timeout)) { throw ($serviceName + ' did not become ready: ' + $serviceHealth) }
        } else { Start-Sleep -Milliseconds 700 }
        if ($serviceProcess.HasExited) { throw ($serviceName + ' exited before it became ready.') }
        Set-Component $serviceId $serviceName '运行中' $true $serviceHealth
    }

    $publicUrl = $null
    if ($config.tunnel -and $config.tunnel.enabled) {
        Set-Component 'tunnel' '公网连接' '正在连接' $false 'Cloudflare'
        Write-State 'starting' '正在创建公网连接...'
        $cloud = Get-Command 'cloudflared' -ErrorAction SilentlyContinue
        if (-not $cloud) { throw 'cloudflared was not found in PATH.' }
        $target = if ($config.tunnel.target) { [string]$config.tunnel.target } else { $script:localUrl }
        $tunnelOut = Join-Path $runtimeRoot 'tunnel.out.log'
        $tunnelError = Join-Path $runtimeRoot 'tunnel.error.log'
        $tunnelProcess = Start-Process -FilePath $cloud.Source -ArgumentList ('tunnel --url ' + (Quote-Argument $target) + ' --no-autoupdate') -WorkingDirectory $controllerRoot -PassThru -WindowStyle Hidden -RedirectStandardOutput $tunnelOut -RedirectStandardError $tunnelError
        [void]$started.Add([ordered]@{ id='tunnel'; name='公网连接'; pid=$tunnelProcess.Id; outLog=$tunnelOut; errorLog=$tunnelError })
        Save-Pids
        $tunnelTimeout = if ($config.tunnel.timeoutSeconds) { [int]$config.tunnel.timeoutSeconds } else { 30 }
        $publicUrl = Read-PublicUrl @($tunnelOut,$tunnelError) $tunnelTimeout
        if (-not $publicUrl) { throw 'The public tunnel did not return a URL.' }
        [IO.File]::WriteAllText($urlPath, $publicUrl, [Text.UTF8Encoding]::new($false))
        Set-Component 'tunnel' '公网连接' '已连接' $true $publicUrl
    }

    Write-State 'running' ($displayName + ' 已运行。') $publicUrl
    Write-Log 'READY' $(if ($publicUrl) { $publicUrl } else { $script:localUrl })
} catch {
    $message = $_.Exception.Message
    Write-Log 'ERROR' $message
    foreach ($item in @($started)) { Stop-ProcessTree ([int]$item.pid) }
    Remove-Item -LiteralPath $pidsPath,$urlPath -Force -ErrorAction SilentlyContinue
    foreach ($id in @($componentOrder)) {
        $component = $componentState[[string]$id]
        if (-not $component.ready) { Set-Component ([string]$id) ([string]$component.name) '启动失败' $false $message }
    }
    Write-State 'error' $message
    exit 1
}
