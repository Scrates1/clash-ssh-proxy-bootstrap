$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$manager = Join-Path $repoRoot 'proxy-manager.ps1'
$ui = Join-Path $repoRoot 'proxy-manager-ui.ps1'
$exampleConfig = Join-Path $repoRoot 'config.example.json'
$helpDocument = Join-Path $repoRoot 'docs\WINDOWS-UI.zh-CN.md'
$versionFile = Join-Path $repoRoot 'VERSION'

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

if ((Get-Content -Raw -LiteralPath $versionFile).Trim() -ne '0.2.1') {
    throw 'Unexpected repository version'
}
if (-not (Test-Path -LiteralPath $helpDocument -PathType Leaf)) {
    throw 'Windows UI help document is missing'
}
$helpSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $helpDocument
foreach ($term in @('Start', 'Deny', 'BLOCKED')) {
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
foreach ($command in @('enable', 'disable', 'start', 'stop')) {
    if ($managerSource -notmatch [regex]::Escape("'$command'")) {
        throw "Manager command is missing: $command"
    }
}

foreach ($requiredSource in @(
    "'-WindowStyle', 'Hidden'",
    'Stop-ManagedTunnelProcesses',
    "'BLOCKED'",
    "'LEAK'"
)) {
    if (-not $managerSource.Contains($requiredSource)) {
        throw "Manager hardening is missing: $requiredSource"
    }
}

$uiSource = Get-Content -Raw -LiteralPath $ui
foreach ($requiredSource in @('Show-HelpDialog', "New-ActionButton 'Help'", "'DENIED'")) {
    if (-not $uiSource.Contains($requiredSource)) {
        throw "Windows UI feature is missing: $requiredSource"
    }
}

Write-Host 'PowerShell manager tests passed'
