# Local SSH identity preparation and interactive Linux public-key installation.

function Assert-SshKeygen {
    $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($null -eq $sshKeygen) {
        throw 'ssh-keygen.exe was not found. Install the Windows OpenSSH Client feature.'
    }
    return $sshKeygen.Source
}

function Invoke-SshKeygen {
    param(
        [string[]]$ArgumentList,
        [string]$Description
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Assert-SshKeygen
    $startInfo.Arguments = ($ArgumentList | ForEach-Object {
        ConvertTo-WindowsArgument ([string]$_)
    }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    try {
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "$Description did not start"
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(15000)) {
            try { $process.Kill() } catch {}
            [void]$process.WaitForExit(2000)
            throw "$Description timed out"
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        if ($process.ExitCode -ne 0) {
            $detail = $stderr.Trim()
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = "exit code $($process.ExitCode)"
            }
            throw "$Description failed: $detail"
        }
        return $stdout.Trim()
    }
    finally {
        $process.Dispose()
    }
}

function Initialize-SshIdentity {
    param(
        $Target,
        [switch]$CreateIfMissing
    )

    Assert-ClientTools
    $identityPath = Resolve-IdentityPath $Target.identityFile
    $publicKeyPath = "$identityPath.pub"
    $identityCreated = $false
    $publicKeyUpdated = $false
    $publicKeyExistedBefore = Test-Path -LiteralPath $publicKeyPath -PathType Leaf

    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
        if (-not $CreateIfMissing) {
            throw "SSH identity file not found: $identityPath"
        }
        if (Test-Path -LiteralPath $identityPath) {
            throw "SSH identity path is not a file: $identityPath"
        }
        if ($publicKeyExistedBefore) {
            throw "SSH private key is missing but its public-key file already exists: $publicKeyPath. Move that file or select a different identity path."
        }

        $parent = Split-Path -Parent $identityPath
        if ([string]::IsNullOrWhiteSpace($parent)) {
            throw "SSH identity path has no parent directory: $identityPath"
        }
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        try {
            [void](Invoke-SshKeygen `
                -ArgumentList @('-q', '-t', 'ed25519', '-N', '', '-C', 'clash-ssh-proxy', '-f', $identityPath) `
                -Description 'Create SSH identity')
            if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
                throw 'ssh-keygen did not create the private key'
            }
            $identityCreated = $true
        }
        catch {
            if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
                Remove-Item -LiteralPath $identityPath -Force
            }
            if (-not $publicKeyExistedBefore -and
                (Test-Path -LiteralPath $publicKeyPath -PathType Leaf)) {
                Remove-Item -LiteralPath $publicKeyPath -Force
            }
            throw
        }
    }

    try {
        $derivedPublicKey = Invoke-SshKeygen `
            -ArgumentList @('-y', '-P', '', '-f', $identityPath) `
            -Description 'Read SSH public key'
    }
    catch {
        throw "SSH identity must be readable without a passphrase for unattended reconnects: $identityPath. $($_.Exception.Message)"
    }
    if ($derivedPublicKey -notmatch '^(ssh-|ecdsa-)') {
        throw "Unsupported public key derived from $identityPath"
    }

    $existingPublicKey = if (Test-Path -LiteralPath $publicKeyPath -PathType Leaf) {
        (Get-Content -Raw -LiteralPath $publicKeyPath).Trim()
    } else {
        ''
    }
    $derivedParts = @($derivedPublicKey -split '\s+')
    $existingParts = @($existingPublicKey -split '\s+')
    $publicMatches = $derivedParts.Count -ge 2 -and $existingParts.Count -ge 2 -and
        $derivedParts[0] -ceq $existingParts[0] -and
        $derivedParts[1] -ceq $existingParts[1]
    if (-not $publicMatches) {
        [IO.File]::WriteAllText(
            $publicKeyPath,
            "$derivedPublicKey`n",
            (New-Object Text.UTF8Encoding($false))
        )
        $publicKeyUpdated = $true
    }

    return [pscustomobject]@{
        IdentityPath = $identityPath
        PublicKeyPath = $publicKeyPath
        PublicKey = $derivedPublicKey
        IdentityCreated = $identityCreated
        PublicKeyUpdated = $publicKeyUpdated
    }
}

function Get-SshReadiness {
    param($Target)

    $identity = Initialize-SshIdentity $Target -CreateIfMissing
    $ready = Test-RemoteConnection $Target
    return [pscustomobject]@{
        Ready = [bool]$ready
        InteractionRequired = -not [bool]$ready
        IdentityCreated = [bool]$identity.IdentityCreated
        PublicKeyUpdated = [bool]$identity.PublicKeyUpdated
    }
}

function Install-PublicKey {
    param($Target)

    $identity = Initialize-SshIdentity $Target -CreateIfMissing
    if (Test-RemoteConnection $Target) {
        Write-Host "SSH public key authentication is already ready for $($Target.name)."
        return
    }

    $encodedKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($identity.PublicKey))
    $remoteCommand = "set -eu; umask 077; mkdir -p `"`$HOME/.ssh`"; touch `"`$HOME/.ssh/authorized_keys`"; chmod 700 `"`$HOME/.ssh`"; chmod 600 `"`$HOME/.ssh/authorized_keys`"; key=`"`$(printf %s $(ConvertTo-ShellLiteral $encodedKey) | base64 -d)`"; grep -qxF `"`$key`" `"`$HOME/.ssh/authorized_keys`" || printf '%s\n' `"`$key`" >> `"`$HOME/.ssh/authorized_keys`""

    $arguments = @(
        '-p', [string]$Target.sshPort,
        '-i', $identity.IdentityPath,
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=ask',
        (Get-SshDestination $Target),
        $remoteCommand
    )
    Write-Host 'SSH may ask for the Linux password once. The password is not stored.' -ForegroundColor Yellow
    Invoke-NativeChecked -FilePath 'ssh.exe' -ArgumentList $arguments -Description 'Install SSH public key'

    if (-not (Test-RemoteConnection $Target)) {
        throw 'Public key was copied, but batch-mode SSH verification still failed'
    }
    Write-Host "SSH public key authentication is ready for $($Target.name)."
}
