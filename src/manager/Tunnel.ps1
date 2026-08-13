# Windows Task Scheduler, secure launcher, and managed SSH tunnel lifecycle.

function Get-TaskSchedulerRootFast {
    if ($null -eq $script:TaskSchedulerRoot) {
        $script:TaskSchedulerService = New-Object -ComObject 'Schedule.Service'
        $script:TaskSchedulerService.Connect()
        $script:TaskSchedulerRoot = $script:TaskSchedulerService.GetFolder('\')
    }
    return $script:TaskSchedulerRoot
}

function Get-RegisteredTaskFast {
    param([string]$TaskName)

    try {
        $root = Get-TaskSchedulerRootFast
        return $root.GetTask($TaskName)
    }
    catch [System.IO.FileNotFoundException] {
        return $null
    }
    catch [System.Runtime.InteropServices.COMException] {
        if ($_.Exception.HResult -eq -2147024894) {
            return $null
        }
        throw
    }
}

function Get-RegisteredTaskStateFast {
    param([AllowNull()]$RegisteredTask)

    if ($null -eq $RegisteredTask) {
        return 'Missing'
    }
    switch ([int]$RegisteredTask.State) {
        1 { return 'Disabled' }
        2 { return 'Queued' }
        3 { return 'Ready' }
        4 { return 'Running' }
        default { return 'Unknown' }
    }
}

function ConvertTo-VbScriptLiteral {
    param([string]$Value)
    return '"' + $Value.Replace('"', '""') + '"'
}

function Get-TunnelLauncherPath {
    param($Target)

    $launcherDirectory = Join-Path $env:ProgramData 'ClashSshProxy\tasks'
    return Join-Path $launcherDirectory ($Target.name + '.vbs')
}

function Assert-SecureLauncherDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Task launcher directory does not exist: $Path"
    }
    $directory = Get-Item -LiteralPath $Path -Force
    if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Task launcher directory must not be a reparse point: $Path"
    }
    $acl = Get-Acl -LiteralPath $Path
    $ownerSid = $acl.Owner
    if (-not $acl.AreAccessRulesProtected) {
        throw "Task launcher directory still inherits permissions: $Path"
    }
    try {
        $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    }
    catch {}
    if ($ownerSid -notin @('S-1-5-18', 'S-1-5-32-544')) {
        throw "Task launcher directory has an unexpected owner: $ownerSid"
    }
    $expectedSids = @('S-1-5-18', 'S-1-5-32-544')
    $observedSids = @{}
    foreach ($entry in @($acl.Access)) {
        $sid = $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($entry.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $sid -notin $expectedSids -or
            ($entry.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
                [Security.AccessControl.FileSystemRights]::FullControl) {
            throw "Task launcher directory grants access to an unexpected principal: $sid"
        }
        $observedSids[$sid] = $true
    }
    if (@($expectedSids | Where-Object { -not $observedSids.ContainsKey($_) }).Count -gt 0) {
        throw "Task launcher directory is missing required access rules: $Path"
    }
}

function Initialize-SecureLauncherDirectory {
    param([string]$Path)

    $icaclsCommand = Get-Command icacls.exe -ErrorAction Stop
    $launcherRoot = Split-Path -Parent $Path
    foreach ($directoryPath in @($launcherRoot, $Path)) {
        if (Test-Path -LiteralPath $directoryPath) {
            $existing = Get-Item -LiteralPath $directoryPath -Force
            if (-not $existing.PSIsContainer -or
                ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Task launcher path is not a regular directory: $directoryPath"
            }
        }
        else {
            New-Item -ItemType Directory -Path $directoryPath | Out-Null
        }
        Invoke-NativeChecked $icaclsCommand.Source @(
            $directoryPath, '/setowner', '*S-1-5-32-544'
        ) 'Secure task launcher directory owner' | Out-Null
        Invoke-NativeChecked $icaclsCommand.Source @(
            $directoryPath, '/reset'
        ) 'Reset task launcher directory permissions' | Out-Null
        Invoke-NativeChecked $icaclsCommand.Source @(
            $directoryPath, '/inheritance:r', '/grant:r',
            '*S-1-5-18:(OI)(CI)(F)', '*S-1-5-32-544:(OI)(CI)(F)'
        ) 'Secure task launcher directory permissions' | Out-Null
        Assert-SecureLauncherDirectory $directoryPath
    }
}

function Write-TunnelLauncher {
    param(
        $Target,
        [string]$SshCommandLine
    )

    $launcherPath = Get-TunnelLauncherPath $Target
    $launcherDirectory = Split-Path -Parent $launcherPath
    Initialize-SecureLauncherDirectory $launcherDirectory | Out-Null

    $content = @(
        'Option Explicit',
        'Dim shell, exitCode',
        'Set shell = CreateObject("WScript.Shell")',
        "exitCode = shell.Run($(ConvertTo-VbScriptLiteral $SshCommandLine), 0, True)",
        'WScript.Quit exitCode'
    ) -join "`r`n"
    $temporaryPath = "$launcherPath.$PID.tmp"
    $encoding = New-Object Text.UnicodeEncoding($false, $true)
    try {
        [IO.File]::WriteAllText($temporaryPath, ($content + "`r`n"), $encoding)
        Move-Item -LiteralPath $temporaryPath -Destination $launcherPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
    Assert-SecureLauncherDirectory $launcherDirectory
    return $launcherPath
}

function Remove-TunnelLauncher {
    param($Target)

    $launcherPath = Get-TunnelLauncherPath $Target
    if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
        Remove-Item -LiteralPath $launcherPath -Force
    }
    $launcherDirectory = Split-Path -Parent $launcherPath
    if ((Test-Path -LiteralPath $launcherDirectory -PathType Container) -and
        @(Get-ChildItem -LiteralPath $launcherDirectory -Force).Count -eq 0) {
        Remove-Item -LiteralPath $launcherDirectory -Force
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this command from an elevated PowerShell window because scheduled tasks are modified.'
    }
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

function Wait-ManagedTunnelProcess {
    param(
        $ManagerConfig,
        $Target,
        [int]$TimeoutSeconds = 3
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (@(Get-ManagedTunnelProcesses $ManagerConfig $Target).Count -gt 0) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Stop-ManagedTunnelProcesses {
    param(
        $ManagerConfig,
        $Target
    )

    for ($pass = 1; $pass -le 2; $pass++) {
        $processes = @(Get-ManagedTunnelProcesses $ManagerConfig $Target)
        if ($processes.Count -eq 0) {
            return
        }
        $processIds = @($processes | ForEach-Object { [int]$_.ProcessId })
        Stop-Process -Id $processIds -Force -ErrorAction SilentlyContinue

        $deadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $deadline) {
            $alive = @(Get-Process -Id $processIds -ErrorAction SilentlyContinue)
            if ($alive.Count -eq 0) {
                break
            }
            Start-Sleep -Milliseconds 50
        }
        $alive = @(Get-Process -Id $processIds -ErrorAction SilentlyContinue)
        if ($alive.Count -gt 0) {
            throw "Unable to stop $($alive.Count) managed SSH tunnel process(es) for $($Target.name)"
        }
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
    $wscriptCommand = Get-Command wscript.exe -ErrorAction Stop
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
    $sshCommandLine = (@(@($sshCommand.Source) + @($argumentValues)) | ForEach-Object {
        ConvertTo-WindowsArgument ([string]$_)
    }) -join ' '
    $launcherPath = Get-TunnelLauncherPath $Target
    $taskArgumentValues = @('//B', '//Nologo', $launcherPath)
    $taskArgumentLine = ($taskArgumentValues | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' '
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    $action = New-ScheduledTaskAction -Execute $wscriptCommand.Source -Argument $taskArgumentLine
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

    Write-TunnelLauncher $Target $sshCommandLine | Out-Null
    Register-ScheduledTask -TaskName $Target.taskName -InputObject $definition -Force | Out-Null
    if (-not $Target.enabled) {
        Disable-ScheduledTask -TaskName $Target.taskName | Out-Null
        $state = (Get-ScheduledTask -TaskName $Target.taskName).State
        if ($state -ne 'Disabled') {
            throw "Scheduled task '$($Target.taskName)' was not disabled; current state: $state"
        }
        Write-Step "Target $($Target.name) remains disabled; its scheduled task is disabled"
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
    $task = Get-RegisteredTaskFast $Target.taskName
    if ($null -eq $task) {
        if (-not $AllowMissing) {
            throw "Scheduled task '$($Target.taskName)' does not exist. Run update to recreate it."
        }
    }
    else {
        $taskWasActive = (Get-RegisteredTaskStateFast $task) -in @('Running', 'Queued')
        if ($Disable) {
            $task.Enabled = $false
        }
        if ($taskWasActive) {
            [void]$task.Stop(0)
        }
    }
    Stop-ManagedTunnelProcesses $ManagerConfig $Target

    if ($Disable -and $null -ne $task) {
        if ([bool]$task.Enabled) {
            throw "Scheduled task '$($Target.taskName)' is still enabled"
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
    $task = Get-RegisteredTaskFast $Target.taskName
    if ($null -eq $task) {
        throw "Scheduled task '$($Target.taskName)' does not exist. Run update to recreate it."
    }
    $wasDisabled = -not [bool]$task.Enabled

    try {
        if ($wasDisabled) {
            $task.Enabled = $true
        }
        [void]$task.Run($null)
        if (-not (Wait-ManagedTunnelProcess $ManagerConfig $Target)) {
            if (-not (Test-RemoteConnection $Target)) {
                throw "SSH key authentication failed for $(Get-SshDestination $Target)"
            }
            throw "SSH tunnel process failed to stay running for $($Target.name)"
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
