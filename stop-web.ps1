$ErrorActionPreference = 'SilentlyContinue'
$runtimeRoot = Join-Path $PSScriptRoot 'runtime'
$pidsPath = Join-Path $runtimeRoot 'pids.json'
$statusPath = Join-Path $runtimeRoot 'status.json'
$urlPath = Join-Path $runtimeRoot 'public-url.txt'
$logPath = Join-Path $runtimeRoot 'controller.log'

function Write-StopLog([string]$Text) {
    try { Add-Content -LiteralPath $logPath -Value ((Get-Date -Format 'HH:mm:ss') + ' [STOP] ' + $Text) -Encoding UTF8 } catch {}
}

function Stop-ProcessTree([int]$ProcessId) {
    if ($ProcessId -le 0 -or $ProcessId -eq $PID) { return }
    $treeIds = @($ProcessId)
    try {
        $found = New-Object System.Collections.ArrayList
        $pending = New-Object System.Collections.Queue
        $pending.Enqueue($ProcessId)
        while ($pending.Count -gt 0) {
            $current = [int]$pending.Dequeue()
            if ($found -contains $current) { continue }
            [void]$found.Add($current)
            foreach ($child in @(Get-CimInstance Win32_Process -Filter ('ParentProcessId = ' + $current) -ErrorAction Stop)) { $pending.Enqueue([int]$child.ProcessId) }
        }
        $treeIds = @($found)
    } catch { Write-StopLog ('process tree lookup warning for pid=' + $ProcessId + ': ' + $_.Exception.Message) }
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    try {
        if (Test-Path -LiteralPath $taskkill) {
            $killer = Start-Process -FilePath $taskkill -ArgumentList ('/PID ' + $ProcessId + ' /T /F') -Wait -PassThru -WindowStyle Hidden
            Write-StopLog ('taskkill pid=' + $ProcessId + ' exit=' + $killer.ExitCode)
        }
    } catch { Write-StopLog ('taskkill warning for pid=' + $ProcessId + ': ' + $_.Exception.Message) }
    $treeIds = @($treeIds)
    [array]::Reverse($treeIds)
    foreach ($id in $treeIds) { Stop-Process -Id ([int]$id) -Force -ErrorAction SilentlyContinue }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $remaining = @($treeIds | Where-Object { Get-Process -Id ([int]$_) -ErrorAction SilentlyContinue })
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }
}

New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
if (Test-Path -LiteralPath $pidsPath) {
    try {
        $raw = Get-Content -LiteralPath $pidsPath -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $parsed = $raw | ConvertFrom-Json
            $items = if ($parsed -is [array]) { @($parsed) } else { @($parsed) }
            Write-StopLog ('tracked count=' + $items.Count)
            foreach ($item in $items) {
                if ($item.pid) {
                    Write-StopLog ('stopping ' + [string]$item.name + ' pid=' + [string]$item.pid)
                    Stop-ProcessTree ([int]$item.pid)
                }
            }
        }
    } catch { Write-StopLog ('PID cleanup failed: ' + $_.Exception.Message) }
}
Remove-Item -LiteralPath $pidsPath,$urlPath -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $runtimeRoot -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.out.log' -or $_.Name -like '*.error.log' } | Remove-Item -Force -ErrorAction SilentlyContinue
$state = [ordered]@{ phase='stopped'; message='所有受管进程已停止。'; publicUrl=$null; localUrl=$null; password=''; components=@(); updated=(Get-Date).ToString('o') }
[IO.File]::WriteAllText($statusPath, ($state | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
Write-StopLog 'All managed processes stopped.'
