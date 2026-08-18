# Bounded startup reconciliation and non-blocking enabled-target recovery.

function Get-TargetRecoveryDecision {
    param(
        [bool]$Enabled,
        [string]$TaskState
    )

    if (-not $Enabled) {
        return 'None'
    }
    switch ($TaskState) {
        { $_ -in @('Ready', 'Disabled') } { return 'Recover' }
        'Missing' { return 'Reinstall' }
        default { return 'None' }
    }
}

function Get-ProxyVerificationFailureReason {
    param($HealthItem)

    $taskState = [string](Get-ObjectProperty $HealthItem 'TaskState' 'Unknown')
    switch ($taskState) {
        'Missing' { return 'task-missing' }
        'Disabled' { return 'task-disabled' }
        'Ready' { return 'task-stopped' }
        'Queued' { return 'task-queued' }
        'Unknown' { return 'task-state-unknown' }
    }
    if ([string](Get-ObjectProperty $HealthItem 'SSH' 'FAIL') -ne 'OK') {
        return 'ssh-unreachable'
    }
    if ([string](Get-ObjectProperty $HealthItem 'Proxy' 'FAIL') -ne 'OK') {
        return 'remote-proxy-unavailable'
    }
    return 'unknown'
}

function Get-RecoveryProcessErrorDetail {
    param(
        [string]$StandardOutput,
        [string]$StandardError,
        [int]$ExitCode
    )

    $encodedMatch = [regex]::Match(
        $StandardError,
        'RECOVERY_ERROR_BASE64=(?<value>[A-Za-z0-9+/=]+)'
    )
    if ($encodedMatch.Success) {
        try {
            $bytes = [Convert]::FromBase64String($encodedMatch.Groups['value'].Value)
            return [Text.Encoding]::UTF8.GetString($bytes)
        }
        catch {}
    }
    if (-not [string]::IsNullOrWhiteSpace($StandardError)) {
        return $StandardError
    }
    if (-not [string]::IsNullOrWhiteSpace($StandardOutput)) {
        return $StandardOutput
    }
    return "Recovery process exited with code $ExitCode"
}

function New-TargetRecoveryProcessStartInfo {
    param([string]$Name)

    $payload = [pscustomobject]@{
        ManagerPath = $script:ManagerPath
        Name = $Name
        Config = $Config
    }
    $payloadJson = $payload | ConvertTo-Json -Compress
    $payloadBase64 = [Convert]::ToBase64String($script:Utf8Encoding.GetBytes($payloadJson))
    $childSource = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payloadBase64'))
`$payload = `$payloadJson | ConvertFrom-Json
try {
    & ([string]`$payload.ManagerPath) 'enable' -Name ([string]`$payload.Name) -Config ([string]`$payload.Config) -Confirm:`$false
}
catch {
    `$errorBytes = [Text.Encoding]::UTF8.GetBytes(`$_.Exception.Message)
    `$errorBase64 = [Convert]::ToBase64String(`$errorBytes)
    [Console]::Error.WriteLine('RECOVERY_ERROR_BASE64=' + `$errorBase64)
    exit 1
}
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childSource))
    $argumentValues = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $encodedCommand
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
    $startInfo.Arguments = ($argumentValues | ForEach-Object {
        ConvertTo-WindowsArgument ([string]$_)
    }) -join ' '
    $startInfo.WorkingDirectory = $script:RepositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    return $startInfo
}

function Stop-BackgroundTargetRecoveries {
    param([string]$Name)

    $stopped = 0
    foreach ($recoveryId in @($script:BackgroundRecoveries.Keys)) {
        $entry = $script:BackgroundRecoveries[$recoveryId]
        if (-not [string]::IsNullOrWhiteSpace($Name) -and [string]$entry.Name -ne $Name) {
            continue
        }
        Stop-BackgroundHealthProcess $entry.Process
        [void]$script:BackgroundRecoveries.Remove($recoveryId)
        $stopped++
    }
    if ($script:BackgroundRecoveries.Count -eq 0 -and $null -ne $script:RecoveryTimer) {
        $script:RecoveryTimer.Stop()
    }
    return $stopped
}

function Start-BackgroundTargetRecovery {
    param(
        [string]$Name,
        [string]$TaskState
    )

    $existing = @($script:BackgroundRecoveries.Values | Where-Object {
        [string]$_.Name -eq $Name
    })
    if ($existing.Count -gt 0) {
        return $false
    }

    $generation = Reset-TargetHealth $Name
    $process = New-Object System.Diagnostics.Process
    try {
        $process.StartInfo = New-TargetRecoveryProcessStartInfo $Name
        if (-not $process.Start()) {
            throw 'The background recovery process did not start'
        }
    }
    catch {
        $process.Dispose()
        throw
    }

    $recoveryId = [guid]::NewGuid().ToString('N')
    $script:BackgroundRecoveries[$recoveryId] = [pscustomobject]@{
        Name = $Name
        Generation = $generation
        PreviousTaskState = $TaskState
        StartedAt = Get-Date
        Process = $process
    }
    $script:HealthCache[$Name] = [pscustomobject]@{
        Name = $Name
        Enabled = $true
        SSH = '...'
        Proxy = 'RECOVERING'
    }
    $row = Get-TargetRowByName $Name
    if ($null -ne $row) {
        $row.Cells['SshState'].Value = '...'
        $row.Cells['ProxyState'].Value = 'RECOVERING'
    }
    Add-Log "Automatic recovery started for $Name because its task is $TaskState."
    $script:StatusLabel.Text = "Recovering $Name in background..."
    $script:RecoveryTimer.Start()
    return $true
}

function Complete-BackgroundTargetRecoveries {
    foreach ($recoveryId in @($script:BackgroundRecoveries.Keys)) {
        $entry = $script:BackgroundRecoveries[$recoveryId]
        $process = $entry.Process
        if (-not $process.HasExited) {
            continue
        }

        $elapsed = [string]::Format(
            [Globalization.CultureInfo]::InvariantCulture,
            '{0:0.00}s',
            ((Get-Date) - $entry.StartedAt).TotalSeconds
        )
        $isCurrent = $script:HealthGenerations.ContainsKey([string]$entry.Name) -and
            [int]$script:HealthGenerations[[string]$entry.Name] -eq [int]$entry.Generation
        try {
            $stdout = $process.StandardOutput.ReadToEnd().Trim()
            $stderr = $process.StandardError.ReadToEnd().Trim()
            if (-not $isCurrent) {
                continue
            }
            if ($process.ExitCode -ne 0) {
                $detail = Get-RecoveryProcessErrorDetail $stdout $stderr $process.ExitCode
                throw $detail
            }

            $managerConfig = Read-UiConfig
            $currentRaw = @($managerConfig.targets | Where-Object {
                [string]$_.name -eq [string]$entry.Name
            })
            if ($currentRaw.Count -ne 1) {
                continue
            }
            $currentTarget = Resolve-UiTarget $managerConfig $currentRaw[0]
            if (-not [bool]$currentTarget.enabled) {
                continue
            }

            Refresh-TargetGrid
            Add-Log "Automatic recovery command completed for $($entry.Name) in $elapsed."
            Start-BackgroundTargetHealthCheck `
                -Name ([string]$entry.Name) `
                -Generation ([int]$entry.Generation) `
                -ExpectedEnabled $true `
                -Reason 'toggle'
        }
        catch {
            if ($isCurrent) {
                $script:HealthCache[[string]$entry.Name] = [pscustomobject]@{
                    Name = [string]$entry.Name
                    Enabled = $true
                    SSH = 'FAIL'
                    Proxy = 'FAIL'
                }
                Refresh-TargetGrid
                Add-Log "AUTOMATIC RECOVERY FAILED for $($entry.Name) after ${elapsed}: $($_.Exception.Message)"
                $script:StatusLabel.Text = "Automatic recovery failed for $($entry.Name)"
            }
        }
        finally {
            $process.Dispose()
            [void]$script:BackgroundRecoveries.Remove($recoveryId)
        }
    }

    if ($script:BackgroundRecoveries.Count -eq 0 -and $null -ne $script:RecoveryTimer) {
        $script:RecoveryTimer.Stop()
    }
}

function Stop-StartupRecoveryWait {
    $script:StartupRecoveryActive = $false
    if ($null -ne $script:StartupRecoveryTimer) {
        $script:StartupRecoveryTimer.Stop()
    }
}

function Invoke-StartupRecoveryTick {
    if (-not $script:StartupRecoveryActive) {
        return
    }

    $script:StartupRecoveryAttempt++
    $attempt = $script:StartupRecoveryAttempt
    try {
        $managerConfig = Read-UiConfig
        $enabledTargets = @($managerConfig.targets | ForEach-Object {
            Resolve-UiTarget $managerConfig $_
        } | Where-Object { [bool]$_.enabled })
        if ($enabledTargets.Count -eq 0) {
            Stop-StartupRecoveryWait
            return
        }

        $proxyHost = [string]$managerConfig.proxy.localHost
        $proxyPort = [int]$managerConfig.proxy.localPort
        if (-not (Test-LocalTcpPort $proxyHost $proxyPort 200)) {
            if (-not $script:StartupRecoveryWaitLogged) {
                Add-Log "Waiting up to 30 seconds for the local proxy on ${proxyHost}:$proxyPort before automatic recovery."
                $script:StartupRecoveryWaitLogged = $true
            }
            if ($attempt -ge $script:StartupRecoveryAttemptLimit) {
                Add-Log "Automatic recovery stopped after $attempt local-proxy checks; use Restart proxy after Clash is ready."
                $script:StatusLabel.Text = 'Automatic recovery timed out waiting for Clash'
                Stop-StartupRecoveryWait
            }
            else {
                $script:StatusLabel.Text = "Waiting for Clash before automatic recovery ($attempt/$($script:StartupRecoveryAttemptLimit))"
            }
            return
        }

        $retryNeeded = $false
        foreach ($target in $enabledTargets) {
            try {
                $taskState = Get-UiScheduledTaskState $target.taskName
                $decision = Get-TargetRecoveryDecision $true $taskState
                switch ($decision) {
                    'Recover' {
                        [void](Start-BackgroundTargetRecovery $target.name $taskState)
                    }
                    'Reinstall' {
                        if (-not $script:MissingRecoveryTargets.ContainsKey([string]$target.name)) {
                            $script:MissingRecoveryTargets[[string]$target.name] = $true
                            Add-Log "AUTOMATIC RECOVERY SKIPPED for $($target.name): scheduled task '$($target.taskName)' is missing. Use Edit / Update to rebuild it."
                            $script:StatusLabel.Text = "Update required for $($target.name)"
                        }
                    }
                }
            }
            catch {
                $retryNeeded = $true
                Add-Log "AUTOMATIC RECOVERY CHECK ERROR for $($target.name), attempt ${attempt}: $($_.Exception.Message)"
            }
        }

        Refresh-TargetGrid
        if (-not $retryNeeded) {
            Stop-StartupRecoveryWait
        }
        elseif ($attempt -ge $script:StartupRecoveryAttemptLimit) {
            Add-Log "Automatic recovery stopped after $attempt attempts because one or more task states could not be checked."
            Stop-StartupRecoveryWait
        }
    }
    catch {
        Add-Log "AUTOMATIC RECOVERY ERROR on attempt ${attempt}: $($_.Exception.Message)"
        if ($attempt -ge $script:StartupRecoveryAttemptLimit) {
            Stop-StartupRecoveryWait
        }
    }
}

function Start-StartupRecovery {
    Stop-StartupRecoveryWait
    $script:StartupRecoveryAttempt = 0
    $script:StartupRecoveryWaitLogged = $false
    $script:MissingRecoveryTargets = @{}
    $script:StartupRecoveryActive = $true
    Invoke-StartupRecoveryTick
    if ($script:StartupRecoveryActive) {
        $script:StartupRecoveryTimer.Start()
    }
}

function Stop-BackgroundRecoveries {
    Stop-StartupRecoveryWait
    [void](Stop-BackgroundTargetRecoveries)
}
