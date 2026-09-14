param([string]$ManagerPath, [string]$TemporaryRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $ManagerPath help *> $null

$echoPath = Join-Path $TemporaryRoot 'native-ssh-arguments.ps1'
$capturePath = Join-Path $TemporaryRoot 'native-ssh-arguments.txt'
[IO.File]::WriteAllText($echoPath, @'
param([string]$CapturePath)
$encodedArguments = @($args | ForEach-Object {
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$_))
})
[IO.File]::WriteAllLines($CapturePath, [string[]]$encodedArguments)
exit 0
'@)
$originalNativeCommand = (Get-Command Invoke-NativeChecked).ScriptBlock
$originalRemoteCommand = (Get-Command Invoke-RemoteCommand).ScriptBlock
$originalSshArguments = (Get-Command Get-SshArguments).ScriptBlock
$originalPublicKeyCleanup = (Get-Command Get-SshPublicKeyForCleanup).ScriptBlock

function Get-ReceivedRemoteScript {
    $receivedArguments = @([IO.File]::ReadAllLines($capturePath) | ForEach-Object {
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_))
    })
    if ($receivedArguments.Count -ne 14 -or $receivedArguments[12] -ne 'tester@example.invalid') {
        throw 'SSH native argument passing split or corrupted the destination or script'
    }
    if ($receivedArguments[13] -notmatch "^printf %s '([A-Za-z0-9+/=]+)' \| base64 -d \| sh$") {
        throw 'Remote SSH script was not protected across native argument passing'
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
}

try {
    Set-Item Function:Invoke-NativeChecked -Value {
        param($FilePath, $ArgumentList, $Description)
        & $originalNativeCommand -FilePath powershell.exe -ArgumentList (@(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $echoPath, $capturePath
        ) + @($ArgumentList)) -Description 'Capture native SSH arguments'
    }
    $target = [pscustomobject]@{
        name = 'native-transport'; host = 'example.invalid'; user = 'tester'
        sshPort = 22; identityFile = (Join-Path $TemporaryRoot 'key with spaces')
    }
    $scriptText = "set -eu`r`nprintf '%s\n' `"`$HOME with spaces`"`r`nawk '{ print `$1, `$2 }' /dev/null"
    Invoke-RemoteCommand $target $scriptText
    if ((Get-ReceivedRemoteScript) -cne $scriptText.Replace("`r`n", "`n")) {
        throw 'Native SSH transport changed shell quotes, variables, or newlines'
    }

    Set-Item Function:Get-SshPublicKeyForCleanup -Value { param($Target) return 'ssh-ed25519 QUJDRA==' }
    Set-Item Function:Invoke-RemoteCommand -Value {
        param($Target, $RemoteCommand, $Description)
        $script:ExpectedCleanupScript = $RemoteCommand.Replace("`r`n", "`n")
        & $originalRemoteCommand $Target $RemoteCommand $Description
    }
    Remove-TargetRemoteArtifacts $target
    if ((Get-ReceivedRemoteScript) -cne $script:ExpectedCleanupScript) {
        throw 'Remote public-key cleanup was corrupted by native argument passing'
    }

    # Route the probe's executable to the same real native argument receiver.
    function Get-Command {
        param([string]$Name, $ErrorAction)
        if ($Name -eq 'ssh.exe') {
            return [pscustomobject]@{ Source = (Microsoft.PowerShell.Core\Get-Command powershell.exe).Source }
        }
        return Microsoft.PowerShell.Core\Get-Command $Name -ErrorAction Stop
    }
    Set-Item Function:Get-SshArguments -Value {
        param($Target)
        return @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $echoPath, $capturePath) + @(& $originalSshArguments $Target)
    }
    foreach ($diagnostics in @($false, $true)) {
        $exitCode = Invoke-RemoteProbe $target $scriptText -ShowDiagnostics:$diagnostics
        if ($exitCode -ne 0 -or (Get-ReceivedRemoteScript) -cne $scriptText.Replace("`r`n", "`n")) {
            throw 'Quiet or diagnostic SSH probing corrupted the remote script'
        }
    }
}
finally {
    Remove-Item Function:Get-Command -ErrorAction SilentlyContinue
    Set-Item Function:Invoke-NativeChecked -Value $originalNativeCommand
    Set-Item Function:Invoke-RemoteCommand -Value $originalRemoteCommand
    Set-Item Function:Get-SshArguments -Value $originalSshArguments
    Set-Item Function:Get-SshPublicKeyForCleanup -Value $originalPublicKeyCleanup
}
Write-Host 'Native SSH transport tests passed'
