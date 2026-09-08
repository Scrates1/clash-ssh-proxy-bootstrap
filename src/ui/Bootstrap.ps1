# UI startup helpers used before elevation and single-instance checks.

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UiInstanceMutexName {
    param([switch]$SmokeTest)

    if ($SmokeTest) {
        return "Local\ClashSshProxyManager.Smoke.$PID"
    }
    return 'Local\ClashSshProxyManager'
}

function Enter-UiInstanceMutex {
    param([string]$Name = 'Local\ClashSshProxyManager')

    $mutex = New-Object System.Threading.Mutex($false, $Name)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(0, $false)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            $mutex.Dispose()
            return $null
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

function Exit-UiInstanceMutex {
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

function Get-TrackedUiProcess {
    param(
        [hashtable]$Registry,
        [string]$Key
    )

    if (-not $Registry.ContainsKey($Key)) {
        return $null
    }
    $process = $Registry[$Key]
    try {
        if (-not $process.HasExited) {
            return $process
        }
    }
    catch {}
    [void]$Registry.Remove($Key)
    try { $process.Dispose() } catch {}
    return $null
}

function Show-UiProcessWindow {
    param(
        [AllowNull()]$Process,
        [string[]]$WindowTitles = @()
    )

    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        if ($null -ne $Process) {
            try {
                if ($shell.AppActivate([int]$Process.Id)) { return $true }
            }
            catch {}
        }
        foreach ($title in $WindowTitles) {
            if (-not [string]::IsNullOrWhiteSpace($title) -and $shell.AppActivate($title)) { return $true }
        }
        return $false
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Show-ExistingManagerWindow {
    $chineseTitle = 'Clash SSH ' + (-join ([char[]]@(0x4ee3, 0x7406, 0x7ba1, 0x7406, 0x5668)))
    return Show-UiProcessWindow -Process $null -WindowTitles @(
        'Clash SSH Proxy Manager',
        $chineseTitle
    )
}

function Show-ManagerUiError {
    param([string]$Message)

    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        [void]$shell.Popup(
            "Clash SSH Proxy Manager could not start:`r`n`r`n$Message",
            0,
            'Clash SSH Proxy Manager',
            16
        )
    }
    catch {}
    finally {
        if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Start-InteractiveSshBootstrapProcess {
    param(
        [string]$ManagerPath,
        [string]$Config,
        [hashtable]$Parameters,
        [string]$WorkingDirectory
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $payload = [ordered]@{ managerPath = $ManagerPath; config = $Config; parameters = $Parameters }
    $payloadBase64 = [Convert]::ToBase64String($encoding.GetBytes(($payload | ConvertTo-Json -Depth 8 -Compress)))
    $childSource = @"
`$ErrorActionPreference = 'Stop'
try { `$Host.UI.RawUI.WindowTitle = 'Clash SSH Proxy - SSH key setup' } catch {}
try {
    if ([Console]::IsInputRedirected) {
        throw 'The SSH setup process did not receive an interactive console input handle.'
    }
    `$payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payloadBase64'))
    `$payload = `$payloadJson | ConvertFrom-Json
    `$invokeParameters = @{ Config = [string]`$payload.config; Confirm = `$false }
    foreach (`$property in `$payload.parameters.PSObject.Properties) {
        `$invokeParameters[`$property.Name] = if (`$property.Value -is [array]) { @(`$property.Value) } else { `$property.Value }
    }
    & ([string]`$payload.managerPath) 'bootstrap-key' @invokeParameters
}
catch {
    Write-Host ''
    Write-Host 'SSH setup failed:' -ForegroundColor Red
    Write-Host `$_.Exception.Message -ForegroundColor Red
    [void](Read-Host 'Press Enter to close this window')
    exit 1
}
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childSource))
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand)
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' '
    return (Start-Process -FilePath 'powershell.exe' -Verb Open -WorkingDirectory $WorkingDirectory -WindowStyle Normal -ArgumentList $argumentLine -PassThru)
}
