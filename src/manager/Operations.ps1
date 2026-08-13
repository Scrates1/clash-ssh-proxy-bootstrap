# Cross-platform manager operations and status presentation.

function Install-Target {
    param(
        $ManagerConfig,
        $Target,
        [AllowNull()]$PreviousManagerConfig,
        [AllowNull()]$PreviousTarget
    )

    Assert-Administrator
    Assert-TunnelTaskTransitionAvailable $Target $PreviousTarget
    Assert-ClientTools
    Assert-IdentityFile $Target
    if (-not (Test-LocalTcpPort $ManagerConfig.proxy.localHost ([int]$ManagerConfig.proxy.localPort))) {
        throw "Local Clash proxy is not listening on $($ManagerConfig.proxy.localHost):$($ManagerConfig.proxy.localPort)"
    }
    if (-not (Test-RemoteConnection $Target)) {
        throw "SSH key authentication failed for $(Get-SshDestination $Target). Run bootstrap-key first."
    }
    if ($null -eq $PreviousTarget -and (Test-RemoteManagedInstallation $Target)) {
        throw "Linux account $((Get-SshDestination $Target)) already has clash-ssh-proxy integration. Adopt the existing task or uninstall that integration before adding a new target."
    }

    $remoteInstallAttempted = $false
    $localRegistrationCompleted = $false
    try {
        Write-Step "Installing Linux files on $($Target.name)"
        $remoteInstallAttempted = $true
        Install-RemoteFiles $Target
        Write-Step "Registering scheduled task $($Target.taskName)"
        Register-TunnelTask $ManagerConfig $Target $PreviousManagerConfig $PreviousTarget
        $localRegistrationCompleted = $true
        if ($Target.enabled) {
            Write-Step "Verifying reverse tunnel for $($Target.name)"
            if (-not (Wait-RemoteProxy $Target)) {
                throw "Proxy verification failed for $($Target.name)"
            }
        }
        else {
            Write-Step "Skipping proxy verification because $($Target.name) is disabled"
        }
    }
    catch {
        if ($localRegistrationCompleted) {
            Disable-FailedTunnelInstall `
                $ManagerConfig $Target $PreviousTarget `
                -CurrentTaskRegistered -LauncherWritten
        }
        if ($null -eq $PreviousTarget -and $remoteInstallAttempted) {
            Remove-NewRemoteInstallationAfterFailure $Target
        }
        throw
    }
}

function Remove-NewRemoteInstallationAfterFailure {
    param($Target)

    try {
        $remoteCommand = 'set -eu; if [ -x "$HOME/.config/clash-ssh-proxy/uninstall-linux.sh" ]; then "$HOME/.config/clash-ssh-proxy/uninstall-linux.sh"; fi'
        Invoke-RemoteCommand $Target $remoteCommand 'Roll back failed Linux installation' | Out-Null
    }
    catch {
        Write-Warning "Unable to roll back Linux files for '$($Target.name)': $($_.Exception.Message)"
    }
}

function Undo-CompletedTargetInstall {
    param(
        $ManagerConfig,
        $Target,
        [AllowNull()]$PreviousTarget,
        [switch]$RemoveRemoteInstallation
    )

    Disable-FailedTunnelInstall `
        $ManagerConfig $Target $PreviousTarget `
        -CurrentTaskRegistered -LauncherWritten
    if ($RemoveRemoteInstallation) {
        Remove-NewRemoteInstallationAfterFailure $Target
    }
}

function Get-TargetStatus {
    param(
        $ManagerConfig,
        [string]$TargetName
    )

    $rawTargets = @($ManagerConfig.targets)
    if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
        $rawTargets = @(Get-ConfigTarget $ManagerConfig $TargetName)
    }

    $results = foreach ($rawTarget in $rawTargets) {
        $statusTimer = [Diagnostics.Stopwatch]::StartNew()
        $target = Resolve-ConfiguredTarget $ManagerConfig $rawTarget
        $task = Get-RegisteredTaskFast $target.taskName
        $taskState = Get-RegisteredTaskStateFast $task
        $sshOk = $false
        $proxyOk = $false
        $proxyStatus = if ($target.enabled) { 'FAIL' } else { 'UNKNOWN' }
        try {
            Assert-IdentityFile $target
            if (-not $target.enabled) {
                $proxyStatus = Get-RemoteTunnelState $target
                $sshOk = $proxyStatus -ne 'UNKNOWN'
            }
            elseif ($taskState -eq 'Running') {
                $proxyExitCode = Invoke-RemoteProxyProbe $target
                $sshOk = $proxyExitCode -ne 255
                $proxyOk = $proxyExitCode -eq 0
                $proxyStatus = if ($proxyOk) { 'OK' } else { 'FAIL' }
            }
            else {
                $sshOk = Test-RemoteConnection $target
            }
        }
        catch {
            $sshOk = $false
            $proxyOk = $false
        }
        finally {
            $statusTimer.Stop()
        }

        [pscustomobject]@{
            Name = $target.name
            Destination = Get-SshDestination $target
            Task = $target.taskName
            TaskState = $taskState
            Enabled = [bool]$target.enabled
            SSH = if ($sshOk) { 'OK' } else { 'FAIL' }
            Proxy = $proxyStatus
            RemotePort = $target.remoteProxyPort
            DurationMs = [math]::Round($statusTimer.Elapsed.TotalMilliseconds)
            CheckedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
    }

    return @($results)
}

function Show-Status {
    param(
        $ManagerConfig,
        [string]$TargetName,
        [switch]$AsJson
    )

    $results = @(Get-TargetStatus $ManagerConfig -TargetName $TargetName)
    if ($AsJson) {
        ConvertTo-Json -InputObject @($results) -Depth 4 -Compress
        return
    }

    if (@($results).Count -eq 0) {
        Write-Host "No managed Linux targets in $Config"
        return
    }
    $results | Format-Table -AutoSize
}

function Show-Help {
    @'
Clash SSH proxy manager

Usage:
  .\proxy-manager.ps1 prepare-ssh  -Name NAME -RemoteHost HOST -RemoteUser USER [options]
  .\proxy-manager.ps1 add           -Name NAME -RemoteHost HOST -RemoteUser USER [options]
  .\proxy-manager.ps1 adopt         -Name NAME -RemoteHost HOST -RemoteUser USER -TaskName TASK
  .\proxy-manager.ps1 bootstrap-key -Name NAME -RemoteHost HOST -RemoteUser USER [options]
  .\proxy-manager.ps1 status        [-Name NAME]
  .\proxy-manager.ps1 enable        -Name NAME
  .\proxy-manager.ps1 disable       -Name NAME
  .\proxy-manager.ps1 update        -Name NAME [options]
  .\proxy-manager.ps1 update-all
  .\proxy-manager.ps1 remove        -Name NAME
  .\proxy-manager.ps1 validate-config [-Config PATH]

Configuration defaults to:
  %LOCALAPPDATA%\ClashSshProxy\config.json

Important:
  * prepare-ssh creates a local Ed25519 identity when missing and silently checks key login.
  * enable starts and marks a target enabled after local startup checks.
  * status performs end-to-end SSH and proxy verification, optionally for one target.
  * disable stops and marks the target locally; status verifies remote closure separately.
  * Commands that modify scheduled tasks must run in elevated PowerShell.
  * Passwords are never accepted as parameters or stored.
  * The Linux reverse endpoint is always bound to 127.0.0.1.
  * Run bootstrap-key interactively once if key authentication is not ready.
'@ | Write-Host
}
