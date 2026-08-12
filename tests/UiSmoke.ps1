# Runs inside proxy-manager-ui.ps1 script scope when -SmokeTest is selected.

    $unicodeProbe = ([string][char]0x65E5) + ([string][char]0x5FD7)
    $nativeCommand = '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); [Console]::Write(([string][char]0x65E5) + ([string][char]0x5FD7))'
    $decodedProbe = (& powershell.exe -NoLogo -NoProfile -NonInteractive -Command $nativeCommand | Out-String).Trim()
    if ($decodedProbe -ne $unicodeProbe) {
        throw 'UI native UTF-8 decoding smoke test failed'
    }
    Add-Log $decodedProbe
    if (-not $script:LogBox.Text.Contains($unicodeProbe)) {
        throw 'UI log Unicode rendering smoke test failed'
    }
    $escape = [string][char]27
    Add-Log ($escape + '[31mANSI-CHECK' + $escape + '[0m')
    if ($script:LogBox.Text.Contains($escape)) {
        throw 'UI log ANSI cleanup smoke test failed'
    }
    Refresh-TargetGrid
    if ($script:Grid.Rows.Count -gt 0) {
        $originalRow = $script:Grid.Rows[0]
        $originalName = [string]$originalRow.Cells['TargetName'].Value
        $originalEnabledForRefresh = [bool]$originalRow.Cells['Enabled'].Value
        $health = @{}
        $health[$originalName] = [pscustomobject]@{
            Name = $originalName
            Enabled = $originalEnabledForRefresh
            TaskState = 'Running'
            SSH = 'OK'
            Proxy = 'OK'
        }
        Refresh-TargetGrid $health
        $refreshedRow = Get-TargetRowByName $originalName
        if (-not [object]::ReferenceEquals($originalRow, $refreshedRow)) {
            throw 'UI target refresh recreated an existing row and may flicker'
        }
        $expectedTaskState = Get-UiScheduledTaskState ([string]$refreshedRow.Cells['TaskName'].Value)
        $expectedProxyState = if ($expectedTaskState -eq 'Running') { 'OK' } else { 'FAIL' }
        if ([string]$refreshedRow.Cells['SshState'].Value -ne 'OK' -or
            [string]$refreshedRow.Cells['TaskState'].Value -ne $expectedTaskState -or
            [string]$refreshedRow.Cells['ProxyState'].Value -ne $expectedProxyState) {
            throw 'UI refresh allowed cached health to override current local task state'
        }

        $row = $script:Grid.Rows[0]
        $script:Grid.ClearSelection()
        $row.Selected = $true
        $originalEnabled = [bool]$row.Cells['Enabled'].Value
        Update-ActionState
        $expectedText = if ($originalEnabled) { 'Disable proxy' } else { 'Enable proxy' }
        if ($accessButton.Text -ne $expectedText) {
            throw 'UI primary proxy action does not match the target state'
        }
        $row.Cells['Enabled'].Value = $false
        Update-ActionState
        if ($accessButton.Text -ne 'Enable proxy') {
            throw 'UI did not offer Enable proxy for a disabled target'
        }
        $row.Cells['Enabled'].Value = $true
        Update-ActionState
        if ($accessButton.Text -ne 'Disable proxy') {
            throw 'UI did not offer Disable proxy for an enabled target'
        }
        $row.Cells['Enabled'].Value = $originalEnabled
        $firstGeneration = Reset-TargetHealth $originalName
        $secondGeneration = Reset-TargetHealth $originalName
        if ($secondGeneration -le $firstGeneration) {
            throw 'UI health generations do not reject stale background results'
        }
        Update-ActionState

        $smokeManagerPath = Join-Path ([IO.Path]::GetTempPath()) (
            'clash-proxy-health-smoke-' + [guid]::NewGuid().ToString('N') + '.ps1'
        )
        $smokeManagerSource = @'
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [string]$Command,
    [string]$Name,
    [string]$Config,
    [string]$RemoteHost,
    [string]$RemoteUser,
    [int]$SshPort,
    [string]$IdentityFile,
    [int]$RemoteProxyPort,
    [string]$TaskName,
    [string[]]$NoProxyExtra,
    [switch]$Json
)
Start-Sleep -Milliseconds 400
if ($Command -eq 'prepare-ssh') {
    $ready = $Name -notlike '*interaction*'
    [pscustomobject]@{
        Ready = $ready
        InteractionRequired = -not $ready
        IdentityCreated = $false
        PublicKeyUpdated = $false
    } | ConvertTo-Json -Compress
    return
}
$managerConfig = Get-Content -Raw -LiteralPath $Config | ConvertFrom-Json
$target = @($managerConfig.targets | Where-Object { [string]$_.name -eq $Name })[0]
$enabled = [bool]$target.enabled
$result = [pscustomobject]@{
    Name = $Name
    Enabled = $enabled
    TaskState = if ($enabled) { 'Running' } else { 'Disabled' }
    SSH = 'OK'
    Proxy = if ($enabled) { 'OK' } else { 'BLOCKED' }
}
ConvertTo-Json -InputObject @($result) -Compress
'@
        $originalManagerPath = $script:ManagerPath
        $originalConfigPath = $Config
        $disabledConfigPath = Join-Path ([IO.Path]::GetTempPath()) (
            'clash-proxy-disabled-smoke-' + [guid]::NewGuid().ToString('N') + '.json'
        )
        $parallelConfigPath = Join-Path ([IO.Path]::GetTempPath()) (
            'clash-proxy-parallel-smoke-' + [guid]::NewGuid().ToString('N') + '.json'
        )
        try {
            [IO.File]::WriteAllText($smokeManagerPath, $smokeManagerSource, $script:Utf8Encoding)
            $script:ManagerPath = $smokeManagerPath

            $originalInteractiveCommand = (Get-Command Invoke-InteractiveManagerCommand).ScriptBlock
            $script:InteractiveSshSmokeCalls = 0
            try {
                Set-Item -Path Function:Invoke-InteractiveManagerCommand -Value {
                    param(
                        [string]$Command,
                        [hashtable]$Parameters,
                        [string]$BusyMessage
                    )
                    if ($Command -ne 'bootstrap-key' -or
                        [string]::IsNullOrWhiteSpace([string]$Parameters.Name)) {
                        throw 'Unexpected interactive SSH smoke invocation'
                    }
                    $script:InteractiveSshSmokeCalls++
                    return $true
                }

                $sshManagerConfig = Read-UiConfig
                $readyTarget = Resolve-UiTarget $sshManagerConfig $sshManagerConfig.targets[0]
                if (-not (Ensure-UiSshKeyAuthentication $readyTarget) -or
                    $script:InteractiveSshSmokeCalls -ne 0) {
                    throw 'Ready SSH key authentication unnecessarily opened a console'
                }

                $interactionTarget = $readyTarget | ConvertTo-Json -Depth 8 | ConvertFrom-Json
                $interactionTarget.name = 'requires-interaction'
                if (-not (Ensure-UiSshKeyAuthentication $interactionTarget -SuppressInteractionNotice) -or
                    $script:InteractiveSshSmokeCalls -ne 1) {
                    throw 'Missing remote SSH key did not route to one interactive console'
                }
            }
            finally {
                Set-Item -Path Function:Invoke-InteractiveManagerCommand -Value $originalInteractiveCommand
            }

            $generation = Reset-TargetHealth $originalName
            Start-BackgroundTargetHealthCheck $originalName $generation
            $backgroundProcess = @($script:BackgroundHealthChecks.Values)[0].Process
            Start-Sleep -Milliseconds 75
            $backgroundProcess.Refresh()
            if ($backgroundProcess.MainWindowHandle -ne [IntPtr]::Zero) {
                throw 'Background target health process created a visible window'
            }
            $deadline = (Get-Date).AddSeconds(5)
            while ($script:BackgroundHealthChecks.Count -gt 0 -and (Get-Date) -lt $deadline) {
                Complete-BackgroundHealthChecks
                Start-Sleep -Milliseconds 50
            }
            if ($script:BackgroundHealthChecks.Count -ne 0) {
                throw 'Background target health process did not complete'
            }
            if (-not $script:HealthCache.ContainsKey($originalName) -or
                [string]$script:HealthCache[$originalName].Proxy -ne 'OK') {
                throw 'Background target health result was not applied'
            }

            $staleGeneration = Reset-TargetHealth $originalName
            Start-BackgroundTargetHealthCheck $originalName $staleGeneration
            $staleProcessId = @($script:BackgroundHealthChecks.Values)[0].Process.Id
            [void](Reset-TargetHealth $originalName)
            if ($script:BackgroundHealthChecks.Count -ne 0 -or
                $null -ne (Get-Process -Id $staleProcessId -ErrorAction SilentlyContinue)) {
                throw 'Starting a newer target state did not terminate the stale background process tree'
            }
            $deadline = (Get-Date).AddSeconds(5)
            while ($script:BackgroundHealthChecks.Count -gt 0 -and (Get-Date) -lt $deadline) {
                Complete-BackgroundHealthChecks
                Start-Sleep -Milliseconds 50
            }
            if ($script:BackgroundHealthChecks.Count -ne 0) {
                throw 'Stale background target health process did not complete'
            }
            if ($script:HealthCache.ContainsKey($originalName)) {
                throw 'Stale background target health result overwrote the current state'
            }
            $disabledConfig = Get-Content -Raw -LiteralPath $originalConfigPath | ConvertFrom-Json
            $disabledConfig.targets[0].enabled = $false
            [IO.File]::WriteAllText(
                $disabledConfigPath,
                ($disabledConfig | ConvertTo-Json -Depth 8),
                $script:Utf8Encoding
            )
            $Config = $disabledConfigPath
            Refresh-TargetGrid
            $disabledGeneration = Reset-TargetHealth $originalName
            Start-BackgroundTargetHealthCheck $originalName $disabledGeneration $false
            $deadline = (Get-Date).AddSeconds(5)
            while ($script:BackgroundHealthChecks.Count -gt 0 -and (Get-Date) -lt $deadline) {
                Complete-BackgroundHealthChecks
                Start-Sleep -Milliseconds 50
            }
            if ($script:BackgroundHealthChecks.Count -ne 0) {
                throw 'Disabled background target health process did not complete'
            }
            if (-not $script:HealthCache.ContainsKey($originalName) -or
                [bool]$script:HealthCache[$originalName].Enabled -or
                [string]$script:HealthCache[$originalName].Proxy -ne 'BLOCKED') {
                throw 'Disabled background closure result was not applied'
            }

            $parallelConfig = Get-Content -Raw -LiteralPath $originalConfigPath | ConvertFrom-Json
            $secondTarget = $parallelConfig.targets[0] | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $secondTarget.name = "$originalName-second"
            $secondTarget.taskName = "$($secondTarget.taskName)-second"
            $secondTarget | Add-Member `
                -NotePropertyName remoteProxyPort `
                -NotePropertyValue ([int]$parallelConfig.defaults.remoteProxyPort + 1) `
                -Force
            $secondTarget.enabled = $false
            $parallelConfig.targets = @($parallelConfig.targets[0], $secondTarget)
            [IO.File]::WriteAllText(
                $parallelConfigPath,
                ($parallelConfig | ConvertTo-Json -Depth 8),
                $script:Utf8Encoding
            )
            $Config = $parallelConfigPath
            Refresh-TargetGrid
            Invoke-HealthCheck
            $manualEntries = @($script:BackgroundHealthChecks.Values | Where-Object {
                [string]$_.Reason -eq 'manual'
            })
            if ($manualEntries.Count -ne 2 -or
                $script:healthButton.Text -ne 'Cancel checks' -or
                -not $script:ActionPanel.Enabled -or
                -not $script:Grid.Enabled) {
                throw 'Manual health check is not parallel, cancellable, or non-blocking'
            }
            Start-Sleep -Milliseconds 75
            foreach ($manualEntry in $manualEntries) {
                $manualEntry.Process.Refresh()
                if ($manualEntry.Process.MainWindowHandle -ne [IntPtr]::Zero) {
                    throw 'Parallel manual health check created a visible window'
                }
            }
            $deadline = (Get-Date).AddSeconds(5)
            while ($script:BackgroundHealthChecks.Count -gt 0 -and (Get-Date) -lt $deadline) {
                Complete-BackgroundHealthChecks
                Start-Sleep -Milliseconds 50
            }
            if ($script:BackgroundHealthChecks.Count -ne 0 -or
                $script:healthButton.Text -ne 'Health check' -or
                [string]$script:HealthCache[$originalName].Proxy -ne 'OK' -or
                [string]$script:HealthCache[[string]$secondTarget.name].Proxy -ne 'BLOCKED') {
                throw 'Parallel manual health results were not completed independently'
            }

            Invoke-HealthCheck
            $cancelProcessIds = @($script:BackgroundHealthChecks.Values | ForEach-Object {
                [int]$_.Process.Id
            })
            if ($cancelProcessIds.Count -ne 2) {
                throw 'Manual cancellation smoke test did not start both target checks'
            }
            Invoke-HealthCheck
            if ($script:BackgroundHealthChecks.Count -ne 0 -or
                $script:healthButton.Text -ne 'Health check') {
                throw 'Manual health cancellation did not reset the background state'
            }
            foreach ($processId in $cancelProcessIds) {
                if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
                    throw 'Manual health cancellation left a background process running'
                }
            }
        }
        finally {
            Stop-BackgroundHealthChecks
            $script:ManagerPath = $originalManagerPath
            $Config = $originalConfigPath
            if (Test-Path -LiteralPath $smokeManagerPath -PathType Leaf) {
                Remove-Item -LiteralPath $smokeManagerPath -Force
            }
            if (Test-Path -LiteralPath $disabledConfigPath -PathType Leaf) {
                Remove-Item -LiteralPath $disabledConfigPath -Force
            }
            if (Test-Path -LiteralPath $parallelConfigPath -PathType Leaf) {
                Remove-Item -LiteralPath $parallelConfigPath -Force
            }
        }
    }
    $advancedLabels = @($advancedMenu.Items | ForEach-Object { [string]$_.Text })
    $instanceSmokeName = 'Local\ClashSshProxyManager.Smoke.' + [guid]::NewGuid().ToString('N')
    $instanceHolderSource = @"
`$mutex = New-Object System.Threading.Mutex(`$false, '$instanceSmokeName')
`$acquired = `$false
try {
    `$acquired = `$mutex.WaitOne(1000, `$false)
    if (-not `$acquired) { exit 2 }
    [Console]::Out.WriteLine('READY')
    Start-Sleep -Milliseconds 800
}
finally {
    if (`$acquired) { `$mutex.ReleaseMutex() }
    `$mutex.Dispose()
}
"@
    $instanceHolderStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $instanceHolderStartInfo.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
    $instanceHolderStartInfo.Arguments = (@(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand',
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($instanceHolderSource))
    ) | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' '
    $instanceHolderStartInfo.UseShellExecute = $false
    $instanceHolderStartInfo.CreateNoWindow = $true
    $instanceHolderStartInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $instanceHolderStartInfo.RedirectStandardOutput = $true
    $instanceHolderStartInfo.RedirectStandardError = $true
    $instanceHolder = New-Object System.Diagnostics.Process
    $duplicateMutex = $null
    $availableMutex = $null
    try {
        $instanceHolder.StartInfo = $instanceHolderStartInfo
        if (-not $instanceHolder.Start()) {
            throw 'UI instance mutex holder did not start'
        }
        if ($instanceHolder.StandardOutput.ReadLine() -ne 'READY') {
            throw 'UI instance mutex holder did not acquire its mutex'
        }
        $duplicateMutex = Enter-UiInstanceMutex $instanceSmokeName
        if ($null -ne $duplicateMutex) {
            throw 'UI single-instance mutex admitted a second process'
        }
        if (-not $instanceHolder.WaitForExit(5000) -or $instanceHolder.ExitCode -ne 0) {
            throw 'UI instance mutex holder did not release normally'
        }
        $availableMutex = Enter-UiInstanceMutex $instanceSmokeName
        if ($null -eq $availableMutex) {
            throw 'UI single-instance mutex was not reusable after release'
        }
    }
    finally {
        if ($null -ne $duplicateMutex) {
            Exit-UiInstanceMutex $duplicateMutex
        }
        if ($null -ne $availableMutex) {
            Exit-UiInstanceMutex $availableMutex
        }
        try {
            if (-not $instanceHolder.HasExited) {
                Stop-BackgroundHealthProcess $instanceHolder
            }
            else {
                $instanceHolder.Dispose()
            }
        }
        catch {
            $instanceHolder.Dispose()
        }
    }

    if (@($advancedLabels | Where-Object { $_ -match '(?i)\b(start|stop)\b' }).Count -gt 0) {
        throw 'Advanced UI unexpectedly exposes Start or Stop'
    }
    $healthStartInfo = New-TargetHealthProcessStartInfo 'smoke-target'
    if ($healthStartInfo.UseShellExecute -or -not $healthStartInfo.CreateNoWindow -or
        $healthStartInfo.WindowStyle -ne [System.Diagnostics.ProcessWindowStyle]::Hidden -or
        $healthStartInfo.Arguments -notmatch '(?:^|\s)status(?:\s|$)' -or
        $healthStartInfo.Arguments -notmatch '(?:^|\s)-Name(?:\s|$)') {
        throw 'Background target health process is not hidden or target-scoped'
    }
    $script:Form.Dispose()
    Write-Output 'UI smoke test passed'
