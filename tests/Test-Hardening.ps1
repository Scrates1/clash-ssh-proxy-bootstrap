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

    $savedCliParameters = $script:CliParameters
    $savedName = $Name
    $savedTargetId = $TargetId
    $savedRemoteHost = $RemoteHost
    $savedRemoteUser = $RemoteUser
    $savedSshPort = $SshPort
    $savedIdentityFile = $IdentityFile
    try {
        $generatedConfig = New-DefaultConfig
        $script:CliParameters = @{
            RemoteHost = $true
            RemoteUser = $true
            SshPort = $true
        }
        $Name = 'generated-target'
        $TargetId = $null
        $RemoteHost = 'generated.example.com'
        $RemoteUser = 'generated-user'
        $SshPort = 22
        $generatedTarget = New-TargetFromCli $generatedConfig $null
        if ($generatedTarget.id -notmatch '^tgt-[0-9a-f]{32}$' -or
            -not $generatedTarget.identityManaged -or
            (Split-Path -Leaf $generatedTarget.identityFile) -ne "$($generatedTarget.id).ed25519") {
            throw 'New targets did not receive a stable ID and dedicated managed identity path'
        }
        Set-ConfigTarget $generatedConfig $generatedTarget

        $Name = 'duplicate-account'
        $RemoteHost = 'GENERATED.EXAMPLE.COM'
        $RemoteUser = 'GENERATED-USER'
        $SshPort = 2200
        $duplicateAccountRejected = $false
        try { New-TargetFromCli $generatedConfig $null | Out-Null }
        catch { $duplicateAccountRejected = $_.Exception.Message -like '*already manages SSH account*' }
        if (-not $duplicateAccountRejected) {
            throw 'Different SSH ports bypassed host+user target uniqueness'
        }

        $Name = 'duplicate-identity'
        $RemoteHost = 'other.example.com'
        $RemoteUser = 'other-user'
        $IdentityFile = $generatedTarget.identityFile
        $script:CliParameters.IdentityFile = $true
        $duplicateIdentityRejected = $false
        try { New-TargetFromCli $generatedConfig $null | Out-Null }
        catch { $duplicateIdentityRejected = $_.Exception.Message -like '*already assigned*' }
        if (-not $duplicateIdentityRejected) {
            throw 'Different targets were allowed to share a private-key path'
        }

        $Name = 'generated-target'
        $IdentityFile = $generatedTarget.identityFile
        $editedTarget = New-TargetFromCli $generatedConfig $generatedTarget
        if (-not $editedTarget.identityManaged) {
            throw 'Editing a target changed its managed identity into an external identity'
        }

        $duplicateConfig = Copy-ManagerConfig $generatedConfig
        $duplicateConfig.targets += [pscustomobject]@{
            id = 'tgt-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            name = 'duplicate-config-identity'
            host = 'config-other.example.com'
            user = 'config-other-user'
            taskName = 'ConfigOtherTask'
            enabled = $true
            sshPort = 22
            identityFile = $generatedTarget.identityFile
            identityManaged = $true
            remoteProxyPort = 17898
            noProxyExtra = @()
        }
        $duplicateConfigRejected = $false
        try { Test-ManagerConfig $duplicateConfig }
        catch { $duplicateConfigRejected = $_.Exception.Message -like '*different private key*' }
        if (-not $duplicateConfigRejected) {
            throw 'Configuration validation accepted a shared private-key path'
        }
    }
    finally {
        $script:CliParameters = $savedCliParameters
        $Name = $savedName
        $TargetId = $savedTargetId
        $RemoteHost = $savedRemoteHost
        $RemoteUser = $savedRemoteUser
        $SshPort = $savedSshPort
        $IdentityFile = $savedIdentityFile
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
    $launcherContent = Get-TunnelLauncherContent $invocation.CommandLine
    foreach ($launcherMarker in @(
        'Const retryDelayMilliseconds = 5000',
        'Do',
        'shell.Run ',
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
    if ($launcherContent.Contains('statusPath') -or
        $launcherContent.Contains('Scripting.FileSystemObject')) {
        throw 'Tunnel launcher still writes an unused sidecar status file'
    }

    $behaviorLauncherPath = Join-Path $TemporaryRoot 'launcher-retry-behavior.vbs'
    $cmdPath = (Get-Command cmd.exe -ErrorAction Stop).Source
    $exitCommand = (ConvertTo-WindowsArgument $cmdPath) + ' /d /c exit 7'
    $behaviorContent = Get-TunnelLauncherContent $exitCommand 1000
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
    try {
        $behaviorProcess.StartInfo = $behaviorStartInfo
        if (-not $behaviorProcess.Start()) {
            throw 'VBS retry behavior process did not start'
        }
        $behaviorStarted = $true
        Start-Sleep -Milliseconds 2500
        if ($behaviorProcess.HasExited) {
            throw 'VBS launcher exited instead of supervising the short-lived child command'
        }
    }
    finally {
        if ($behaviorStarted -and -not $behaviorProcess.HasExited) {
            $behaviorProcess.Kill()
            [void]$behaviorProcess.WaitForExit(2000)
        }
        $behaviorProcess.Dispose()
    }

    & {
        $functionNames = @(
            'Test-LocalTcpPort', 'Enter-ConfigMutationLock', 'Exit-ConfigMutationLock',
            'Get-RegisteredTaskFast', 'Start-TunnelTask'
        )
        $originalFunctions = @{}
        foreach ($functionName in $functionNames) {
            $originalFunctions[$functionName] = (Get-Command $functionName).ScriptBlock
        }
        try {
            $script:ReconciliationProbeAttempt = 0
            Set-Item Function:Test-LocalTcpPort -Value {
                param([string]$HostName, [int]$Port, [int]$TimeoutMilliseconds)
                $script:ReconciliationProbeAttempt++
                return $script:ReconciliationProbeAttempt -ge 3
            }
            $waitResult = Wait-LocalProxyForReconciliation `
                (New-DefaultConfig) -AttemptLimit 3 -DelayMilliseconds 0 -ConnectTimeoutMilliseconds 50
            if (-not $waitResult -or $script:ReconciliationProbeAttempt -ne 3) {
                throw 'Reconciliation did not stop probing when the local proxy became ready'
            }

            $script:ReconciliationProbeAttempt = 0
            Set-Item Function:Test-LocalTcpPort -Value {
                param([string]$HostName, [int]$Port, [int]$TimeoutMilliseconds)
                $script:ReconciliationProbeAttempt++
                return $false
            }
            $waitResult = Wait-LocalProxyForReconciliation `
                (New-DefaultConfig) -AttemptLimit 2 -DelayMilliseconds 0 -ConnectTimeoutMilliseconds 50
            if ($waitResult -or $script:ReconciliationProbeAttempt -ne 2) {
                throw 'Reconciliation local-proxy wait did not honor its retry bound'
            }

            $reconciliationConfig = New-DefaultConfig
            $stateNames = @('running', 'ready', 'disabled-task', 'missing')
            for ($stateIndex = 0; $stateIndex -lt $stateNames.Count; $stateIndex++) {
                Set-ConfigTarget $reconciliationConfig ([pscustomobject]@{
                    name = $stateNames[$stateIndex]
                    host = 'reconcile-' + $stateIndex + '.example.com'
                    user = 'reconcile-user' + $stateIndex
                    taskName = 'ReconcileTask' + $stateIndex
                    enabled = $true
                    sshPort = 22
                    identityFile = (Join-Path $TemporaryRoot ('reconcile-' + $stateIndex + '.ed25519'))
                    remoteProxyPort = 17897 + $stateIndex
                    noProxyExtra = @()
                })
            }
            $reconciliationPath = Join-Path $TemporaryRoot 'reconciliation-config.json'
            Save-ManagerConfig $reconciliationConfig $reconciliationPath

            $script:ReconciliationTaskStates = @{
                ReconcileTask0 = 4
                ReconcileTask1 = 3
                ReconcileTask2 = 1
            }
            $script:ReconciliationStarts = @()
            $script:ReconciliationLockCount = 0
            Set-Item Function:Test-LocalTcpPort -Value {
                param([string]$HostName, [int]$Port, [int]$TimeoutMilliseconds)
                return $true
            }
            Set-Item Function:Enter-ConfigMutationLock -Value {
                param([string]$Path, [int]$TimeoutMilliseconds = 30000)
                $script:ReconciliationLockCount++
                return [pscustomobject]@{}
            }
            Set-Item Function:Exit-ConfigMutationLock -Value { param($Mutex) }
            Set-Item Function:Get-RegisteredTaskFast -Value {
                param([string]$TaskName)
                if (-not $script:ReconciliationTaskStates.ContainsKey($TaskName)) {
                    return $null
                }
                return [pscustomobject]@{ State = $script:ReconciliationTaskStates[$TaskName] }
            }
            Set-Item Function:Start-TunnelTask -Value {
                param($ManagerConfig, $Target)
                $script:ReconciliationStarts += [string]$Target.name
                $script:ReconciliationTaskStates[[string]$Target.taskName] = 4
            }

            $null = Invoke-EnabledTargetReconciliation `
                -ConfigPath $reconciliationPath `
                -AttemptLimit 1 `
                -DelayMilliseconds 0 `
                -ConnectTimeoutMilliseconds 50 3> $null 6> $null
            if ($script:ReconciliationLockCount -ne 4 -or
                ($script:ReconciliationStarts -join ',') -ne 'ready,disabled-task') {
                throw 'Sequential reconciliation did not preserve target order and state decisions'
            }
        }
        finally {
            foreach ($functionName in $functionNames) {
                Set-Item -Path ("Function:$functionName") -Value $originalFunctions[$functionName]
            }
        }
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
