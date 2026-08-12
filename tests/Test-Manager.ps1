$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$manager = Join-Path $repoRoot 'proxy-manager.ps1'
$ui = Join-Path $repoRoot 'proxy-manager-ui.ps1'
$exampleConfig = Join-Path $repoRoot 'config.example.json'
$helpDocument = Join-Path $repoRoot 'docs\WINDOWS-UI.zh-CN.md'
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

Assert-PowerShellParses $manager
Assert-PowerShellParses $ui

$uiSmokeOutput = @(& $ui -Config $exampleConfig -SmokeTest)
if ($uiSmokeOutput -notcontains 'UI smoke test passed') {
    throw 'Windows UI smoke test did not complete'
}

& cscript.exe //B //Nologo $launcherVbs --smoke-test
if ($LASTEXITCODE -ne 0) {
    throw "Windowless launcher smoke test failed with exit code $LASTEXITCODE"
}

if ((Get-Content -Raw -LiteralPath $versionFile).Trim() -ne '0.2.7') {
    throw 'Unexpected repository version'
}
if (-not (Test-Path -LiteralPath $helpDocument -PathType Leaf)) {
    throw 'Windows UI help document is missing'
}
$helpSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $helpDocument
foreach ($term in @('Enable proxy', 'Disable proxy', 'Enabled', 'Advanced...', 'BLOCKED', 'CHECKING', '0.2.7', 'Open-ProxyManager.vbs')) {
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
    'function Invoke-RemoteProbe',
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
    'Get-Process -Id $processIds',
    '[void]$task.Stop(0)',
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
    $managerSource,
    '(?s)function Start-TunnelTask\s*\{(?<body>.*?)\n\}\s*\n\s*function Install-Target'
)
$startTunnelFastPath = @($startTunnelMatch.Groups['body'].Value -split '\n\s*catch\s*\{')[0]
if (-not $startTunnelMatch.Success -or
    -not $startTunnelFastPath.Contains('Wait-ManagedTunnelProcess') -or
    $startTunnelFastPath.Contains('Wait-RemoteProxy') -or
    $startTunnelFastPath.Contains('Get-ScheduledTask')) {
    throw 'Enable does not use bounded local startup before background verification'
}
$stopTunnelMatch = [regex]::Match(
    $managerSource,
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
    $managerSource,
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
foreach ($removedManagerMarker in @('ConvertTo-PowerShellLiteral', "'-WindowStyle', 'Hidden'", 'Get-Command powershell.exe')) {
    if ($managerSource.Contains($removedManagerMarker)) {
        throw "Removed console launcher is still present: $removedManagerMarker"
    }
}


$uiSource = Get-Content -Raw -LiteralPath $ui
foreach ($requiredSource in @('Show-HelpDialog', "New-ActionButton 'Help'", "New-ActionButton 'Proxy access'", "New-ActionButton 'Advanced...'", "'Enable proxy'", "'Disable proxy'", "'DISABLED'", "'CHECKING'", "'BLOCKED'", 'UTF8Encoding', 'ANSI-CHECK', 'Invoke-SelectedAccessToggle', 'Invoke-InteractiveManagerCommand', 'Start-BackgroundTargetHealthCheck', 'Complete-BackgroundHealthChecks', 'Stop-BackgroundHealthChecks', 'New-TargetHealthProcessStartInfo', 'Get-UiScheduledTaskState', 'CreateNoWindow', 'ExpectedEnabled', 'DoubleBuffered', 'SuspendLayout', 'Add_CellContentClick', 'Add_FormClosed', "Columns['Enabled'].Index", "Items.Add('Install SSH key')", "Items.Add('Refresh local status')", "Items.Add('Remove target')")) {
    if (-not $uiSource.Contains($requiredSource)) {
        throw "Windows UI feature is missing: $requiredSource"
    }
}
if ($uiSource -notmatch '(?s)function Invoke-SelectedAccessToggle.*?\$command = ''disable''.*?\$command = ''enable''.*?Invoke-ManagerCommand.*?Refresh-TargetGrid.*?Start-BackgroundTargetHealthCheck') {
    throw 'Shared proxy toggle does not implement quick enable and background verification'
}
if (-not $uiSource.Contains("'-WindowStyle', 'Hidden'") -or
    -not $uiSource.Contains('-Verb RunAs -WindowStyle Hidden') -or
    -not $uiSource.Contains('-WindowStyle Normal') -or
    $uiSource.Contains("Invoke-ManagerCommand 'bootstrap-key'")) {
    throw 'UI console visibility or interactive SSH key routing is incorrect'
}
if (-not $uiSource.Contains("Start-BackgroundTargetHealthCheck `$name `$generation (`$command -eq 'enable')")) {
    throw 'Enable and Disable do not share expected-state background verification'
}
if ($uiSource -notmatch '(?s)\$accessButton\.Add_Click\(\{\s*Invoke-SelectedAccessToggle\s*\}\).*?Add_CellContentClick.*?Invoke-SelectedAccessToggle') {
    throw 'Button and Enabled checkbox do not share the proxy toggle'
}
if ($uiSource -notmatch '(?s)function Invoke-HealthCheck.*?Reset-TargetHealth.*?& \$script:ManagerPath status' -or
    $uiSource -notmatch '(?s)\$removeMenuItem\.Add_Click.*?Invoke-ManagerCommand ''remove''.*?Reset-TargetHealth') {
    throw 'Manual health or target removal does not invalidate stale background results'
}
$accessHandlerMatch = [regex]::Match($uiSource, '(?s)\$accessButton\.Add_Click\(\{(?<body>.*?)\}\)')
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
