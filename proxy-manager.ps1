[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)]
    [ValidateSet('add', 'adopt', 'bootstrap-key', 'status', 'enable', 'disable', 'start', 'stop', 'update', 'update-all', 'install-all', 'remove', 'validate-config', 'help')]
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

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-DefaultConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return Join-Path $env:LOCALAPPDATA 'ClashSshProxy\config.json'
    }
    return Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\ClashSshProxy\config.json'
}

if ([string]::IsNullOrWhiteSpace($Config)) {
    $Config = Get-DefaultConfigPath
}

function New-DefaultConfig {
    [pscustomobject]@{
        version = 1
        proxy = [pscustomobject]@{
            localHost = '127.0.0.1'
            localPort = 7897
        }
        defaults = [pscustomobject]@{
            sshPort = 22
            identityFile = '~/.ssh/id_ed25519'
            remoteProxyPort = 17897
            noProxyExtra = @()
        }
        targets = @()
    }
}

function Test-ObjectProperty {
    param(
        [AllowNull()]$Object,
        [string]$Name
    )
    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Get-ObjectProperty {
    param(
        [AllowNull()]$Object,
        [string]$Name,
        $DefaultValue
    )
    if (Test-ObjectProperty $Object $Name) {
        $value = $Object.$Name
        if ($null -ne $value) {
            return $value
        }
    }
    return $DefaultValue
}

function Read-ManagerConfig {
    param(
        [string]$Path,
        [switch]$AllowMissing
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($AllowMissing) {
            return New-DefaultConfig
        }
        throw "Configuration file not found: $Path"
    }

    try {
        $parsed = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON configuration '$Path': $($_.Exception.Message)"
    }

    Test-ManagerConfig -ManagerConfig $parsed
    return $parsed
}

function Test-Port {
    param(
        [int]$Port,
        [string]$Label
    )
    if ($Port -lt 1 -or $Port -gt 65535) {
        throw "$Label must be between 1 and 65535"
    }
}

function Resolve-ConfiguredTarget {
    param(
        $ManagerConfig,
        $Target
    )

    $defaults = $ManagerConfig.defaults
    [pscustomobject]@{
        name = [string]$Target.name
        host = [string]$Target.host
        user = [string]$Target.user
        taskName = [string]$Target.taskName
        enabled = [bool](Get-ObjectProperty $Target 'enabled' $true)
        sshPort = [int](Get-ObjectProperty $Target 'sshPort' $defaults.sshPort)
        identityFile = [string](Get-ObjectProperty $Target 'identityFile' $defaults.identityFile)
        remoteProxyPort = [int](Get-ObjectProperty $Target 'remoteProxyPort' $defaults.remoteProxyPort)
        noProxyExtra = @((Get-ObjectProperty $Target 'noProxyExtra' $defaults.noProxyExtra))
    }
}

function Test-ManagerConfig {
    param($ManagerConfig)

    if ($null -eq $ManagerConfig) {
        throw 'Configuration is empty'
    }
    if ([int](Get-ObjectProperty $ManagerConfig 'version' 0) -ne 1) {
        throw 'Only configuration version 1 is supported'
    }
    if (-not (Test-ObjectProperty $ManagerConfig 'proxy')) {
        throw 'Configuration is missing proxy'
    }
    if (-not (Test-ObjectProperty $ManagerConfig 'defaults')) {
        throw 'Configuration is missing defaults'
    }
    if (-not (Test-ObjectProperty $ManagerConfig 'targets')) {
        throw 'Configuration is missing targets'
    }

    $localHostValue = [string](Get-ObjectProperty $ManagerConfig.proxy 'localHost' '')
    if ([string]::IsNullOrWhiteSpace($localHostValue)) {
        throw 'proxy.localHost is required'
    }
    Test-Port ([int](Get-ObjectProperty $ManagerConfig.proxy 'localPort' 0)) 'proxy.localPort'
    Test-Port ([int](Get-ObjectProperty $ManagerConfig.defaults 'sshPort' 0)) 'defaults.sshPort'
    Test-Port ([int](Get-ObjectProperty $ManagerConfig.defaults 'remoteProxyPort' 0)) 'defaults.remoteProxyPort'

    $names = @{}
    $taskNames = @{}
    foreach ($rawTarget in @($ManagerConfig.targets)) {
        if ((Test-ObjectProperty $rawTarget 'enabled') -and $rawTarget.enabled -isnot [bool]) {
            throw "enabled must be true or false for target $($rawTarget.name)"
        }
        $target = Resolve-ConfiguredTarget $ManagerConfig $rawTarget
        if ($target.name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw "Invalid target name: $($target.name)"
        }
        if ([string]::IsNullOrWhiteSpace($target.host) -or $target.host -match '\s') {
            throw "Invalid host for target $($target.name)"
        }
        if ([string]::IsNullOrWhiteSpace($target.user) -or $target.user -match '\s') {
            throw "Invalid user for target $($target.name)"
        }
        if ([string]::IsNullOrWhiteSpace($target.taskName) -or $target.taskName -match '[\\/:*?"<>|]') {
            throw "Invalid scheduled task name for target $($target.name)"
        }
        Test-Port $target.sshPort "sshPort for $($target.name)"
        Test-Port $target.remoteProxyPort "remoteProxyPort for $($target.name)"
        if ([string]::IsNullOrWhiteSpace($target.identityFile)) {
            throw "identityFile is required for target $($target.name)"
        }
        foreach ($entry in @($target.noProxyExtra)) {
            if ([string]$entry -notmatch '^[A-Za-z0-9._:/-]+$') {
                throw "Invalid NO_PROXY entry '$entry' for target $($target.name)"
            }
        }
        if ($names.ContainsKey($target.name)) {
            throw "Duplicate target name: $($target.name)"
        }
        if ($taskNames.ContainsKey($target.taskName)) {
            throw "Duplicate task name: $($target.taskName)"
        }
        $names[$target.name] = $true
        $taskNames[$target.taskName] = $true
    }
}

function Save-ManagerConfig {
    param(
        $ManagerConfig,
        [string]$Path
    )

    Test-ManagerConfig -ManagerConfig $ManagerConfig
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $temporaryPath = "$Path.tmp.$PID"
    $json = $ManagerConfig | ConvertTo-Json -Depth 8
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temporaryPath, "$json`r`n", $encoding)
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-ConfigTarget {
    param(
        $ManagerConfig,
        [string]$TargetName,
        [switch]$AllowMissing
    )

    $matches = @($ManagerConfig.targets | Where-Object { $_.name -eq $TargetName })
    if ($matches.Count -gt 1) {
        throw "Configuration contains duplicate target '$TargetName'"
    }
    if ($matches.Count -eq 0) {
        if ($AllowMissing) {
            return $null
        }
        throw "Target '$TargetName' was not found in $Config"
    }
    return $matches[0]
}

function Get-SafeTaskName {
    param([string]$TargetName)
    $safe = [regex]::Replace($TargetName, '[^A-Za-z0-9._-]', '-')
    return "ClashProxyTo-$safe"
}

function New-TargetFromCli {
    param(
        $ManagerConfig,
        [AllowNull()]$ExistingTarget
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw '-Name is required'
    }

    $existingResolved = $null
    if ($null -ne $ExistingTarget) {
        $existingResolved = Resolve-ConfiguredTarget $ManagerConfig $ExistingTarget
    }

    $hostValue = if ($script:CliParameters.ContainsKey('RemoteHost')) { $RemoteHost } elseif ($null -ne $existingResolved) { $existingResolved.host } else { '' }
    $userValue = if ($script:CliParameters.ContainsKey('RemoteUser')) { $RemoteUser } elseif ($null -ne $existingResolved) { $existingResolved.user } else { '' }
    $sshPortValue = if ($script:CliParameters.ContainsKey('SshPort')) { $SshPort } elseif ($null -ne $existingResolved) { $existingResolved.sshPort } else { [int]$ManagerConfig.defaults.sshPort }
    $identityValue = if ($script:CliParameters.ContainsKey('IdentityFile')) { $IdentityFile } elseif ($null -ne $existingResolved) { $existingResolved.identityFile } else { [string]$ManagerConfig.defaults.identityFile }
    $remotePortValue = if ($script:CliParameters.ContainsKey('RemoteProxyPort')) { $RemoteProxyPort } elseif ($null -ne $existingResolved) { $existingResolved.remoteProxyPort } else { [int]$ManagerConfig.defaults.remoteProxyPort }
    $taskValue = if ($script:CliParameters.ContainsKey('TaskName')) { $TaskName } elseif ($null -ne $existingResolved) { $existingResolved.taskName } else { Get-SafeTaskName $Name }
    $noProxyValue = if ($script:CliParameters.ContainsKey('NoProxyExtra')) { @($NoProxyExtra) } elseif ($null -ne $existingResolved) { @($existingResolved.noProxyExtra) } else { @($ManagerConfig.defaults.noProxyExtra) }
    $enabledValue = if ($null -ne $existingResolved) { [bool]$existingResolved.enabled } else { $true }

    $target = [pscustomobject]@{
        name = $Name
        host = $hostValue
        user = $userValue
        taskName = $taskValue
        enabled = $enabledValue
        sshPort = [int]$sshPortValue
        identityFile = $identityValue
        remoteProxyPort = [int]$remotePortValue
        noProxyExtra = @($noProxyValue)
    }

    $testConfig = New-DefaultConfig
    $testConfig.proxy = $ManagerConfig.proxy
    $testConfig.defaults = $ManagerConfig.defaults
    $testConfig.targets = @($target)
    Test-ManagerConfig $testConfig
    return $target
}

function Update-GlobalProxyFromCli {
    param($ManagerConfig)
    if ($script:CliParameters.ContainsKey('LocalProxyHost')) {
        if ([string]::IsNullOrWhiteSpace($LocalProxyHost)) {
            throw '-LocalProxyHost cannot be empty'
        }
        $ManagerConfig.proxy.localHost = $LocalProxyHost
    }
    if ($script:CliParameters.ContainsKey('LocalProxyPort')) {
        Test-Port $LocalProxyPort 'LocalProxyPort'
        $ManagerConfig.proxy.localPort = $LocalProxyPort
    }
}

function Set-ConfigTarget {
    param(
        $ManagerConfig,
        $Target
    )
    $remaining = @($ManagerConfig.targets | Where-Object { $_.name -ne $Target.name })
    $ManagerConfig.targets = @($remaining + $Target)
}

function Resolve-IdentityPath {
    param([string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -eq '~') {
        $expanded = [Environment]::GetFolderPath('UserProfile')
    }
    elseif ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        $expanded = Join-Path ([Environment]::GetFolderPath('UserProfile')) $expanded.Substring(2)
    }
    return [System.IO.Path]::GetFullPath($expanded)
}

function Get-SshDestination {
    param($Target)
    return "$($Target.user)@$($Target.host)"
}

function Get-SshArguments {
    param($Target)
    $identity = Resolve-IdentityPath $Target.identityFile
    return @(
        '-p', [string]$Target.sshPort,
        '-i', $identity,
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=yes',
        '-o', 'ConnectTimeout=8'
    )
}

function Get-ScpArguments {
    param($Target)
    $identity = Resolve-IdentityPath $Target.identityFile
    return @(
        '-P', [string]$Target.sshPort,
        '-i', $identity,
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=yes',
        '-o', 'ConnectTimeout=8'
    )
}

function Assert-ClientTools {
    foreach ($tool in @('ssh.exe', 'scp.exe')) {
        if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool was not found. Install the Windows OpenSSH Client feature."
        }
    }
}

function Assert-IdentityFile {
    param($Target)
    $identity = Resolve-IdentityPath $Target.identityFile
    if (-not (Test-Path -LiteralPath $identity -PathType Leaf)) {
        throw "SSH identity file not found: $identity"
    }
}

function Invoke-NativeChecked {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$Description
    )
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

function Invoke-RemoteCommand {
    param(
        $Target,
        [string]$RemoteCommand,
        [string]$Description = 'Remote command'
    )
    $arguments = @(Get-SshArguments $Target) + @((Get-SshDestination $Target), $RemoteCommand)
    Invoke-NativeChecked -FilePath 'ssh.exe' -ArgumentList $arguments -Description $Description
}

function Test-RemoteCommand {
    param(
        $Target,
        [string]$RemoteCommand
    )
    $arguments = @(Get-SshArguments $Target) + @((Get-SshDestination $Target), $RemoteCommand)
    & ssh.exe @arguments *> $null
    return $LASTEXITCODE -eq 0
}

function Test-RemoteConnection {
    param($Target)
    return Test-RemoteCommand $Target 'printf REMOTE_OK'
}

function Test-LocalTcpPort {
    param(
        [string]$HostName,
        [int]$Port
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connectTask = $client.ConnectAsync($HostName, $Port)
        if (-not $connectTask.Wait(3000)) {
            return $false
        }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function ConvertTo-ShellLiteral {
    param([string]$Value)
    $singleQuote = [char]39
    $doubleQuote = [char]34
    $escapedSingleQuote = [string]$singleQuote + $doubleQuote + $singleQuote + $doubleQuote + $singleQuote
    return [string]$singleQuote + $Value.Replace([string]$singleQuote, $escapedSingleQuote) + $singleQuote
}

function ConvertTo-WindowsArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function ConvertTo-PowerShellLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this command from an elevated PowerShell window because scheduled tasks are modified.'
    }
}

function Install-RemoteFiles {
    param($Target)

    $linuxSource = Join-Path $script:RepositoryRoot 'linux'
    if (-not (Test-Path -LiteralPath (Join-Path $linuxSource 'install-linux.sh') -PathType Leaf)) {
        throw "Linux installer files were not found under $linuxSource"
    }

    $safeName = [regex]::Replace($Target.name, '[^A-Za-z0-9._-]', '-')
    $remoteStage = "/tmp/clash-ssh-proxy-$safeName-$PID"
    $quotedStage = ConvertTo-ShellLiteral $remoteStage
    Invoke-RemoteCommand $Target "set -eu; test ! -e $quotedStage; mkdir -m 700 $quotedStage" 'Create remote staging directory'

    try {
        $scpArguments = @(Get-ScpArguments $Target) + @(
            '-r',
            $linuxSource,
            "$(Get-SshDestination $Target):$remoteStage/"
        )
        Invoke-NativeChecked -FilePath 'scp.exe' -ArgumentList $scpArguments -Description 'Upload Linux installer'

        $extra = (@($Target.noProxyExtra) -join ',')
        $installer = "$remoteStage/linux/install-linux.sh"
        $remoteCommand = "bash $(ConvertTo-ShellLiteral $installer) --remote-proxy-port $($Target.remoteProxyPort) --no-proxy-extra $(ConvertTo-ShellLiteral $extra)"
        Invoke-RemoteCommand $Target $remoteCommand 'Install Linux account proxy'
    }
    finally {
        $cleanupArguments = @(Get-SshArguments $Target) + @(
            (Get-SshDestination $Target),
            "test ! -d $quotedStage || rm -r -- $quotedStage"
        )
        & ssh.exe @cleanupArguments *> $null
    }
}

function Test-RemoteProxy {
    param($Target)
    $command = 'set -eu; if [ -x "$HOME/.config/clash-ssh-proxy/check-linux.sh" ]; then "$HOME/.config/clash-ssh-proxy/check-linux.sh" --quiet; else . "$HOME/.config/clash-ssh-proxy/proxy-on.sh"; curl -fsS -o /dev/null --connect-timeout 3 --max-time 12 -x "$CLASH_SSH_PROXY" https://www.google.com/generate_204; fi'
    return Test-RemoteCommand $Target $command
}

function Wait-RemoteProxy {
    param(
        $Target,
        [int]$TimeoutSeconds = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-RemoteProxy $Target) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Test-RemoteTunnelClosed {
    param($Target)
    $probe = "</dev/tcp/127.0.0.1/$($Target.remoteProxyPort)"
    $command = "command -v timeout >/dev/null 2>&1 && ! timeout 2 bash -c $(ConvertTo-ShellLiteral $probe)"
    return Test-RemoteCommand $Target $command
}

function Wait-RemoteTunnelClosed {
    param(
        $Target,
        [int]$TimeoutSeconds = 10
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-RemoteTunnelClosed $Target) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-ManagedTunnelProcesses {
    param(
        $ManagerConfig,
        $Target
    )

    $forward = "127.0.0.1:$($Target.remoteProxyPort):$($ManagerConfig.proxy.localHost):$($ManagerConfig.proxy.localPort)"
    $destination = Get-SshDestination $Target
    return @(Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction Stop | Where-Object {
        $line = [string]$_.CommandLine
        -not [string]::IsNullOrWhiteSpace($line) -and
        $line.Contains($forward) -and
        $line.Contains($destination) -and
        $line.Contains('ExitOnForwardFailure=yes')
    })
}

function Stop-ManagedTunnelProcesses {
    param(
        $ManagerConfig,
        $Target
    )

    foreach ($process in @(Get-ManagedTunnelProcesses $ManagerConfig $Target)) {
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds(10)
    while (@(Get-ManagedTunnelProcesses $ManagerConfig $Target).Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
    }
    $remaining = @(Get-ManagedTunnelProcesses $ManagerConfig $Target)
    if ($remaining.Count -gt 0) {
        throw "Unable to stop $($remaining.Count) managed SSH tunnel process(es) for $($Target.name)"
    }
}

function Register-TunnelTask {
    param(
        $ManagerConfig,
        $Target
    )

    Assert-Administrator
    $sshCommand = Get-Command ssh.exe -ErrorAction Stop
    $powerShellCommand = Get-Command powershell.exe -ErrorAction Stop
    $identityPath = Resolve-IdentityPath $Target.identityFile
    $destination = Get-SshDestination $Target
    $argumentValues = @(
        '-N', '-T',
        '-i', $identityPath,
        '-p', [string]$Target.sshPort,
        '-R', "127.0.0.1:$($Target.remoteProxyPort):$($ManagerConfig.proxy.localHost):$($ManagerConfig.proxy.localPort)",
        '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ServerAliveInterval=30',
        '-o', 'ServerAliveCountMax=3',
        '-o', 'TCPKeepAlive=yes',
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=yes',
        $destination
    )
    $sshInvocation = '& ' + (ConvertTo-PowerShellLiteral $sshCommand.Source) + ' ' + (($argumentValues | ForEach-Object {
        ConvertTo-PowerShellLiteral ([string]$_)
    }) -join ' ') + '; exit $LASTEXITCODE'
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($sshInvocation))
    $taskArgumentValues = @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-WindowStyle', 'Hidden',
        '-EncodedCommand', $encodedCommand
    )
    $taskArgumentLine = ($taskArgumentValues | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' '
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    $action = New-ScheduledTaskAction -Execute $powerShellCommand.Source -Argument $taskArgumentLine
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable

    $definition = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Clash SSH reverse proxy for $($Target.name) ($destination)"

    $existing = Get-ScheduledTask -TaskName $Target.taskName -ErrorAction SilentlyContinue
    if ($null -ne $existing -and $existing.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $Target.taskName
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-ScheduledTask -TaskName $Target.taskName).State -eq 'Running' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
    }
    Stop-ManagedTunnelProcesses $ManagerConfig $Target

    Register-ScheduledTask -TaskName $Target.taskName -InputObject $definition -Force | Out-Null
    if (-not $Target.enabled) {
        Disable-ScheduledTask -TaskName $Target.taskName | Out-Null
        $state = (Get-ScheduledTask -TaskName $Target.taskName).State
        if ($state -ne 'Disabled') {
            throw "Scheduled task '$($Target.taskName)' was not disabled; current state: $state"
        }
        Write-Step "Target $($Target.name) remains denied; its scheduled task is disabled"
        return
    }

    Start-ScheduledTask -TaskName $Target.taskName

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-ScheduledTask -TaskName $Target.taskName).State -ne 'Running' -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
    }
    $state = (Get-ScheduledTask -TaskName $Target.taskName).State
    if ($state -ne 'Running') {
        throw "Scheduled task '$($Target.taskName)' did not enter Running state; current state: $state"
    }
}

function Stop-TunnelTask {
    param(
        $ManagerConfig,
        $Target,
        [switch]$Disable,
        [switch]$AllowMissing
    )

    Assert-Administrator
    $task = Get-ScheduledTask -TaskName $Target.taskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        if (-not $AllowMissing) {
            throw "Scheduled task '$($Target.taskName)' does not exist. Run update to recreate it."
        }
    }
    elseif ($task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $Target.taskName
        $deadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 250
            $task = Get-ScheduledTask -TaskName $Target.taskName
        } while ($task.State -eq 'Running' -and (Get-Date) -lt $deadline)
        if ($task.State -eq 'Running') {
            throw "Scheduled task '$($Target.taskName)' did not stop"
        }
    }
    Stop-ManagedTunnelProcesses $ManagerConfig $Target

    if ($Disable -and $null -ne $task) {
        Disable-ScheduledTask -TaskName $Target.taskName | Out-Null
        $state = (Get-ScheduledTask -TaskName $Target.taskName).State
        if ($state -ne 'Disabled') {
            throw "Scheduled task '$($Target.taskName)' was not disabled; current state: $state"
        }
    }
}

function Start-TunnelTask {
    param(
        $ManagerConfig,
        $Target
    )

    Assert-Administrator
    Assert-ClientTools
    Assert-IdentityFile $Target
    if (-not (Test-LocalTcpPort $ManagerConfig.proxy.localHost ([int]$ManagerConfig.proxy.localPort))) {
        throw "Local Clash proxy is not listening on $($ManagerConfig.proxy.localHost):$($ManagerConfig.proxy.localPort)"
    }
    if (-not (Test-RemoteConnection $Target)) {
        throw "SSH key authentication failed for $(Get-SshDestination $Target)"
    }

    $task = Get-ScheduledTask -TaskName $Target.taskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        throw "Scheduled task '$($Target.taskName)' does not exist. Run update to recreate it."
    }
    $wasDisabled = $task.State -eq 'Disabled'

    try {
        if ($wasDisabled) {
            Enable-ScheduledTask -TaskName $Target.taskName | Out-Null
        }
        Start-ScheduledTask -TaskName $Target.taskName
        $deadline = (Get-Date).AddSeconds(15)
        do {
            Start-Sleep -Milliseconds 250
            $task = Get-ScheduledTask -TaskName $Target.taskName
        } while ($task.State -ne 'Running' -and (Get-Date) -lt $deadline)
        if ($task.State -ne 'Running') {
            throw "Scheduled task '$($Target.taskName)' did not enter Running state; current state: $($task.State)"
        }
        if (-not (Wait-RemoteProxy $Target)) {
            throw "Proxy verification failed for $($Target.name)"
        }
    }
    catch {
        $failedTask = Get-ScheduledTask -TaskName $Target.taskName -ErrorAction SilentlyContinue
        if ($null -ne $failedTask -and $failedTask.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $Target.taskName
        }
        Stop-ManagedTunnelProcesses $ManagerConfig $Target
        if ($wasDisabled) {
            Disable-ScheduledTask -TaskName $Target.taskName | Out-Null
        }
        throw
    }
}

function Install-Target {
    param(
        $ManagerConfig,
        $Target
    )

    Assert-ClientTools
    Assert-IdentityFile $Target
    if (-not (Test-LocalTcpPort $ManagerConfig.proxy.localHost ([int]$ManagerConfig.proxy.localPort))) {
        throw "Local Clash proxy is not listening on $($ManagerConfig.proxy.localHost):$($ManagerConfig.proxy.localPort)"
    }
    if (-not (Test-RemoteConnection $Target)) {
        throw "SSH key authentication failed for $(Get-SshDestination $Target). Run bootstrap-key first."
    }

    Write-Step "Installing Linux files on $($Target.name)"
    Install-RemoteFiles $Target
    Write-Step "Registering scheduled task $($Target.taskName)"
    Register-TunnelTask $ManagerConfig $Target
    if ($Target.enabled) {
        Write-Step "Verifying reverse tunnel for $($Target.name)"
        if (-not (Wait-RemoteProxy $Target)) {
            throw "Proxy verification failed for $($Target.name)"
        }
    }
    else {
        Write-Step "Skipping proxy verification because $($Target.name) is denied"
    }
}

function Install-PublicKey {
    param($Target)

    Assert-ClientTools
    Assert-IdentityFile $Target
    $identityPath = Resolve-IdentityPath $Target.identityFile
    $publicKeyPath = "$identityPath.pub"
    if (-not (Test-Path -LiteralPath $publicKeyPath -PathType Leaf)) {
        $publicKey = & ssh-keygen.exe -y -f $identityPath
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to derive public key from $identityPath"
        }
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($publicKeyPath, (($publicKey -join "`n").Trim() + "`n"), $encoding)
    }

    $publicKeyText = (Get-Content -Raw -LiteralPath $publicKeyPath).Trim()
    if ($publicKeyText -notmatch '^(ssh-|ecdsa-)') {
        throw "Unsupported public key format in $publicKeyPath"
    }
    $encodedKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($publicKeyText))
    $remoteCommand = "set -eu; umask 077; mkdir -p `"`$HOME/.ssh`"; touch `"`$HOME/.ssh/authorized_keys`"; chmod 700 `"`$HOME/.ssh`"; chmod 600 `"`$HOME/.ssh/authorized_keys`"; key=`"`$(printf %s $(ConvertTo-ShellLiteral $encodedKey) | base64 -d)`"; grep -qxF `"`$key`" `"`$HOME/.ssh/authorized_keys`" || printf '%s\n' `"`$key`" >> `"`$HOME/.ssh/authorized_keys`""

    $arguments = @(
        '-p', [string]$Target.sshPort,
        '-i', $identityPath,
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=ask',
        (Get-SshDestination $Target),
        $remoteCommand
    )
    Write-Host 'SSH may ask for the Linux password once. The password is not stored.' -ForegroundColor Yellow
    Invoke-NativeChecked -FilePath 'ssh.exe' -ArgumentList $arguments -Description 'Install SSH public key'

    if (-not (Test-RemoteConnection $Target)) {
        throw 'Public key was copied, but batch-mode SSH verification still failed'
    }
    Write-Host "SSH public key authentication is ready for $($Target.name)."
}

function Get-TargetStatus {
    param($ManagerConfig)

    $results = foreach ($rawTarget in @($ManagerConfig.targets)) {
        $target = Resolve-ConfiguredTarget $ManagerConfig $rawTarget
        $task = Get-ScheduledTask -TaskName $target.taskName -ErrorAction SilentlyContinue
        $taskState = if ($null -eq $task) { 'Missing' } else { [string]$task.State }
        $sshOk = $false
        $proxyOk = $false
        $proxyStatus = if ($target.enabled) { 'FAIL' } else { 'UNKNOWN' }
        try {
            Assert-IdentityFile $target
            $sshOk = Test-RemoteConnection $target
            if ($sshOk -and -not $target.enabled) {
                $proxyStatus = if (Test-RemoteTunnelClosed $target) { 'BLOCKED' } else { 'LEAK' }
            }
            elseif ($sshOk -and $taskState -eq 'Running') {
                $proxyOk = Test-RemoteProxy $target
                $proxyStatus = if ($proxyOk) { 'OK' } else { 'FAIL' }
            }
        }
        catch {
            $sshOk = $false
            $proxyOk = $false
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
        }
    }

    return @($results)
}

function Show-Status {
    param(
        $ManagerConfig,
        [switch]$AsJson
    )

    $results = @(Get-TargetStatus $ManagerConfig)
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
  .\proxy-manager.ps1 add           -Name NAME -RemoteHost HOST -RemoteUser USER [options]
  .\proxy-manager.ps1 adopt         -Name NAME -RemoteHost HOST -RemoteUser USER -TaskName TASK
  .\proxy-manager.ps1 bootstrap-key -Name NAME -RemoteHost HOST -RemoteUser USER [options]
  .\proxy-manager.ps1 status
  .\proxy-manager.ps1 enable        -Name NAME
  .\proxy-manager.ps1 disable       -Name NAME
  .\proxy-manager.ps1 start         -Name NAME
  .\proxy-manager.ps1 stop          -Name NAME
  .\proxy-manager.ps1 update        -Name NAME [options]
  .\proxy-manager.ps1 update-all
  .\proxy-manager.ps1 remove        -Name NAME
  .\proxy-manager.ps1 validate-config [-Config PATH]

Configuration defaults to:
  %LOCALAPPDATA%\ClashSshProxy\config.json

Important:
  * enable/disable persistently allow or deny a target.
  * start/stop change only the current tunnel process.
  * Commands that modify scheduled tasks must run in elevated PowerShell.
  * Passwords are never accepted as parameters or stored.
  * The Linux reverse endpoint is always bound to 127.0.0.1.
  * Run bootstrap-key interactively once if key authentication is not ready.
'@ | Write-Host
}

if ($env:OS -ne 'Windows_NT' -and $Command -notin @('validate-config', 'help')) {
    throw 'proxy-manager.ps1 must run on Windows'
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

    'bootstrap-key' {
        $managerConfig = Read-ManagerConfig -Path $Config -AllowMissing
        Update-GlobalProxyFromCli $managerConfig
        $existing = if (-not [string]::IsNullOrWhiteSpace($Name)) { Get-ConfigTarget $managerConfig $Name -AllowMissing } else { $null }
        $target = New-TargetFromCli $managerConfig $existing
        Install-PublicKey $target
    }

    'add' {
        $managerConfig = Read-ManagerConfig -Path $Config -AllowMissing
        Update-GlobalProxyFromCli $managerConfig
        if ($null -ne (Get-ConfigTarget $managerConfig $Name -AllowMissing)) {
            throw "Target '$Name' already exists. Use update instead."
        }
        $target = New-TargetFromCli $managerConfig $null
        if ($null -ne (Get-ScheduledTask -TaskName $target.taskName -ErrorAction SilentlyContinue)) {
            throw "Scheduled task '$($target.taskName)' already exists. Use adopt or choose another task name."
        }
        Install-Target $managerConfig $target
        Set-ConfigTarget $managerConfig $target
        Save-ManagerConfig $managerConfig $Config
        Write-Host "Added $($target.name). Configuration saved to $Config" -ForegroundColor Green
    }

    'adopt' {
        $managerConfig = Read-ManagerConfig -Path $Config -AllowMissing
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
        Show-Status $managerConfig -AsJson:$Json
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
        Write-Host "Allowed and started $($target.name)." -ForegroundColor Green
    }

    'disable' {
        $managerConfig = Read-ManagerConfig -Path $Config
        $rawTarget = Get-ConfigTarget $managerConfig $Name
        $target = Resolve-ConfiguredTarget $managerConfig $rawTarget
        Stop-TunnelTask $managerConfig $target -Disable -AllowMissing
        $target.enabled = $false
        Set-ConfigTarget $managerConfig $target
        Save-ManagerConfig $managerConfig $Config
        if (Test-RemoteConnection $target) {
            if (-not (Wait-RemoteTunnelClosed $target)) {
                throw "Deny verification failed for $($target.name): remote proxy port is still listening"
            }
            Write-Host "Denied and verified $($target.name). Its remote proxy is blocked." -ForegroundColor Green
        }
        else {
            Write-Warning "Denied $($target.name) locally, but the offline Linux host could not be checked"
        }
    }

    'start' {
        $managerConfig = Read-ManagerConfig -Path $Config
        $rawTarget = Get-ConfigTarget $managerConfig $Name
        $target = Resolve-ConfiguredTarget $managerConfig $rawTarget
        if (-not $target.enabled) {
            throw "Target '$($target.name)' is denied. Run enable instead."
        }
        Start-TunnelTask $managerConfig $target
        Write-Host "Started $($target.name)." -ForegroundColor Green
    }

    'stop' {
        $managerConfig = Read-ManagerConfig -Path $Config
        $rawTarget = Get-ConfigTarget $managerConfig $Name
        $target = Resolve-ConfiguredTarget $managerConfig $rawTarget
        Stop-TunnelTask $managerConfig $target
        if ($target.enabled) {
            Write-Host "Stopped $($target.name). It remains allowed and can start at the next logon." -ForegroundColor Green
        }
        else {
            Write-Host "$($target.name) is denied and stopped." -ForegroundColor Green
        }
    }

    'update' {
        $managerConfig = Read-ManagerConfig -Path $Config
        Update-GlobalProxyFromCli $managerConfig
        $existing = Get-ConfigTarget $managerConfig $Name
        $target = New-TargetFromCli $managerConfig $existing
        Install-Target $managerConfig $target
        Set-ConfigTarget $managerConfig $target
        Save-ManagerConfig $managerConfig $Config
        Write-Host "Updated $($target.name)." -ForegroundColor Green
    }

    { $_ -in @('update-all', 'install-all') } {
        $managerConfig = Read-ManagerConfig -Path $Config
        Update-GlobalProxyFromCli $managerConfig
        foreach ($rawTarget in @($managerConfig.targets)) {
            $target = Resolve-ConfiguredTarget $managerConfig $rawTarget
            Install-Target $managerConfig $target
        }
        Save-ManagerConfig $managerConfig $Config
        Write-Host 'All targets were updated.' -ForegroundColor Green
    }

    'remove' {
        $managerConfig = Read-ManagerConfig -Path $Config
        $rawTarget = Get-ConfigTarget $managerConfig $Name
        $target = Resolve-ConfiguredTarget $managerConfig $rawTarget
        if ($PSCmdlet.ShouldProcess($target.name, 'Remove the Windows task and Linux shell integration')) {
            Assert-Administrator
            Stop-TunnelTask $managerConfig $target -Disable -AllowMissing
            if (-not $SkipRemoteUninstall) {
                $remoteCommand = 'set -eu; if [ -x "$HOME/.config/clash-ssh-proxy/uninstall-linux.sh" ]; then "$HOME/.config/clash-ssh-proxy/uninstall-linux.sh" --purge; else echo "Remote uninstaller not found" >&2; exit 1; fi'
                Invoke-RemoteCommand $target $remoteCommand 'Remove Linux account proxy'
            }
            $task = Get-ScheduledTask -TaskName $target.taskName -ErrorAction SilentlyContinue
            if ($null -ne $task) {
                Unregister-ScheduledTask -TaskName $target.taskName -Confirm:$false
            }
            $managerConfig.targets = @($managerConfig.targets | Where-Object { $_.name -ne $target.name })
            Save-ManagerConfig $managerConfig $Config
            Write-Host "Removed $($target.name)." -ForegroundColor Green
        }
    }
}
