# Windows OpenSSH argument construction and generic local/remote probes.

function Resolve-IdentityPath {
    param([string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -eq '~') {
        $expanded = [Environment]::GetFolderPath('UserProfile')
    }
    elseif ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        $expanded = Join-Path ([Environment]::GetFolderPath('UserProfile')) $expanded.Substring(2)
    }
    return [System.IO.Path]::GetFullPath($expanded)
}

function Get-SshDestination {
    param($Target)
    $userName = [string]$Target.user
    $hostName = [string]$Target.host
    if ([string]::IsNullOrWhiteSpace($userName) -or
        $userName -match '[\s@\x00-\x1F\x7F]' -or $userName.StartsWith('-')) {
        throw 'SSH user is invalid'
    }
    if ([string]::IsNullOrWhiteSpace($hostName) -or
        $hostName -match '[\s@\x00-\x1F\x7F]' -or $hostName.StartsWith('-')) {
        throw 'SSH host is invalid'
    }
    return "$userName@$hostName"
}

function Get-SshArguments {
    param($Target)
    $identity = Resolve-IdentityPath $Target.identityFile
    return @(
        '-p', [string]$Target.sshPort,
        '-i', $identity,
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=yes',
        '-o', 'ConnectTimeout=8'
    )
}

function Get-ScpArguments {
    param($Target)
    $identity = Resolve-IdentityPath $Target.identityFile
    return @(
        '-P', [string]$Target.sshPort,
        '-i', $identity,
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=yes',
        '-o', 'ConnectTimeout=8'
    )
}

function Assert-ClientTools {
    foreach ($tool in @('ssh.exe', 'scp.exe')) {
        if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool was not found. Install the Windows OpenSSH Client feature."
        }
    }
}

function Assert-IdentityFile {
    param($Target)
    $identity = Resolve-IdentityPath $Target.identityFile
    if (-not (Test-Path -LiteralPath $identity -PathType Leaf)) {
        throw "SSH identity file not found: $identity"
    }
}

function Invoke-NativeChecked {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$Description
    )
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

function Invoke-RemoteCommand {
    param(
        $Target,
        [string]$RemoteCommand,
        [string]$Description = 'Remote command'
    )
    $arguments = @(Get-SshArguments $Target) + @((Get-SshDestination $Target), (ConvertTo-RemoteScriptCommand $RemoteCommand))
    Invoke-NativeChecked -FilePath 'ssh.exe' -ArgumentList $arguments -Description $Description
}

function Invoke-RemoteProbe {
    param(
        $Target,
        [string]$RemoteCommand,
        [switch]$ShowDiagnostics
    )
    $arguments = @(Get-SshArguments $Target) + @((Get-SshDestination $Target), (ConvertTo-RemoteScriptCommand $RemoteCommand))
    $sshCommand = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($null -eq $sshCommand) {
        return 255
    }
    $exitCode = 255
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 turns native stderr into ErrorRecord objects.
        # Keep routine probes quiet, but show SSH errors during interactive setup.
        $ErrorActionPreference = 'Continue'
        if ($ShowDiagnostics) {
            & $sshCommand.Source @arguments 1> $null
        }
        else {
            & $sshCommand.Source @arguments 1> $null 2> $null
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [int]$exitCode
}

function Test-RemoteCommand {
    param(
        $Target,
        [string]$RemoteCommand,
        [switch]$ShowDiagnostics
    )
    return (Invoke-RemoteProbe $Target $RemoteCommand -ShowDiagnostics:$ShowDiagnostics) -eq 0
}

function Test-RemoteConnection {
    param($Target, [switch]$ShowDiagnostics)
    return Test-RemoteCommand $Target 'printf REMOTE_OK' -ShowDiagnostics:$ShowDiagnostics
}

function Test-LocalTcpPort {
    param(
        [string]$HostName,
        [int]$Port,
        [ValidateRange(50, 5000)]
        [int]$TimeoutMilliseconds = 3000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connectTask = $client.ConnectAsync($HostName, $Port)
        if (-not $connectTask.Wait($TimeoutMilliseconds)) {
            return $false
        }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function ConvertTo-ShellLiteral {
    param([string]$Value)
    $singleQuote = [char]39
    $doubleQuote = [char]34
    $escapedSingleQuote = [string]$singleQuote + $doubleQuote + $singleQuote + $doubleQuote + $singleQuote
    return [string]$singleQuote + $Value.Replace([string]$singleQuote, $escapedSingleQuote) + $singleQuote
}

function ConvertTo-RemoteScriptCommand {
    param([string]$ScriptText)

    # Legacy PowerShell native argument passing removes embedded double quotes.
    # Keep every shell expansion and argument intact across the SSH boundary.
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ScriptText.Replace("`r`n", "`n")))
    return "printf %s $(ConvertTo-ShellLiteral $encodedScript) | base64 -d | sh"
}
