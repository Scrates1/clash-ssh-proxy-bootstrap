[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)]
    [ValidateSet('add', 'adopt', 'prepare-ssh', 'bootstrap-key', 'status', 'enable', 'disable', 'update', 'update-all', 'install-all', 'remove', 'validate-config', 'help')]
    [string]$Command = 'help',

    [string]$Name,
    [string]$RemoteHost,
    [string]$RemoteUser,
    [int]$SshPort,
    [string]$IdentityFile,
    [string]$LocalProxyHost,
    [int]$LocalProxyPort,
    [int]$RemoteProxyPort,
    [string]$TaskName,
    [string[]]$NoProxyExtra,
    [string]$Config,
    [switch]$Json,
    [switch]$SkipRemoteUninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CliParameters = $PSBoundParameters
$script:RepositoryRoot = $PSScriptRoot
$script:Utf8Encoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $script:Utf8Encoding
try {
    [Console]::InputEncoding = $script:Utf8Encoding
} catch {}
try {
    [Console]::OutputEncoding = $script:Utf8Encoding
} catch {}
$script:TaskSchedulerService = $null
$script:TaskSchedulerRoot = $null

$commonPath = Join-Path $script:RepositoryRoot 'src/Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "Shared module was not found: $commonPath"
}
. $commonPath

$script:ManagerModuleRoot = Join-Path $script:RepositoryRoot 'src/manager'
foreach ($moduleName in @(
    'Config.ps1', 'Transport.ps1', 'SshBootstrap.ps1', 'TunnelProcess.ps1',
    'Tunnel.ps1', 'Remote.ps1', 'Operations.ps1'
)) {
    $modulePath = Join-Path $script:ManagerModuleRoot $moduleName
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Manager module was not found: $modulePath"
    }
    . $modulePath
}

if ($env:OS -ne 'Windows_NT' -and $Command -notin @('validate-config', 'help')) {
    throw 'proxy-manager.ps1 must run on Windows'
}

$configMutationLock = $null
try {
    if ($Command -in @(
        'add', 'adopt', 'prepare-ssh', 'bootstrap-key', 'enable', 'disable',
        'update', 'update-all', 'install-all', 'remove'
    )) {
        $configMutationLock = Enter-ConfigMutationLock -Path $Config
    }

switch ($Command) {
    'help' {
        Show-Help
    }

    'validate-config' {
        $managerConfig = Read-ManagerConfig -Path $Config
        Test-ManagerConfig $managerConfig
        Write-Host "Configuration is valid: $Config"
    }

    'prepare-ssh' {
        $managerConfig = Read-ManagerConfig -Path $Config -AllowMissing
        Update-GlobalProxyFromCli $managerConfig
        $existing = if (-not [string]::IsNullOrWhiteSpace($Name)) { Get-ConfigTarget $managerConfig $Name -AllowMissing } else { $null }
        $target = New-TargetFromCli $managerConfig $existing
        $readiness = Get-SshReadiness $target
        if ($Json) {
            ConvertTo-Json -InputObject $readiness -Compress
        }
        elseif ($readiness.Ready) {
            Write-Host "SSH public key authentication is ready for $($target.name)." -ForegroundColor Green
        }
        else {
            Write-Host "SSH interaction is required once for $($target.name). Run bootstrap-key." -ForegroundColor Yellow
        }
    }

    'bootstrap-key' {
        $managerConfig = Read-ManagerConfig -Path $Config -AllowMissing
        Update-GlobalProxyFromCli $managerConfig
        $existing = if (-not [string]::IsNullOrWhiteSpace($Name)) { Get-ConfigTarget $managerConfig $Name -AllowMissing } else { $null }
        $target = New-TargetFromCli $managerConfig $existing
        Install-PublicKey $target
    }

    'add' {
        $managerConfig = Read-ManagerConfig -Path $Config -AllowMissing
        Assert-GlobalProxyOverrideSafe $managerConfig 0 'add'
        Update-GlobalProxyFromCli $managerConfig
        if ($null -ne (Get-ConfigTarget $managerConfig $Name -AllowMissing)) {
            throw "Target '$Name' already exists. Use update instead."
        }
        $target = New-TargetFromCli $managerConfig $null
        $installCompleted = $false
        try {
            Install-Target $managerConfig $target $null $null
            $installCompleted = $true
            Set-ConfigTarget $managerConfig $target
            Save-ManagerConfig $managerConfig $Config
        }
        catch {
            if ($installCompleted) {
                Undo-CompletedTargetInstall `
                    $managerConfig $target $null `
                    -RemoveRemoteInstallation
            }
            throw
        }
        Write-Host "Added $($target.name). Configuration saved to $Config" -ForegroundColor Green
    }

    'adopt' {
        $managerConfig = Read-ManagerConfig -Path $Config -AllowMissing
        Assert-GlobalProxyOverrideSafe $managerConfig 0 'adopt'
        Update-GlobalProxyFromCli $managerConfig
        if ($null -ne (Get-ConfigTarget $managerConfig $Name -AllowMissing)) {
            throw "Target '$Name' is already managed"
        }
        $target = New-TargetFromCli $managerConfig $null
        Assert-ClientTools
        Assert-IdentityFile $target
        $task = Get-ScheduledTask -TaskName $target.taskName -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            throw "Scheduled task '$($target.taskName)' does not exist"
        }
        if (-not (Test-TunnelTaskOwnedByTarget $task $target)) {
            throw "Scheduled task '$($target.taskName)' is not recognized as a clash-ssh-proxy-bootstrap task"
        }
        $target.enabled = $task.State -ne 'Disabled'
        if (-not (Test-RemoteConnection $target)) {
            throw "SSH verification failed for $(Get-SshDestination $target)"
        }
        if ($target.enabled -and -not (Test-RemoteProxy $target)) {
            throw "Remote proxy verification failed for $($target.name)"
        }
        Set-ConfigTarget $managerConfig $target
        Save-ManagerConfig $managerConfig $Config
        Write-Host "Adopted $($target.name). Configuration saved to $Config" -ForegroundColor Green
    }

    'status' {
        $managerConfig = Read-ManagerConfig -Path $Config -AllowMissing
        Show-Status $managerConfig -TargetName $Name -AsJson:$Json
    }

    'enable' {
        $managerConfig = Read-ManagerConfig -Path $Config
        $rawTarget = Get-ConfigTarget $managerConfig $Name
        $target = Resolve-ConfiguredTarget $managerConfig $rawTarget
        $wasEnabled = $target.enabled
        Start-TunnelTask $managerConfig $target
        try {
            $target.enabled = $true
            Set-ConfigTarget $managerConfig $target
            Save-ManagerConfig $managerConfig $Config
        }
        catch {
            if (-not $wasEnabled) {
                Stop-TunnelTask $managerConfig $target -Disable
            }
            throw
        }
        Write-Host "Enabled and started $($target.name). End-to-end health verification is pending." -ForegroundColor Green
    }

    'disable' {
        $managerConfig = Read-ManagerConfig -Path $Config
        $rawTarget = Get-ConfigTarget $managerConfig $Name
        $target = Resolve-ConfiguredTarget $managerConfig $rawTarget
        Stop-TunnelTask $managerConfig $target -Disable -AllowMissing
        $target.enabled = $false
        Set-ConfigTarget $managerConfig $target
        Save-ManagerConfig $managerConfig $Config
        Write-Host "Disabled $($target.name) locally. Remote proxy closure verification is pending." -ForegroundColor Green
    }

    'update' {
        $managerConfig = Read-ManagerConfig -Path $Config
        $previousManagerConfig = Copy-ManagerConfig $managerConfig
        Assert-GlobalProxyOverrideSafe $managerConfig 1 'update'
        Update-GlobalProxyFromCli $managerConfig
        $existing = Get-ConfigTarget $managerConfig $Name
        $previousTarget = Resolve-ConfiguredTarget `
            $previousManagerConfig `
            (Get-ConfigTarget $previousManagerConfig $Name)
        $target = New-TargetFromCli $managerConfig $existing
        $installCompleted = $false
        try {
            Install-Target $managerConfig $target $previousManagerConfig $previousTarget
            $installCompleted = $true
            Set-ConfigTarget $managerConfig $target
            Save-ManagerConfig $managerConfig $Config
        }
        catch {
            if ($installCompleted) {
                Undo-CompletedTargetInstall $managerConfig $target $previousTarget
            }
            throw
        }
        Write-Host "Updated $($target.name)." -ForegroundColor Green
    }

    { $_ -in @('update-all', 'install-all') } {
        $managerConfig = Read-ManagerConfig -Path $Config
        $previousManagerConfig = Copy-ManagerConfig $managerConfig
        Update-GlobalProxyFromCli $managerConfig
        $completedInstalls = New-Object 'System.Collections.Generic.List[object]'
        try {
            foreach ($rawTarget in @($managerConfig.targets)) {
                $target = Resolve-ConfiguredTarget $managerConfig $rawTarget
                $previousTarget = Resolve-ConfiguredTarget `
                    $previousManagerConfig `
                    (Get-ConfigTarget $previousManagerConfig $target.name)
                Install-Target $managerConfig $target $previousManagerConfig $previousTarget
                [void]$completedInstalls.Add([pscustomobject]@{
                    Target = $target
                    PreviousTarget = $previousTarget
                })
            }
            Save-ManagerConfig $managerConfig $Config
        }
        catch {
            foreach ($completedInstall in $completedInstalls) {
                Undo-CompletedTargetInstall `
                    $managerConfig `
                    $completedInstall.Target `
                    $completedInstall.PreviousTarget
            }
            throw
        }
        Write-Host 'All targets were updated.' -ForegroundColor Green
    }

    'remove' {
        $managerConfig = Read-ManagerConfig -Path $Config
        $rawTarget = Get-ConfigTarget $managerConfig $Name
        $target = Resolve-ConfiguredTarget $managerConfig $rawTarget
        if ($PSCmdlet.ShouldProcess($target.name, 'Remove the Windows task and Linux shell integration')) {
            Assert-Administrator
            Assert-TunnelTaskTransitionAvailable $target $target
            Stop-TunnelTask $managerConfig $target -Disable -AllowMissing
            if (-not $SkipRemoteUninstall) {
                $remoteCommand = 'set -eu; if [ -x "$HOME/.config/clash-ssh-proxy/uninstall-linux.sh" ]; then "$HOME/.config/clash-ssh-proxy/uninstall-linux.sh" --purge; else echo "Remote uninstaller not found" >&2; exit 1; fi'
                Invoke-RemoteCommand $target $remoteCommand 'Remove Linux account proxy'
            }
            $task = Get-ScheduledTask -TaskName $target.taskName -ErrorAction SilentlyContinue
            if ($null -ne $task) {
                Unregister-ScheduledTask -TaskName $target.taskName -Confirm:$false
            }
            Remove-TunnelLauncher $target
            $managerConfig.targets = @($managerConfig.targets | Where-Object { $_.name -ne $target.name })
            Save-ManagerConfig $managerConfig $Config
            Write-Host "Removed $($target.name)." -ForegroundColor Green
        }
    }
}
}
finally {
    if ($null -ne $configMutationLock) {
        Exit-ConfigMutationLock $configMutationLock
    }
}
