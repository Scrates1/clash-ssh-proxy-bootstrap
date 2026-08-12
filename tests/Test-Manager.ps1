$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$manager = Join-Path $repoRoot 'proxy-manager.ps1'
$ui = Join-Path $repoRoot 'proxy-manager-ui.ps1'
$exampleConfig = Join-Path $repoRoot 'config.example.json'
$helpDocument = Join-Path $repoRoot 'docs\WINDOWS-UI.zh-CN.md'
$versionFile = Join-Path $repoRoot 'VERSION'
$launcher = Join-Path $repoRoot 'Open-ProxyManager.cmd'

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

Assert-PowerShellParses $manager
Assert-PowerShellParses $ui

$uiSmokeOutput = @(& $ui -Config $exampleConfig -SmokeTest)
if ($uiSmokeOutput -notcontains 'UI smoke test passed') {
    throw 'Windows UI smoke test did not complete'
}

if ((Get-Content -Raw -LiteralPath $versionFile).Trim() -ne '0.2.3') {
    throw 'Unexpected repository version'
}
if (-not (Test-Path -LiteralPath $helpDocument -PathType Leaf)) {
    throw 'Windows UI help document is missing'
}
$helpSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $helpDocument
foreach ($term in @('Enable proxy', 'Disable proxy', 'Advanced...', 'BLOCKED')) {
    if (-not $helpSource.Contains($term)) { throw "UI help is missing: $term" }
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

& $manager validate-config -Config $exampleConfig

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('clash-manager-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
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
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}

$managerSource = Get-Content -Raw -LiteralPath $manager
foreach ($command in @('enable', 'disable')) {
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
    "'-WindowStyle', 'Hidden'",
    'Stop-ManagedTunnelProcesses',
    "'BLOCKED'",
    'UTF8Encoding',
    'previousErrorActionPreference',
    "'LEAK'",
    'function Start-TunnelTask',
    'function Stop-TunnelTask'
)) {
    if (-not $managerSource.Contains($requiredSource)) {
        throw "Manager hardening is missing: $requiredSource"
    }
}

$uiSource = Get-Content -Raw -LiteralPath $ui
foreach ($requiredSource in @('Show-HelpDialog', "New-ActionButton 'Help'", "New-ActionButton 'Proxy access'", "New-ActionButton 'Advanced...'", "'Enable proxy'", "'Disable proxy'", "'DISABLED'", 'UTF8Encoding', 'ANSI-CHECK', 'Proxy access disabled', "Items.Add('Install SSH key')", "Items.Add('Refresh local status')", "Items.Add('Remove target')")) {
    if (-not $uiSource.Contains($requiredSource)) {
        throw "Windows UI feature is missing: $requiredSource"
    }
}
if ($uiSource -notmatch '(?s)\$accessButton\.Add_Click\(\{.*?Invoke-ManagerCommand ''enable''.*?Invoke-ManagerCommand ''disable''.*?Invoke-HealthCheck') {
    throw 'Dynamic proxy button does not implement enable, disable, and health check'
}
foreach ($removedUiMarker in @('$startButton', '$stopButton', '$enableButton', '$disableButton', "Invoke-ManagerCommand 'start'", "Invoke-ManagerCommand 'stop'")) {
    if ($uiSource.Contains($removedUiMarker)) {
        throw "Removed UI action is still exposed: $removedUiMarker"
    }
}

$launcherSource = Get-Content -Raw -LiteralPath $launcher
if (-not $launcherSource.Contains('chcp 65001')) {
    throw 'Windows launcher does not select the UTF-8 code page'
}
$denyBoundaryMarker = '`Disable proxy` ' + ([string][char]0x4E0D) + ([string][char]0x662F) +
    ' Linux ' + ([string][char]0x9632) + ([string][char]0x706B) + ([string][char]0x5899)
if (-not $helpSource.Contains($denyBoundaryMarker)) {
    throw 'UI help does not explain the Disable proxy boundary'
}

Write-Host 'PowerShell manager tests passed'
