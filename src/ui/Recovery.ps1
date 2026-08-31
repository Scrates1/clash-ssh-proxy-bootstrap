# One-process startup reconciliation and non-blocking health-check handoff.

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

function New-ReconciliationProcessStartInfo {
    $argumentValues = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $script:ManagerPath,
        'reconcile',
        '-Config', $Config
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
    return $startInfo
}

function Start-StartupReconciliation {
    if ($null -ne $script:BackgroundReconciliation) {
        return $false
    }

    $managerConfig = Read-UiConfig
    $candidates = @()
    foreach ($rawTarget in @($managerConfig.targets)) {
        $target = Resolve-UiTarget $managerConfig $rawTarget
        if (-not [bool]$target.enabled) {
            continue
        }
        try {
            $taskState = Get-UiScheduledTaskState $target.taskName
            switch (Get-TargetRecoveryDecision $true $taskState) {
                'Recover' {
                    $candidates += [string]$target.name
                }
                'Reinstall' {
                    Add-Log "AUTOMATIC RECOVERY SKIPPED for $($target.name): scheduled task '$($target.taskName)' is missing. Use Edit / Update to rebuild it."
                    $script:StatusLabel.Text = "Update required for $($target.name)"
                }
            }
        }
        catch {
            Add-Log "AUTOMATIC RECOVERY CHECK ERROR for $($target.name): $($_.Exception.Message)"
        }
    }

    if ($candidates.Count -eq 0) {
        return $false
    }

    $process = New-Object System.Diagnostics.Process
    try {
        $process.StartInfo = New-ReconciliationProcessStartInfo
        if (-not $process.Start()) {
            throw 'The reconciliation process did not start'
        }
    }
    catch {
        $process.Dispose()
        throw
    }

    $trackedTargets = @($candidates | ForEach-Object {
        $name = [string]$_
        $generation = Reset-TargetHealth $name
        $script:HealthCache[$name] = [pscustomobject]@{
            Name = $name
            Enabled = $true
            SSH = '...'
            Proxy = 'RECOVERING'
        }
        $row = Get-TargetRowByName $name
        if ($null -ne $row) {
            $row.Cells['SshState'].Value = '...'
            $row.Cells['ProxyState'].Value = 'RECOVERING'
        }
        [pscustomobject]@{
            Name = $name
            Generation = $generation
        }
    })

    $script:BackgroundReconciliation = [pscustomobject]@{
        Targets = $trackedTargets
        StartedAt = Get-Date
        Process = $process
    }
    Add-Log "Automatic reconciliation started for $($trackedTargets.Count) target(s); waiting up to 30 seconds for Clash if needed."
    $script:StatusLabel.Text = "Recovering $($trackedTargets.Count) target(s) in background..."
    $script:ReconciliationTimer.Start()
    return $true
}

function Complete-StartupReconciliation {
    $entry = $script:BackgroundReconciliation
    if ($null -eq $entry -or -not $entry.Process.HasExited) {
        return
    }

    $process = $entry.Process
    $exitCode = $process.ExitCode
    $elapsed = [string]::Format(
        [Globalization.CultureInfo]::InvariantCulture,
        '{0:0.00}s',
        ((Get-Date) - $entry.StartedAt).TotalSeconds
    )
    $managerConfig = if ($exitCode -eq 0) { Read-UiConfig } else { $null }
    $script:BackgroundReconciliation = $null
    if ($null -ne $script:ReconciliationTimer) {
        $script:ReconciliationTimer.Stop()
    }
    $process.Dispose()

    if ($exitCode -ne 0) {
        foreach ($targetEntry in @($entry.Targets)) {
            $name = [string]$targetEntry.Name
            if ($script:HealthGenerations.ContainsKey($name) -and
                [int]$script:HealthGenerations[$name] -eq [int]$targetEntry.Generation) {
                $script:HealthCache[$name] = [pscustomobject]@{
                    Name = $name
                    Enabled = $true
                    SSH = 'FAIL'
                    Proxy = 'FAIL'
                }
            }
        }
        Refresh-TargetGrid
        Add-Log "AUTOMATIC RECONCILIATION FAILED after ${elapsed}: process exited with code $exitCode"
        $script:StatusLabel.Text = 'Automatic reconciliation failed'
        return
    }

    Refresh-TargetGrid
    $startedChecks = 0
    foreach ($targetEntry in @($entry.Targets)) {
        $name = [string]$targetEntry.Name
        $isCurrent = $script:HealthGenerations.ContainsKey($name) -and
            [int]$script:HealthGenerations[$name] -eq [int]$targetEntry.Generation
        if (-not $isCurrent) {
            continue
        }
        try {
            $currentRaw = @($managerConfig.targets | Where-Object { [string]$_.name -eq $name })
            if ($currentRaw.Count -ne 1) {
                continue
            }
            $currentTarget = Resolve-UiTarget $managerConfig $currentRaw[0]
            if (-not [bool]$currentTarget.enabled) {
                continue
            }
            Start-BackgroundTargetHealthCheck $name ([int]$targetEntry.Generation) $true
            $startedChecks++
        }
        catch {
            Add-Log "BACKGROUND HEALTH START ERROR for ${name}: $($_.Exception.Message)"
        }
    }

    Add-Log "Automatic reconciliation completed in $elapsed; started $startedChecks background verification check(s)."
}

function Detach-StartupReconciliation {
    if ($null -ne $script:ReconciliationTimer) {
        $script:ReconciliationTimer.Stop()
    }
    if ($null -ne $script:BackgroundReconciliation) {
        $script:BackgroundReconciliation.Process.Dispose()
        $script:BackgroundReconciliation = $null
    }
}
