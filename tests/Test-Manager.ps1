$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$manager = Join-Path $repoRoot 'proxy-manager.ps1'
$exampleConfig = Join-Path $repoRoot 'config.example.json'

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $manager,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null

if ($parseErrors.Count -gt 0) {
    $messages = $parseErrors | ForEach-Object { $_.Message }
    throw "PowerShell parse errors:`n$($messages -join "`n")"
}

$config = Get-Content -Raw -LiteralPath $exampleConfig | ConvertFrom-Json
if ($config.version -ne 1) { throw 'Unexpected config version' }
if (@($config.targets).Count -ne 1) { throw 'Example must contain one target' }
if ($config.targets[0].host -ne 'linux.example.com') { throw 'Example contains a non-placeholder host' }
if ($config.targets[0].user -ne 'linuxuser') { throw 'Example contains a non-placeholder user' }

& $manager validate-config -Config $exampleConfig

Write-Host 'PowerShell manager tests passed'
