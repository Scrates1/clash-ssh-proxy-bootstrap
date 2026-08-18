[CmdletBinding()]
param(
    [string]$Config,
    [switch]$SmokeTest,
    [switch]$LauncherSmokeTest
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

$script:RepositoryRoot = $PSScriptRoot
$commonPath = Join-Path $script:RepositoryRoot 'src/Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "Shared module was not found: $commonPath"
}
. $commonPath

$script:UiModuleRoot = Join-Path $script:RepositoryRoot 'src/ui'
$bootstrapPath = Join-Path $script:UiModuleRoot 'Bootstrap.ps1'
if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) {
    throw "UI bootstrap module was not found: $bootstrapPath"
}
. $bootstrapPath

if ([string]::IsNullOrWhiteSpace($Config)) {
    $Config = Get-DefaultConfigPath
}
$Config = [Environment]::ExpandEnvironmentVariables($Config)

if (-not $SmokeTest -and -not (Test-Administrator)) {
    try {
        $argumentValues = @(
            '-NoLogo',
            '-NoProfile',
            '-WindowStyle', 'Hidden',
            '-ExecutionPolicy', 'Bypass',
            '-File', $PSCommandPath,
            '-Config', $Config
        )
        $argumentLine = ($argumentValues | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' '
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $argumentLine | Out-Null
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

$script:InstanceMutex = $null
if (-not $SmokeTest) {
    $script:InstanceMutex = Enter-UiInstanceMutex
    if ($null -eq $script:InstanceMutex) {
        [System.Windows.Forms.MessageBox]::Show(
            'Clash SSH Proxy Manager is already running for this Windows session.',
            'Clash SSH Proxy Manager',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }
}

$script:HealthCache = @{}
$script:HealthGenerations = @{}
$script:BackgroundHealthChecks = @{}
$script:HealthTimer = $null
$script:BackgroundRecoveries = @{}
$script:RecoveryTimer = $null
$script:StartupRecoveryTimer = $null
$script:StartupRecoveryActive = $false
$script:StartupRecoveryAttempt = 0
$script:StartupRecoveryAttemptLimit = 15
$script:StartupRecoveryWaitLogged = $false
$script:MissingRecoveryTargets = @{}
$script:TaskSchedulerService = $null
$script:TaskSchedulerRoot = $null

foreach ($moduleName in @('Runtime.ps1', 'Health.ps1', 'Recovery.ps1', 'Dialogs.ps1')) {
    $modulePath = Join-Path $script:UiModuleRoot $moduleName
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "UI module was not found: $modulePath"
    }
    . $modulePath
}

if ($LauncherSmokeTest) {
    if (-not $SmokeTest) {
        throw 'LauncherSmokeTest is only available with SmokeTest.'
    }
    [void](Read-UiConfig)
    Write-Output 'Windowless launcher smoke test passed'
    return
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

$doubleBufferedProperty = $script:Grid.GetType().GetProperty(
    'DoubleBuffered',
    [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
)
$doubleBufferedProperty.SetValue($script:Grid, $true, $null)

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
$script:healthButton = New-ActionButton 'Health check' 108
$helpButton = New-ActionButton 'Help' 78
$advancedButton = New-ActionButton 'Advanced...' 104

$advancedMenu = New-Object System.Windows.Forms.ContextMenuStrip
$keyMenuItem = $advancedMenu.Items.Add('Configure SSH login')
$refreshMenuItem = $advancedMenu.Items.Add('Refresh local status')
$advancedMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$removeMenuItem = $advancedMenu.Items.Add('Remove target')
$keyMenuItem.ToolTipText = 'Prepare a local key, reuse it when already authorized, or request the Linux password once.'
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
    $taskState = [string]$row.Cells['TaskState'].Value
    $decision = Get-TargetRecoveryDecision $enabled $taskState
    $accessButton.Text = if ($taskState -eq 'Missing') {
        $accessButton.Enabled = $false
        'Update required'
    }
    elseif (-not $enabled) {
        'Enable proxy'
    }
    elseif ($decision -eq 'Recover') {
        'Restart proxy'
    }
    else {
        'Disable proxy'
    }
}

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 12000
$toolTip.InitialDelay = 400
$toolTip.ReshowDelay = 100
$toolTip.SetToolTip($addButton, 'Install and manage a new Linux target.')
$toolTip.SetToolTip($editButton, 'Change settings, redeploy files, and rebuild the tunnel task.')
$toolTip.SetToolTip($accessButton, 'Enable or disable persistent access to the Windows proxy.')
$toolTip.SetToolTip($advancedButton, 'Open SSH key, local refresh, and removal actions.')
$toolTip.SetToolTip($script:healthButton, 'Check all Linux targets in parallel. Click again to cancel running checks.')
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

$script:HealthTimer = New-Object System.Windows.Forms.Timer
$script:HealthTimer.Interval = 250
$script:HealthTimer.Add_Tick({
    try {
        Complete-BackgroundHealthChecks
    }
    catch {
        Add-Log "BACKGROUND HEALTH TIMER ERROR: $($_.Exception.Message)"
    }
})

$script:RecoveryTimer = New-Object System.Windows.Forms.Timer
$script:RecoveryTimer.Interval = 250
$script:RecoveryTimer.Add_Tick({
    try {
        Complete-BackgroundTargetRecoveries
    }
    catch {
        Add-Log "BACKGROUND RECOVERY TIMER ERROR: $($_.Exception.Message)"
    }
})

$script:StartupRecoveryTimer = New-Object System.Windows.Forms.Timer
$script:StartupRecoveryTimer.Interval = 2000
$script:StartupRecoveryTimer.Add_Tick({
    try {
        Invoke-StartupRecoveryTick
    }
    catch {
        Add-Log "STARTUP RECOVERY TIMER ERROR: $($_.Exception.Message)"
    }
})

function Invoke-SelectedAccessToggle {
    $name = Get-SelectedTargetName
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $row = Get-SelectedTargetRow
    $enabled = [bool]$row.Cells['Enabled'].Value
    $taskState = [string]$row.Cells['TaskState'].Value
    if ($taskState -eq 'Missing') {
        Add-Log "Cannot change proxy access for $name because its scheduled task is missing. Use Edit / Update first."
        $script:StatusLabel.Text = "Update required for $name"
        return
    }
    [void](Stop-BackgroundTargetRecoveries -Name $name)
    if ($enabled -and $taskState -notin @('Ready', 'Disabled')) {
        $command = 'disable'
        $busyMessage = 'Disabling proxy access...'
    }
    else {
        $command = 'enable'
        $busyMessage = if ($enabled) { 'Restarting proxy access...' } else { 'Enabling proxy access...' }
    }

    $generation = Reset-TargetHealth $name
    if (Invoke-ManagerCommand $command @{ Name = $name } $busyMessage) {
        Refresh-TargetGrid
        try {
            Start-BackgroundTargetHealthCheck $name $generation ($command -eq 'enable')
        }
        catch {
            Add-Log "BACKGROUND HEALTH START ERROR for ${name}: $($_.Exception.Message)"
            $script:StatusLabel.Text = "$command completed for $name; background verification could not start"
        }
    }
    else {
        Refresh-TargetGrid
    }
}

$addButton.Add_Click({
    $target = Show-TargetDialog 'Add Linux target' $null
    if ($null -eq $target) { return }
    $parameters = Convert-TargetToParameters $target
    if ($target.autoConfigureSsh -and -not (Ensure-UiSshKeyAuthentication $target)) {
        return
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
    [void](Stop-BackgroundTargetRecoveries -Name $name)
    [void](Reset-TargetHealth $name)
    if (Invoke-ManagerCommand 'update' (Convert-TargetToParameters $target) 'Updating Linux target...') {
        Refresh-TargetGrid
    }
})

$keyMenuItem.Add_Click({
    $target = Get-SelectedResolvedTarget
    if ($null -eq $target) { return }
    Ensure-UiSshKeyAuthentication $target | Out-Null
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
    [void](Stop-BackgroundTargetRecoveries -Name $name)
    [void](Reset-TargetHealth $name)
    if (Invoke-ManagerCommand 'remove' @{ Name = $name } 'Removing target...') {
        Refresh-TargetGrid
    }
})

$refreshMenuItem.Add_Click({ Refresh-TargetGrid })
$advancedButton.Add_Click({
    Update-ActionState
    $advancedMenu.Show($advancedButton, (New-Object System.Drawing.Point(0, $advancedButton.Height)))
})
$script:healthButton.Add_Click({ Invoke-HealthCheck })
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
    Add-Log 'Manager started. Enable and Disable return after local changes, then verify the selected Linux proxy in the background.'
    Refresh-TargetGrid
    Start-StartupRecovery
})
$script:Form.Add_FormClosed({
    Stop-BackgroundRecoveries
    Stop-BackgroundHealthChecks
    if ($null -ne $script:InstanceMutex) {
        Exit-UiInstanceMutex $script:InstanceMutex
        $script:InstanceMutex = $null
    }
})

if ($SmokeTest) {
    $smokePath = Join-Path $script:RepositoryRoot 'tests/UiSmoke.ps1'
    if (-not (Test-Path -LiteralPath $smokePath -PathType Leaf)) {
        throw "UI smoke test was not found: $smokePath"
    }
    . $smokePath
    return
}

[System.Windows.Forms.Application]::Run($script:Form)
