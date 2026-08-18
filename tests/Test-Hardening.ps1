param(
    [Parameter(Mandatory = $true)]
    [string]$ManagerPath,
    [Parameter(Mandatory = $true)]
    [string]$UiRuntimePath,
    [Parameter(Mandatory = $true)]
    [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& {
    . $ManagerPath help *> $null

    function Assert-ConfigRejected {
        param(
            $Candidate,
            [string]$Label
        )
        try {
            Test-ManagerConfig $Candidate
        }
        catch {
            return
        }
        throw "Invalid configuration was accepted: $Label"
    }

    $unicodeConfig = New-DefaultConfig
    $unicodeTarget = [pscustomobject]@{
        name = 'unicode-target'
        host = 'linux.example.com'
        user = 'linuxuser'
        taskName = ([string][char]0x4EE3) + ([string][char]0x7406) +
            ([string][char]0x4EFB) + ([string][char]0x52A1)
        enabled = $false
        sshPort = 22
        identityFile = '~/.ssh/id_ed25519'
        remoteProxyPort = 17897
        noProxyExtra = @('intranet.example.com')
    }
    Set-ConfigTarget $unicodeConfig $unicodeTarget
    $unicodePath = Join-Path $TemporaryRoot 'unicode-config.json'
    Save-ManagerConfig $unicodeConfig $unicodePath
    $bytes = [IO.File]::ReadAllBytes($unicodePath)
    if ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'Manager configuration unexpectedly contains a UTF-8 BOM'
    }
    $reloaded = Read-ManagerConfig $unicodePath
    if ($reloaded.targets[0].taskName -ne $unicodeTarget.taskName) {
        throw 'BOM-less UTF-8 configuration did not round-trip through the manager'
    }

    . $UiRuntimePath
    $Config = $unicodePath
    $uiReloaded = Read-UiConfig
    if ($uiReloaded.targets[0].taskName -ne $unicodeTarget.taskName) {
        throw 'BOM-less UTF-8 configuration did not round-trip through the UI reader'
    }

    $invalidUtf8Path = Join-Path $TemporaryRoot 'invalid-utf8.json'
    [IO.File]::WriteAllBytes($invalidUtf8Path, [byte[]]@(0x7B, 0x22, 0x78, 0x22, 0x3A, 0xFF, 0x7D))
    try {
        [void](Read-ManagerConfig $invalidUtf8Path)
        throw 'Invalid UTF-8 configuration bytes were accepted'
    }
    catch {
        if ($_.Exception.Message -eq 'Invalid UTF-8 configuration bytes were accepted') {
            throw
        }
    }

    $invalidCases = @()
    $candidate = Copy-ManagerConfig $unicodeConfig
    $candidate.proxy.localPort = [double]7897.5
    $invalidCases += [pscustomobject]@{ Label = 'fractional port'; Config = $candidate }
    $candidate = Copy-ManagerConfig $unicodeConfig
    $candidate.proxy.localHost = 'host with spaces'
    $invalidCases += [pscustomobject]@{ Label = 'whitespace in local host'; Config = $candidate }
    $candidate = Copy-ManagerConfig $unicodeConfig
    Add-Member -InputObject $candidate -NotePropertyName unexpected -NotePropertyValue $true
    $invalidCases += [pscustomobject]@{ Label = 'unknown top-level property'; Config = $candidate }
    $candidate = Copy-ManagerConfig $unicodeConfig
    Add-Member -InputObject $candidate.targets[0] -NotePropertyName unexpected -NotePropertyValue $true
    $invalidCases += [pscustomobject]@{ Label = 'unknown target property'; Config = $candidate }
    $candidate = Copy-ManagerConfig $unicodeConfig
    $candidate.targets[0].taskName = "task`nname"
    $invalidCases += [pscustomobject]@{ Label = 'control character in task name'; Config = $candidate }
    $candidate = Copy-ManagerConfig $unicodeConfig
    $candidate.targets[0].host = 'linux' + [char]1 + '.example.com'
    $invalidCases += [pscustomobject]@{ Label = 'control character in host'; Config = $candidate }
    $candidate = Copy-ManagerConfig $unicodeConfig
    $candidate.defaults.sshPort = '22'
    $invalidCases += [pscustomobject]@{ Label = 'string port'; Config = $candidate }
    $candidate = Copy-ManagerConfig $unicodeConfig
    $candidate.defaults.noProxyExtra = 'not-an-array'
    $invalidCases += [pscustomobject]@{ Label = 'string NO_PROXY list'; Config = $candidate }
    foreach ($invalidCase in $invalidCases) {
        Assert-ConfigRejected $invalidCase.Config $invalidCase.Label
    }

    $signatureTarget = [pscustomobject]@{
        name = 'signature-target'
        host = 'linux.example.com'
        user = 'linuxuser'
        taskName = 'SignatureTask'
        enabled = $true
        sshPort = 22
        identityFile = (Join-Path $TemporaryRoot 'identity with spaces')
        remoteProxyPort = 17897
        noProxyExtra = @()
    }
    $invocation = Get-TunnelSshInvocation $unicodeConfig $signatureTarget
    if (-not (Test-ManagedTunnelCommandLine $invocation.CommandLine $invocation)) {
        throw 'Exact managed SSH command line was not recognized'
    }
    $launcherStatusPath = Join-Path $TemporaryRoot 'signature-target.vbs.status'
    $launcherContent = Get-TunnelLauncherContent $invocation.CommandLine $launcherStatusPath
    foreach ($launcherMarker in @(
        'Const retryDelayMilliseconds = 5000',
        'Do',
        'shell.Run(',
        'fileSystem.CreateTextFile(statusPath, True, False)',
        'statusFile.WriteLine "ExitCode="',
        'statusFile.WriteLine "ExitCount="',
        'statusFile.WriteLine "RecordedAt="',
        'WScript.Sleep retryDelayMilliseconds',
        'Loop'
    )) {
        if (-not $launcherContent.Contains($launcherMarker)) {
            throw "Supervised tunnel launcher is missing: $launcherMarker"
        }
    }
    if ($launcherContent.Contains('WScript.Quit')) {
        throw 'Tunnel launcher still exits permanently after one SSH failure'
    }

    $behaviorLauncherPath = Join-Path $TemporaryRoot 'launcher-retry-behavior.vbs'
    $behaviorStatusPath = $behaviorLauncherPath + '.status'
    $cmdPath = (Get-Command cmd.exe -ErrorAction Stop).Source
    $exitCommand = (ConvertTo-WindowsArgument $cmdPath) + ' /d /c exit 7'
    $behaviorContent = Get-TunnelLauncherContent $exitCommand $behaviorStatusPath 1000
    $unicodeEncoding = New-Object Text.UnicodeEncoding($false, $true)
    [IO.File]::WriteAllText($behaviorLauncherPath, ($behaviorContent + "`r`n"), $unicodeEncoding)
    $behaviorStartInfo = New-Object Diagnostics.ProcessStartInfo
    $behaviorStartInfo.FileName = (Get-Command cscript.exe -ErrorAction Stop).Source
    $behaviorStartInfo.Arguments = '//B //Nologo ' + (ConvertTo-WindowsArgument $behaviorLauncherPath)
    $behaviorStartInfo.UseShellExecute = $false
    $behaviorStartInfo.CreateNoWindow = $true
    $behaviorStartInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $behaviorProcess = New-Object Diagnostics.Process
    $behaviorStarted = $false
    $observedExitCount = 0
    try {
        $behaviorProcess.StartInfo = $behaviorStartInfo
        if (-not $behaviorProcess.Start()) {
            throw 'VBS retry behavior process did not start'
        }
        $behaviorStarted = $true
        $behaviorDeadline = (Get-Date).AddSeconds(6)
        while ($observedExitCount -lt 2 -and (Get-Date) -lt $behaviorDeadline) {
            Start-Sleep -Milliseconds 100
            if (-not (Test-Path -LiteralPath $behaviorStatusPath -PathType Leaf)) {
                continue
            }
            try {
                $behaviorStatus = Get-Content -Raw -LiteralPath $behaviorStatusPath
                $exitCodeMatch = [regex]::Match($behaviorStatus, '(?m)^ExitCode=(?<value>-?\d+)\r?$')
                $exitCountMatch = [regex]::Match($behaviorStatus, '(?m)^ExitCount=(?<value>\d+)\r?$')
                if ($exitCodeMatch.Success -and [int]$exitCodeMatch.Groups['value'].Value -ne 7) {
                    throw 'VBS launcher recorded the wrong child exit code'
                }
                if ($exitCountMatch.Success) {
                    $observedExitCount = [int]$exitCountMatch.Groups['value'].Value
                }
            }
            catch [System.IO.IOException] {}
        }
        if ($observedExitCount -lt 2) {
            throw 'VBS launcher did not restart a failed child process'
        }
        if (-not $behaviorProcess.HasExited) {
            $behaviorProcess.Kill()
            [void]$behaviorProcess.WaitForExit(2000)
        }
        $statusLines = @(Get-Content -LiteralPath $behaviorStatusPath)
        if ($statusLines.Count -ne 3 -or
            @($statusLines | Where-Object { $_ -like 'RecordedAt=*' }).Count -ne 1 -or
            ($statusLines -join "`n").Contains($cmdPath)) {
            throw 'VBS launcher status is not bounded or contains child command details'
        }
    }
    finally {
        if ($behaviorStarted -and -not $behaviorProcess.HasExited) {
            $behaviorProcess.Kill()
            [void]$behaviorProcess.WaitForExit(2000)
        }
        $behaviorProcess.Dispose()
    }

    foreach ($nearMiss in @(
        $invocation.CommandLine.Replace('-p 22', '-p 2200'),
        $invocation.CommandLine.Replace('identity with spaces', 'different identity'),
        $invocation.CommandLine.Replace('linuxuser@linux.example.com', 'other@linux.example.com')
    )) {
        if (Test-ManagedTunnelCommandLine $nearMiss $invocation) {
            throw "Unrelated SSH command line matched the managed tunnel: $nearMiss"
        }
    }
    if (Test-ManagedTunnelCommandLine `
        $invocation.CommandLine `
        $invocation `
        'C:\Unrelated\ssh.exe') {
        throw 'SSH process from an unrelated executable path matched the managed tunnel'
    }

    $script:MockManagedProcessCall = 0
    $script:StoppedManagedProcessIds = @()
    function Get-ManagedTunnelProcesses {
        param($ManagerConfig, $Target)
        $script:MockManagedProcessCall++
        switch ($script:MockManagedProcessCall) {
            1 { return ,([pscustomobject]@{ ProcessId = 101 }) }
            2 { return ,([pscustomobject]@{ ProcessId = 102 }) }
            3 { return ,([pscustomobject]@{ ProcessId = 103 }) }
            default { return @() }
        }
    }
    function Stop-Process {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [int[]]$Id,
            [switch]$Force
        )
        $script:StoppedManagedProcessIds += @($Id)
    }
    Stop-ManagedTunnelProcesses `
        $unicodeConfig `
        $signatureTarget `
        -TimeoutMilliseconds 100 `
        -QuietPeriodMilliseconds 0 `
        -PollMilliseconds 0
    if (($script:StoppedManagedProcessIds -join ',') -ne '101,102,103') {
        throw 'Managed tunnel cleanup did not drain processes that appeared during task shutdown'
    }

    $script:MockTaskExists = $true
    function Get-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName)
        if ($script:MockTaskExists) {
            return [pscustomobject]@{
                TaskName = $TaskName
                State = 'Ready'
                Description = 'Managed by clash-ssh-proxy-bootstrap; target=signature-target; destination=linuxuser@linux.example.com'
                Actions = @()
            }
        }
        return $null
    }
    $previousTarget = $signatureTarget.PSObject.Copy()
    $previousTarget.taskName = 'PreviousTask'
    try {
        Assert-TunnelTaskTransitionAvailable $signatureTarget $null
        throw 'New-target task collision was accepted'
    }
    catch {
        if ($_.Exception.Message -eq 'New-target task collision was accepted') { throw }
    }
    try {
        Assert-TunnelTaskTransitionAvailable $signatureTarget $previousTarget
        throw 'Renamed-target task collision was accepted'
    }
    catch {
        if ($_.Exception.Message -eq 'Renamed-target task collision was accepted') { throw }
    }
    $previousTarget.taskName = $signatureTarget.taskName
    Assert-TunnelTaskTransitionAvailable $signatureTarget $previousTarget
    function Get-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName)
        [pscustomobject]@{
            TaskName = $TaskName
            State = 'Ready'
            Description = 'Unrelated task'
            Actions = @()
        }
    }
    try {
        Assert-TunnelTaskTransitionAvailable $signatureTarget $previousTarget
        throw 'Unowned same-name task collision was accepted'
    }
    catch {
        if ($_.Exception.Message -eq 'Unowned same-name task collision was accepted') { throw }
    }
    $script:MockTaskExists = $false
    function Get-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName)
        return $null
    }
    Assert-TunnelTaskTransitionAvailable $signatureTarget $null
    $renamedTarget = $signatureTarget.PSObject.Copy()
    $renamedTarget.taskName = 'ReplacementTask'
    $previousTarget.taskName = 'UnownedPreviousTask'
    function Get-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName)
        if ($TaskName -eq 'UnownedPreviousTask') {
            return [pscustomobject]@{
                TaskName = $TaskName
                State = 'Ready'
                Description = 'Unrelated task'
                Actions = @()
            }
        }
        return $null
    }
    try {
        Assert-TunnelTaskTransitionAvailable $renamedTarget $previousTarget
        throw 'Unowned previous task was accepted during rename'
    }
    catch {
        if ($_.Exception.Message -eq 'Unowned previous task was accepted during rename') { throw }
    }
    Remove-Item Function:Get-ScheduledTask
}

& {
    . $ManagerPath help *> $null
    $script:LifecycleEvents = New-Object 'System.Collections.Generic.List[string]'
    $script:StartShouldFail = $false
    $script:CapturedRestartCount = $null
    $script:CapturedLogonDelay = $null
    $functionNames = @(
        'Assert-Administrator', 'Assert-TunnelTaskTransitionAvailable',
        'Get-TunnelSshInvocation', 'Write-TunnelLauncher', 'Stop-TunnelTask',
        'Remove-TunnelTaskRegistration', 'Remove-TunnelLauncher'
    )
    $originalFunctions = @{}
    foreach ($functionName in $functionNames) {
        $originalFunctions[$functionName] = (Get-Command $functionName).ScriptBlock
    }

    try {
        Set-Item Function:Assert-Administrator -Value {}
        Set-Item Function:Assert-TunnelTaskTransitionAvailable -Value {
            param($Target, $PreviousTarget)
        }
        Set-Item Function:Get-TunnelSshInvocation -Value {
            param($ManagerConfig, $Target)
            [pscustomobject]@{
                Executable = 'C:\Windows\System32\OpenSSH\ssh.exe'
                Arguments = @('-N')
                CommandLine = 'ssh.exe -N'
            }
        }
        Set-Item Function:Write-TunnelLauncher -Value {
            param($Target, [string]$SshCommandLine)
            [void]$script:LifecycleEvents.Add("write:$($Target.taskName)")
            return 'C:\ProgramData\ClashSshProxy\tasks\target.vbs'
        }
        Set-Item Function:Stop-TunnelTask -Value {
            param($ManagerConfig, $Target, [switch]$Disable, [switch]$AllowMissing)
            [void]$script:LifecycleEvents.Add("stop:$($Target.taskName)")
        }
        Set-Item Function:Remove-TunnelTaskRegistration -Value {
            param([string]$TaskName)
            [void]$script:LifecycleEvents.Add("remove:$TaskName")
        }
        Set-Item Function:Remove-TunnelLauncher -Value {
            param($Target)
            [void]$script:LifecycleEvents.Add("launcher-remove:$($Target.taskName)")
        }
        function New-ScheduledTaskAction { param($Execute, $Argument) [pscustomobject]@{} }
        function New-ScheduledTaskTrigger {
            param([switch]$AtLogOn, $User)
            [pscustomobject]@{ Delay = $null }
        }
        function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) [pscustomobject]@{} }
        function New-ScheduledTaskSettingsSet {
            param(
                $RestartCount, $RestartInterval, $ExecutionTimeLimit, $MultipleInstances,
                [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries,
                [switch]$StartWhenAvailable
            )
            $script:CapturedRestartCount = $RestartCount
            [pscustomobject]@{}
        }
        function New-ScheduledTask {
            param($Action, $Trigger, $Principal, $Settings, $Description)
            $script:CapturedLogonDelay = $Trigger.Delay
            [pscustomobject]@{}
        }
        function Register-ScheduledTask {
            param([string]$TaskName, $InputObject, [switch]$Force)
            [void]$script:LifecycleEvents.Add("register:$TaskName")
        }
        function Disable-ScheduledTask { param([string]$TaskName) }
        function Start-ScheduledTask {
            param([string]$TaskName)
            [void]$script:LifecycleEvents.Add("start:$TaskName")
            if ($script:StartShouldFail) { throw 'injected start failure' }
        }
        function Get-ScheduledTask {
            [CmdletBinding()]
            param([string]$TaskName)
            [pscustomobject]@{ TaskName = $TaskName; State = 'Running' }
        }

        $managerConfig = New-DefaultConfig
        $oldTarget = [pscustomobject]@{
            name = 'lifecycle'; host = 'linux.example.com'; user = 'linuxuser'
            taskName = 'OldTask'; enabled = $true; sshPort = 22
            identityFile = '~/.ssh/id_ed25519'; remoteProxyPort = 17897; noProxyExtra = @()
        }
        $newTarget = $oldTarget.PSObject.Copy()
        $newTarget.taskName = 'NewTask'
        Register-TunnelTask $managerConfig $newTarget $managerConfig $oldTarget
        if ($script:CapturedRestartCount -ne 255 -or $script:CapturedLogonDelay -ne 'PT15S') {
            throw 'Tunnel task does not use a schema-safe restart count and fixed logon delay'
        }
        $expectedOrder = @('stop:OldTask', 'remove:OldTask', 'write:NewTask', 'register:NewTask', 'start:NewTask')
        if (($script:LifecycleEvents -join '|') -ne ($expectedOrder -join '|')) {
            throw "Task rename did not migrate in order: $($script:LifecycleEvents -join '|')"
        }

        $script:LifecycleEvents.Clear()
        Disable-FailedTunnelInstall `
            $managerConfig $oldTarget $oldTarget `
            -CurrentTaskRegistered -LauncherWritten
        $sameNameCleanup = @('stop:OldTask', 'remove:OldTask', 'launcher-remove:OldTask')
        if (($script:LifecycleEvents -join '|') -ne ($sameNameCleanup -join '|')) {
            throw "Same-name failed replacement was not removed safely: $($script:LifecycleEvents -join '|')"
        }

        $script:LifecycleEvents.Clear()
        $script:StartShouldFail = $true
        $failedTarget = $oldTarget.PSObject.Copy()
        $failedTarget.taskName = 'FailedTask'
        try {
            Register-TunnelTask $managerConfig $failedTarget $managerConfig $oldTarget
            throw 'Injected task registration failure was swallowed'
        }
        catch {
            if ($_.Exception.Message -eq 'Injected task registration failure was swallowed') { throw }
        }
        foreach ($requiredEvent in @(
            'stop:OldTask', 'remove:OldTask', 'register:FailedTask',
            'stop:FailedTask', 'remove:FailedTask', 'launcher-remove:FailedTask'
        )) {
            if ($script:LifecycleEvents -notcontains $requiredEvent) {
                throw "Failed task registration did not clean up: $requiredEvent"
            }
        }
    }
    finally {
        foreach ($functionName in @(
            'New-ScheduledTaskAction', 'New-ScheduledTaskTrigger', 'New-ScheduledTaskPrincipal',
            'New-ScheduledTaskSettingsSet', 'New-ScheduledTask', 'Register-ScheduledTask',
            'Disable-ScheduledTask', 'Start-ScheduledTask', 'Get-ScheduledTask'
        )) {
            Remove-Item -Path ("Function:$functionName") -ErrorAction SilentlyContinue
        }
        foreach ($functionName in $functionNames) {
            Set-Item -Path ("Function:$functionName") -Value $originalFunctions[$functionName]
        }
    }
}

& {
    . $ManagerPath help *> $null
    $script:InstallEvents = New-Object 'System.Collections.Generic.List[string]'
    $functionNames = @(
        'Assert-Administrator', 'Assert-TunnelTaskTransitionAvailable',
        'Assert-ClientTools', 'Assert-IdentityFile', 'Test-LocalTcpPort',
        'Test-RemoteConnection', 'Test-RemoteManagedInstallation',
        'Install-RemoteFiles', 'Register-TunnelTask',
        'Wait-RemoteProxy', 'Disable-FailedTunnelInstall',
        'Remove-NewRemoteInstallationAfterFailure', 'Write-Step'
    )
    $originalFunctions = @{}
    foreach ($functionName in $functionNames) {
        $originalFunctions[$functionName] = (Get-Command $functionName).ScriptBlock
    }
    try {
        Set-Item Function:Assert-Administrator -Value {
            [void]$script:InstallEvents.Add('administrator')
        }
        Set-Item Function:Assert-TunnelTaskTransitionAvailable -Value {
            param($Target, $PreviousTarget)
            [void]$script:InstallEvents.Add('task-preflight')
        }
        Set-Item Function:Assert-ClientTools -Value {
            [void]$script:InstallEvents.Add('client-tools')
        }
        Set-Item Function:Assert-IdentityFile -Value {
            param($Target)
            [void]$script:InstallEvents.Add('identity')
        }
        Set-Item Function:Test-LocalTcpPort -Value {
            param([string]$HostName, [int]$Port)
            [void]$script:InstallEvents.Add('local-proxy')
            return $true
        }
        Set-Item Function:Test-RemoteConnection -Value {
            param($Target)
            [void]$script:InstallEvents.Add('ssh')
            return $true
        }
        Set-Item Function:Test-RemoteManagedInstallation -Value {
            param($Target)
            [void]$script:InstallEvents.Add('remote-state')
            return $false
        }
        Set-Item Function:Install-RemoteFiles -Value {
            param($Target)
            [void]$script:InstallEvents.Add('remote-install')
        }
        Set-Item Function:Register-TunnelTask -Value {
            param($ManagerConfig, $Target, $PreviousManagerConfig, $PreviousTarget)
            [void]$script:InstallEvents.Add('task-register')
        }
        Set-Item Function:Wait-RemoteProxy -Value {
            param($Target)
            [void]$script:InstallEvents.Add('proxy-verify')
            return $false
        }
        Set-Item Function:Disable-FailedTunnelInstall -Value {
            param(
                $ManagerConfig, $Target, $PreviousTarget,
                [switch]$CurrentTaskRegistered, [switch]$LauncherWritten
            )
            [void]$script:InstallEvents.Add('local-cleanup')
        }
        Set-Item Function:Remove-NewRemoteInstallationAfterFailure -Value {
            param($Target)
            [void]$script:InstallEvents.Add('remote-rollback')
        }
        Set-Item Function:Write-Step -Value { param([string]$Message) }

        $managerConfig = New-DefaultConfig
        $target = [pscustomobject]@{
            name = 'install-failure'; host = 'linux.example.com'; user = 'linuxuser'
            taskName = 'InstallFailureTask'; enabled = $true; sshPort = 22
            identityFile = '~/.ssh/id_ed25519'; remoteProxyPort = 17897; noProxyExtra = @()
        }
        try {
            Install-Target $managerConfig $target $null $null
            throw 'Injected proxy verification failure was swallowed'
        }
        catch {
            if ($_.Exception.Message -eq 'Injected proxy verification failure was swallowed') { throw }
        }
        $expectedEvents = @(
            'administrator', 'task-preflight', 'client-tools', 'identity',
            'local-proxy', 'ssh', 'remote-state', 'remote-install', 'task-register',
            'proxy-verify', 'local-cleanup', 'remote-rollback'
        )
        if (($script:InstallEvents -join '|') -ne ($expectedEvents -join '|')) {
            throw "Install preflight or rollback order was wrong: $($script:InstallEvents -join '|')"
        }
    }
    finally {
        foreach ($functionName in $functionNames) {
            Set-Item -Path ("Function:$functionName") -Value $originalFunctions[$functionName]
        }
    }
}

Write-Host 'Release hardening tests passed'
