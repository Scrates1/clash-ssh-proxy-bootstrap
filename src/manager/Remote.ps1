# Linux-side installation, proxy verification, and SSH public-key bootstrap.

function Install-RemoteFiles {
    param($Target)

    $linuxSource = Join-Path $script:RepositoryRoot 'linux'
    if (-not (Test-Path -LiteralPath (Join-Path $linuxSource 'install-linux.sh') -PathType Leaf)) {
        throw "Linux installer files were not found under $linuxSource"
    }

    $safeName = [regex]::Replace($Target.name, '[^A-Za-z0-9._-]', '-')
    $remoteStage = "/tmp/clash-ssh-proxy-$safeName-$PID"
    $quotedStage = ConvertTo-ShellLiteral $remoteStage
    Invoke-RemoteCommand $Target "set -eu; test ! -e $quotedStage; mkdir -m 700 $quotedStage" 'Create remote staging directory'

    try {
        $scpArguments = @(Get-ScpArguments $Target) + @(
            '-r',
            $linuxSource,
            "$(Get-SshDestination $Target):$remoteStage/"
        )
        Invoke-NativeChecked -FilePath 'scp.exe' -ArgumentList $scpArguments -Description 'Upload Linux installer'

        $extra = (@($Target.noProxyExtra) -join ',')
        $installer = "$remoteStage/linux/install-linux.sh"
        $remoteCommand = "bash $(ConvertTo-ShellLiteral $installer) --remote-proxy-port $($Target.remoteProxyPort) --no-proxy-extra $(ConvertTo-ShellLiteral $extra)"
        Invoke-RemoteCommand $Target $remoteCommand 'Install Linux account proxy'
    }
    finally {
        $cleanupArguments = @(Get-SshArguments $Target) + @(
            (Get-SshDestination $Target),
            "test ! -d $quotedStage || rm -r -- $quotedStage"
        )
        & ssh.exe @cleanupArguments *> $null
    }
}

function Invoke-RemoteProxyProbe {
    param($Target)
    $command = 'set -eu; if [ -x "$HOME/.config/clash-ssh-proxy/check-linux.sh" ]; then "$HOME/.config/clash-ssh-proxy/check-linux.sh" --quiet; else . "$HOME/.config/clash-ssh-proxy/proxy-on.sh"; for url in https://www.gstatic.com/generate_204 https://cp.cloudflare.com/generate_204 https://www.google.com/generate_204; do if curl -fsS -o /dev/null --connect-timeout 2 --max-time 4 -x "$CLASH_SSH_PROXY" "$url" 2>/dev/null; then exit 0; fi; done; exit 1; fi'
    return Invoke-RemoteProbe $Target $command
}

function Test-RemoteProxy {
    param($Target)
    return (Invoke-RemoteProxyProbe $Target) -eq 0
}

function Wait-RemoteProxy {
    param(
        $Target,
        [int]$TimeoutSeconds = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-RemoteProxy $Target) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-RemoteTunnelState {
    param($Target)
    $probe = "</dev/tcp/127.0.0.1/$($Target.remoteProxyPort)"
    $command = "command -v timeout >/dev/null 2>&1 && ! timeout 2 bash -c $(ConvertTo-ShellLiteral $probe) >/dev/null 2>&1"
    $exitCode = Invoke-RemoteProbe $Target $command
    if ($exitCode -eq 0) {
        return 'BLOCKED'
    }
    if ($exitCode -eq 255) {
        return 'UNKNOWN'
    }
    return 'LEAK'
}

function Install-PublicKey {
    param($Target)

    Assert-ClientTools
    Assert-IdentityFile $Target
    $identityPath = Resolve-IdentityPath $Target.identityFile
    $publicKeyPath = "$identityPath.pub"
    if (-not (Test-Path -LiteralPath $publicKeyPath -PathType Leaf)) {
        $publicKey = & ssh-keygen.exe -y -f $identityPath
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to derive public key from $identityPath"
        }
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($publicKeyPath, (($publicKey -join "`n").Trim() + "`n"), $encoding)
    }

    $publicKeyText = (Get-Content -Raw -LiteralPath $publicKeyPath).Trim()
    if ($publicKeyText -notmatch '^(ssh-|ecdsa-)') {
        throw "Unsupported public key format in $publicKeyPath"
    }
    $encodedKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($publicKeyText))
    $remoteCommand = "set -eu; umask 077; mkdir -p `"`$HOME/.ssh`"; touch `"`$HOME/.ssh/authorized_keys`"; chmod 700 `"`$HOME/.ssh`"; chmod 600 `"`$HOME/.ssh/authorized_keys`"; key=`"`$(printf %s $(ConvertTo-ShellLiteral $encodedKey) | base64 -d)`"; grep -qxF `"`$key`" `"`$HOME/.ssh/authorized_keys`" || printf '%s\n' `"`$key`" >> `"`$HOME/.ssh/authorized_keys`""

    $arguments = @(
        '-p', [string]$Target.sshPort,
        '-i', $identityPath,
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
