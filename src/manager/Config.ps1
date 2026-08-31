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

function New-TargetId {
    return "tgt-$([guid]::NewGuid().ToString('N'))"
}

function Get-LegacyTargetId {
    param([string]$TargetName)

    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$TargetName)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    $hash = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    return "tgt-legacy-$hash"
}

function Assert-TargetId {
    param([string]$TargetId)

    if ([string]::IsNullOrWhiteSpace($TargetId) -or
        $TargetId -notmatch '^tgt-[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Invalid target id: $TargetId"
    }
}

function Get-ManagedIdentityPath {
    param([string]$TargetId)

    Assert-TargetId $TargetId
    $configDirectory = Split-Path -Parent (Get-DefaultConfigPath)
    $keyDirectory = Join-Path $configDirectory 'keys'
    return Join-Path $keyDirectory "$TargetId.ed25519"
}

function Get-CanonicalIdentityPath {
    param([string]$IdentityFile)

    if ([string]::IsNullOrWhiteSpace($IdentityFile)) {
        return ''
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($IdentityFile)
    if ($expanded -eq '~') {
        $expanded = [Environment]::GetFolderPath('UserProfile')
    }
    elseif ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        $expanded = Join-Path ([Environment]::GetFolderPath('UserProfile')) $expanded.Substring(2)
    }
    return [IO.Path]::GetFullPath($expanded).ToUpperInvariant()
}

function Get-TargetConnectionKey {
    param(
        [string]$HostName,
        [string]$UserName
    )

    return "$($HostName.Trim().ToLowerInvariant())|$($UserName.Trim().ToLowerInvariant())"
}

function Test-TargetUsesManagedIdentity {
    param($Target)

    $targetId = [string](Get-ObjectProperty $Target 'id' '')
    $identityFile = [string](Get-ObjectProperty $Target 'identityFile' '')
    if ($targetId -notmatch '^tgt-[0-9a-f]{32}$' -or
        [string]::IsNullOrWhiteSpace($identityFile)) {
        return $false
    }
    try {
        return [string]::Equals(
            (Get-CanonicalIdentityPath $identityFile),
            (Get-CanonicalIdentityPath (Get-ManagedIdentityPath $targetId)),
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
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
        $parsed = Read-Utf8TextFile $Path | ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON configuration '$Path': $($_.Exception.Message)"
    }

    Test-ManagerConfig -ManagerConfig $parsed
    return $parsed
}

function Test-IntegralValue {
    param($Value)

    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) {
        return $false
    }
    if ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]) {
        return $true
    }
    if ($Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
        $number = [double]$Value
        return -not [double]::IsNaN($number) -and
            -not [double]::IsInfinity($number) -and
            [math]::Truncate($number) -eq $number
    }
    return $false
}

function Test-Port {
    param(
        $Port,
        [string]$Label
    )
    if (-not (Test-IntegralValue $Port) -or [decimal]$Port -lt 1 -or [decimal]$Port -gt 65535) {
        throw "$Label must be between 1 and 65535"
    }
}

function Assert-ConfigObjectShape {
    param(
        [AllowNull()]$Object,
        [string]$Label,
        [string[]]$AllowedProperties,
        [string[]]$RequiredProperties = @()
    )

    if ($null -eq $Object -or $Object -is [string] -or
        $Object -is [System.Collections.IList] -or $Object.GetType().IsValueType) {
        throw "$Label must be an object"
    }

    $propertyNames = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($propertyName in $propertyNames) {
        if ($propertyName -notin $AllowedProperties) {
            throw "Unknown property '$propertyName' in $Label"
        }
    }
    foreach ($propertyName in $RequiredProperties) {
        if (-not (Test-ObjectProperty $Object $propertyName)) {
            throw "$Label is missing $propertyName"
        }
    }
}

function Assert-ConfigArray {
    param(
        [AllowNull()]$Value,
        [string]$Label
    )
    if ($null -eq $Value -or $Value -isnot [System.Collections.IList] -or $Value -is [string]) {
        throw "$Label must be an array"
    }
}

function Assert-PlainConfigString {
    param(
        [AllowNull()]$Value,
        [string]$Label,
        [switch]$RejectWhitespace,
        [switch]$RejectAtSign
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or
        $Value -match '[\x00-\x1F\x7F]') {
        throw "$Label is invalid"
    }
    if ($RejectWhitespace -and $Value -match '\s') {
        throw "$Label is invalid"
    }
    if ($RejectAtSign -and $Value.Contains('@')) {
        throw "$Label is invalid"
    }
}

function Assert-ConfigStringArray {
    param(
        [AllowNull()]$Value,
        [string]$Label
    )

    Assert-ConfigArray $Value $Label
    foreach ($entry in @($Value)) {
        if ($entry -isnot [string] -or $entry -notmatch '^[A-Za-z0-9._:/-]+$') {
            throw "Invalid NO_PROXY entry '$entry' in $Label"
        }
    }
}

function Resolve-ConfiguredTarget {
    param(
        $ManagerConfig,
        $Target
    )

    $defaults = $ManagerConfig.defaults
    $targetName = [string]$Target.name
    $targetId = [string](Get-ObjectProperty $Target 'id' (Get-LegacyTargetId $targetName))
    $identityFile = [string](Get-ObjectProperty $Target 'identityFile' $defaults.identityFile)
    [pscustomobject]@{
        id = $targetId
        name = $targetName
        host = [string]$Target.host
        user = [string]$Target.user
        taskName = [string]$Target.taskName
        enabled = [bool](Get-ObjectProperty $Target 'enabled' $true)
        sshPort = [int](Get-ObjectProperty $Target 'sshPort' $defaults.sshPort)
        identityFile = $identityFile
        identityManaged = [bool](Get-ObjectProperty $Target 'identityManaged' (Test-TargetUsesManagedIdentity $Target))
        remoteProxyPort = [int](Get-ObjectProperty $Target 'remoteProxyPort' $defaults.remoteProxyPort)
        noProxyExtra = @((Get-ObjectProperty $Target 'noProxyExtra' $defaults.noProxyExtra))
    }
}

function Test-ManagerConfig {
    param($ManagerConfig)

    Assert-ConfigObjectShape $ManagerConfig 'Configuration' `
        @('$schema', 'version', 'proxy', 'defaults', 'targets') `
        @('version', 'proxy', 'defaults', 'targets')
    if ((Test-ObjectProperty $ManagerConfig '$schema') -and
        $ManagerConfig.'$schema' -isnot [string]) {
        throw 'Configuration $schema must be a string'
    }
    $versionValue = Get-ObjectProperty $ManagerConfig 'version' $null
    if (-not (Test-IntegralValue $versionValue) -or [decimal]$versionValue -ne 1) {
        throw 'Only configuration version 1 is supported'
    }

    Assert-ConfigObjectShape $ManagerConfig.proxy 'proxy' `
        @('localHost', 'localPort') @('localHost', 'localPort')
    Assert-ConfigObjectShape $ManagerConfig.defaults 'defaults' `
        @('sshPort', 'identityFile', 'remoteProxyPort', 'noProxyExtra') `
        @('sshPort', 'identityFile', 'remoteProxyPort', 'noProxyExtra')
    Assert-ConfigArray $ManagerConfig.targets 'targets'

    $localHostValue = Get-ObjectProperty $ManagerConfig.proxy 'localHost' $null
    Assert-PlainConfigString $localHostValue 'proxy.localHost' -RejectWhitespace
    if ($localHostValue.StartsWith('-')) {
        throw 'proxy.localHost is invalid'
    }
    Test-Port (Get-ObjectProperty $ManagerConfig.proxy 'localPort' $null) 'proxy.localPort'
    Test-Port (Get-ObjectProperty $ManagerConfig.defaults 'sshPort' $null) 'defaults.sshPort'
    Test-Port (Get-ObjectProperty $ManagerConfig.defaults 'remoteProxyPort' $null) 'defaults.remoteProxyPort'
    Assert-PlainConfigString $ManagerConfig.defaults.identityFile 'defaults.identityFile'
    Assert-ConfigStringArray $ManagerConfig.defaults.noProxyExtra 'defaults.noProxyExtra'

    $names = @{}
    $taskNames = @{}
    $targetIds = @{}
    $connections = @{}
    $identityPaths = @{}
    foreach ($rawTarget in @($ManagerConfig.targets)) {
        Assert-ConfigObjectShape $rawTarget 'target' `
            @('id', 'name', 'host', 'user', 'taskName', 'enabled', 'sshPort', 'identityFile', 'identityManaged', 'remoteProxyPort', 'noProxyExtra') `
            @('name', 'host', 'user', 'taskName')
        if (Test-ObjectProperty $rawTarget 'id') {
            Assert-TargetId ([string]$rawTarget.id)
        }
        if ((Test-ObjectProperty $rawTarget 'enabled') -and $rawTarget.enabled -isnot [bool]) {
            throw "enabled must be true or false for target $($rawTarget.name)"
        }
        if ((Test-ObjectProperty $rawTarget 'identityManaged') -and
            $rawTarget.identityManaged -isnot [bool]) {
            throw "identityManaged must be true or false for target $($rawTarget.name)"
        }
        if ($rawTarget.name -isnot [string] -or $rawTarget.name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw "Invalid target name: $($rawTarget.name)"
        }
        if ($rawTarget.host -isnot [string] -or [string]::IsNullOrWhiteSpace($rawTarget.host) -or
            $rawTarget.host -match '[\s@\x00-\x1F\x7F]' -or $rawTarget.host.StartsWith('-')) {
            throw "Invalid host for target $($rawTarget.name)"
        }
        if ($rawTarget.user -isnot [string] -or [string]::IsNullOrWhiteSpace($rawTarget.user) -or
            $rawTarget.user -match '[\s@\x00-\x1F\x7F]' -or $rawTarget.user.StartsWith('-')) {
            throw "Invalid user for target $($rawTarget.name)"
        }
        if ($rawTarget.taskName -isnot [string] -or [string]::IsNullOrWhiteSpace($rawTarget.taskName) -or
            $rawTarget.taskName.Length -gt 200 -or $rawTarget.taskName -match '[\x00-\x1F\x7F\\/:*?"<>|]') {
            throw "Invalid scheduled task name for target $($rawTarget.name)"
        }
        if (Test-ObjectProperty $rawTarget 'sshPort') {
            Test-Port $rawTarget.sshPort "sshPort for $($rawTarget.name)"
        }
        if (Test-ObjectProperty $rawTarget 'remoteProxyPort') {
            Test-Port $rawTarget.remoteProxyPort "remoteProxyPort for $($rawTarget.name)"
        }
        if (Test-ObjectProperty $rawTarget 'identityFile') {
            Assert-PlainConfigString $rawTarget.identityFile "identityFile for target $($rawTarget.name)"
        }
        if (Test-ObjectProperty $rawTarget 'noProxyExtra') {
            Assert-ConfigStringArray `
                $rawTarget.noProxyExtra `
                "noProxyExtra for target $($rawTarget.name)"
        }
        $target = Resolve-ConfiguredTarget $ManagerConfig $rawTarget
        if ($names.ContainsKey($target.name)) {
            throw "Duplicate target name: $($target.name)"
        }
        if ($taskNames.ContainsKey($target.taskName)) {
            throw "Duplicate task name: $($target.taskName)"
        }
        if ($targetIds.ContainsKey($target.id)) {
            throw "Duplicate target id: $($target.id)"
        }
        $connectionKey = Get-TargetConnectionKey $target.host $target.user
        if ($connections.ContainsKey($connectionKey)) {
            throw "Duplicate target SSH account: $($target.user)@$($target.host). Use update instead of creating another target."
        }
        $identityKey = Get-CanonicalIdentityPath $target.identityFile
        if ($identityPaths.ContainsKey($identityKey)) {
            throw "Duplicate SSH identity '$($target.identityFile)'. Each target must use a different private key."
        }
        $names[$target.name] = $true
        $taskNames[$target.taskName] = $true
        $targetIds[$target.id] = $true
        $connections[$connectionKey] = $true
        $identityPaths[$identityKey] = $true
    }
}

function Copy-ManagerConfig {
    param($ManagerConfig)

    return ($ManagerConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
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
    $identityProvided = $script:CliParameters.ContainsKey('IdentityFile')
    if ($identityProvided -and [string]::IsNullOrWhiteSpace($IdentityFile)) {
        throw '-IdentityFile cannot be empty'
    }
    $identityValue = if ($identityProvided) {
        $IdentityFile
    }
    elseif ($null -ne $existingResolved) {
        $existingResolved.identityFile
    }
    elseif ($Command -eq 'adopt') {
        $ManagerConfig.defaults.identityFile
    }
    else {
        ''
    }
   $remotePortValue = if ($script:CliParameters.ContainsKey('RemoteProxyPort')) { $RemoteProxyPort } elseif ($null -ne $existingResolved) { $existingResolved.remoteProxyPort } else { [int]$ManagerConfig.defaults.remoteProxyPort }
   $taskValue = if ($script:CliParameters.ContainsKey('TaskName')) { $TaskName } elseif ($null -ne $existingResolved) { $existingResolved.taskName } else { Get-SafeTaskName $Name }
   $noProxyValue = if ($script:CliParameters.ContainsKey('NoProxyExtra')) { @($NoProxyExtra) } elseif ($null -ne $existingResolved) { @($existingResolved.noProxyExtra) } else { @($ManagerConfig.defaults.noProxyExtra) }
   $enabledValue = if ($null -ne $existingResolved) { [bool]$existingResolved.enabled } else { $true }
    $targetIdValue = if ($null -ne $existingResolved -and (Test-ObjectProperty $ExistingTarget 'id') -and -not [string]::IsNullOrWhiteSpace([string]$ExistingTarget.id)) {
        [string]$ExistingTarget.id
    }
    elseif ($script:CliParameters.ContainsKey('TargetId')) {
        [string]$TargetId
    }
    else {
        New-TargetId
    }
    Assert-TargetId $targetIdValue
    if ([string]::IsNullOrWhiteSpace($identityValue)) {
        $identityValue = Get-ManagedIdentityPath $targetIdValue
    }
    $identityManaged = -not $identityProvided -and $null -eq $existingResolved -and $Command -ne 'adopt'
    if ($null -ne $existingResolved) {
        $sameIdentity = [string]::Equals(
            (Get-CanonicalIdentityPath $identityValue),
            (Get-CanonicalIdentityPath $existingResolved.identityFile),
            [StringComparison]::OrdinalIgnoreCase
        )
        $identityManaged = $sameIdentity -and [bool]$existingResolved.identityManaged
    }

   $target = [pscustomobject]@{
        id = $targetIdValue
       name = $Name
       host = $hostValue
       user = $userValue
       taskName = $taskValue
       enabled = $enabledValue
       sshPort = [int]$sshPortValue
       identityFile = $identityValue
        identityManaged = $identityManaged
       remoteProxyPort = [int]$remotePortValue
       noProxyExtra = @($noProxyValue)
   }

    Assert-TargetConnectionAvailable $ManagerConfig $target $ExistingTarget
    Assert-TargetIdentityAvailable $ManagerConfig $target $ExistingTarget

   $testConfig = New-DefaultConfig
   $testConfig.proxy = $ManagerConfig.proxy
   $testConfig.defaults = $ManagerConfig.defaults
   $testConfig.targets = @($target)
   Test-ManagerConfig $testConfig
   return $target
}

function Assert-TargetConnectionAvailable {
    param(
        $ManagerConfig,
        $Target,
        [AllowNull()]$ExistingTarget
    )

    $connectionKey = Get-TargetConnectionKey $Target.host $Target.user
    foreach ($rawTarget in @($ManagerConfig.targets)) {
        $sameTarget = $false
        if ($null -ne $ExistingTarget) {
            $sameTarget = [string]$rawTarget.name -eq [string]$ExistingTarget.name -or
                ((Test-ObjectProperty $rawTarget 'id') -and
                (Test-ObjectProperty $ExistingTarget 'id') -and
                [string]$rawTarget.id -eq [string]$ExistingTarget.id)
        }
        if ($sameTarget) {
            continue
        }
        $candidate = Resolve-ConfiguredTarget $ManagerConfig $rawTarget
        if ((Get-TargetConnectionKey $candidate.host $candidate.user) -eq $connectionKey) {
            throw "Target '$($candidate.name)' already manages SSH account $($candidate.user)@$($candidate.host). SSH port does not create a second target; use update instead."
        }
    }
}

function Assert-TargetIdentityAvailable {
    param(
        $ManagerConfig,
        $Target,
        [AllowNull()]$ExistingTarget
    )

    $identityKey = Get-CanonicalIdentityPath $Target.identityFile
    foreach ($rawTarget in @($ManagerConfig.targets)) {
        $sameTarget = $false
        if ($null -ne $ExistingTarget) {
            $sameTarget = [string]$rawTarget.name -eq [string]$ExistingTarget.name -or
                ((Test-ObjectProperty $rawTarget 'id') -and
                (Test-ObjectProperty $ExistingTarget 'id') -and
                [string]$rawTarget.id -eq [string]$ExistingTarget.id)
        }
        if ($sameTarget) {
            continue
        }
        $candidate = Resolve-ConfiguredTarget $ManagerConfig $rawTarget
        if ((Get-CanonicalIdentityPath $candidate.identityFile) -eq $identityKey) {
            throw "SSH identity '$($Target.identityFile)' is already assigned to target '$($candidate.name)'. Each target must use a different private key."
        }
    }
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

function Assert-GlobalProxyOverrideSafe {
    param(
        $ManagerConfig,
        [int]$MaximumExistingTargets,
        [string]$Operation
    )

    $hostChanges = $script:CliParameters.ContainsKey('LocalProxyHost') -and
        -not [string]::Equals(
            [string]$LocalProxyHost,
            [string]$ManagerConfig.proxy.localHost,
            [StringComparison]::OrdinalIgnoreCase
        )
    $portChanges = $script:CliParameters.ContainsKey('LocalProxyPort') -and
        [int]$LocalProxyPort -ne [int]$ManagerConfig.proxy.localPort
    if (($hostChanges -or $portChanges) -and
        @($ManagerConfig.targets).Count -gt $MaximumExistingTargets) {
        throw "$Operation cannot change the shared local proxy while other targets exist. Run update-all with the proxy options first."
    }
}

function Set-ConfigTarget {
    param(
        $ManagerConfig,
        $Target
    )
    $remaining = @($ManagerConfig.targets | Where-Object {
        $sameId = (Test-ObjectProperty $_ 'id') -and
            [string]$_.id -eq [string](Get-ObjectProperty $Target 'id' '')
        -not $sameId -and $_.name -ne $Target.name
    })
    $ManagerConfig.targets = @($remaining + $Target)
}
