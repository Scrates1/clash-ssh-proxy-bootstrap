$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$manager = Join-Path $repoRoot 'proxy-manager.ps1'
$reactHost = Join-Path $repoRoot 'proxy-manager-react-host.ps1'
$exampleConfig = Join-Path $repoRoot 'config.example.json'
$helpDocument = Join-Path $repoRoot 'docs\WINDOWS-UI.zh-CN.md'
$englishHelpDocument = Join-Path $repoRoot 'docs\WINDOWS-UI.en-US.md'
$architectureDocument = Join-Path $repoRoot 'docs\ARCHITECTURE.zh-CN.md'
$versionFile = Join-Path $repoRoot 'VERSION'
$launcherCmd = Join-Path $repoRoot 'Open-ProxyManager.cmd'
$launcherVbs = Join-Path $repoRoot 'Open-ProxyManager.vbs'

function Assert-PowerShellParses {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    if ($parseErrors.Count -gt 0) {
        throw "PowerShell parse errors in $Path"
    }
}

$sourceRoot = Join-Path $repoRoot 'src'
$commonModule = Join-Path $sourceRoot 'Common.ps1'
$managerModuleRoot = Join-Path $sourceRoot 'manager'
$sharedUiModule = Join-Path $sourceRoot 'ui\Bootstrap.ps1'
$hardeningTest = Join-Path $PSScriptRoot 'Test-Hardening.ps1'
$managerModulePaths = @(
    $commonModule,
    (Join-Path $managerModuleRoot 'Config.ps1'),
    (Join-Path $managerModuleRoot 'Transport.ps1'),
    (Join-Path $managerModuleRoot 'SshBootstrap.ps1'),
    (Join-Path $managerModuleRoot 'TunnelProcess.ps1'),
    (Join-Path $managerModuleRoot 'Tunnel.ps1'),
    (Join-Path $managerModuleRoot 'Remote.ps1'),
    (Join-Path $managerModuleRoot 'Operations.ps1')
)
$reactModulePaths = @($commonModule, $sharedUiModule)
foreach ($sourcePath in @($manager, $reactHost) + $managerModulePaths + $reactModulePaths) {
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Expected PowerShell source file is missing: $sourcePath"
    }
    Assert-PowerShellParses $sourcePath
}
Assert-PowerShellParses $hardeningTest

if ((Get-Content -LiteralPath $manager).Count -ge 300 -or
    (Get-Content -LiteralPath $reactHost).Count -ge 500) {
    throw 'Public entry scripts have accumulated implementation details again'
}

$reactSmokeOutput = @(& $reactHost -Config $exampleConfig -SmokeTest)
if ($reactSmokeOutput -notcontains 'React UI smoke test passed') {
    throw 'React UI smoke test did not complete'
}

& cscript.exe //B //Nologo $launcherVbs --smoke-test
if ($LASTEXITCODE -ne 0) {
    throw "Windowless launcher smoke test failed with exit code $LASTEXITCODE"
}

if ((Get-Content -Raw -LiteralPath $versionFile).Trim() -ne '1.0.0') {
    throw 'Unexpected repository version'
}
if (-not (Test-Path -LiteralPath $helpDocument -PathType Leaf)) {
    throw 'Chinese Windows UI help document is missing'
}
if (-not (Test-Path -LiteralPath $englishHelpDocument -PathType Leaf)) {
    throw 'English Windows UI help document is missing'
}
if (-not (Test-Path -LiteralPath $architectureDocument -PathType Leaf)) {
    throw 'Architecture document is missing'
}
$architectureSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $architectureDocument
foreach ($term in @(
    'src/Common.ps1', 'SshBootstrap.ps1', 'TunnelProcess.ps1',
    'Remote.ps1', 'proxy-manager-react-host.ps1', 'web/src',
    'ui/Bootstrap.ps1', 'tests/Test-Hardening.ps1', 'tests/test-privacy.sh'
)) {
    if (-not $architectureSource.Contains($term)) { throw "Architecture guide is missing: $term" }
}
$helpSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $helpDocument
$englishHelpSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $englishHelpDocument
foreach ($term in @('Add target', 'Advanced SSH settings', 'Configure SSH login', 'BLOCKED', 'CHECKING', 'RECOVERING', '1.0.0', 'Open-ProxyManager.vbs')) {
    if (-not $helpSource.Contains($term)) { throw "UI help is missing: $term" }
}
foreach ($term in @('Add target', 'Advanced SSH settings', 'Configure SSH login', 'BLOCKED', 'CHECKING', 'RECOVERING', '1.0.0', 'Open-ProxyManager.vbs')) {
    if (-not $englishHelpSource.Contains($term)) { throw "English UI help is missing: $term" }
}

$config = Get-Content -Raw -LiteralPath $exampleConfig | ConvertFrom-Json
if ($config.version -ne 1) { throw 'Unexpected config version' }
if (@($config.targets).Count -ne 1) { throw 'Example must contain one target' }
if ($config.targets[0].host -ne 'linux.example.com') { throw 'Example contains a non-placeholder host' }
if ($config.targets[0].user -ne 'linuxuser') { throw 'Example contains a non-placeholder user' }
if ($config.targets[0].enabled -ne $true) { throw 'Example target must be enabled' }

$schema = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'config.schema.json') | ConvertFrom-Json
if ($schema.properties.targets.items.properties.enabled.type -ne 'boolean') {
    throw 'Schema is missing the target enabled boolean'
}
foreach ($propertyName in @('host', 'user')) {
    $pattern = [string]$schema.properties.targets.items.properties.$propertyName.pattern
    if ([string]::IsNullOrWhiteSpace($pattern) -or '-option' -match $pattern) {
        throw "Schema does not reject a leading SSH option in target $propertyName"
    }
}

& $manager validate-config -Config $exampleConfig

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('clash-manager-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    & $hardeningTest `
        -ManagerPath $manager `
        -TemporaryRoot $temporaryRoot

    $legacyConfig = Get-Content -Raw -LiteralPath $exampleConfig | ConvertFrom-Json
    $legacyConfig.targets[0].PSObject.Properties.Remove('enabled')
    $legacyPath = Join-Path $temporaryRoot 'legacy.json'
    [IO.File]::WriteAllText($legacyPath, ($legacyConfig | ConvertTo-Json -Depth 8))
    & $manager validate-config -Config $legacyPath

    $emptyConfig = Get-Content -Raw -LiteralPath $exampleConfig | ConvertFrom-Json
    $emptyConfig.targets = @()
    $emptyPath = Join-Path $temporaryRoot 'empty.json'
    [IO.File]::WriteAllText($emptyPath, ($emptyConfig | ConvertTo-Json -Depth 8))
    $statusJson = & $manager status -Config $emptyPath -Json
    if ($statusJson -ne '[]') { throw "Empty JSON status was unexpected: $statusJson" }
    & $manager reconcile -Config $emptyPath *> $null

    $invalidConfig = Get-Content -Raw -LiteralPath $exampleConfig | ConvertFrom-Json
    $invalidConfig.targets[0].enabled = 'yes'
    $invalidPath = Join-Path $temporaryRoot 'invalid-enabled.json'
    [IO.File]::WriteAllText($invalidPath, ($invalidConfig | ConvertTo-Json -Depth 8))
    $invalidRejected = $false
    try {
        & $manager validate-config -Config $invalidPath
    }
    catch {
        $invalidRejected = $true
    }
    if (-not $invalidRejected) { throw 'String enabled value should have been rejected' }

    foreach ($invalidSshField in @('host', 'user')) {
        $invalidSshConfig = Get-Content -Raw -LiteralPath $exampleConfig | ConvertFrom-Json
        $invalidSshConfig.targets[0].$invalidSshField = '-F'
        $invalidSshPath = Join-Path $temporaryRoot "invalid-ssh-$invalidSshField.json"
        [IO.File]::WriteAllText(
            $invalidSshPath,
            ($invalidSshConfig | ConvertTo-Json -Depth 8)
        )
        $invalidSshRejected = $false
        try {
            & $manager validate-config -Config $invalidSshPath
        }
        catch {
            $invalidSshRejected = $_.Exception.Message.Contains("Invalid $invalidSshField")
        }
        if (-not $invalidSshRejected) {
            throw "Leading SSH option was accepted as target $invalidSshField"
        }
    }

    $lockReadyPath = Join-Path $temporaryRoot 'lock-ready.txt'
    $lockPath = Join-Path $temporaryRoot 'lock-target.json'
    $lockPayload = [pscustomobject]@{
        Manager = $manager
        LockPath = $lockPath
        ReadyPath = $lockReadyPath
    } | ConvertTo-Json -Compress
    $lockPayloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lockPayload))
    $lockHolderSource = @"
`$ErrorActionPreference = 'Stop'
`$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$lockPayloadBase64')) | ConvertFrom-Json
. ([string]`$payload.Manager) help *> `$null
`$mutex = Enter-ConfigMutationLock -Path ([string]`$payload.LockPath) -TimeoutMilliseconds 2000
try {
    [IO.File]::WriteAllText([string]`$payload.ReadyPath, 'ready')
    Start-Sleep -Milliseconds 800
}
finally {
    Exit-ConfigMutationLock `$mutex
}
"@
    $lockHolderInfo = New-Object Diagnostics.ProcessStartInfo
    $lockHolderInfo.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
    $lockHolderInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' +
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($lockHolderSource))
    $lockHolderInfo.UseShellExecute = $false
    $lockHolderInfo.CreateNoWindow = $true
    $lockHolderInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $lockHolderInfo.RedirectStandardOutput = $true
    $lockHolderInfo.RedirectStandardError = $true
    $lockHolder = New-Object Diagnostics.Process
    try {
        $lockHolder.StartInfo = $lockHolderInfo
        if (-not $lockHolder.Start()) {
            throw 'Config lock holder did not start'
        }
        $readyDeadline = (Get-Date).AddSeconds(5)
        while (-not (Test-Path -LiteralPath $lockReadyPath -PathType Leaf) -and
            -not $lockHolder.HasExited -and (Get-Date) -lt $readyDeadline) {
            Start-Sleep -Milliseconds 25
        }
        if (-not (Test-Path -LiteralPath $lockReadyPath -PathType Leaf)) {
            $holderError = $lockHolder.StandardError.ReadToEnd()
            throw "Config lock holder was not ready: $holderError"
        }

        $contentionRejected = & {
            param($ManagerPath, $ConfigPath)
            . $ManagerPath help *> $null
            $contendingMutex = $null
            try {
                $contendingMutex = Enter-ConfigMutationLock `
                    -Path $ConfigPath `
                    -TimeoutMilliseconds 100
                return $false
            }
            catch {
                return $_.Exception.Message.Contains('Another proxy-manager process')
            }
            finally {
                if ($null -ne $contendingMutex) {
                    Exit-ConfigMutationLock $contendingMutex
                }
            }
        } $manager $lockPath
        if (-not $contentionRejected) {
            throw 'Config mutation lock did not reject cross-process contention'
        }
        if (-not $lockHolder.WaitForExit(5000) -or $lockHolder.ExitCode -ne 0) {
            throw "Config lock holder failed: $($lockHolder.StandardError.ReadToEnd())"
        }

        $lockReusable = & {
            param($ManagerPath, $ConfigPath)
            . $ManagerPath help *> $null
            $mutex = Enter-ConfigMutationLock -Path $ConfigPath -TimeoutMilliseconds 1000
            try {
                return $null -ne $mutex
            }
            finally {
                Exit-ConfigMutationLock $mutex
            }
        } $manager $lockPath
        if (-not $lockReusable) {
            throw 'Config mutation lock was not reusable after release'
        }
    }
    finally {
        try {
            if (-not $lockHolder.HasExited) {
                $lockHolder.Kill()
                [void]$lockHolder.WaitForExit(2000)
            }
        }
        catch {}
        $lockHolder.Dispose()
    }

    $sshIdentityResult = & {
        param($ManagerPath, $TemporaryRoot)
        . $ManagerPath help *> $null

        foreach ($invalidDestinationField in @('host', 'user')) {
            $invalidDestination = [pscustomobject]@{
                host = 'example.invalid'
                user = 'test-user'
            }
            $invalidDestination.$invalidDestinationField = '-F'
            $destinationRejected = $false
            try {
                [void](Get-SshDestination $invalidDestination)
            }
            catch {
                $destinationRejected = $_.Exception.Message.Contains('is invalid')
            }
            if (-not $destinationRejected) {
                throw "Direct SSH destination accepted leading option in $invalidDestinationField"
            }
        }

        $identityPath = Join-Path $TemporaryRoot 'ssh identity with spaces\id ed25519'
        $target = [pscustomobject]@{
            name = 'ssh-identity-test'
            host = 'example.invalid'
            user = 'test-user'
            sshPort = 22
            identityFile = $identityPath
        }

        $missingRejected = $false
        try {
            [void](Initialize-SshIdentity $target)
        }
        catch {
            $missingRejected = $_.Exception.Message.Contains('SSH identity file not found')
        }
        if (-not $missingRejected) {
            throw 'Missing SSH identity was not rejected without creation permission'
        }

        $first = Initialize-SshIdentity $target -CreateIfMissing
        if (-not $first.IdentityCreated -or
            -not (Test-Path -LiteralPath $identityPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath "$identityPath.pub" -PathType Leaf) -or
            $first.PublicKey -notmatch '^ssh-ed25519\s+') {
            throw 'Missing Ed25519 identity was not created correctly'
        }
        $privateHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $identityPath).Hash

        $second = Initialize-SshIdentity $target -CreateIfMissing
        if ($second.IdentityCreated -or $second.PublicKeyUpdated -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $identityPath).Hash -ne $privateHash) {
            throw 'Existing SSH identity preparation was not idempotent'
        }

        [IO.File]::WriteAllText("$identityPath.pub", 'ssh-ed25519 stale-value stale')
        $third = Initialize-SshIdentity $target -CreateIfMissing
        $expectedKeyMaterial = @($first.PublicKey -split '\s+')[1]
        if (-not $third.PublicKeyUpdated -or
            -not (Get-Content -Raw -LiteralPath "$identityPath.pub").Contains($expectedKeyMaterial)) {
            throw 'Stale SSH public-key file was not rebuilt from the private key'
        }

        $publicKeySentinel = Join-Path $TemporaryRoot 'public-key-hardlink-sentinel.txt'
        [IO.File]::WriteAllText($publicKeySentinel, 'hardlink-sentinel')
        Remove-Item -LiteralPath "$identityPath.pub" -Force
        New-Item -ItemType HardLink -Path "$identityPath.pub" -Target $publicKeySentinel | Out-Null
        $hardLinkRepair = Initialize-SshIdentity $target -CreateIfMissing
        if (-not $hardLinkRepair.PublicKeyUpdated -or
            (Get-Content -Raw -LiteralPath $publicKeySentinel) -ne 'hardlink-sentinel' -or
            -not (Get-Content -Raw -LiteralPath "$identityPath.pub").Contains($expectedKeyMaterial)) {
            throw 'SSH public-key repair modified a hard-linked source file'
        }

        $encryptedIdentityPath = Join-Path $TemporaryRoot 'encrypted identity\id ed25519'
        New-Item -ItemType Directory -Path (Split-Path -Parent $encryptedIdentityPath) | Out-Null
        [void](Invoke-SshKeygen `
            -ArgumentList @(
                '-q', '-t', 'ed25519', '-N', 'test-only-passphrase',
                '-C', 'encrypted-regression', '-f', $encryptedIdentityPath
            ) `
            -Description 'Create encrypted test SSH identity')
        $encryptedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $encryptedIdentityPath).Hash
        $encryptedTarget = [pscustomobject]@{
            name = 'encrypted-identity-test'
            host = 'example.invalid'
            user = 'test-user'
            sshPort = 22
            identityFile = $encryptedIdentityPath
        }
        $encryptedTimer = [Diagnostics.Stopwatch]::StartNew()
        $encryptedRejected = $false
        try {
            [void](Initialize-SshIdentity $encryptedTarget -CreateIfMissing)
        }
        catch {
            $encryptedRejected = $_.Exception.Message.Contains('without a passphrase')
        }
        $encryptedTimer.Stop()
        if (-not $encryptedRejected -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $encryptedIdentityPath).Hash -ne $encryptedHash -or
            $encryptedTimer.ElapsedMilliseconds -ge 16000) {
            throw 'Encrypted SSH identity was not rejected quickly and without modification'
        }

        $originalRemoteConnection = (Get-Command Test-RemoteConnection).ScriptBlock
        $originalNativeCommand = (Get-Command Invoke-NativeChecked).ScriptBlock
        $safeAuthorizedKeysAppend = $false
        try {
            Set-Item -Path Function:Test-RemoteConnection -Value { param($Target) return $true }
            Set-Item -Path Function:Invoke-NativeChecked -Value { throw 'Interactive SSH should have been skipped' }
            $ready = Get-SshReadiness $target
            if (-not $ready.Ready -or $ready.InteractionRequired) {
                throw 'Ready SSH authentication was not detected'
            }
            Install-PublicKey $target *> $null

            Set-Item -Path Function:Test-RemoteConnection -Value { param($Target) return $false }
            $pending = Get-SshReadiness $target
            if ($pending.Ready -or -not $pending.InteractionRequired) {
                throw 'Missing remote public key did not request interaction'
            }

            $script:SshInstallProbeCalls = 0
            $script:CapturedSshInstallCommand = $null
            $script:CapturedSshInstallArguments = @()
            Set-Item -Path Function:Test-RemoteConnection -Value {
                param($Target)
                $script:SshInstallProbeCalls++
                return $script:SshInstallProbeCalls -ge 2
            }
            Set-Item -Path Function:Invoke-NativeChecked -Value {
                param(
                    [string]$FilePath,
                    [string[]]$ArgumentList,
                    [string]$Description
                )
                $script:CapturedSshInstallArguments = @($ArgumentList)
                $script:CapturedSshInstallCommand = $ArgumentList[$ArgumentList.Count - 1]
            }
            Install-PublicKey $target *> $null
            $safeAuthorizedKeysAppend =
                $script:SshInstallProbeCalls -eq 2 -and
                $script:CapturedSshInstallArguments -contains 'BatchMode=no' -and
                $script:CapturedSshInstallArguments -contains 'ConnectTimeout=8' -and
                [string]$script:CapturedSshInstallCommand -match
                    'awk -v key_type=.*\|\| \{ \[ ! -s .*authorized_keys.*printf ''\\n'''
            if (-not $safeAuthorizedKeysAppend) {
                throw 'Public-key installation does not protect a missing authorized_keys newline'
            }
        }
        finally {
            Set-Item -Path Function:Test-RemoteConnection -Value $originalRemoteConnection
            Set-Item -Path Function:Invoke-NativeChecked -Value $originalNativeCommand
        }

        $failedIdentityPath = Join-Path $TemporaryRoot 'ssh-failure\id_ed25519'
        $failedParent = Split-Path -Parent $failedIdentityPath
        New-Item -ItemType Directory -Path $failedParent | Out-Null
        $existingPublicKeyPath = "$failedIdentityPath.pub"
        [IO.File]::WriteAllText($existingPublicKeyPath, 'pre-existing-public-key')
        $failedTarget = [pscustomobject]@{
            name = 'ssh-failure-test'
            host = 'example.invalid'
            user = 'test-user'
            sshPort = 22
            identityFile = $failedIdentityPath
        }
        $orphanPublicKeyRejected = $false
        try {
            [void](Initialize-SshIdentity $failedTarget -CreateIfMissing)
        }
        catch {
            $orphanPublicKeyRejected = $_.Exception.Message.Contains(
                'private key is missing but its public-key file already exists'
            )
        }
        if (-not $orphanPublicKeyRejected -or
            (Test-Path -LiteralPath $failedIdentityPath -PathType Leaf) -or
            (Get-Content -Raw -LiteralPath $existingPublicKeyPath) -ne 'pre-existing-public-key') {
            throw 'Orphaned public-key protection did not preserve the existing file'
        }

        $generationFailurePath = Join-Path $TemporaryRoot 'ssh-generation-failure\id_ed25519'
        $generationFailureTarget = [pscustomobject]@{
            name = 'ssh-generation-failure-test'
            host = 'example.invalid'
            user = 'test-user'
            sshPort = 22
            identityFile = $generationFailurePath
        }
        $originalSshKeygen = (Get-Command Invoke-SshKeygen).ScriptBlock
        $generationFailureObserved = $false
        try {
            Set-Item -Path Function:Invoke-SshKeygen -Value {
                param([string[]]$ArgumentList, [string]$Description)
                $requestedPath = $ArgumentList[$ArgumentList.Count - 1]
                New-Item -ItemType Directory -Path (Split-Path -Parent $requestedPath) -Force | Out-Null
                [IO.File]::WriteAllText($requestedPath, 'partial-private-key')
                [IO.File]::WriteAllText("$requestedPath.pub", 'partial-public-key')
                throw 'simulated ssh-keygen failure'
            }
            [void](Initialize-SshIdentity $generationFailureTarget -CreateIfMissing)
        }
        catch {
            $generationFailureObserved = $_.Exception.Message.Contains('simulated ssh-keygen failure')
        }
        finally {
            Set-Item -Path Function:Invoke-SshKeygen -Value $originalSshKeygen
        }
        if (-not $generationFailureObserved -or
            (Test-Path -LiteralPath $generationFailurePath) -or
            (Test-Path -LiteralPath "$generationFailurePath.pub") -or
            @(Get-ChildItem -LiteralPath (Split-Path -Parent $generationFailurePath) -Force |
                Where-Object { $_.Name -like '*.clash-ssh-proxy.*.tmp*' }).Count -gt 0) {
            throw 'Failed SSH identity generation left partial key files behind'
        }

        $publicWriteFailurePath = Join-Path $TemporaryRoot 'ssh-public-write-failure\id_ed25519'
        $publicWriteFailureTarget = [pscustomobject]@{
            name = 'ssh-public-write-failure-test'
            host = 'example.invalid'
            user = 'test-user'
            sshPort = 22
            identityFile = $publicWriteFailurePath
        }
        $originalPublicKeyWriter = (Get-Command Write-SshPublicKeyFile).ScriptBlock
        $publicWriteFailureObserved = $false
        try {
            Set-Item -Path Function:Write-SshPublicKeyFile -Value {
                throw 'simulated public-key write failure'
            }
            [void](Initialize-SshIdentity $publicWriteFailureTarget -CreateIfMissing)
        }
        catch {
            $publicWriteFailureObserved = $_.Exception.Message.Contains(
                'simulated public-key write failure'
            )
        }
        finally {
            Set-Item -Path Function:Write-SshPublicKeyFile -Value $originalPublicKeyWriter
        }
        if (-not $publicWriteFailureObserved -or
            -not (Test-Path -LiteralPath $publicWriteFailurePath -PathType Leaf) -or
            (Test-Path -LiteralPath "$publicWriteFailurePath.pub")) {
            throw 'Public-key write failure did not preserve the installed private key'
        }
        $preservedPrivateHash = (
            Get-FileHash -Algorithm SHA256 -LiteralPath $publicWriteFailurePath
        ).Hash
        $publicWriteRecovery = Initialize-SshIdentity `
            $publicWriteFailureTarget `
            -CreateIfMissing
        if ($publicWriteRecovery.IdentityCreated -or
            -not $publicWriteRecovery.PublicKeyUpdated -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $publicWriteFailurePath).Hash -ne
                $preservedPrivateHash) {
            throw 'Private key was not reused when recovering its public-key file'
        }

        $raceIdentityPath = Join-Path $TemporaryRoot 'ssh-race\id_ed25519'
        $raceTarget = [pscustomobject]@{
            name = 'ssh-race-test'
            host = 'example.invalid'
            user = 'test-user'
            sshPort = 22
            identityFile = $raceIdentityPath
        }
        $script:SshRaceIdentityPath = $raceIdentityPath
        $originalSshKeygen = (Get-Command Invoke-SshKeygen).ScriptBlock
        $raceRejected = $false
        try {
            Set-Item -Path Function:Invoke-SshKeygen -Value {
                param([string[]]$ArgumentList, [string]$Description)
                $requestedPath = $ArgumentList[$ArgumentList.Count - 1]
                if ($Description -eq 'Create SSH identity') {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $requestedPath) -Force | Out-Null
                    [IO.File]::WriteAllText($requestedPath, 'temporary-private-key')
                    [IO.File]::WriteAllText("$requestedPath.pub", 'temporary-public-key')
                    return ''
                }
                if ($Description -eq 'Verify new SSH identity') {
                    [IO.File]::WriteAllText($script:SshRaceIdentityPath, 'concurrent-private-key')
                    [IO.File]::WriteAllText("$($script:SshRaceIdentityPath).pub", 'concurrent-public-key')
                    return 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREVIEW race-test'
                }
                throw "Unexpected ssh-keygen description: $Description"
            }
            [void](Initialize-SshIdentity $raceTarget -CreateIfMissing)
        }
        catch {
            $raceRejected = $_.Exception.Message.Contains('path changed while it was being created')
        }
        finally {
            Set-Item -Path Function:Invoke-SshKeygen -Value $originalSshKeygen
        }
        $raceParent = Split-Path -Parent $raceIdentityPath
        if (-not $raceRejected -or
            (Get-Content -Raw -LiteralPath $raceIdentityPath) -ne 'concurrent-private-key' -or
            (Get-Content -Raw -LiteralPath "$raceIdentityPath.pub") -ne 'concurrent-public-key' -or
            @(Get-ChildItem -LiteralPath $raceParent -Force |
                Where-Object { $_.Name -like '*.clash-ssh-proxy.*.tmp*' }).Count -gt 0) {
            throw 'Concurrent SSH identity creation was not preserved safely'
        }

        return [pscustomobject]@{
            IdentityCreated = [bool]$first.IdentityCreated
            ExistingIdentityReused = -not [bool]$second.IdentityCreated
            PublicKeyRepaired = [bool]$third.PublicKeyUpdated
            InteractionRequested = [bool]$pending.InteractionRequired
            EncryptedIdentityRejected = [bool]$encryptedRejected
            SafeAuthorizedKeysAppend = [bool]$safeAuthorizedKeysAppend
            FailurePreservedPublicKey = [bool]$orphanPublicKeyRejected
            FailureCleanedPartialFiles = [bool]$generationFailureObserved
            PublicWriteFailureRecovered = [bool]$publicWriteFailureObserved
            ConcurrentIdentityPreserved = [bool]$raceRejected
        }
    } $manager $temporaryRoot
    if (-not $sshIdentityResult.IdentityCreated -or
        -not $sshIdentityResult.ExistingIdentityReused -or
        -not $sshIdentityResult.PublicKeyRepaired -or
        -not $sshIdentityResult.InteractionRequested -or
        -not $sshIdentityResult.EncryptedIdentityRejected -or
        -not $sshIdentityResult.SafeAuthorizedKeysAppend -or
        -not $sshIdentityResult.FailurePreservedPublicKey -or
        -not $sshIdentityResult.FailureCleanedPartialFiles -or
        -not $sshIdentityResult.PublicWriteFailureRecovered -or
        -not $sshIdentityResult.ConcurrentIdentityPreserved) {
        throw 'SSH identity integration result was incomplete'
    }
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}

$managerEntrySource = Get-Content -Raw -LiteralPath $manager
$managerConfigSource = Get-Content -Raw -LiteralPath (Join-Path $managerModuleRoot 'Config.ps1')
$managerTransportSource = Get-Content -Raw -LiteralPath (Join-Path $managerModuleRoot 'Transport.ps1')
$managerSshBootstrapSource = Get-Content -Raw -LiteralPath (Join-Path $managerModuleRoot 'SshBootstrap.ps1')
$managerTunnelProcessSource = Get-Content -Raw -LiteralPath (Join-Path $managerModuleRoot 'TunnelProcess.ps1')
$managerTunnelSource = Get-Content -Raw -LiteralPath (Join-Path $managerModuleRoot 'Tunnel.ps1')
$managerRemoteSource = Get-Content -Raw -LiteralPath (Join-Path $managerModuleRoot 'Remote.ps1')
$managerOperationsSource = Get-Content -Raw -LiteralPath (Join-Path $managerModuleRoot 'Operations.ps1')
$managerSource = @(
    $managerEntrySource,
    (Get-Content -Raw -LiteralPath $commonModule),
    $managerConfigSource,
    $managerTransportSource,
    $managerSshBootstrapSource,
    $managerTunnelProcessSource,
    $managerTunnelSource,
    $managerRemoteSource,
    $managerOperationsSource
) -join "`n"
if (-not $managerEntrySource.Contains("'src/manager'") -or
    -not $managerEntrySource.Contains("'src/Common.ps1'")) {
    throw 'CLI entry does not load the shared and manager module layers'
}
foreach ($command in @('enable', 'disable', 'reconcile')) {
    if ($managerSource -notmatch [regex]::Escape("'$command'")) {
        throw "Manager command is missing: $command"
    }
}

foreach ($removedCommand in @('start', 'stop')) {
    if ($managerSource.Contains("'$removedCommand'")) {
        throw "Removed public command is still exposed: $removedCommand"
    }
}

foreach ($requiredSource in @(
    'function Invoke-RemoteProbe',
    'function Initialize-SshIdentity',
    'function ConvertTo-NormalizedSshPublicKey',
    'function Write-SshPublicKeyFile',
    'function Get-SshReadiness',
    'function Install-PublicKey',
    'RedirectStandardInput',
    'WaitForExit(15000)',
    '[IO.File]::Move($temporaryIdentityPath, $identityPath)',
    'Move-Item -LiteralPath $temporaryPath -Destination $Path -Force',
    'awk -v key_type=',
    '[ ! -s `"`$HOME/.ssh/authorized_keys`" ]',
    "'ConnectTimeout=8'",
    'function Get-RemoteTunnelState',
    'Remote proxy closure verification is pending',
    'function Write-TunnelLauncher',
    'function Remove-TunnelLauncher',
    'function Assert-SecureLauncherDirectory',
    'function Initialize-SecureLauncherDirectory',
    "Join-Path `$env:ProgramData 'ClashSshProxy\tasks'",
    "'/inheritance:r'",
    "'/setowner'",
    'AreAccessRulesProtected',
    '[IO.FileAttributes]::ReparsePoint',
    'wscript.exe',
    "'//B', '//Nologo'",
    'Stop-ManagedTunnelProcesses',
    "'BLOCKED'",
    'UTF8Encoding',
    'previousErrorActionPreference',
    "'LEAK'",
    'function Start-TunnelTask',
    'function Stop-TunnelTask',
    'function Get-RegisteredTaskFast',
    "New-Object -ComObject 'Schedule.Service'",
    'function Wait-ManagedTunnelProcess',
    'function Test-TunnelTaskOwnedByTarget',
    'function Test-RegisteredTunnelTaskOwnedByTarget',
    '[Diagnostics.Stopwatch]::StartNew()',
    '$QuietPeriodMilliseconds',
    '[void]$task.Stop(0)',
    'function Invoke-RemoteProxyProbe',
    'function Test-RemoteManagedInstallation',
    'Invoke-RemoteProxyProbe $target',
    "[guid]::NewGuid().ToString('N')",
    'DurationMs',
    'CheckedAt',
    'function Get-ConfigMutationLockName',
    ".StartsWith('-')",
    'function Enter-ConfigMutationLock',
    'function Exit-ConfigMutationLock',
    '$configMutationLock = Enter-ConfigMutationLock -Path $Config',
    'function Wait-LocalProxyForReconciliation',
    'function Invoke-EnabledTargetReconciliation',
    'Invoke-EnabledTargetReconciliation -ConfigPath $Config',
    'Show-Status $managerConfig -TargetName $Name'
)) {
    if (-not $managerSource.Contains($requiredSource)) {
        throw "Manager hardening is missing: $requiredSource"
    }
}
foreach ($healthEndpoint in @(
    'https://www.gstatic.com/generate_204',
    'https://cp.cloudflare.com/generate_204',
    'https://www.google.com/generate_204'
)) {
    if (-not $managerSource.Contains($healthEndpoint)) {
        throw "Manager proxy health fallback is missing: $healthEndpoint"
    }
}
$startTunnelMatch = [regex]::Match(
    $managerTunnelSource,
    '(?s)function Start-TunnelTask\s*\{(?<body>.*?)\n\}\s*$'
)
$startTunnelFastPath = @($startTunnelMatch.Groups['body'].Value -split '\n\s*catch\s*\{')[0]
if (-not $startTunnelMatch.Success -or
    -not $startTunnelFastPath.Contains('Wait-ManagedTunnelProcess') -or
    -not $managerTunnelProcessSource.Contains('[int]$TimeoutSeconds = 7') -or
    $startTunnelFastPath.Contains('Wait-RemoteProxy') -or
    $startTunnelFastPath.Contains('Get-ScheduledTask')) {
    throw 'Enable does not use bounded local startup before background verification'
}
$stopTunnelMatch = [regex]::Match(
    $managerTunnelSource,
    '(?s)function Stop-TunnelTask\s*\{(?<body>.*?)\n\}\s*\n\s*function Start-TunnelTask'
)
$stopTunnelBody = $stopTunnelMatch.Groups['body'].Value
if (-not $stopTunnelMatch.Success -or
    -not $stopTunnelBody.Contains('Get-RegisteredTaskFast') -or
    -not $stopTunnelBody.Contains('$task.Enabled = $false') -or
    -not $stopTunnelBody.Contains('[void]$task.Stop(0)') -or
    $stopTunnelBody.Contains('Get-ScheduledTask') -or
    $stopTunnelBody.Contains('Stop-ScheduledTask') -or
    $stopTunnelBody.Contains('Wait-Remote')) {
    throw 'Disable does not use the fast local Task Scheduler stop path'
}
$disableCommandMatch = [regex]::Match(
    $managerEntrySource,
    "(?s)'disable'\s*\{(?<body>.*?)\n\s*\}\s*\n\s*'update'"
)
$disableCommandBody = $disableCommandMatch.Groups['body'].Value
if (-not $disableCommandMatch.Success -or
    -not $disableCommandBody.Contains('Stop-TunnelTask') -or
    -not $disableCommandBody.Contains('Save-ManagerConfig') -or
    $disableCommandBody.Contains('RemoteTunnelState') -or
    $disableCommandBody.Contains('Test-Remote')) {
    throw 'Disable still waits for remote verification before returning'
}
$statusMatch = [regex]::Match(
    $managerOperationsSource,
    '(?s)function Get-TargetStatus\s*\{(?<body>.*?)\n\}\s*\n\s*function Show-Status'
)
$statusBody = $statusMatch.Groups['body'].Value
if (-not $statusMatch.Success -or
    -not $statusBody.Contains('Invoke-RemoteProxyProbe $target') -or
    $statusBody.Contains('Test-RemoteProxy $target') -or
    -not $statusBody.Contains('$sshOk = $proxyExitCode -ne 255') -or
    -not $statusBody.Contains('DurationMs') -or
    -not $statusBody.Contains('CheckedAt')) {
    throw 'Enabled status does not use one SSH proxy probe with timing metadata'
}
$mutationWrapperMatch = [regex]::Match(
    $managerEntrySource,
    '(?s)\$configMutationLock = \$null.*?Enter-ConfigMutationLock.*?switch \(\$Command\).*?finally.*?Exit-ConfigMutationLock'
)
$requiredMutationCommands = @(
    'add', 'adopt', 'prepare-ssh', 'bootstrap-key', 'enable', 'disable',
    'update', 'update-all', 'install-all', 'remove'
)
$mutationCommandMatch = [regex]::Match(
    $managerEntrySource,
    '(?s)if \(\$Command -in @\((?<commands>.*?)\)\)'
)
$missingMutationCommands = @($requiredMutationCommands | Where-Object {
    -not $mutationCommandMatch.Groups['commands'].Value.Contains("'$_'")
})
if (-not $mutationWrapperMatch.Success -or
    -not $mutationCommandMatch.Success -or
    $missingMutationCommands.Count -gt 0 -or
    -not $managerConfigSource.Contains('Remove-Item -LiteralPath $temporaryPath -Force')) {
    throw 'Configuration mutations are not serialized across the complete transaction'
}
if (-not $managerOperationsSource.Contains('Wait-LocalProxyForReconciliation') -or
    -not $managerOperationsSource.Contains('Enter-ConfigMutationLock -Path $ConfigPath') -or
    -not $managerOperationsSource.Contains('Read-ManagerConfig -Path $ConfigPath') -or
    -not $managerOperationsSource.Contains("{ `$_ -in @('Ready', 'Disabled') }") -or
    $managerOperationsSource -match '(?s)function Invoke-EnabledTargetReconciliation.*?Start-Process') {
    throw 'Reconciliation is not one bounded sequential manager operation with per-target locking'
}
if ($managerTunnelSource.Contains('Get-TunnelLauncherStatusPath') -or
    $managerTunnelSource.Contains('Scripting.FileSystemObject') -or
    $managerTunnelSource.Contains('.vbs.status')) {
    throw 'Unused launcher sidecar status handling is still present'
}
if ($managerEntrySource.Contains('@($completedInstalls)')) {
    throw 'update-all rollback uses an incompatible generic-list array conversion'
}
foreach ($removedManagerMarker in @('ConvertTo-PowerShellLiteral', "'-WindowStyle', 'Hidden'", 'Get-Command powershell.exe')) {
    if ($managerSource.Contains($removedManagerMarker)) {
        throw "Removed console launcher is still present: $removedManagerMarker"
    }
}


$reactHostSource = Get-Content -Raw -LiteralPath $reactHost
if (-not $reactHostSource.Contains("'src/ui/Bootstrap.ps1'") -or
    -not $reactHostSource.Contains('web/dist') -or
    -not $reactHostSource.Contains('Start-Listener') -or
    -not $reactHostSource.Contains('Enter-UiInstanceMutex') -or
    -not $reactHostSource.Contains('SmokeTest')) {
    throw 'React host is missing the local bridge, single-instance, or smoke-test behavior'
}
foreach ($interactiveConsoleMarker in @(
    "'-EncodedCommand'",
    '-Verb Open',
    '[Console]::IsInputRedirected',
    "Read-Host 'Press Enter to close this window'"
)) {
    if (-not $reactHostSource.Contains($interactiveConsoleMarker)) {
        throw "Interactive SSH console is missing: $interactiveConsoleMarker"
    }
}

$launcherCmdSource = Get-Content -Raw -LiteralPath $launcherCmd
$launcherVbsSource = Get-Content -Raw -LiteralPath $launcherVbs
if (-not $launcherCmdSource.Contains('wscript.exe') -or
    -not $launcherCmdSource.Contains('Open-ProxyManager.vbs') -or
    $launcherCmdSource.Contains('powershell.exe')) {
    throw 'CMD compatibility launcher does not immediately hand off to WScript'
}
foreach ($launcherMarker in @(
    'shell.Run(commandLine, 0, waitForExit)',
    '-WindowStyle Hidden',
    'proxy-manager-react-host.ps1',
    '-SmokeTest',
    '--smoke-test'
)) {
    if (-not $launcherVbsSource.Contains($launcherMarker)) {
        throw "React launcher is missing: $launcherMarker"
    }
}

$denyBoundaryMarker = '`Disable proxy` ' + ([string][char]0x4E0D) + ([string][char]0x662F) +
    ' Linux ' + ([string][char]0x9632) + ([string][char]0x706B) + ([string][char]0x5899)
if (-not $helpSource.Contains($denyBoundaryMarker)) {
    throw 'UI help does not explain the Disable proxy boundary'
}

Write-Host 'PowerShell manager tests passed'
