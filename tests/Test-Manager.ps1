$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$manager = Join-Path $repoRoot 'proxy-manager.ps1'
$ui = Join-Path $repoRoot 'proxy-manager-ui.ps1'
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
        $messages = $parseErrors | ForEach-Object { $_.Message }
        throw "PowerShell parse errors in $Path`:`n$($messages -join "`n")"
    }
}

$sourceRoot = Join-Path $repoRoot 'src'
$commonModule = Join-Path $sourceRoot 'Common.ps1'
$managerModuleRoot = Join-Path $sourceRoot 'manager'
$uiModuleRoot = Join-Path $sourceRoot 'ui'
$uiSmoke = Join-Path $PSScriptRoot 'UiSmoke.ps1'
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
$uiModulePaths = @(
    $commonModule,
    (Join-Path $uiModuleRoot 'Bootstrap.ps1'),
    (Join-Path $uiModuleRoot 'Runtime.ps1'),
    (Join-Path $uiModuleRoot 'Health.ps1'),
    (Join-Path $uiModuleRoot 'Recovery.ps1'),
    (Join-Path $uiModuleRoot 'Dialogs.ps1'),
    $uiSmoke
)
foreach ($sourcePath in @($manager, $ui) + $managerModulePaths + $uiModulePaths) {
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Expected PowerShell source file is missing: $sourcePath"
    }
    Assert-PowerShellParses $sourcePath
}
Assert-PowerShellParses $hardeningTest

if ((Get-Content -LiteralPath $manager).Count -ge 300 -or
    (Get-Content -LiteralPath $ui).Count -ge 500) {
    throw 'Public entry scripts have accumulated implementation details again'
}

$uiSmokeOutput = @(& $ui -Config $exampleConfig -SmokeTest)
if ($uiSmokeOutput -notcontains 'UI smoke test passed') {
    throw 'Windows UI smoke test did not complete'
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
    'src/Common.ps1', 'manager/SshBootstrap.ps1', 'manager/TunnelProcess.ps1',
    'manager/Remote.ps1', 'ui/Health.ps1', 'ui/Recovery.ps1', 'tests/Test-Hardening.ps1',
    'tests/test-privacy.sh', 'tests/UiSmoke.ps1'
)) {
    if (-not $architectureSource.Contains($term)) { throw "Architecture guide is missing: $term" }
}
$helpSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $helpDocument
$englishHelpSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $englishHelpDocument
foreach ($term in @('Enable proxy', 'Disable proxy', 'Enabled', 'Advanced...', 'Configure SSH login', 'BLOCKED', 'CHECKING', 'RECOVERING', 'Cancel checks', '1.0.0', 'Open-ProxyManager.vbs')) {
    if (-not $helpSource.Contains($term)) { throw "UI help is missing: $term" }
}


foreach ($term in @('Enable proxy', 'Disable proxy', 'Enabled', 'Advanced...', 'Configure SSH login', 'BLOCKED', 'CHECKING', 'RECOVERING', 'Cancel checks', '1.0.0', 'Open-ProxyManager.vbs')) {
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
        -UiRuntimePath (Join-Path $uiModuleRoot 'Runtime.ps1') `
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


$uiEntrySource = Get-Content -Raw -LiteralPath $ui
$uiBootstrapSource = Get-Content -Raw -LiteralPath (Join-Path $uiModuleRoot 'Bootstrap.ps1')
$uiRuntimeSource = Get-Content -Raw -LiteralPath (Join-Path $uiModuleRoot 'Runtime.ps1')
$uiHealthSource = Get-Content -Raw -LiteralPath (Join-Path $uiModuleRoot 'Health.ps1')
$uiRecoverySource = Get-Content -Raw -LiteralPath (Join-Path $uiModuleRoot 'Recovery.ps1')
$uiDialogsSource = Get-Content -Raw -LiteralPath (Join-Path $uiModuleRoot 'Dialogs.ps1')
$uiSmokeSource = Get-Content -Raw -LiteralPath $uiSmoke
$uiSource = @(
    $uiEntrySource,
    (Get-Content -Raw -LiteralPath $commonModule),
    $uiBootstrapSource,
    $uiRuntimeSource,
    $uiHealthSource,
    $uiRecoverySource,
    $uiDialogsSource,
    $uiSmokeSource
) -join "`n"
if (-not $uiEntrySource.Contains("'src/ui'") -or
    -not $uiEntrySource.Contains("'src/Common.ps1'") -or
    -not $uiEntrySource.Contains("'tests/UiSmoke.ps1'") -or
    -not $uiEntrySource.Contains('[switch]$LauncherSmokeTest')) {
    throw 'UI entry does not load the shared, UI, and smoke-test layers'
}
foreach ($requiredSource in @('Show-HelpDialog', 'Get-PreferredHelpLocale', 'WINDOWS-UI.zh-CN.md', 'WINDOWS-UI.en-US.md', 'SelectedIndexChanged', "New-ActionButton 'Help'", "New-ActionButton 'Proxy access'", "New-ActionButton 'Advanced...'", "'Enable proxy'", "'Disable proxy'", "'Restart proxy'", "'Update required'", "'DISABLED'", "'CHECKING'", "'RECOVERING'", "'BLOCKED'", "'Cancel checks'", 'UTF8Encoding', 'ANSI-CHECK', 'Invoke-SelectedAccessToggle', 'Start-StartupReconciliation', 'Get-TargetRecoveryDecision', 'Complete-StartupReconciliation', 'Detach-StartupReconciliation', 'New-ReconciliationProcessStartInfo', 'Invoke-ManagerJsonCommand', 'Ensure-UiSshKeyAuthentication', 'Invoke-InteractiveManagerCommand', 'Start-BackgroundTargetHealthCheck', 'Complete-BackgroundHealthChecks', 'Stop-BackgroundHealthChecks', 'Stop-BackgroundTargetHealthChecks', 'Stop-BackgroundHealthProcess', 'Stop-ManualHealthChecks', 'New-TargetHealthProcessStartInfo', 'Get-UiScheduledTaskState', 'CreateNoWindow', 'ExpectedEnabled', "-Reason 'manual'", 'taskkill.exe', 'Enter-UiInstanceMutex', 'Exit-UiInstanceMutex', 'DoubleBuffered', 'SuspendLayout', 'Add_CellContentClick', 'Add_FormClosed', "Columns['Enabled'].Index", "Items.Add('Configure SSH login')", "Items.Add('Refresh local status')", "Items.Add('Remove target')", 'Automatically configure SSH key login (recommended)', '$bootstrapBox.Checked = -not $isEdit')) {
    if (-not $uiSource.Contains($requiredSource)) {
        throw "Windows UI feature is missing: $requiredSource"
    }
}
if (-not $uiRecoverySource.Contains("'reconcile'") -or
    -not $uiRecoverySource.Contains('$script:BackgroundReconciliation') -or
    -not $uiRecoverySource.Contains('Detach-StartupReconciliation') -or
    -not $uiRecoverySource.Contains("'Ready', 'Disabled'") -or
    -not $uiRecoverySource.Contains("'Missing' { return 'Reinstall' }") -or
    $uiRecoverySource.Contains('RedirectStandardOutput = $true') -or
    $uiRecoverySource.Contains('RECOVERY_ERROR_BASE64=') -or
    $uiRecoverySource.Contains('Stop-BackgroundHealthProcess') -or
    $uiRecoverySource.Contains('Invoke-ManagerCommand')) {
    throw 'Startup reconciliation is not one state-aware detached background process'
}
foreach ($removedRecoveryMarker in @(
    'BackgroundRecoveries', 'StartupRecoveryAttempt', 'Invoke-StartupRecoveryTick',
    'Start-BackgroundTargetRecovery', 'Stop-BackgroundTargetRecoveries', '-EncodedCommand'
)) {
    if ($uiRecoverySource.Contains($removedRecoveryMarker) -or
        $uiEntrySource.Contains($removedRecoveryMarker)) {
        throw "Removed multi-process recovery machinery is still present: $removedRecoveryMarker"
    }
}
if ($uiSource -notmatch '(?s)function Invoke-SelectedAccessToggle.*?\$command = ''disable''.*?\$command = ''enable''.*?Invoke-ManagerCommand.*?Refresh-TargetGrid.*?Start-BackgroundTargetHealthCheck') {
    throw 'Shared proxy toggle does not implement quick enable and background verification'
}
if (-not $uiSource.Contains("'-WindowStyle', 'Hidden'") -or
    -not $uiSource.Contains('-Verb RunAs -WindowStyle Hidden') -or
    -not $uiSource.Contains('-WindowStyle Normal') -or
    -not $uiEntrySource.Contains('Ensure-UiSshKeyAuthentication $target') -or
    -not $uiRuntimeSource.Contains("-Command 'prepare-ssh'") -or
    -not $uiRuntimeSource.Contains("-Command 'bootstrap-key'") -or
    $uiSource.Contains("Invoke-ManagerCommand 'bootstrap-key'")) {
    throw 'UI console visibility or interactive SSH key routing is incorrect'
}
if (-not $uiSource.Contains("Start-BackgroundTargetHealthCheck `$name `$generation (`$command -eq 'enable')")) {
    throw 'Enable and Disable do not share expected-state background verification'
}
if ($uiSource -notmatch '(?s)\$accessButton\.Add_Click\(\{\s*Invoke-SelectedAccessToggle\s*\}\).*?Add_CellContentClick.*?Invoke-SelectedAccessToggle') {
    throw 'Button and Enabled checkbox do not share the proxy toggle'
}
$manualHealthMatch = [regex]::Match(
    $uiHealthSource,
    '(?s)function Invoke-HealthCheck\s*\{(?<body>.*?)\n\}\s*$'
)
$manualHealthBody = $manualHealthMatch.Groups['body'].Value
if (-not $manualHealthMatch.Success -or
    -not $manualHealthBody.Contains('Start-BackgroundTargetHealthCheck') -or
    -not $manualHealthBody.Contains("-Reason 'manual'") -or
    -not $manualHealthBody.Contains('Stop-ManualHealthChecks') -or
    $manualHealthBody.Contains('Set-Busy') -or
    $manualHealthBody.Contains('& $script:ManagerPath status') -or
    $uiEntrySource -notmatch '(?s)\$removeMenuItem\.Add_Click.*?Reset-TargetHealth.*?Invoke-ManagerCommand ''remove''') {
    throw 'Manual health or target removal does not invalidate stale background results'
}
$accessHandlerMatch = [regex]::Match($uiEntrySource, '(?s)\$accessButton\.Add_Click\(\{(?<body>.*?)\}\)')
if (-not $accessHandlerMatch.Success -or
    $accessHandlerMatch.Groups['body'].Value.Contains('Invoke-HealthCheck') -or
    $uiSource.Contains('Confirm disable') -or $uiSource.Contains('Proxy disabled')) {
    throw 'Enable or disable still repeats health checks or shows normal-operation dialogs'
}
if ($uiSource.Contains('$script:Grid.Rows.Clear()')) {
    throw 'Target refresh still clears the whole grid and may visibly flicker'
}
foreach ($removedUiMarker in @('$startButton', '$stopButton', '$enableButton', '$disableButton', "Invoke-ManagerCommand 'start'", "Invoke-ManagerCommand 'stop'")) {
    if ($uiSource.Contains($removedUiMarker)) {
        throw "Removed UI action is still exposed: $removedUiMarker"
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
    'proxy-manager-ui.ps1',
    '-LauncherSmokeTest',
    '--smoke-test'
)) {
    if (-not $launcherVbsSource.Contains($launcherMarker)) {
        throw "Windowless launcher is missing: $launcherMarker"
    }
}
$denyBoundaryMarker = '`Disable proxy` ' + ([string][char]0x4E0D) + ([string][char]0x662F) +
    ' Linux ' + ([string][char]0x9632) + ([string][char]0x706B) + ([string][char]0x5899)
if (-not $helpSource.Contains($denyBoundaryMarker)) {
    throw 'UI help does not explain the Disable proxy boundary'
}

Write-Host 'PowerShell manager tests passed'
