# Asynchronous, cancellable target health checks and in-place grid refresh.

function Test-ManualHealthChecksRunning {
    return @($script:BackgroundHealthChecks.Values | Where-Object {
        [string]$_.Reason -eq 'manual'
    }).Count -gt 0
}

function Update-HealthCheckActionState {
    if ($null -eq (Get-Variable -Name healthButton -Scope Script -ErrorAction SilentlyContinue)) {
        return
    }
    $manualCount = @($script:BackgroundHealthChecks.Values | Where-Object {
        [string]$_.Reason -eq 'manual'
    }).Count
    $script:healthButton.Text = if ($manualCount -gt 0) { 'Cancel checks' } else { 'Health check' }
}

function Stop-BackgroundHealthProcess {
    param($Process)

    try {
        if (-not $Process.HasExited) {
            $taskKill = Get-Command taskkill.exe -ErrorAction SilentlyContinue
            if ($null -ne $taskKill) {
                $previousErrorActionPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    & $taskKill.Source /PID ([string]$Process.Id) /T /F 1> $null 2> $null
                }
                finally {
                    $ErrorActionPreference = $previousErrorActionPreference
                }
            }
            if (-not $Process.WaitForExit(2000)) {
                $Process.Kill()
                [void]$Process.WaitForExit(1000)
            }
        }
    }
    catch {}
    finally {
        $Process.Dispose()
    }
}

function Stop-BackgroundTargetHealthChecks {
    param(
        [string]$Name,
        [string]$Reason
    )

    $stopped = 0
    foreach ($checkId in @($script:BackgroundHealthChecks.Keys)) {
        $entry = $script:BackgroundHealthChecks[$checkId]
        if (-not [string]::IsNullOrWhiteSpace($Name) -and [string]$entry.Name -ne $Name) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($Reason) -and [string]$entry.Reason -ne $Reason) {
            continue
        }
        Stop-BackgroundHealthProcess $entry.Process
        [void]$script:BackgroundHealthChecks.Remove($checkId)
        $stopped++
    }
    if ($script:BackgroundHealthChecks.Count -eq 0 -and $null -ne $script:HealthTimer) {
        $script:HealthTimer.Stop()
    }
    Update-HealthCheckActionState
    return $stopped
}

function Reset-TargetHealth {
    param([string]$Name)

    $canceled = Stop-BackgroundTargetHealthChecks -Name $Name
    if ($canceled -gt 0) {
        Add-Log "Canceled $canceled stale background check(s) for $Name."
    }
    [void]$script:HealthCache.Remove($Name)
    $generation = if ($script:HealthGenerations.ContainsKey($Name)) {
        [int]$script:HealthGenerations[$Name] + 1
    } else {
        1
    }
    $script:HealthGenerations[$Name] = $generation
    return $generation
}

function Stop-ManualHealthChecks {
    $entries = @($script:BackgroundHealthChecks.Values | Where-Object {
        [string]$_.Reason -eq 'manual'
    })
    if ($entries.Count -eq 0) {
        return
    }
    $names = @($entries | ForEach-Object { [string]$_.Name } | Select-Object -Unique)
    foreach ($name in $names) {
        [void](Reset-TargetHealth $name)
    }
    Refresh-TargetGrid
    Update-HealthCheckActionState
    Add-Log "Canceled manual health checks for $($names.Count) target(s)."
    $script:StatusLabel.Text = 'Health check canceled'
}

function New-TargetHealthProcessStartInfo {
    param([string]$Name)

    $argumentValues = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $script:ManagerPath,
        'status',
        '-Name', $Name,
        '-Config', $Config,
        '-Json'
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
    $startInfo.Arguments = ($argumentValues | ForEach-Object {
        ConvertTo-WindowsArgument ([string]$_)
    }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    return $startInfo
}

function Start-BackgroundTargetHealthCheck {
    param(
        [string]$Name,
        [int]$Generation,
        [bool]$ExpectedEnabled = $true,
        [ValidateSet('toggle', 'manual')][string]$Reason = 'toggle'
    )

    [void](Stop-BackgroundTargetHealthChecks -Name $Name)
    $process = New-Object System.Diagnostics.Process
    try {
        $process.StartInfo = New-TargetHealthProcessStartInfo $Name
        if (-not $process.Start()) {
            throw 'The background health process did not start'
        }
    }
    catch {
        $process.Dispose()
        throw
    }

    $checkId = [guid]::NewGuid().ToString('N')
    $script:BackgroundHealthChecks[$checkId] = [pscustomobject]@{
        Name = $Name
        Generation = $Generation
        ExpectedEnabled = $ExpectedEnabled
        Reason = $Reason
        StartedAt = Get-Date
        Process = $process
    }
    $script:HealthCache[$Name] = [pscustomobject]@{
        Name = $Name
        Enabled = $ExpectedEnabled
        SSH = '...'
        Proxy = 'CHECKING'
    }
    $row = Get-TargetRowByName $Name
    if ($null -ne $row) {
        $row.Cells['SshState'].Value = '...'
        $row.Cells['ProxyState'].Value = 'CHECKING'
    }
    if ($Reason -eq 'manual') {
        Add-Log "Health check started for $Name."
        $script:StatusLabel.Text = "Checking $Name in background..."
    }
    elseif ($ExpectedEnabled) {
        Add-Log "Background proxy verification started for $Name."
        $script:StatusLabel.Text = "Enabled $Name - checking proxy in background..."
    }
    else {
        Add-Log "Background proxy-closure verification started for $Name."
        $script:StatusLabel.Text = "Disabled $Name - confirming remote closure in background..."
    }
    $script:HealthTimer.Start()
    Update-HealthCheckActionState
}

function Complete-BackgroundHealthChecks {
    $completedManual = 0
    foreach ($checkId in @($script:BackgroundHealthChecks.Keys)) {
        $entry = $script:BackgroundHealthChecks[$checkId]
        $process = $entry.Process
        if (-not $process.HasExited) {
            continue
        }

        $reason = [string]$entry.Reason
        if ($reason -eq 'manual') {
            $completedManual++
        }
        $elapsed = [string]::Format(
            [Globalization.CultureInfo]::InvariantCulture, '{0:0.00}s', ((Get-Date) - $entry.StartedAt).TotalSeconds
        )
        $expectedEnabled = [bool]$entry.ExpectedEnabled
        $isCurrent = $script:HealthGenerations.ContainsKey([string]$entry.Name) -and
            [int]$script:HealthGenerations[[string]$entry.Name] -eq [int]$entry.Generation
        try {
            if (-not $isCurrent) {
                continue
            }
            $stdout = $process.StandardOutput.ReadToEnd().Trim()
            $stderr = $process.StandardError.ReadToEnd().Trim()
            if ($process.ExitCode -ne 0) {
                $detail = if ([string]::IsNullOrWhiteSpace($stderr)) {
                    "Background health process exited with code $($process.ExitCode)"
                } else {
                    $stderr
                }
                throw $detail
            }
            if ([string]::IsNullOrWhiteSpace($stdout)) {
                throw 'Background health process returned no status'
            }

            $items = @($stdout | ConvertFrom-Json)
            $matches = @($items | Where-Object { [string]$_.Name -eq [string]$entry.Name })
            if ($matches.Count -ne 1) {
                throw "Background health result for $($entry.Name) was missing or duplicated"
            }

            $managerConfig = Read-UiConfig
            $currentRaw = @($managerConfig.targets | Where-Object {
                [string]$_.name -eq [string]$entry.Name
            })
            if ($currentRaw.Count -ne 1) {
                continue
            }
            $currentTarget = Resolve-UiTarget $managerConfig $currentRaw[0]
            $item = $matches[0]
            if ([bool]$item.Enabled -ne [bool]$currentTarget.enabled -or
                [bool]$currentTarget.enabled -ne $expectedEnabled) {
                continue
            }

            $health = @{}
            $health[[string]$entry.Name] = $item
            Refresh-TargetGrid $health
            if ($expectedEnabled -and [string]$item.SSH -eq 'OK' -and [string]$item.Proxy -eq 'OK') {
                Add-Log "Proxy verification OK for $($entry.Name) in $elapsed."
                $script:StatusLabel.Text = "Proxy verified for $($entry.Name)"
            }
            elseif ($expectedEnabled) {
                $failureReason = Get-ProxyVerificationFailureReason $item
                Add-Log "PROXY VERIFICATION FAILED for $($entry.Name) in ${elapsed}: Reason=$failureReason, SSH=$($item.SSH), Proxy=$($item.Proxy), Task=$($item.TaskState)"
                $script:StatusLabel.Text = "Proxy verification failed for $($entry.Name)"
            }
            elseif ([string]$item.Proxy -eq 'BLOCKED') {
                Add-Log "Proxy-closure verification OK for $($entry.Name) in $elapsed."
                $script:StatusLabel.Text = "Remote proxy blocked for $($entry.Name)"
            }
            elseif ([string]$item.Proxy -eq 'LEAK') {
                Add-Log "PROXY-CLOSURE VERIFICATION FAILED for $($entry.Name) in ${elapsed}: remote proxy is still listening"
                $script:StatusLabel.Text = "Remote proxy leak detected for $($entry.Name)"
            }
            else {
                Add-Log "PROXY-CLOSURE UNKNOWN for $($entry.Name) in ${elapsed}: Linux host could not be checked"
                $script:StatusLabel.Text = "Remote closure could not be confirmed for $($entry.Name)"
            }
        }
        catch {
            if ($isCurrent) {
                $script:HealthCache[[string]$entry.Name] = [pscustomobject]@{
                    Name = [string]$entry.Name
                    Enabled = $expectedEnabled
                    SSH = 'FAIL'
                    Proxy = if ($expectedEnabled) { 'FAIL' } else { 'UNKNOWN' }
                }
                Refresh-TargetGrid
                Add-Log "BACKGROUND HEALTH ERROR for $($entry.Name) after ${elapsed}: $($_.Exception.Message)"
                $script:StatusLabel.Text = "Background health check failed for $($entry.Name)"
            }
        }
        finally {
            $process.Dispose()
            [void]$script:BackgroundHealthChecks.Remove($checkId)
        }
    }

    if ($script:BackgroundHealthChecks.Count -eq 0) {
        $script:HealthTimer.Stop()
    }
    Update-HealthCheckActionState
    $manualRemaining = @($script:BackgroundHealthChecks.Values | Where-Object {
        [string]$_.Reason -eq 'manual'
    }).Count
    if ($manualRemaining -gt 0) {
        $script:StatusLabel.Text = "Health check running - $manualRemaining target(s) remaining"
    }
    elseif ($completedManual -gt 0) {
        Add-Log 'Manual health check completed.'
        $script:StatusLabel.Text = 'Health check completed'
    }
}

function Stop-BackgroundHealthChecks {
    foreach ($checkId in @($script:BackgroundHealthChecks.Keys)) {
        Stop-BackgroundHealthProcess $script:BackgroundHealthChecks[$checkId].Process
        [void]$script:BackgroundHealthChecks.Remove($checkId)
    }
    if ($null -ne $script:HealthTimer) {
        $script:HealthTimer.Stop()
    }
    Update-HealthCheckActionState
}

function Refresh-TargetGrid {
    param([hashtable]$Health = @{})

    foreach ($name in @($Health.Keys)) {
        $script:HealthCache[[string]$name] = $Health[$name]
    }
    $selectedRow = Get-SelectedTargetRow
    $selectedName = if ($null -eq $selectedRow) {
        $null
    } else {
        [string]$selectedRow.Cells['TargetName'].Value
    }
    try {
        $managerConfig = Read-UiConfig
        $proxyHost = [string]$managerConfig.proxy.localHost
        $proxyPort = [int]$managerConfig.proxy.localPort
        $proxyUp = Test-LocalTcpPort $proxyHost $proxyPort
        $script:ProxyLabel.Text = "Local proxy: ${proxyHost}:$proxyPort  " + $(if ($proxyUp) { '[UP]' } else { '[DOWN]' })
        $script:ProxyLabel.ForeColor = if ($proxyUp) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::Firebrick }

        $rowsByName = @{}
        foreach ($existingRow in @($script:Grid.Rows)) {
            $existingName = [string]$existingRow.Cells['TargetName'].Value
            if (-not [string]::IsNullOrWhiteSpace($existingName)) {
                $rowsByName[$existingName] = $existingRow
            }
        }
        $targetNames = @{}
        $script:Grid.SuspendLayout()
        try {
            foreach ($rawTarget in @($managerConfig.targets)) {
                $target = Resolve-UiTarget $managerConfig $rawTarget
                $targetNames[$target.name] = $true
                $taskState = Get-UiScheduledTaskState $target.taskName
                $sshState = '-'
                $proxyState = if ($target.enabled) { '-' } else { 'DISABLED' }
                if ($script:HealthCache.ContainsKey($target.name)) {
                    $healthItem = $script:HealthCache[$target.name]
                    $healthEnabled = [bool](Get-ObjectProperty $healthItem 'Enabled' $target.enabled)
                    if ($healthEnabled -eq [bool]$target.enabled) {
                        $sshState = [string]$healthItem.SSH
                        $proxyState = [string]$healthItem.Proxy
                    }
                }
                if ($target.enabled -and $taskState -ne 'Running' -and
                    $proxyState -notin @('CHECKING', 'RECOVERING')) {
                    $proxyState = 'FAIL'
                }

                if ($rowsByName.ContainsKey($target.name)) {
                    $row = $rowsByName[$target.name]
                }
                else {
                    $rowIndex = $script:Grid.Rows.Add()
                    $row = $script:Grid.Rows[$rowIndex]
                    $rowsByName[$target.name] = $row
                }
                $row.Cells['Enabled'].Value = [bool]$target.enabled
                $row.Cells['TargetName'].Value = $target.name
                $row.Cells['Destination'].Value = "$($target.user)@$($target.host):$($target.sshPort)"
                $row.Cells['TaskState'].Value = $taskState
                $row.Cells['SshState'].Value = $sshState
                $row.Cells['ProxyState'].Value = $proxyState
                $row.Cells['RemotePort'].Value = $target.remoteProxyPort
                $row.Cells['TaskName'].Value = $target.taskName
                $row.DefaultCellStyle.ForeColor = $script:Grid.DefaultCellStyle.ForeColor
                $row.DefaultCellStyle.BackColor = $script:Grid.DefaultCellStyle.BackColor

                if ($proxyState -eq 'LEAK') {
                    $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkRed
                    $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightCoral
                }
                elseif (-not $target.enabled) {
                    $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DimGray
                    $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::Gainsboro
                }
                elseif ($taskState -ne 'Running' -or $proxyState -eq 'FAIL') {
                    $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose
                }
            }

            for ($rowIndex = $script:Grid.Rows.Count - 1; $rowIndex -ge 0; $rowIndex--) {
                $name = [string]$script:Grid.Rows[$rowIndex].Cells['TargetName'].Value
                if (-not $targetNames.ContainsKey($name)) {
                    $script:Grid.Rows.RemoveAt($rowIndex)
                    [void]$script:HealthCache.Remove($name)
                }
            }
        }
        finally {
            $script:Grid.ResumeLayout()
        }

        $rowToSelect = if ([string]::IsNullOrWhiteSpace($selectedName)) {
            $null
        } else {
            Get-TargetRowByName $selectedName
        }
        if ($null -eq $rowToSelect -and $script:Grid.Rows.Count -gt 0) {
            $rowToSelect = $script:Grid.Rows[0]
        }
        if ($null -ne $rowToSelect -and
            ($script:Grid.SelectedRows.Count -eq 0 -or
             $script:Grid.SelectedRows[0] -ne $rowToSelect)) {
            $script:Grid.ClearSelection()
            $rowToSelect.Selected = $true
        }
        $script:ConfigLabel.Text = "Private config: $Config"
        $activeChecks = $script:BackgroundHealthChecks.Count
        $reconciliationActive = $null -ne $script:BackgroundReconciliation
        $script:StatusLabel.Text = if ($reconciliationActive) {
            'Automatic reconciliation running'
        }
        elseif ($activeChecks -gt 0) {
            "$activeChecks background check(s) running"
        } else {
            "Ready - $($script:Grid.Rows.Count) target(s)"
        }
        Update-ActionState
    }
    catch {
        Add-Log "REFRESH ERROR: $($_.Exception.Message)"
        $script:StatusLabel.Text = 'Configuration error'
    }
}

function Invoke-HealthCheck {
    if (Test-ManualHealthChecksRunning) {
        Stop-ManualHealthChecks
        return
    }

    Add-Log '> parallel background health check'
    try {
        $managerConfig = Read-UiConfig
        $targets = @($managerConfig.targets | ForEach-Object {
            Resolve-UiTarget $managerConfig $_
        })
        if ($targets.Count -eq 0) {
            Add-Log 'No Linux targets to check.'
            $script:StatusLabel.Text = 'No targets to check'
            return
        }

        $started = 0
        foreach ($target in $targets) {
            $generation = Reset-TargetHealth ([string]$target.name)
            try {
                Start-BackgroundTargetHealthCheck `
                    -Name ([string]$target.name) `
                    -Generation $generation `
                    -ExpectedEnabled ([bool]$target.enabled) `
                    -Reason 'manual'
                $started++
            }
            catch {
                $script:HealthCache[[string]$target.name] = [pscustomobject]@{
                    Name = [string]$target.name
                    Enabled = [bool]$target.enabled
                    SSH = 'FAIL'
                    Proxy = if ([bool]$target.enabled) { 'FAIL' } else { 'UNKNOWN' }
                }
                Add-Log "HEALTH CHECK START ERROR for $($target.name): $($_.Exception.Message)"
            }
        }
        Refresh-TargetGrid
        Update-HealthCheckActionState
        if ($started -gt 0) {
            $script:StatusLabel.Text = "Health check running in parallel for $started target(s)"
        }
    }
    catch {
        $message = $_.Exception.Message
        Add-Log "HEALTH CHECK ERROR: $message"
        [System.Windows.Forms.MessageBox]::Show(
            $message,
            'Health check failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}
