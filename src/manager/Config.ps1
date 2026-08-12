# Configuration loading, validation, target defaults, and cross-process mutation locking.

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
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
    try {
        [System.IO.File]::WriteAllText($temporaryPath, "$json`r`n", $encoding)
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-ConfigMutationLockName {
    param([string]$Path)

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    $fullPath = [IO.Path]::GetFullPath($expandedPath).ToUpperInvariant()
    $pathBytes = [Text.Encoding]::UTF8.GetBytes($fullPath)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($pathBytes)
    }
    finally {
        $sha256.Dispose()
    }
    $hash = ([BitConverter]::ToString($hashBytes)).Replace('-', '')
    return "Local\ClashSshProxy.Config.$hash"
}

function Enter-ConfigMutationLock {
    param(
        [string]$Path,
        [int]$TimeoutMilliseconds = 30000
    )

    $lockName = Get-ConfigMutationLockName $Path
    $mutex = New-Object System.Threading.Mutex($false, $lockName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds, $false)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Another proxy-manager process is modifying '$Path'. Try again after it finishes."
        }
        return $mutex
    }
    catch {
        if (-not $acquired) {
            $mutex.Dispose()
        }
        throw
    }
}

function Exit-ConfigMutationLock {
    param([AllowNull()]$Mutex)

    if ($null -eq $Mutex) {
        return
    }
    try {
        $Mutex.ReleaseMutex()
    }
    finally {
        $Mutex.Dispose()
    }
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
