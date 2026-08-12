[CmdletBinding()]
param(
    [string]$Config,
    [switch]$SmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Utf8Encoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $script:Utf8Encoding
try {
    [Console]::InputEncoding = $script:Utf8Encoding
} catch {}
try {
    [Console]::OutputEncoding = $script:Utf8Encoding
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-DefaultConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return Join-Path $env:LOCALAPPDATA 'ClashSshProxy\config.json'
    }
    return Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\ClashSshProxy\config.json'
}

function ConvertTo-WindowsArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ([string]::IsNullOrWhiteSpace($Config)) {
    $Config = Get-DefaultConfigPath
}
$Config = [Environment]::ExpandEnvironmentVariables($Config)

if (-not $SmokeTest -and -not (Test-Administrator)) {
    try {
        $argumentValues = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $PSCommandPath,
            '-Config', $Config
        )
        $argumentLine = ($argumentValues | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' '
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentLine | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Administrator access is required to manage scheduled tasks.`r`n`r`n$($_.Exception.Message)",
            'Clash SSH Proxy Manager',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    return
}

$script:ManagerPath = Join-Path $PSScriptRoot 'proxy-manager.ps1'
if (-not (Test-Path -LiteralPath $script:ManagerPath -PathType Leaf)) {
    throw "Manager script was not found: $script:ManagerPath"
}

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
        return Get-Content -Raw -LiteralPath $Config | ConvertFrom-Json
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

function Test-LocalTcpPort {
    param(
        [string]$HostName,
        [int]$Port
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        return $task.Wait(800) -and $client.Connected
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

function Refresh-TargetGrid {
    param([hashtable]$Health = @{})

    $selectedRow = Get-SelectedTargetRow
    $selectedName = if ($null -eq $selectedRow) {
        $null
    } else {
        [string]$selectedRow.Cells['TargetName'].Value
    }
    try {
        $managerConfig = Read-UiConfig
        $script:Grid.Rows.Clear()
        $proxyHost = [string]$managerConfig.proxy.localHost
        $proxyPort = [int]$managerConfig.proxy.localPort
        $proxyUp = Test-LocalTcpPort $proxyHost $proxyPort
        $script:ProxyLabel.Text = "Local proxy: ${proxyHost}:$proxyPort  " + $(if ($proxyUp) { '[UP]' } else { '[DOWN]' })
        $script:ProxyLabel.ForeColor = if ($proxyUp) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::Firebrick }

        foreach ($rawTarget in @($managerConfig.targets)) {
            $target = Resolve-UiTarget $managerConfig $rawTarget
            $task = Get-ScheduledTask -TaskName $target.taskName -ErrorAction SilentlyContinue
            $taskState = if ($null -eq $task) { 'Missing' } else { [string]$task.State }
            $sshState = '-'
            $proxyState = if ($target.enabled) { '-' } else { 'DISABLED' }
            if ($Health.ContainsKey($target.name)) {
                $sshState = [string]$Health[$target.name].SSH
                $proxyState = [string]$Health[$target.name].Proxy
                $taskState = [string]$Health[$target.name].TaskState
            }

            $rowIndex = $script:Grid.Rows.Add()
            $row = $script:Grid.Rows[$rowIndex]
            $row.Cells['Enabled'].Value = [bool]$target.enabled
            $row.Cells['TargetName'].Value = $target.name
            $row.Cells['Destination'].Value = "$($target.user)@$($target.host):$($target.sshPort)"
            $row.Cells['TaskState'].Value = $taskState
            $row.Cells['SshState'].Value = $sshState
            $row.Cells['ProxyState'].Value = $proxyState
            $row.Cells['RemotePort'].Value = $target.remoteProxyPort
            $row.Cells['TaskName'].Value = $target.taskName

            if ($proxyState -eq 'LEAK') {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkRed
                $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightCoral
            }
            elseif (-not $target.enabled) {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DimGray
                $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::Gainsboro
            }
            elseif ($taskState -ne 'Running') {
                $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose
            }
        }
        $script:Grid.ClearSelection()
        $rowToSelect = $null
        if (-not [string]::IsNullOrWhiteSpace($selectedName)) {
            $rowToSelect = @($script:Grid.Rows | Where-Object {
                [string]$_.Cells['TargetName'].Value -eq $selectedName
            } | Select-Object -First 1)
        }
        if (@($rowToSelect).Count -eq 0 -and $script:Grid.Rows.Count -gt 0) {
            $rowToSelect = @($script:Grid.Rows[0])
        }
        if (@($rowToSelect).Count -eq 1) {
            $rowToSelect[0].Selected = $true
        }
        $script:ConfigLabel.Text = "Private config: $Config"
        $script:StatusLabel.Text = "Ready - $($script:Grid.Rows.Count) target(s)"
        Update-ActionState
    }
    catch {
        Add-Log "REFRESH ERROR: $($_.Exception.Message)"
        $script:StatusLabel.Text = 'Configuration error'
    }
}

function Invoke-HealthCheck {
    Set-Busy $true 'Checking SSH and proxy connectivity...'
    Add-Log '> proxy-manager.ps1 status -Json'
    try {
        $records = @(& $script:ManagerPath status -Config $Config -Json 2>&1)
        $json = Convert-RecordsToText $records
        $items = @()
        if (-not [string]::IsNullOrWhiteSpace($json)) {
            $items = @($json | ConvertFrom-Json)
        }
        $health = @{}
        foreach ($item in $items) {
            $health[[string]$item.Name] = $item
        }
        Refresh-TargetGrid $health
        Add-Log 'Health check completed.'
    }
    catch {
        $message = $_.Exception.Message
        Add-Log "HEALTH CHECK ERROR: $message"
        [System.Windows.Forms.MessageBox]::Show(
            $message,
            'Health check failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        Set-Busy $false 'Ready'
    }
}

function Show-HelpDialog {
    $helpPath = Join-Path $PSScriptRoot 'docs\WINDOWS-UI.zh-CN.md'
    if (-not (Test-Path -LiteralPath $helpPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Help document was not found: $helpPath",
            'Help',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Clash SSH Proxy Manager - Help'
    $dialog.Size = New-Object System.Drawing.Size(860, 680)
    $dialog.MinimumSize = New-Object System.Drawing.Size(700, 520)
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.ShowInTaskbar = $false

    $helpText = New-Object System.Windows.Forms.RichTextBox
    $helpText.Dock = [System.Windows.Forms.DockStyle]::Fill
    $helpText.ReadOnly = $true
    $helpText.BackColor = [System.Drawing.Color]::White
    $helpText.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $helpText.DetectUrls = $true
    $helpText.Text = Get-Content -Raw -Encoding UTF8 -LiteralPath $helpPath
    $dialog.Controls.Add($helpText)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $closeButton.Height = 38
    $closeButton.Add_Click({ $dialog.Close() })
    $dialog.Controls.Add($closeButton)
    $dialog.AcceptButton = $closeButton
    $dialog.CancelButton = $closeButton

    $dialog.ShowDialog($script:Form) | Out-Null
    $dialog.Dispose()
}

function Show-TargetDialog {
    param(
        [string]$Title,
        [AllowNull()]$ExistingTarget
    )

    $managerConfig = Read-UiConfig
    $isEdit = $null -ne $ExistingTarget
    if ($isEdit) {
        $target = Resolve-UiTarget $managerConfig $ExistingTarget
    }
    else {
        $target = [pscustomobject]@{
            name = ''
            host = ''
            user = ''
            taskName = ''
            sshPort = [int]$managerConfig.defaults.sshPort
            identityFile = [string]$managerConfig.defaults.identityFile
            remoteProxyPort = [int]$managerConfig.defaults.remoteProxyPort
            noProxyExtra = @($managerConfig.defaults.noProxyExtra)
        }
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.ClientSize = New-Object System.Drawing.Size(610, 390)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.ShowInTaskbar = $false

    function Add-DialogLabel {
        param([string]$Text, [int]$Top)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Location = New-Object System.Drawing.Point(14, $Top)
        $label.Size = New-Object System.Drawing.Size(135, 24)
        $dialog.Controls.Add($label)
    }

    function Add-DialogTextBox {
        param([string]$Text, [int]$Top, [int]$Width = 420)
        $box = New-Object System.Windows.Forms.TextBox
        $box.Text = $Text
        $box.Location = New-Object System.Drawing.Point(155, ($Top - 3))
        $box.Size = New-Object System.Drawing.Size($Width, 24)
        $dialog.Controls.Add($box)
        return $box
    }

    Add-DialogLabel 'Target name' 20
    $nameBox = Add-DialogTextBox $target.name 20
    $nameBox.ReadOnly = $isEdit
    Add-DialogLabel 'Linux host / IP' 55
    $hostBox = Add-DialogTextBox $target.host 55
    Add-DialogLabel 'Linux user' 90
    $userBox = Add-DialogTextBox $target.user 90
    Add-DialogLabel 'SSH port' 125
    $sshPortBox = Add-DialogTextBox ([string]$target.sshPort) 125 120
    Add-DialogLabel 'SSH private key' 160
    $identityBox = Add-DialogTextBox $target.identityFile 160 350
    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = 'Browse...'
    $browseButton.Location = New-Object System.Drawing.Point(510, 155)
    $browseButton.Size = New-Object System.Drawing.Size(75, 27)
    $dialog.Controls.Add($browseButton)
    Add-DialogLabel 'Remote proxy port' 195
    $remotePortBox = Add-DialogTextBox ([string]$target.remoteProxyPort) 195 120
    Add-DialogLabel 'Scheduled task' 230
    $taskBox = Add-DialogTextBox $target.taskName 230
    Add-DialogLabel 'Extra NO_PROXY' 265
    $noProxyBox = Add-DialogTextBox (@($target.noProxyExtra) -join ',') 265

    $bootstrapBox = New-Object System.Windows.Forms.CheckBox
    $bootstrapBox.Text = 'Install the SSH public key first (a Linux password may be requested in the console)'
    $bootstrapBox.Location = New-Object System.Drawing.Point(155, 297)
    $bootstrapBox.Size = New-Object System.Drawing.Size(430, 28)
    $bootstrapBox.Visible = -not $isEdit
    $dialog.Controls.Add($bootstrapBox)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = if ($isEdit) { 'Update' } else { 'Add' }
    $okButton.Location = New-Object System.Drawing.Point(410, 340)
    $okButton.Size = New-Object System.Drawing.Size(80, 30)
    $dialog.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(500, 340)
    $cancelButton.Size = New-Object System.Drawing.Size(80, 30)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)
    $dialog.CancelButton = $cancelButton

    $browseButton.Add_Click({
        $picker = New-Object System.Windows.Forms.OpenFileDialog
        $picker.Title = 'Select an SSH private key'
        $picker.CheckFileExists = $true
        if ($picker.ShowDialog($dialog) -eq [System.Windows.Forms.DialogResult]::OK) {
            $identityBox.Text = $picker.FileName
        }
        $picker.Dispose()
    })

    $okButton.Add_Click({
        $name = $nameBox.Text.Trim()
        $hostName = $hostBox.Text.Trim()
        $userName = $userBox.Text.Trim()
        $identityFile = $identityBox.Text.Trim()
        $taskName = $taskBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($taskName) -and $name -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            $taskName = "ClashProxyTo-$name"
        }

        [int]$sshPort = 0
        [int]$remotePort = 0
        $validationError = $null
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            $validationError = 'Target name may contain letters, numbers, dots, underscores, and hyphens.'
        }
        elseif ([string]::IsNullOrWhiteSpace($hostName) -or $hostName -match '\s') {
            $validationError = 'Enter a valid Linux host name or IP address.'
        }
        elseif ([string]::IsNullOrWhiteSpace($userName) -or $userName -match '\s') {
            $validationError = 'Enter a valid Linux user name.'
        }
        elseif (-not [int]::TryParse($sshPortBox.Text, [ref]$sshPort) -or $sshPort -lt 1 -or $sshPort -gt 65535) {
            $validationError = 'SSH port must be between 1 and 65535.'
        }
        elseif ([string]::IsNullOrWhiteSpace($identityFile)) {
            $validationError = 'Select an SSH private key.'
        }
        elseif (-not [int]::TryParse($remotePortBox.Text, [ref]$remotePort) -or $remotePort -lt 1 -or $remotePort -gt 65535) {
            $validationError = 'Remote proxy port must be between 1 and 65535.'
        }
        elseif ([string]::IsNullOrWhiteSpace($taskName) -or $taskName -match '[\\/:*?"<>|]') {
            $validationError = 'Scheduled task name contains an invalid character.'
        }

        if ($null -ne $validationError) {
            [System.Windows.Forms.MessageBox]::Show(
                $validationError,
                'Invalid target',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        $extraValues = @($noProxyBox.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $dialog.Tag = [pscustomobject]@{
            name = $name
            host = $hostName
            user = $userName
            taskName = $taskName
            sshPort = $sshPort
            identityFile = $identityFile
            remoteProxyPort = $remotePort
            noProxyExtra = $extraValues
            bootstrapKey = [bool]$bootstrapBox.Checked
        }
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $result = $null
    if ($dialog.ShowDialog($script:Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $result = $dialog.Tag
    }
    $dialog.Dispose()
    return $result
}

function Convert-TargetToParameters {
    param($Target)
    $parameters = @{
        Name = $Target.name
        RemoteHost = $Target.host
        RemoteUser = $Target.user
        SshPort = [int]$Target.sshPort
        IdentityFile = $Target.identityFile
        RemoteProxyPort = [int]$Target.remoteProxyPort
        TaskName = $Target.taskName
    }
    if (@($Target.noProxyExtra).Count -gt 0) {
        $parameters.NoProxyExtra = @($Target.noProxyExtra)
    }
    return $parameters
}

function Get-SelectedResolvedTarget {
    $name = Get-SelectedTargetName
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $null
    }
    $managerConfig = Read-UiConfig
    $rawTarget = @($managerConfig.targets | Where-Object { $_.name -eq $name })
    if ($rawTarget.Count -ne 1) {
        throw "Target '$name' was not found in the private configuration."
    }
    return Resolve-UiTarget $managerConfig $rawTarget[0]
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'Clash SSH Proxy Manager'
$script:Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$script:Form.MinimumSize = New-Object System.Drawing.Size(1050, 720)
$script:Form.Size = New-Object System.Drawing.Size(1180, 790)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'Linux proxy access control'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(12, 10)
$titleLabel.Size = New-Object System.Drawing.Size(450, 32)
$script:Form.Controls.Add($titleLabel)

$script:ProxyLabel = New-Object System.Windows.Forms.Label
$script:ProxyLabel.Location = New-Object System.Drawing.Point(14, 46)
$script:ProxyLabel.Size = New-Object System.Drawing.Size(360, 22)
$script:Form.Controls.Add($script:ProxyLabel)

$script:ConfigLabel = New-Object System.Windows.Forms.Label
$script:ConfigLabel.Location = New-Object System.Drawing.Point(380, 46)
$script:ConfigLabel.Size = New-Object System.Drawing.Size(760, 22)
$script:ConfigLabel.TextAlign = [System.Drawing.ContentAlignment]::TopRight
$script:ConfigLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:Form.Controls.Add($script:ConfigLabel)

$script:Grid = New-Object System.Windows.Forms.DataGridView
$script:Grid.Location = New-Object System.Drawing.Point(12, 72)
$script:Grid.Size = New-Object System.Drawing.Size(1140, 350)
$script:Grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:Grid.AllowUserToAddRows = $false
$script:Grid.AllowUserToDeleteRows = $false
$script:Grid.AllowUserToResizeRows = $false
$script:Grid.ReadOnly = $true
$script:Grid.MultiSelect = $false
$script:Grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$script:Grid.RowHeadersVisible = $false
$script:Grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$script:Grid.BackgroundColor = [System.Drawing.Color]::White

$enabledColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$enabledColumn.Name = 'Enabled'
$enabledColumn.HeaderText = 'Enabled'
$enabledColumn.FillWeight = 50
$enabledColumn.ToolTipText = 'Click the checkbox to enable or disable proxy access.'
$script:Grid.Columns.Add($enabledColumn) | Out-Null

foreach ($definition in @(
    @('TargetName', 'Target', 90),
    @('Destination', 'Linux destination', 150),
    @('TaskState', 'Task', 70),
    @('SshState', 'SSH', 55),
    @('ProxyState', 'Proxy', 55),
    @('RemotePort', 'Remote port', 65),
    @('TaskName', 'Scheduled task name', 135)
)) {
    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $definition[0]
    $column.HeaderText = $definition[1]
    $column.FillWeight = [single]$definition[2]
    $script:Grid.Columns.Add($column) | Out-Null
}
$script:Form.Controls.Add($script:Grid)

$script:ActionPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$script:ActionPanel.Location = New-Object System.Drawing.Point(12, 432)
$script:ActionPanel.Size = New-Object System.Drawing.Size(1140, 44)
$script:ActionPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:ActionPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$script:ActionPanel.WrapContents = $true
$script:Form.Controls.Add($script:ActionPanel)

function New-ActionButton {
    param([string]$Text, [int]$Width = 102)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size($Width, 31)
    $button.Margin = New-Object System.Windows.Forms.Padding(3)
    $script:ActionPanel.Controls.Add($button)
    return $button
}

$addButton = New-ActionButton 'Add target'
$editButton = New-ActionButton 'Edit / Update' 112
$accessButton = New-ActionButton 'Proxy access' 118
$healthButton = New-ActionButton 'Health check' 108
$helpButton = New-ActionButton 'Help' 78
$advancedButton = New-ActionButton 'Advanced...' 104

$advancedMenu = New-Object System.Windows.Forms.ContextMenuStrip
$keyMenuItem = $advancedMenu.Items.Add('Install SSH key')
$refreshMenuItem = $advancedMenu.Items.Add('Refresh local status')
$advancedMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$removeMenuItem = $advancedMenu.Items.Add('Remove target')
$keyMenuItem.ToolTipText = 'Append the Windows SSH public key to the selected Linux account.'
$refreshMenuItem.ToolTipText = 'Refresh local config, Clash port, and scheduled-task state only.'
$removeMenuItem.ToolTipText = 'Remove the task, private target entry, and Linux shell integration.'

function Update-ActionState {
    $row = Get-SelectedTargetRow
    $hasSelection = $null -ne $row
    $editButton.Enabled = $hasSelection
    $accessButton.Enabled = $hasSelection
    $keyMenuItem.Enabled = $hasSelection
    $removeMenuItem.Enabled = $hasSelection
    if (-not $hasSelection) {
        $accessButton.Text = 'Proxy access'
        return
    }
    $enabled = [bool]$row.Cells['Enabled'].Value
    $accessButton.Text = if ($enabled) { 'Disable proxy' } else { 'Enable proxy' }
}

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 12000
$toolTip.InitialDelay = 400
$toolTip.ReshowDelay = 100
$toolTip.SetToolTip($addButton, 'Install and manage a new Linux target.')
$toolTip.SetToolTip($editButton, 'Change settings, redeploy files, and rebuild the tunnel task.')
$toolTip.SetToolTip($accessButton, 'Enable or disable persistent access to the Windows proxy.')
$toolTip.SetToolTip($advancedButton, 'Open SSH key, local refresh, and removal actions.')
$toolTip.SetToolTip($healthButton, 'Contact Linux and verify SSH plus proxy state end to end.')
$toolTip.SetToolTip($helpButton, 'Open the built-in Chinese user guide.')

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Location = New-Object System.Drawing.Point(12, 486)
$script:LogBox.Size = New-Object System.Drawing.Size(1140, 219)
$script:LogBox.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:LogBox.Multiline = $true
$script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$script:LogBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:Form.Controls.Add($script:LogBox)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$script:StatusLabel.Spring = $true
$script:StatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusStrip.Items.Add($script:StatusLabel) | Out-Null
$script:Form.Controls.Add($statusStrip)

function Invoke-SelectedAccessToggle {
    $name = Get-SelectedTargetName
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $row = Get-SelectedTargetRow
    $enabled = [bool]$row.Cells['Enabled'].Value
    if ($enabled) {
        $command = 'disable'
        $busyMessage = 'Disabling proxy access...'
    }
    else {
        $command = 'enable'
        $busyMessage = 'Enabling proxy access...'
    }

    if (Invoke-ManagerCommand $command @{ Name = $name } $busyMessage) {
        Refresh-TargetGrid
    }
}

$addButton.Add_Click({
    $target = Show-TargetDialog 'Add Linux target' $null
    if ($null -eq $target) { return }
    $parameters = Convert-TargetToParameters $target
    if ($target.bootstrapKey) {
        [System.Windows.Forms.MessageBox]::Show(
            'The Linux password prompt appears in the PowerShell console. The password is never stored.',
            'SSH public key setup',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        if (-not (Invoke-ManagerCommand 'bootstrap-key' $parameters 'Installing SSH public key...')) { return }
    }
    if (Invoke-ManagerCommand 'add' $parameters 'Installing Linux target...') {
        Refresh-TargetGrid
    }
})

$editButton.Add_Click({
    $name = Get-SelectedTargetName
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $managerConfig = Read-UiConfig
    $rawTarget = @($managerConfig.targets | Where-Object { $_.name -eq $name })
    if ($rawTarget.Count -ne 1) { return }
    $target = Show-TargetDialog 'Edit Linux target' $rawTarget[0]
    if ($null -eq $target) { return }
    if (Invoke-ManagerCommand 'update' (Convert-TargetToParameters $target) 'Updating Linux target...') {
        Refresh-TargetGrid
    }
})

$keyMenuItem.Add_Click({
    $target = Get-SelectedResolvedTarget
    if ($null -eq $target) { return }
    [System.Windows.Forms.MessageBox]::Show(
        'If needed, enter the Linux password in the PowerShell console. The password is never stored.',
        'SSH public key setup',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    Invoke-ManagerCommand 'bootstrap-key' (Convert-TargetToParameters $target) 'Installing SSH public key...' | Out-Null
})

$accessButton.Add_Click({
    Invoke-SelectedAccessToggle
})


$removeMenuItem.Add_Click({
    $name = Get-SelectedTargetName
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Remove '$name'? This removes its Windows task and Linux shell integration.",
        'Confirm removal',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    if (Invoke-ManagerCommand 'remove' @{ Name = $name } 'Removing target...') {
        Refresh-TargetGrid
    }
})

$refreshMenuItem.Add_Click({ Refresh-TargetGrid })
$advancedButton.Add_Click({
    Update-ActionState
    $advancedMenu.Show($advancedButton, (New-Object System.Drawing.Point(0, $advancedButton.Height)))
})
$healthButton.Add_Click({ Invoke-HealthCheck })
$helpButton.Add_Click({ Show-HelpDialog })
$script:Grid.Add_SelectionChanged({ Update-ActionState })
$script:Grid.Add_CellContentClick({
    param($sender, $eventArgs)
    if ($eventArgs.RowIndex -lt 0 -or
        $eventArgs.ColumnIndex -ne $script:Grid.Columns['Enabled'].Index) {
        return
    }
    $script:Grid.ClearSelection()
    $row = $script:Grid.Rows[$eventArgs.RowIndex]
    $row.Selected = $true
    $script:Grid.CurrentCell = $row.Cells['Enabled']
    Invoke-SelectedAccessToggle
})
$script:Grid.Add_CellDoubleClick({
    param($sender, $eventArgs)
    if ($eventArgs.RowIndex -ge 0 -and
        $eventArgs.ColumnIndex -ne $script:Grid.Columns['Enabled'].Index) {
        $editButton.PerformClick()
    }
})
$script:Form.Add_Shown({
    Add-Log 'Manager started. Quick refresh does not contact Linux hosts; use Health check for end-to-end verification.'
    Refresh-TargetGrid
})

if ($SmokeTest) {
    $unicodeProbe = ([string][char]0x65E5) + ([string][char]0x5FD7)
    $nativeCommand = '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); [Console]::Write(([string][char]0x65E5) + ([string][char]0x5FD7))'
    $decodedProbe = (& powershell.exe -NoLogo -NoProfile -NonInteractive -Command $nativeCommand | Out-String).Trim()
    if ($decodedProbe -ne $unicodeProbe) {
        throw 'UI native UTF-8 decoding smoke test failed'
    }
    Add-Log $decodedProbe
    if (-not $script:LogBox.Text.Contains($unicodeProbe)) {
        throw 'UI log Unicode rendering smoke test failed'
    }
    $escape = [string][char]27
    Add-Log ($escape + '[31mANSI-CHECK' + $escape + '[0m')
    if ($script:LogBox.Text.Contains($escape)) {
        throw 'UI log ANSI cleanup smoke test failed'
    }
    Refresh-TargetGrid
    if ($script:Grid.Rows.Count -gt 0) {
        $row = $script:Grid.Rows[0]
        $script:Grid.ClearSelection()
        $row.Selected = $true
        $originalEnabled = [bool]$row.Cells['Enabled'].Value
        Update-ActionState
        $expectedText = if ($originalEnabled) { 'Disable proxy' } else { 'Enable proxy' }
        if ($accessButton.Text -ne $expectedText) {
            throw 'UI primary proxy action does not match the target state'
        }
        $row.Cells['Enabled'].Value = $false
        Update-ActionState
        if ($accessButton.Text -ne 'Enable proxy') {
            throw 'UI did not offer Enable proxy for a disabled target'
        }
        $row.Cells['Enabled'].Value = $true
        Update-ActionState
        if ($accessButton.Text -ne 'Disable proxy') {
            throw 'UI did not offer Disable proxy for an enabled target'
        }
        $row.Cells['Enabled'].Value = $originalEnabled
        Update-ActionState
    }
    $advancedLabels = @($advancedMenu.Items | ForEach-Object { [string]$_.Text })
    if (@($advancedLabels | Where-Object { $_ -match '(?i)\b(start|stop)\b' }).Count -gt 0) {
        throw 'Advanced UI unexpectedly exposes Start or Stop'
    }
    $script:Form.Dispose()
    Write-Output 'UI smoke test passed'
    return
}

[System.Windows.Forms.Application]::Run($script:Form)
