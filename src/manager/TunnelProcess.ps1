# Exact Windows OpenSSH invocation construction and managed-process lifecycle.

function Get-TunnelSshInvocation {
    param(
        $ManagerConfig,
        $Target
    )

    $sshCommand = Get-Command ssh.exe -ErrorAction Stop
    $identityPath = Resolve-IdentityPath $Target.identityFile
    $destination = Get-SshDestination $Target
    $argumentValues = @(
        '-N', '-T',
        '-i', $identityPath,
        '-p', [string]$Target.sshPort,
        '-R', "127.0.0.1:$($Target.remoteProxyPort):$($ManagerConfig.proxy.localHost):$($ManagerConfig.proxy.localPort)",
        '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ServerAliveInterval=30',
        '-o', 'ServerAliveCountMax=3',
        '-o', 'TCPKeepAlive=yes',
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=yes',
        $destination
    )
    $commandLine = (@(@($sshCommand.Source) + @($argumentValues)) | ForEach-Object {
        ConvertTo-WindowsArgument ([string]$_)
    }) -join ' '

    return [pscustomobject]@{
        Executable = [string]$sshCommand.Source
        Arguments = @($argumentValues)
        CommandLine = $commandLine
    }
}

function ConvertFrom-WindowsCommandLine {
    param([string]$CommandLine)

    $result = New-Object 'System.Collections.Generic.List[string]'
    $length = $CommandLine.Length
    $index = 0
    while ($index -lt $length) {
        while ($index -lt $length -and [char]::IsWhiteSpace($CommandLine[$index])) {
            $index++
        }
        if ($index -ge $length) {
            break
        }

        $builder = New-Object Text.StringBuilder
        $inQuotes = $false
        while ($index -lt $length) {
            if (-not $inQuotes -and [char]::IsWhiteSpace($CommandLine[$index])) {
                break
            }

            $backslashCount = 0
            while ($index -lt $length -and $CommandLine[$index] -eq '\') {
                $backslashCount++
                $index++
            }
            if ($index -lt $length -and $CommandLine[$index] -eq '"') {
                for ($slash = 0; $slash -lt [math]::Floor($backslashCount / 2); $slash++) {
                    [void]$builder.Append('\')
                }
                if (($backslashCount % 2) -eq 1) {
                    [void]$builder.Append('"')
                    $index++
                    continue
                }
                if ($inQuotes -and $index + 1 -lt $length -and $CommandLine[$index + 1] -eq '"') {
                    [void]$builder.Append('"')
                    $index += 2
                    continue
                }
                $inQuotes = -not $inQuotes
                $index++
                continue
            }
            for ($slash = 0; $slash -lt $backslashCount; $slash++) {
                [void]$builder.Append('\')
            }
            if ($index -lt $length) {
                [void]$builder.Append($CommandLine[$index])
                $index++
            }
        }
        [void]$result.Add($builder.ToString())
    }
    return $result.ToArray()
}

function Test-ManagedTunnelCommandLine {
    param(
        [string]$CommandLine,
        $Invocation,
        [AllowNull()][string]$ExecutablePath
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $false
    }
    $actual = @(ConvertFrom-WindowsCommandLine $CommandLine)
    $expected = @([string]$Invocation.Executable) + @($Invocation.Arguments | ForEach-Object { [string]$_ })
    if ($actual.Count -ne $expected.Count) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($ExecutablePath) -and
        -not [string]::Equals(
            $ExecutablePath,
            [string]$Invocation.Executable,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        return $false
    }
    $actualExecutableMatches = [string]::Equals(
        [string]$actual[0],
        [string]$expected[0],
        [StringComparison]::OrdinalIgnoreCase
    ) -or [string]::Equals(
        [IO.Path]::GetFileName([string]$actual[0]),
        [IO.Path]::GetFileName([string]$expected[0]),
        [StringComparison]::OrdinalIgnoreCase
    )
    if (-not $actualExecutableMatches) {
        return $false
    }
    for ($index = 1; $index -lt $expected.Count; $index++) {
        $comparison = if ($index -eq 4) {
            [StringComparison]::OrdinalIgnoreCase
        }
        else {
            [StringComparison]::Ordinal
        }
        if (-not [string]::Equals(
            [string]$actual[$index],
            [string]$expected[$index],
            $comparison
        )) {
            return $false
        }
    }
    return $true
}

function Get-ManagedTunnelProcesses {
    param(
        $ManagerConfig,
        $Target
    )

    $invocation = Get-TunnelSshInvocation $ManagerConfig $Target
    return @(Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction Stop | Where-Object {
        Test-ManagedTunnelCommandLine ([string]$_.CommandLine) $invocation ([string]$_.ExecutablePath)
    })
}

function Wait-ManagedTunnelProcess {
    param(
        $ManagerConfig,
        $Target,
        [int]$TimeoutSeconds = 7
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (@(Get-ManagedTunnelProcesses $ManagerConfig $Target).Count -gt 0) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Stop-ManagedTunnelProcesses {
    param(
        $ManagerConfig,
        $Target,
        [ValidateRange(1, 60000)]
        [int]$TimeoutMilliseconds = 5000,
        [ValidateRange(0, 5000)]
        [int]$QuietPeriodMilliseconds = 250,
        [ValidateRange(0, 1000)]
        [int]$PollMilliseconds = 50
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $quietStopwatch = $null
    $stoppedAtLeastOne = $false
    do {
        $processes = @(Get-ManagedTunnelProcesses $ManagerConfig $Target)
        if ($processes.Count -eq 0) {
            if (-not $stoppedAtLeastOne) {
                return
            }
            if ($null -eq $quietStopwatch) {
                $quietStopwatch = [Diagnostics.Stopwatch]::StartNew()
            }
            if ($quietStopwatch.ElapsedMilliseconds -ge $QuietPeriodMilliseconds) {
                return
            }
        }
        else {
            $stoppedAtLeastOne = $true
            $quietStopwatch = $null
            $processIds = @($processes | ForEach-Object { [int]$_.ProcessId })
            Stop-Process -Id $processIds -Force -ErrorAction SilentlyContinue
        }
        if ($PollMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $PollMilliseconds
        }
    } while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds)

    $remaining = @(Get-ManagedTunnelProcesses $ManagerConfig $Target)
    if ($remaining.Count -gt 0) {
        throw "Unable to stop $($remaining.Count) managed SSH tunnel process(es) for $($Target.name)"
    }
}
