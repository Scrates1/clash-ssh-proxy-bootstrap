# UI configuration, task-state, logging, command invocation, and selection helpers.

function Get-ObjectProperty {
    param(
        [AllowNull()]$Object,
        [string]$Name,
        $DefaultValue
    )
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        $value = $Object.$Name
        if ($null -ne $value) {
            return $value
        }
    }
    return $DefaultValue
}

function New-UiDefaultConfig {
    return [pscustomobject]@{
        version = 1
        proxy = [pscustomobject]@{
            localHost = '127.0.0.1'
            localPort = 7897
        }
        defaults = [pscustomobject]@{
            sshPort = 22
            identityFile = '~/.ssh/id_ed25519'
            remoteProxyPort = 17897
            noProxyExtra = @()
        }
        targets = @()
    }
}

function Read-UiConfig {
    if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
        return New-UiDefaultConfig
    }
    try {
        return Read-Utf8TextFile $Config | ConvertFrom-Json
    }
    catch {
        throw "Unable to read configuration '$Config': $($_.Exception.Message)"
    }
}

function Resolve-UiTarget {
    param(
        $ManagerConfig,
        $Target
    )
    $defaults = $ManagerConfig.defaults
    return [pscustomobject]@{
        name = [string]$Target.name
        host = [string]$Target.host
        user = [string]$Target.user
        taskName = [string]$Target.taskName
        enabled = [bool](Get-ObjectProperty $Target 'enabled' $true)
        sshPort = [int](Get-ObjectProperty $Target 'sshPort' $defaults.sshPort)
        identityFile = [string](Get-ObjectProperty $Target 'identityFile' $defaults.identityFile)
        remoteProxyPort = [int](Get-ObjectProperty $Target 'remoteProxyPort' $defaults.remoteProxyPort)
        noProxyExtra = @((Get-ObjectProperty $Target 'noProxyExtra' $defaults.noProxyExtra))
    }
}

function Get-UiScheduledTaskState {
    param([string]$TaskName)

    try {
        if ($null -eq $script:TaskSchedulerRoot) {
            $script:TaskSchedulerService = New-Object -ComObject 'Schedule.Service'
            $script:TaskSchedulerService.Connect()
            $script:TaskSchedulerRoot = $script:TaskSchedulerService.GetFolder('\')
        }
        $task = $script:TaskSchedulerRoot.GetTask($TaskName)
        switch ([int]$task.State) {
            1 { return 'Disabled' }
            2 { return 'Queued' }
            3 { return 'Ready' }
            4 { return 'Running' }
            default { return 'Unknown' }
        }
    }
    catch [System.IO.FileNotFoundException] {
        return 'Missing'
    }
    catch [System.Runtime.InteropServices.COMException] {
        if ($_.Exception.HResult -eq -2147024894) {
            return 'Missing'
        }
        throw
    }
}

function Test-LocalTcpPort {
    param(
        [string]$HostName,
        [int]$Port,
        [ValidateRange(50, 5000)]
        [int]$TimeoutMilliseconds = 800
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        return $task.Wait($TimeoutMilliseconds) -and $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Add-Log {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }
    $cleanMessage = [regex]::Replace($Message, ([string][char]27) + '\[[0-?]*[ -/]*[@-~]', '')
    if ([string]::IsNullOrWhiteSpace($cleanMessage)) {
        return
    }
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $script:LogBox.AppendText("[$timestamp] $cleanMessage`r`n")
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.ScrollToCaret()
}

function Set-Busy {
    param(
        [bool]$Busy,
        [string]$Message = 'Ready'
    )
    $script:Form.UseWaitCursor = $Busy
    $script:ActionPanel.Enabled = -not $Busy
    $script:Grid.Enabled = -not $Busy
    $script:StatusLabel.Text = $Message
    [System.Windows.Forms.Application]::DoEvents()
    if (-not $Busy -and $null -ne (Get-Command Update-ActionState -ErrorAction SilentlyContinue)) {
        Update-ActionState
    }
}

function Convert-RecordsToText {
    param([object[]]$Records)
    return (@($Records | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Invoke-ManagerCommand {
    param(
        [string]$Command,
        [hashtable]$Parameters = @{},
        [string]$BusyMessage = 'Working...'
    )

    $invokeParameters = @{ Config = $Config; Confirm = $false }
    foreach ($key in $Parameters.Keys) {
        $invokeParameters[$key] = $Parameters[$key]
    }

    Set-Busy $true $BusyMessage
    Add-Log "> proxy-manager.ps1 $Command"
    try {
        $records = @(& $script:ManagerPath $Command @invokeParameters *>&1)
        $text = Convert-RecordsToText $records
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            Add-Log $text
        }
        return $true
    }
    catch {
        $message = $_.Exception.Message
        Add-Log "ERROR: $message"
        [System.Windows.Forms.MessageBox]::Show(
            $message,
            'Operation failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return $false
    }
    finally {
        Set-Busy $false 'Ready'
    }
}

function Invoke-ManagerJsonCommand {
    param(
        [string]$Command,
        [hashtable]$Parameters = @{},
        [string]$BusyMessage = 'Checking...'
    )

    $invokeParameters = @{ Config = $Config; Confirm = $false; Json = $true }
    foreach ($key in $Parameters.Keys) {
        $invokeParameters[$key] = $Parameters[$key]
    }

    Set-Busy $true $BusyMessage
    Add-Log "> proxy-manager.ps1 $Command"
    try {
        $records = @(& $script:ManagerPath $Command @invokeParameters 2>&1)
        $text = Convert-RecordsToText $records
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw "$Command returned no JSON result"
        }
        return $text | ConvertFrom-Json
    }
    catch {
        $message = $_.Exception.Message
        Add-Log "ERROR: $message"
        [System.Windows.Forms.MessageBox]::Show(
            $message,
            'Operation failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return $null
    }
    finally {
        Set-Busy $false 'Ready'
    }
}

function Ensure-UiSshKeyAuthentication {
    param(
        $Target,
        [switch]$SuppressInteractionNotice
    )

    $parameters = Convert-TargetToParameters $Target
    $readiness = Invoke-ManagerJsonCommand `
        -Command 'prepare-ssh' `
        -Parameters $parameters `
        -BusyMessage 'Preparing SSH key authentication...'
    if ($null -eq $readiness) {
        return $false
    }

    if ([bool]$readiness.IdentityCreated) {
        Add-Log 'Created a passwordless Ed25519 SSH identity for unattended reconnects.'
    }
    elseif ([bool]$readiness.PublicKeyUpdated) {
        Add-Log 'Rebuilt the SSH public-key file from the selected private key.'
    }
    if ([bool]$readiness.Ready) {
        Add-Log "SSH key authentication is already ready for $($Target.name); no console is needed."
        return $true
    }

    if (-not $SuppressInteractionNotice) {
        [System.Windows.Forms.MessageBox]::Show(
            'SSH key login is not ready yet. A separate console will open. Enter the Linux password once (and confirm the host fingerprint if asked); the password is never stored.',
            'Configure SSH key login',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    return Invoke-InteractiveManagerCommand `
        -Command 'bootstrap-key' `
        -Parameters $parameters `
        -BusyMessage 'Configuring SSH key login...'
}

function Invoke-InteractiveManagerCommand {
    param(
        [string]$Command,
        [hashtable]$Parameters = @{},
        [string]$BusyMessage = 'Waiting for interactive command...'
    )

    $payload = [pscustomobject]@{
        ManagerPath = $script:ManagerPath
        Command = $Command
        Config = $Config
        Parameters = $Parameters
    }
    $payloadJson = $payload | ConvertTo-Json -Depth 8 -Compress
    $payloadBase64 = [Convert]::ToBase64String($script:Utf8Encoding.GetBytes($payloadJson))
    $childSource = @"
`$ErrorActionPreference = 'Stop'
`$payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payloadBase64'))
`$payload = `$payloadJson | ConvertFrom-Json
`$invokeParameters = @{ Config = [string]`$payload.Config; Confirm = `$false }
foreach (`$property in `$payload.Parameters.PSObject.Properties) {
    if (`$property.Value -is [array]) {
        `$invokeParameters[`$property.Name] = @(`$property.Value)
    }
    else {
        `$invokeParameters[`$property.Name] = `$property.Value
    }
}
try {
    & ([string]`$payload.ManagerPath) ([string]`$payload.Command) @invokeParameters
}
catch {
    Write-Error `$_.Exception.Message
    exit 1
}
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childSource))
    $argumentValues = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $encodedCommand
    )
    $argumentLine = ($argumentValues | ForEach-Object {
        ConvertTo-WindowsArgument ([string]$_)
    }) -join ' '

    Set-Busy $true $BusyMessage
    Add-Log "> proxy-manager.ps1 $Command (interactive console)"
    try {
        $process = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList $argumentLine `
            -WorkingDirectory $PSScriptRoot `
            -WindowStyle Normal `
            -Wait `
            -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Interactive command exited with code $($process.ExitCode)."
        }
        Add-Log "$Command completed."
        return $true
    }
    catch {
        $message = $_.Exception.Message
        Add-Log "ERROR: $message"
        [System.Windows.Forms.MessageBox]::Show(
            "$message`r`n`r`nRun the command again and review the separate console if more detail is needed.",
            'Operation failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return $false
    }
    finally {
        Set-Busy $false 'Ready'
    }
}

function Get-SelectedTargetRow {
    if ($script:Grid.SelectedRows.Count -eq 0) {
        return $null
    }
    return $script:Grid.SelectedRows[0]
}

function Get-SelectedTargetName {
    $row = Get-SelectedTargetRow
    if ($null -eq $row) {
        [System.Windows.Forms.MessageBox]::Show(
            'Select a Linux target first.',
            'Clash SSH Proxy Manager',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return $null
    }
    return [string]$row.Cells['TargetName'].Value
}

function Get-TargetRowByName {
    param([string]$Name)

    foreach ($row in @($script:Grid.Rows)) {
        if ([string]$row.Cells['TargetName'].Value -eq $Name) {
            return $row
        }
    }
    return $null
}
