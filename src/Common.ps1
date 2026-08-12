# Shared path and Windows process-argument helpers used by both entry points.

function Get-DefaultConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return Join-Path $env:LOCALAPPDATA 'ClashSshProxy\config.json'
    }
    return Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\ClashSshProxy\config.json'
}

function ConvertTo-WindowsArgument {
    param([string]$Value)
    if ($Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}
