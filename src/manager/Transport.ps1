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
    return "$($Target.user)@$($Target.host)"
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
    $arguments = @(Get-SshArguments $Target) + @((Get-SshDestination $Target), $RemoteCommand)
    Invoke-NativeChecked -FilePath 'ssh.exe' -ArgumentList $arguments -Description $Description
}

function Invoke-RemoteProbe {
    param(
        $Target,
        [string]$RemoteCommand
    )
    $arguments = @(Get-SshArguments $Target) + @((Get-SshDestination $Target), $RemoteCommand)
    $sshCommand = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($null -eq $sshCommand) {
        return 255
    }
    $exitCode = 255
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 turns native stderr into ErrorRecord objects.
        # Probes communicate state through the native exit code; ignore stderr.
        $ErrorActionPreference = 'Continue'
        & $sshCommand.Source @arguments 1> $null 2> $null
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
        [string]$RemoteCommand
    )
    return (Invoke-RemoteProbe $Target $RemoteCommand) -eq 0
}

function Test-RemoteConnection {
    param($Target)
    return Test-RemoteCommand $Target 'printf REMOTE_OK'
}

function Test-LocalTcpPort {
    param(
        [string]$HostName,
        [int]$Port
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connectTask = $client.ConnectAsync($HostName, $Port)
        if (-not $connectTask.Wait(3000)) {
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
