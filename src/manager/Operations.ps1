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

function Enable-TargetAccess {
    param(
        [string]$ConfigPath,
        [string]$TargetName
    )

    $managerConfig = Read-ManagerConfig -Path $ConfigPath
    $rawTarget = Get-ConfigTarget $managerConfig $TargetName
    $target = Resolve-ConfiguredTarget $managerConfig $rawTarget
    $wasEnabled = $target.enabled
    Start-TunnelTask $managerConfig $target
    try {
        $target.enabled = $true
        Set-ConfigTarget $managerConfig $target
        Save-ManagerConfig $managerConfig $ConfigPath
    }
    catch {
        if (-not $wasEnabled) {
            Stop-TunnelTask $managerConfig $target -Disable
        }
        throw
    }
    Write-Host "Enabled and started $($target.name). End-to-end health verification is pending." -ForegroundColor Green
}

function Disable-TargetAccess {
    param(
        [string]$ConfigPath,
        [string]$TargetName
    )

    $managerConfig = Read-ManagerConfig -Path $ConfigPath
    $rawTarget = Get-ConfigTarget $managerConfig $TargetName
    $target = Resolve-ConfiguredTarget $managerConfig $rawTarget
    Stop-TunnelTask $managerConfig $target -Disable -AllowMissing
    $target.enabled = $false
    Set-ConfigTarget $managerConfig $target
    Save-ManagerConfig $managerConfig $ConfigPath
    Write-Host "Disabled $($target.name) locally. Remote proxy closure verification is pending." -ForegroundColor Green
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

function Remove-TargetRemoteArtifacts {
    param($Target)

    Assert-ClientTools
    $identity = Get-SshPublicKeyForCleanup $Target
    $encodedKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($identity))
    $encodedKeyLiteral = ConvertTo-ShellLiteral $encodedKey
    $remoteCommand = @'
set -eu
umask 077
if [ -x "$HOME/.config/clash-ssh-proxy/uninstall-linux.sh" ]; then
    "$HOME/.config/clash-ssh-proxy/uninstall-linux.sh" --purge
fi
authorized_keys="$HOME/.ssh/authorized_keys"
if [ -L "$authorized_keys" ]; then
    echo "Refusing to edit a symbolic-link authorized_keys file" >&2
    exit 1
fi
if [ -e "$authorized_keys" ] && [ ! -f "$authorized_keys" ]; then
    echo "authorized_keys is not a regular file" >&2
    exit 1
fi
if [ -f "$authorized_keys" ]; then
    key="$(printf %s __ENCODED_KEY__ | base64 -d)"
    key_type="$(printf '%s\n' "$key" | awk '{print $1}')"
    key_data="$(printf '%s\n' "$key" | awk '{print $2}')"
    temporary="$(mktemp "$authorized_keys.clash-ssh-proxy.XXXXXX")"
    trap 'rm -f -- "$temporary"' EXIT
    awk -v key_type="$key_type" -v key_data="$key_data" '
        {
            for (i = 1; i < NF; i++) {
                if ($i == key_type && $(i + 1) == key_data) next
            }
            print
        }
    ' "$authorized_keys" > "$temporary"
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$authorized_keys"
    trap - EXIT
fi
echo "Removed clash-ssh-proxy remote integration and SSH public key"
'@.Replace('__ENCODED_KEY__', $encodedKeyLiteral)
    Invoke-RemoteCommand $Target $remoteCommand 'Remove Linux integration and SSH public key'
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

function Wait-LocalProxyForReconciliation {
    param(
        $ManagerConfig,
        [ValidateRange(1, 120)]
        [int]$AttemptLimit = 15,
        [ValidateRange(0, 10000)]
        [int]$DelayMilliseconds = 2000,
        [ValidateRange(50, 5000)]
        [int]$ConnectTimeoutMilliseconds = 100
    )

    for ($attempt = 1; $attempt -le $AttemptLimit; $attempt++) {
        if (Test-LocalTcpPort `
            ([string]$ManagerConfig.proxy.localHost) `
            ([int]$ManagerConfig.proxy.localPort) `
            $ConnectTimeoutMilliseconds) {
            return $true
        }
        if ($attempt -lt $AttemptLimit -and $DelayMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }

    return $false
}

function Invoke-EnabledTargetReconciliation {
    param(
        [string]$ConfigPath,
        [ValidateRange(1, 120)]
        [int]$AttemptLimit = 15,
        [ValidateRange(0, 10000)]
        [int]$DelayMilliseconds = 2000,
        [ValidateRange(50, 5000)]
        [int]$ConnectTimeoutMilliseconds = 100
    )

    $initialConfig = Read-ManagerConfig -Path $ConfigPath
    $targetNames = @($initialConfig.targets | ForEach-Object {
        Resolve-ConfiguredTarget $initialConfig $_
    } | Where-Object { [bool]$_.enabled } | ForEach-Object { [string]$_.name })

    if ($targetNames.Count -eq 0) {
        Write-Host 'No enabled targets need reconciliation.'
        return
    }

    if (-not (Wait-LocalProxyForReconciliation `
        $initialConfig $AttemptLimit $DelayMilliseconds $ConnectTimeoutMilliseconds)) {
        throw "Local proxy did not become ready after $AttemptLimit checks"
    }

    foreach ($targetName in $targetNames) {
        $targetLock = Enter-ConfigMutationLock -Path $ConfigPath
        try {
            $currentConfig = Read-ManagerConfig -Path $ConfigPath
            $rawTarget = Get-ConfigTarget $currentConfig $targetName -AllowMissing
            if ($null -eq $rawTarget) {
                Write-Host "Skipped $targetName because it was removed while reconciliation was waiting."
                continue
            }

            $target = Resolve-ConfiguredTarget $currentConfig $rawTarget
            if (-not [bool]$target.enabled) {
                Write-Host "Skipped $targetName because it is no longer enabled."
                continue
            }

            try {
                $task = Get-RegisteredTaskFast $target.taskName
                $taskState = Get-RegisteredTaskStateFast $task
                switch ($taskState) {
                    { $_ -in @('Running', 'Queued') } {
                        Write-Host "$targetName is already $($taskState.ToLowerInvariant())."
                    }
                    'Missing' {
                        Write-Warning "Scheduled task '$($target.taskName)' is missing. Use update to recreate it."
                    }
                    { $_ -in @('Ready', 'Disabled') } {
                        [void](Start-TunnelTask $currentConfig $target)
                        Write-Host "Recovered $targetName from task state $taskState."
                    }
                    default {
                        Write-Warning "Scheduled task '$($target.taskName)' has unsupported state '$taskState'."
                    }
                }
            }
            catch {
                Write-Warning "Unable to reconcile ${targetName}: $($_.Exception.Message)"
            }
        }
        finally {
            Exit-ConfigMutationLock $targetLock
        }
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
            Id = $target.id
           Name = $target.name
           Destination = Get-SshDestination $target
           Task = $target.taskName
           TaskState = $taskState
           Enabled = [bool]$target.enabled
           SSH = if ($sshOk) { 'OK' } else { 'FAIL' }
           Proxy = $proxyStatus
           RemotePort = $target.remoteProxyPort
            IdentityManaged = [bool]$target.identityManaged
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
  .\proxy-manager.ps1 adopt         -Name NAME -RemoteHost HOST -RemoteUser USER -TaskName TASK [options]
  .\proxy-manager.ps1 bootstrap-key -Name NAME -RemoteHost HOST -RemoteUser USER [options]
  .\proxy-manager.ps1 status        [-Name NAME]
  .\proxy-manager.ps1 reconcile
  .\proxy-manager.ps1 enable        -Name NAME
  .\proxy-manager.ps1 disable       -Name NAME
  .\proxy-manager.ps1 update        -Name NAME [options]
  .\proxy-manager.ps1 update-all
  .\proxy-manager.ps1 remove        -Name NAME [-DeleteIdentityFile]
  .\proxy-manager.ps1 validate-config [-Config PATH]

Configuration defaults to:
  %LOCALAPPDATA%\ClashSshProxy\config.json

Important:
  * New targets receive a stable ID and a dedicated Ed25519 identity under
    %LOCALAPPDATA%\ClashSshProxy\keys. Pass the same -TargetId to a manual
    prepare-ssh/bootstrap-key/add sequence when the target is not saved yet.
  * prepare-ssh creates a local Ed25519 identity when missing and silently checks key login.
  * enable starts and marks a target enabled after local startup checks.
  * reconcile waits briefly for Clash, then sequentially restarts stopped enabled targets.
  * status performs end-to-end SSH and proxy verification, optionally for one target.
  * disable stops and marks the target locally; status verifies remote closure separately.
  * remove clears the Windows task, Linux integration, and matching authorized_keys entry.
    -DeleteIdentityFile additionally removes the manager-generated private key and .pub file.
    External identity files are never deleted by the manager.
  * Commands that modify scheduled tasks must run in elevated PowerShell.
  * Passwords are never accepted as parameters or stored.
  * The Linux reverse endpoint is always bound to 127.0.0.1.
  * Run bootstrap-key interactively once if key authentication is not ready.
'@ | Write-Host
}
