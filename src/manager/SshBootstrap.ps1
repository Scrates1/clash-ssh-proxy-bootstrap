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

function Write-SshPublicKeyFile {
    param(
        [string]$Path,
        [string]$PublicKey
    )

    if ((Test-Path -LiteralPath $Path) -and
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "SSH public-key path is not a file: $Path"
    }
    $parent = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $temporaryPath = Join-Path $parent (
        ".$leaf.clash-ssh-proxy.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    )
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            "$PublicKey`n",
            (New-Object Text.UTF8Encoding($false))
        )
        if ((Test-Path -LiteralPath $Path) -and
            -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "SSH public-key path changed while it was being written: $Path"
        }
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function ConvertTo-NormalizedSshPublicKey {
    param(
        [string]$PublicKey,
        [string]$IdentityPath
    )

    $parts = @($PublicKey.Trim() -split '\s+')
    if ($parts.Count -lt 2 -or
        $parts[0] -notmatch '^(ssh-|ecdsa-)[A-Za-z0-9@._+-]+$' -or
        $parts[1] -notmatch '^[A-Za-z0-9+/]+={0,3}$') {
        throw "Unsupported public key derived from $IdentityPath"
    }
    return "$($parts[0]) $($parts[1])"
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
    $derivedPublicKey = $null
    if ((Test-Path -LiteralPath $publicKeyPath) -and -not $publicKeyExistedBefore) {
        throw "SSH public-key path is not a file: $publicKeyPath"
    }

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

        $identityLeaf = Split-Path -Leaf $identityPath
        $temporaryIdentityPath = Join-Path $parent (
            ".$identityLeaf.clash-ssh-proxy.$PID.$([guid]::NewGuid().ToString('N')).tmp"
        )
        $temporaryPublicKeyPath = "$temporaryIdentityPath.pub"
        try {
            [void](Invoke-SshKeygen `
                -ArgumentList @('-q', '-t', 'ed25519', '-N', '', '-C', 'clash-ssh-proxy', '-f', $temporaryIdentityPath) `
                -Description 'Create SSH identity')
            if (-not (Test-Path -LiteralPath $temporaryIdentityPath -PathType Leaf) -or
                -not (Test-Path -LiteralPath $temporaryPublicKeyPath -PathType Leaf)) {
                throw 'ssh-keygen did not create a complete key pair'
            }

            $derivedPublicKey = Invoke-SshKeygen `
                -ArgumentList @('-y', '-P', '', '-f', $temporaryIdentityPath) `
                -Description 'Verify new SSH identity'
            $derivedPublicKey = ConvertTo-NormalizedSshPublicKey `
                -PublicKey $derivedPublicKey `
                -IdentityPath $identityPath
            if (Test-Path -LiteralPath $identityPath) {
                throw "SSH identity path changed while it was being created: $identityPath. Retry the operation."
            }

            [IO.File]::Move($temporaryIdentityPath, $identityPath)
            $identityCreated = $true
        }
        finally {
            foreach ($temporaryPath in @($temporaryIdentityPath, $temporaryPublicKeyPath)) {
                if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                    Remove-Item -LiteralPath $temporaryPath -Force
                }
            }
        }
    }

    if ($null -eq $derivedPublicKey) {
        try {
            $derivedPublicKey = Invoke-SshKeygen `
                -ArgumentList @('-y', '-P', '', '-f', $identityPath) `
                -Description 'Read SSH public key'
        }
        catch {
            throw "SSH identity must be readable without a passphrase for unattended reconnects: $identityPath. $($_.Exception.Message)"
        }
    }
    $derivedPublicKey = ConvertTo-NormalizedSshPublicKey `
        -PublicKey $derivedPublicKey `
        -IdentityPath $identityPath

    $existingPublicKey = if (Test-Path -LiteralPath $publicKeyPath -PathType Leaf) {
        (Get-Content -Raw -LiteralPath $publicKeyPath).Trim()
    } else {
        ''
    }
    $derivedParts = @($derivedPublicKey -split ' ')
    $existingParts = @($existingPublicKey -split '\s+')
    $publicMatches = $derivedParts.Count -ge 2 -and $existingParts.Count -ge 2 -and
        $derivedParts[0] -ceq $existingParts[0] -and
        $derivedParts[1] -ceq $existingParts[1]
    if (-not $publicMatches) {
        Write-SshPublicKeyFile -Path $publicKeyPath -PublicKey $derivedPublicKey
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

function Get-SshPublicKeyForCleanup {
    param($Target)

    Assert-SshKeygen | Out-Null
    $identityPath = Resolve-IdentityPath $Target.identityFile
    $publicKeyPath = "$identityPath.pub"
    $deriveError = $null
    if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
        try {
            $derived = Invoke-SshKeygen `
                -ArgumentList @('-y', '-P', '', '-f', $identityPath) `
                -Description 'Read SSH public key for cleanup'
            return ConvertTo-NormalizedSshPublicKey `
                -PublicKey $derived `
                -IdentityPath $identityPath
        }
        catch {
            $deriveError = $_.Exception.Message
        }
    }
    if (Test-Path -LiteralPath $publicKeyPath -PathType Leaf) {
        try {
            return ConvertTo-NormalizedSshPublicKey `
                -PublicKey (Get-Content -Raw -LiteralPath $publicKeyPath) `
                -IdentityPath $identityPath
        }
        catch {
            throw "SSH public-key file is invalid: $publicKeyPath. $($_.Exception.Message)"
        }
    }
    if ($null -ne $deriveError) {
        throw "SSH public key could not be read from the private key and no usable .pub file exists: $identityPath. $deriveError"
    }
    throw "SSH identity and public-key files are both missing: $identityPath"
}

function Remove-ManagedSshIdentity {
    param($Target)

    if (-not [bool]$Target.identityManaged) {
        throw "Refusing to delete externally selected SSH identity '$($Target.identityFile)'."
    }
    $expectedPath = Get-ManagedIdentityPath $Target.id
    $actualPath = Get-CanonicalIdentityPath $Target.identityFile
    if ($actualPath -ne (Get-CanonicalIdentityPath $expectedPath)) {
        throw "Refusing to delete SSH identity outside the managed target key directory: $($Target.identityFile)"
    }
    foreach ($path in @((Resolve-IdentityPath $Target.identityFile), (Resolve-IdentityPath "$($Target.identityFile).pub"))) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
        elseif (Test-Path -LiteralPath $path) {
            throw "SSH identity path is not a regular file: $path"
        }
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
    $remoteCommand = "set -eu; umask 077; mkdir -p `"`$HOME/.ssh`"; touch `"`$HOME/.ssh/authorized_keys`"; chmod 700 `"`$HOME/.ssh`"; chmod 600 `"`$HOME/.ssh/authorized_keys`"; key=`"`$(printf %s $(ConvertTo-ShellLiteral $encodedKey) | base64 -d)`"; key_type=`"`$`{key%% *`}`"; key_data=`"`$`{key#* `}`"; awk -v key_type=`"`$key_type`" -v key_data=`"`$key_data`" '{ if (`$1 ~ /^#/) next; for (i = 1; i < NF; i++) if (`$i == key_type && `$(i + 1) == key_data) found = 1 } END { exit(found ? 0 : 1) }' `"`$HOME/.ssh/authorized_keys`" || { [ ! -s `"`$HOME/.ssh/authorized_keys`" ] || printf '\n' >> `"`$HOME/.ssh/authorized_keys`"; printf '%s\n' `"`$key`" >> `"`$HOME/.ssh/authorized_keys`"; }"

    $arguments = @(
        '-p', [string]$Target.sshPort,
        '-i', $identity.IdentityPath,
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=ask',
        '-o', 'ConnectTimeout=8',
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
