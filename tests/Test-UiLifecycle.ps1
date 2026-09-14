param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]
    [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $RepositoryRoot 'src/Common.ps1')

$fixtureRoot = Join-Path $TemporaryRoot ('ui-lifecycle-' + [guid]::NewGuid().ToString('N'))
$fixtureUi = Join-Path $fixtureRoot 'src/ui'
$browserLog = Join-Path $fixtureRoot 'browser.txt'
$windowMarker = Join-Path $fixtureRoot 'window-open'
$focusLog = Join-Path $fixtureRoot 'focus.txt'
$processes = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
$encoding = New-Object Text.UTF8Encoding($false)

function Wait-UiCondition {
    param([scriptblock]$Condition, [string]$Failure)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $Failure
}

function Start-TestUiHost {
    $runId = [guid]::NewGuid().ToString('N')
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $fixtureRoot 'proxy-manager-react-host.ps1'), '-BrowserTest', '-OpenBrowser',
        '-Port', '18070', '-Config', (Join-Path $fixtureRoot 'config.json'))
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' '
    $process = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argumentLine `
        -RedirectStandardOutput (Join-Path $fixtureRoot "$runId.stdout") `
        -RedirectStandardError (Join-Path $fixtureRoot "$runId.stderr") -PassThru
    $null = $process.Handle
    [void]$processes.Add($process)
    return $process
}

function Assert-UiSessionWorks {
    param([string]$Url)
    $uri = [Uri]$Url
    $token = $uri.Fragment -replace '^#token=', ''
    $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST `
        -Uri ($uri.GetLeftPart([UriPartial]::Authority) + '/api/heartbeat') `
        -Headers @{ 'X-Proxy-Manager-Token' = $token }
    if ($response.StatusCode -ne 200 -or $response.Content -notmatch '"ok":true') {
        throw 'Reopened browser did not receive a working manager session'
    }
}

try {
    [void](New-Item -ItemType Directory -Path $fixtureUi -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'web/dist') -Force)
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'proxy-manager-react-host.ps1') -Destination $fixtureRoot
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/Common.ps1') -Destination (Join-Path $fixtureRoot 'src')
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/ui/Http.ps1') -Destination $fixtureUi
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'web/dist/index.html'), '<div id="root"></div>', $encoding)
    # Run the real host in separate processes. Only desktop browser operations
    # and the instance name are replaced, keeping tests away from the user's UI.
    $bootstrapPath = (Join-Path $RepositoryRoot 'src/ui/Bootstrap.ps1').Replace("'", "''")
    $quotedBrowserLog = $browserLog.Replace("'", "''")
    $quotedWindowMarker = $windowMarker.Replace("'", "''")
    $quotedFocusLog = $focusLog.Replace("'", "''")
    $mutexName = 'Local\ClashSshProxyManager.Lifecycle.' + [guid]::NewGuid().ToString('N')
    $bootstrap = @"
. '$bootstrapPath'
function Get-UiInstanceMutexName {
    param([switch]`$SmokeTest)
    return '$mutexName'
}
function Open-ManagerBrowser {
    param([string]`$Url)
    [IO.File]::WriteAllText('$quotedWindowMarker', 'open')
    [IO.File]::AppendAllText('$quotedBrowserLog', "`$Url``n")
}
function Show-ExistingManagerWindow {
    if (-not (Test-Path -LiteralPath '$quotedWindowMarker')) { return `$false }
    [IO.File]::AppendAllText('$quotedFocusLog', "focused``n")
    return `$true
}
"@
    [IO.File]::WriteAllText((Join-Path $fixtureUi 'Bootstrap.ps1'), $bootstrap, $encoding)

    $hostProcess = Start-TestUiHost
    Wait-UiCondition { (Test-Path -LiteralPath $browserLog) -and @(Get-Content -LiteralPath $browserLog).Count -eq 1 } 'Initial browser did not open'
    $initialUrl = [string]@(Get-Content -LiteralPath $browserLog)[0]
    Assert-UiSessionWorks $initialUrl

    $duplicate = Start-TestUiHost
    if (-not $duplicate.WaitForExit(10000) -or $duplicate.ExitCode -ne 0) {
        $hostErrors = Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.stderr' | Get-Content -Raw
        throw "Repeated launch did not reuse the host (exit $($duplicate.ExitCode)): $hostErrors"
    }
    Wait-UiCondition { Test-Path -LiteralPath $focusLog } 'Existing browser was not brought forward'
    if (@(Get-Content -LiteralPath $browserLog).Count -ne 1) { throw 'Repeated launch opened a duplicate browser' }

    Remove-Item -LiteralPath $windowMarker -Force
    $reopen = Start-TestUiHost
    if (-not $reopen.WaitForExit(10000) -or $reopen.ExitCode -ne 0) { throw 'Launch after closing the browser failed' }
    Wait-UiCondition { @(Get-Content -LiteralPath $browserLog).Count -eq 2 } 'Closed browser was not reopened'
    $reopenedUrl = [string]@(Get-Content -LiteralPath $browserLog)[1]
    if ($reopenedUrl -ne $initialUrl -or $hostProcess.HasExited) { throw 'Reopen did not preserve the active host and session' }
    Assert-UiSessionWorks $reopenedUrl

    Stop-Process -InputObject $hostProcess -Force
    if (-not $hostProcess.WaitForExit(5000)) { throw 'Test host did not stop' }
    Remove-Item -LiteralPath $windowMarker -Force
    $replacement = Start-TestUiHost
    Wait-UiCondition { @(Get-Content -LiteralPath $browserLog).Count -eq 3 } 'Browser did not open after host exit'
    $replacementUrl = [string]@(Get-Content -LiteralPath $browserLog)[2]
    if ($replacementUrl -eq $initialUrl -or $replacement.HasExited) { throw 'Replacement host did not establish a new session' }
    Assert-UiSessionWorks $replacementUrl

    & {
        . (Join-Path $RepositoryRoot 'src/ui/Bootstrap.ps1')
        function Show-ExistingManagerWindow { return $false }
        function Open-ManagerBrowser { param([string]$Url) }
        $openEvent = New-UiBrowserOpenEvent -MutexName ($mutexName + '.Heartbeat')
        try {
            $script:LastHeartbeat = (Get-Date).AddSeconds(-100)
            [void]$openEvent.Set()
            Show-RequestedManagerBrowser -OpenEvent $openEvent -Url 'http://127.0.0.1:18070/'
            if (((Get-Date) - $script:LastHeartbeat).TotalSeconds -gt 5 -or $openEvent.WaitOne(0)) {
                throw 'Reopening did not renew the idle deadline and consume the request'
            }
        }
        finally { $openEvent.Dispose() }
    }
    Write-Host 'UI close/reopen lifecycle tests passed'
}
finally {
    foreach ($process in $processes) {
        if (-not $process.HasExited) {
            Stop-Process -InputObject $process -Force -ErrorAction SilentlyContinue
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
    $resolvedRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $allowedParent = [IO.Path]::GetFullPath($TemporaryRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedRoot.StartsWith($allowedParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean a UI fixture outside the test directory: $resolvedRoot"
    }
    if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
