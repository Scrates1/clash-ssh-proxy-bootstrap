# Shared path and Windows process-argument helpers used by both entry points.

function Get-DefaultConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return Join-Path $env:LOCALAPPDATA 'ClashSshProxy\config.json'
    }
    return Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\ClashSshProxy\config.json'
}

function Read-Utf8TextFile {
    param([string]$Path)

    # Windows PowerShell 5.1 otherwise treats BOM-less UTF-8 as the active ANSI
    # code page. Invalid byte sequences are rejected instead of being silently
    # replaced, because this helper is used for executable configuration data.
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    return [IO.File]::ReadAllText($Path, $encoding)
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
