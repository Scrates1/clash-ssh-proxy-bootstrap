# Help and target-editing dialogs plus target parameter conversion.

function Show-HelpDialog {
    $helpPath = Join-Path $script:RepositoryRoot 'docs\WINDOWS-UI.zh-CN.md'
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
    $bootstrapBox.Text = 'Automatically configure SSH key login (recommended)'
    $bootstrapBox.Location = New-Object System.Drawing.Point(155, 297)
    $bootstrapBox.Size = New-Object System.Drawing.Size(430, 28)
    $bootstrapBox.Visible = -not $isEdit
    $bootstrapBox.Checked = -not $isEdit
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
        elseif ([string]::IsNullOrWhiteSpace($hostName) -or
            $hostName -match '\s' -or $hostName.StartsWith('-')) {
            $validationError = 'Enter a valid Linux host name or IP address.'
        }
        elseif ([string]::IsNullOrWhiteSpace($userName) -or
            $userName -match '\s' -or $userName.StartsWith('-')) {
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
            autoConfigureSsh = [bool]$bootstrapBox.Checked
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
