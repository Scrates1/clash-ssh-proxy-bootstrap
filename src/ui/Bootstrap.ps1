# UI startup helpers used before elevation and single-instance checks.

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UiInstanceMutexName {
    param([switch]$SmokeTest)

    if ($SmokeTest) {
        return "Local\ClashSshProxyManager.Smoke.$PID"
    }
    return 'Local\ClashSshProxyManager'
}

function Enter-UiInstanceMutex {
    param([string]$Name = 'Local\ClashSshProxyManager')

    $mutex = New-Object System.Threading.Mutex($false, $Name)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(0, $false)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            $mutex.Dispose()
            return $null
        }
        return $mutex
    }
    catch {
        if (-not $acquired) {
            $mutex.Dispose()
        }
        throw
    }
}

function Exit-UiInstanceMutex {
    param([AllowNull()]$Mutex)

    if ($null -eq $Mutex) {
        return
    }
    try {
        $Mutex.ReleaseMutex()
    }
    finally {
        $Mutex.Dispose()
    }
}

function New-UiBrowserOpenEvent {
    param([string]$MutexName)

    return [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, "$MutexName.OpenBrowser")
}

function Open-ManagerBrowser {
    param([string]$Url)

    $edge = $null
    $edgeCommand = Get-Command 'msedge.exe' -ErrorAction SilentlyContinue
    if ($null -ne $edgeCommand) { $edge = $edgeCommand.Source }
    foreach ($candidate in @((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'), (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'))) {
        if ($null -eq $edge -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $edge = $candidate }
    }
    # The browser is the visible, interactive part of the application.
    if ($null -ne $edge) { Start-Process -FilePath $edge -ArgumentList "--app=$Url" | Out-Null }
    else { Start-Process -FilePath $Url | Out-Null }
}

function Show-RequestedManagerBrowser {
    param([Threading.EventWaitHandle]$OpenEvent, [string]$Url)

    if (-not $OpenEvent.WaitOne(0)) { return }
    if (-not (Show-ExistingManagerWindow)) { Open-ManagerBrowser -Url $Url }
}

function Get-TrackedUiProcess {
    param(
        [hashtable]$Registry,
        [string]$Key
    )

    if (-not $Registry.ContainsKey($Key)) {
        return $null
    }
    $process = $Registry[$Key]
    try {
        if (-not $process.HasExited) {
            return $process
        }
    }
    catch {}
    [void]$Registry.Remove($Key)
    try { $process.Dispose() } catch {}
    return $null
}

function Show-UiProcessWindow {
    param(
        [AllowNull()]$Process,
        [string[]]$WindowTitles = @()
    )

    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        if ($null -ne $Process) {
            try {
                if ($shell.AppActivate([int]$Process.Id)) { return $true }
            }
            catch {}
        }
        foreach ($title in $WindowTitles) {
            if (-not [string]::IsNullOrWhiteSpace($title) -and $shell.AppActivate($title)) { return $true }
        }
        return $false
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Show-ExistingManagerWindow {
    $chineseTitle = 'Clash SSH ' + (-join ([char[]]@(0x4ee3, 0x7406, 0x7ba1, 0x7406, 0x5668)))
    return Show-UiProcessWindow -Process $null -WindowTitles @(
        'Clash SSH Proxy Manager',
        $chineseTitle
    )
}

function Show-ManagerUiError {
    param([string]$Message)

    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        [void]$shell.Popup(
            "Clash SSH Proxy Manager could not start:`r`n`r`n$Message",
            0,
            'Clash SSH Proxy Manager',
            16
        )
    }
    catch {}
    finally {
        if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Start-InteractiveSshBootstrapProcess {
    param(
        [string]$ManagerPath,
        [string]$Config,
        [hashtable]$Parameters,
        [string]$WorkingDirectory
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $payload = [ordered]@{ managerPath = $ManagerPath; config = $Config; parameters = $Parameters }
    $payloadBase64 = [Convert]::ToBase64String($encoding.GetBytes(($payload | ConvertTo-Json -Depth 8 -Compress)))
    $childSource = @"
`$ErrorActionPreference = 'Stop'
try { `$Host.UI.RawUI.WindowTitle = 'Clash SSH Proxy - SSH key setup' } catch {}
try {
    if ([Console]::IsInputRedirected) {
        throw 'The SSH setup process did not receive an interactive console input handle.'
    }
    `$payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payloadBase64'))
    `$payload = `$payloadJson | ConvertFrom-Json
    `$invokeParameters = @{ Config = [string]`$payload.config; Confirm = `$false }
    foreach (`$property in `$payload.parameters.PSObject.Properties) {
        `$invokeParameters[`$property.Name] = if (`$property.Value -is [array]) { @(`$property.Value) } else { `$property.Value }
    }
    & ([string]`$payload.managerPath) 'bootstrap-key' @invokeParameters
}
catch {
    Write-Host ''
    Write-Host 'SSH setup failed:' -ForegroundColor Red
    Write-Host `$_.Exception.Message -ForegroundColor Red
    [void](Read-Host 'Press Enter to close this window')
    exit 1
}
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childSource))
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand)
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' '
    return (Start-Process -FilePath 'powershell.exe' -Verb Open -WorkingDirectory $WorkingDirectory -WindowStyle Normal -ArgumentList $argumentLine -PassThru)
}

$script:TrayState = $null

function Get-UiIsChineseLocale {
    try { return [System.Globalization.CultureInfo]::CurrentUICulture.Name -like 'zh*' }
    catch { return $false }
}

function Get-UiIsDarkTheme {
    try {
        $val = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme' -ErrorAction Stop
        return ([int]$val -eq 0)
    }
    catch { return $false }
}

function Get-UiTrayStrings {
    if (Get-UiIsChineseLocale) {
        return @{
            AppTitle = 'Clash SSH ' + [regex]::Unescape('\u4ee3\u7406\u7ba1\u7406\u5668')
            HeaderActiveFmt = 'Clash SSH ' + [regex]::Unescape('\u4ee3\u7406 \u00b7 {0} \u6761\u8fd0\u884c\u4e2d')
            HeaderIdle = 'Clash SSH ' + [regex]::Unescape('\u4ee3\u7406 \u00b7 \u7a7a\u95f2')
            OpenManager = [regex]::Unescape('\u6253\u5f00\u4e3b\u754c\u9762')
            TargetsMenu = [regex]::Unescape('\u4ee3\u7406\u76ee\u6807')
            NoTargets = [regex]::Unescape('\u6682\u65e0\u5df2\u914d\u7f6e\u76ee\u6807')
            StopAll = [regex]::Unescape('\u505c\u6b62\u6240\u6709\u4ee3\u7406')
            Exit = [regex]::Unescape('\u9000\u51fa')
        }
    }
    return @{
        AppTitle = 'Clash SSH Proxy Manager'
        HeaderActiveFmt = 'Clash SSH Proxy - {0} active'
        HeaderIdle = 'Clash SSH Proxy - Idle'
        OpenManager = 'Open Manager'
        TargetsMenu = 'Proxy Targets'
        NoTargets = 'No configured targets'
        StopAll = 'Stop All Tunnels'
        Exit = 'Exit'
    }
}

function Initialize-ModernTrayTypes {
    if ('ClashSshProxyModernTray' -as [type]) { return }
    $source = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class ClashSshProxyModernTray
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    public static void ApplyWindowChrome(IntPtr handle, bool isDark)
    {
        if (handle == IntPtr.Zero) return;
        try
        {
            int corner = 2; // DWMWCP_ROUND (Windows 11 rounded corners)
            DwmSetWindowAttribute(handle, 33, ref corner, sizeof(int));
            int dark = isDark ? 1 : 0;
            DwmSetWindowAttribute(handle, 20, ref dark, sizeof(int));
        }
        catch { }
    }
}

public class ClashSshProxyMenuRenderer : ToolStripProfessionalRenderer
{
    private readonly bool _dark;

    public ClashSshProxyMenuRenderer(bool isDark)
    {
        _dark = isDark;
        this.RoundedEdges = false;
    }

    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e)
    {
        // Omit legacy Win98 left gutter for a clean modern floating list.
    }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
    {
        Color bg = _dark ? Color.FromArgb(31, 36, 48) : Color.FromArgb(255, 255, 255);
        using (SolidBrush b = new SolidBrush(bg))
        {
            e.Graphics.FillRectangle(b, e.AffectedBounds);
        }
    }

    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
    {
        Color border = _dark ? Color.FromArgb(52, 60, 78) : Color.FromArgb(224, 230, 240);
        using (Pen p = new Pen(border, 1f))
        {
            e.Graphics.DrawRectangle(p, 0, 0, e.AffectedBounds.Width - 1, e.AffectedBounds.Height - 1);
        }
    }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        if (!e.Item.Selected || !e.Item.Enabled) return;
        bool isDanger = object.Equals(e.Item.Tag, "danger");
        Color fill = isDanger
            ? (_dark ? Color.FromArgb(72, 34, 42) : Color.FromArgb(253, 236, 238))
            : (_dark ? Color.FromArgb(47, 55, 74) : Color.FromArgb(238, 241, 255));
        Rectangle rect = new Rectangle(6, 2, e.Item.Width - 12, e.Item.Height - 4);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (GraphicsPath path = CreateRoundedRect(rect, 6))
        using (SolidBrush brush = new SolidBrush(fill))
        {
            e.Graphics.FillPath(brush, path);
        }
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
    {
        Color line = _dark ? Color.FromArgb(48, 55, 72) : Color.FromArgb(235, 239, 246);
        int y = e.Item.Height / 2;
        using (Pen p = new Pen(line, 1f))
        {
            e.Graphics.DrawLine(p, 12, y, e.Item.Width - 12, y);
        }
    }

    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
    {
        Color c = e.Item.Enabled
            ? (_dark ? Color.FromArgb(148, 163, 184) : Color.FromArgb(120, 134, 158))
            : Color.Gray;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        int cx = e.ArrowRectangle.Left + e.ArrowRectangle.Width / 2;
        int cy = e.ArrowRectangle.Top + e.ArrowRectangle.Height / 2;
        using (Pen p = new Pen(c, 1.5f))
        {
            p.StartCap = LineCap.Round;
            p.EndCap = LineCap.Round;
            e.Graphics.DrawLine(p, cx - 2, cy - 4, cx + 2, cy);
            e.Graphics.DrawLine(p, cx + 2, cy, cx - 2, cy + 4);
        }
    }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        bool isDanger = object.Equals(e.Item.Tag, "danger");
        if (!e.Item.Enabled)
        {
            e.TextColor = _dark ? Color.FromArgb(148, 163, 184) : Color.FromArgb(115, 128, 150);
        }
        else if (isDanger)
        {
            e.TextColor = _dark ? Color.FromArgb(248, 113, 129) : Color.FromArgb(201, 68, 78);
        }
        else
        {
            e.TextColor = _dark ? Color.FromArgb(238, 242, 250) : Color.FromArgb(24, 33, 53);
        }
        e.Graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        base.OnRenderItemText(e);
    }

    private static GraphicsPath CreateRoundedRect(Rectangle bounds, int radius)
    {
        int d = radius * 2;
        GraphicsPath path = new GraphicsPath();
        path.AddArc(bounds.X, bounds.Y, d, d, 180, 90);
        path.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
        path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
        path.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}
'@
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $refs = @(
        [System.Windows.Forms.ToolStripProfessionalRenderer].Assembly.Location,
        [System.Drawing.Graphics].Assembly.Location,
        [System.Drawing.Rectangle].Assembly.Location,
        [System.ComponentModel.Component].Assembly.Location
    ) | Select-Object -Unique
    Add-Type -TypeDefinition $source -ReferencedAssemblies $refs -ErrorAction Stop
}

function Remove-NativeIconHandle {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return }
    try {
        Initialize-ModernTrayTypes
        [void][ClashSshProxyModernTray]::DestroyIcon($Handle)
    } catch {}
}

function New-TrayMenuGlyph {
    param([ValidateSet('dot-active', 'dot-idle', 'home', 'targets', 'stop', 'exit')][string]$Kind, [bool]$IsDark = $false)
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        switch ($Kind) {
            'dot-active' {
                $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 20, 184, 152))
                try { $g.FillEllipse($b, 4, 4, 8, 8) } finally { $b.Dispose() }
            }
            'dot-idle' {
                $p = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 148, 163, 184), 1.6)
                try { $g.DrawEllipse($p, 4.5, 4.5, 7, 7) } finally { $p.Dispose() }
            }
            'home' {
                $c = if ($IsDark) { [System.Drawing.Color]::FromArgb(255, 129, 140, 248) } else { [System.Drawing.Color]::FromArgb(255, 79, 95, 226) }
                $p = New-Object System.Drawing.Pen($c, 1.5)
                try {
                    $g.DrawRectangle($p, 2.5, 3, 11, 10)
                    $g.DrawLine($p, 2.5, 6.2, 13.5, 6.2)
                } finally { $p.Dispose() }
            }
            'targets' {
                $c = if ($IsDark) { [System.Drawing.Color]::FromArgb(255, 148, 163, 184) } else { [System.Drawing.Color]::FromArgb(255, 100, 116, 139) }
                $p = New-Object System.Drawing.Pen($c, 1.5)
                try {
                    $g.DrawRectangle($p, 2.5, 3, 11, 4.2)
                    $g.DrawRectangle($p, 2.5, 9, 11, 4.2)
                } finally { $p.Dispose() }
            }
            'stop' {
                $c = if ($IsDark) { [System.Drawing.Color]::FromArgb(255, 217, 155, 67) } else { [System.Drawing.Color]::FromArgb(255, 193, 132, 45) }
                $p = New-Object System.Drawing.Pen($c, 1.5)
                $b = New-Object System.Drawing.SolidBrush($c)
                try {
                    $g.DrawEllipse($p, 2.5, 2.5, 11, 11)
                    $g.FillRectangle($b, 6, 6, 4, 4)
                } finally { $p.Dispose(); $b.Dispose() }
            }
            'exit' {
                $c = if ($IsDark) { [System.Drawing.Color]::FromArgb(255, 248, 113, 129) } else { [System.Drawing.Color]::FromArgb(255, 201, 68, 78) }
                $p = New-Object System.Drawing.Pen($c, 1.6)
                try {
                    $p.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                    $p.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                    $g.DrawArc($p, 3, 3.5, 10, 10, -50, 280)
                    $g.DrawLine($p, 8, 2, 8, 7.5)
                } finally { $p.Dispose() }
            }
        }
        return $bmp
    }
    finally { $g.Dispose() }
}

function New-ManagerTrayIconGraphic {
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        try {
            $path.AddArc(2, 2, 10, 10, 180, 90)
            $path.AddArc(20, 2, 10, 10, 270, 90)
            $path.AddArc(20, 20, 10, 10, 0, 90)
            $path.AddArc(2, 20, 10, 10, 90, 90)
            $path.CloseFigure()
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 79, 95, 226))
            try { $graphics.FillPath($brush, $path) } finally { $brush.Dispose() }
        } finally { $path.Dispose() }
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2.6)
        try {
            $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $points = [System.Drawing.PointF[]]@(
                (New-Object System.Drawing.PointF(6.5, 16.5)),
                (New-Object System.Drawing.PointF(11.0, 16.5)),
                (New-Object System.Drawing.PointF(13.8, 9.5)),
                (New-Object System.Drawing.PointF(18.2, 22.5)),
                (New-Object System.Drawing.PointF(21.0, 16.5)),
                (New-Object System.Drawing.PointF(25.5, 16.5))
            )
            $graphics.DrawLines($pen, $points)
        } finally { $pen.Dispose() }
        $hIcon = $bitmap.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($hIcon)
        return [pscustomobject]@{ Icon = $icon; Handle = $hIcon }
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Test-ManagerHasActiveTasks {
    param([string]$ConfigPath)

    $enabledNames = New-Object 'System.Collections.Generic.List[string]'
    $allTargets = New-Object 'System.Collections.Generic.List[object]'
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        try {
            $cfg = Read-Utf8TextFile $ConfigPath | ConvertFrom-Json
            foreach ($t in @($cfg.targets)) {
                $name = [string]$t.name
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $isEnabled = if ($null -ne $t.PSObject.Properties['enabled'] -and $null -ne $t.enabled) { [bool]$t.enabled } else { $true }
                $port = if ($null -ne $t.PSObject.Properties['remoteProxyPort'] -and $null -ne $t.remoteProxyPort) { [int]$t.remoteProxyPort } else { 17897 }
                [void]$allTargets.Add([pscustomobject]@{ Name = $name; Enabled = $isEnabled; RemotePort = $port })
                if ($isEnabled) { [void]$enabledNames.Add($name) }
            }
        } catch {}
    }
    $runningTaskCount = 0
    try {
        foreach ($task in @(Get-ScheduledTask -TaskName 'ClashProxyTo*' -ErrorAction SilentlyContinue)) {
            if ([string]$task.State -in @('Running', 'Queued')) { $runningTaskCount++ }
        }
    } catch {}
    $activeCount = [Math]::Max($enabledNames.Count, $runningTaskCount)
    return [pscustomobject]@{
        HasActive = ($activeCount -gt 0)
        ActiveCount = $activeCount
        EnabledTargets = $enabledNames.ToArray()
        Targets = $allTargets.ToArray()
        RunningTaskCount = $runningTaskCount
    }
}

function Register-ManagerWindowClosed {
    if ($null -eq $script:TrayState) { return }
    $script:TrayState.PendingWindowCloseAt = [DateTime]::UtcNow.AddSeconds(3)
}

function Clear-ManagerWindowClosed {
    if ($null -eq $script:TrayState) { return }
    $script:TrayState.PendingWindowCloseAt = $null
}

function New-StyledTrayMenuItem {
    param([string]$Text, [System.Drawing.Font]$Font, $Image = $null, [string]$Tag = '', [bool]$Enabled = $true)
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
    $item.Font = $Font
    $item.Enabled = $Enabled
    $item.AutoSize = $true
    $item.Padding = New-Object System.Windows.Forms.Padding(6, 5, 14, 5)
    if ($null -ne $Image) { $item.Image = $Image; $item.ImageScaling = [System.Windows.Forms.ToolStripItemImageScaling]::None }
    if (-not [string]::IsNullOrWhiteSpace($Tag)) { $item.Tag = $Tag }
    return $item
}

function Initialize-ManagerTrayIcon {
    param(
        [string]$ConfigPath,
        [switch]$Disabled
    )

    $script:TrayState = $null
    if ($Disabled) { return }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        Initialize-ModernTrayTypes
        $isDark = Get-UiIsDarkTheme
        $strings = Get-UiTrayStrings
        $iconGraphic = New-ManagerTrayIconGraphic
        $fontFamily = if (Get-UiIsChineseLocale) { 'Microsoft YaHei UI' } else { 'Segoe UI' }
        $regularFont = New-Object System.Drawing.Font($fontFamily, 9.5, [System.Drawing.FontStyle]::Regular)
        $boldFont = New-Object System.Drawing.Font($fontFamily, 9.5, [System.Drawing.FontStyle]::Bold)
        $headerFont = New-Object System.Drawing.Font($fontFamily, 8.75, [System.Drawing.FontStyle]::Bold)
        $renderer = New-Object ClashSshProxyMenuRenderer($isDark)

        $glyphs = @{
            DotActive = New-TrayMenuGlyph 'dot-active' $isDark
            DotIdle = New-TrayMenuGlyph 'dot-idle' $isDark
            Home = New-TrayMenuGlyph 'home' $isDark
            Targets = New-TrayMenuGlyph 'targets' $isDark
            Stop = New-TrayMenuGlyph 'stop' $isDark
            Exit = New-TrayMenuGlyph 'exit' $isDark
        }

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $menu.Renderer = $renderer
        $menu.ShowCheckMargin = $false
        $menu.ShowImageMargin = $true
        $menu.Padding = New-Object System.Windows.Forms.Padding(2, 6, 2, 6)
        $menu.Font = $regularFont
        $menu.DropShadowEnabled = $true

        $headerItem = New-StyledTrayMenuItem $strings.HeaderIdle $headerFont $glyphs.DotIdle '' $false
        $sep1 = New-Object System.Windows.Forms.ToolStripSeparator
        $openItem = New-StyledTrayMenuItem $strings.OpenManager $boldFont $glyphs.Home '' $true
        $targetsMenu = New-StyledTrayMenuItem $strings.TargetsMenu $regularFont $glyphs.Targets '' $true
        $targetsMenu.DropDown.Renderer = $renderer
        $targetsMenu.DropDown.Padding = New-Object System.Windows.Forms.Padding(2, 6, 2, 6)
        $targetsMenu.DropDown.ShowCheckMargin = $false
        $sep2 = New-Object System.Windows.Forms.ToolStripSeparator
        $stopAllItem = New-StyledTrayMenuItem $strings.StopAll $regularFont $glyphs.Stop '' $true
        $exitItem = New-StyledTrayMenuItem $strings.Exit $regularFont $glyphs.Exit 'danger' $true

        [void]$menu.Items.Add($headerItem)
        [void]$menu.Items.Add($sep1)
        [void]$menu.Items.Add($openItem)
        [void]$menu.Items.Add($targetsMenu)
        [void]$menu.Items.Add($sep2)
        [void]$menu.Items.Add($stopAllItem)
        [void]$menu.Items.Add($exitItem)

        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $notifyIcon.Icon = $iconGraphic.Icon
        $notifyIcon.Text = $strings.AppTitle
        $notifyIcon.ContextMenuStrip = $menu
        $notifyIcon.Visible = $true

        $script:TrayState = @{
            OpenRequested = $false
            ExitRequested = $false
            StopAllRequested = $false
            ToggleTarget = $null
            PendingWindowCloseAt = $null
            ConfigPath = $ConfigPath
            IsDark = $isDark
            Strings = $strings
            RegularFont = $regularFont
            BoldFont = $boldFont
            HeaderFont = $headerFont
            Glyphs = $glyphs
            NotifyIcon = $notifyIcon
            ContextMenu = $menu
            HeaderItem = $headerItem
            TargetsMenu = $targetsMenu
            StopAllItem = $stopAllItem
            IconHandle = $iconGraphic.Handle
            IconObject = $iconGraphic.Icon
        }

        $openItem.Add_Click({ if ($null -ne $script:TrayState) { $script:TrayState.OpenRequested = $true } })
        $stopAllItem.Add_Click({ if ($null -ne $script:TrayState) { $script:TrayState.StopAllRequested = $true } })
        $exitItem.Add_Click({ if ($null -ne $script:TrayState) { $script:TrayState.ExitRequested = $true } })
        $notifyIcon.Add_DoubleClick({ if ($null -ne $script:TrayState) { $script:TrayState.OpenRequested = $true } })
        $notifyIcon.Add_MouseClick({
            param($sender, $eventArgs)
            if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $null -ne $script:TrayState) {
                $script:TrayState.OpenRequested = $true
            }
        })
        $menu.Add_Opened({
            if ($null -eq $script:TrayState) { return }
            [ClashSshProxyModernTray]::ApplyWindowChrome($script:TrayState.ContextMenu.Handle, $script:TrayState.IsDark)
        })
        $targetsMenu.DropDown.Add_Opened({
            if ($null -eq $script:TrayState) { return }
            [ClashSshProxyModernTray]::ApplyWindowChrome($script:TrayState.TargetsMenu.DropDown.Handle, $script:TrayState.IsDark)
        })
        $menu.Add_Opening({
            if ($null -eq $script:TrayState) { return }
            $active = Test-ManagerHasActiveTasks -ConfigPath $script:TrayState.ConfigPath
            $script:TrayState.HeaderItem.Text = if ($active.HasActive) { $script:TrayState.Strings.HeaderActiveFmt -f $active.ActiveCount } else { $script:TrayState.Strings.HeaderIdle }
            $script:TrayState.HeaderItem.Image = if ($active.HasActive) { $script:TrayState.Glyphs.DotActive } else { $script:TrayState.Glyphs.DotIdle }
            $script:TrayState.StopAllItem.Visible = $active.HasActive

            $sub = $script:TrayState.TargetsMenu.DropDownItems
            $sub.Clear()
            if (@($active.Targets).Count -eq 0) {
                [void]$sub.Add((New-StyledTrayMenuItem $script:TrayState.Strings.NoTargets $script:TrayState.RegularFont $null '' $false))
            }
            else {
                foreach ($t in @($active.Targets)) {
                    $label = "$($t.Name)  :$($t.RemotePort)"
                    $glyph = if ($t.Enabled) { $script:TrayState.Glyphs.DotActive } else { $script:TrayState.Glyphs.DotIdle }
                    $ti = New-StyledTrayMenuItem $label $script:TrayState.RegularFont $glyph '' $true
                    $ti.Tag = [pscustomobject]@{ Name = $t.Name; NextCommand = $(if ($t.Enabled) { 'disable' } else { 'enable' }) }
                    $ti.Add_Click({
                        param($itemSender, $clickArgs)
                        if ($null -ne $script:TrayState -and $null -ne $itemSender.Tag) {
                            $script:TrayState.ToggleTarget = $itemSender.Tag
                        }
                    })
                    [void]$sub.Add($ti)
                }
            }
        })
    }
    catch {
        $script:TrayState = $null
    }
}

function Invoke-ManagerTrayPump {
    param(
        [string]$Url,
        [string]$ConfigPath,
        [string]$ManagerPath
    )

    if ($null -eq $script:TrayState) { return 'continue' }
    [System.Windows.Forms.Application]::DoEvents()

    if ($script:TrayState.OpenRequested) {
        $script:TrayState.OpenRequested = $false
        $script:TrayState.PendingWindowCloseAt = $null
        if (-not (Show-ExistingManagerWindow)) { Open-ManagerBrowser -Url $Url }
    }

    if ($null -ne $script:TrayState.ToggleTarget) {
        $toggle = $script:TrayState.ToggleTarget
        $script:TrayState.ToggleTarget = $null
        try { [void](& $ManagerPath $toggle.NextCommand -Name $toggle.Name -Config $ConfigPath -Confirm:$false *>&1) } catch {}
    }

    if ($script:TrayState.StopAllRequested) {
        $script:TrayState.StopAllRequested = $false
        $active = Test-ManagerHasActiveTasks -ConfigPath $ConfigPath
        foreach ($targetName in @($active.EnabledTargets)) {
            try { [void](& $ManagerPath 'disable' -Name $targetName -Config $ConfigPath -Confirm:$false *>&1) } catch {}
        }
    }

    if ($null -ne $script:TrayState.PendingWindowCloseAt -and [DateTime]::UtcNow -ge $script:TrayState.PendingWindowCloseAt) {
        $script:TrayState.PendingWindowCloseAt = $null
        $active = Test-ManagerHasActiveTasks -ConfigPath $ConfigPath
        if (-not $active.HasActive) {
            $script:TrayState.ExitRequested = $true
        }
    }

    if ($script:TrayState.ExitRequested) {
        return 'exit'
    }
    return 'continue'
}

function Dispose-ManagerTrayIcon {
    if ($null -eq $script:TrayState) { return }
    try {
        if ($null -ne $script:TrayState.NotifyIcon) {
            $script:TrayState.NotifyIcon.Visible = $false
            $script:TrayState.NotifyIcon.Dispose()
        }
    } catch {}
    try { if ($null -ne $script:TrayState.ContextMenu) { $script:TrayState.ContextMenu.Dispose() } } catch {}
    foreach ($fontKey in @('RegularFont', 'BoldFont', 'HeaderFont')) {
        try { if ($null -ne $script:TrayState[$fontKey]) { $script:TrayState[$fontKey].Dispose() } } catch {}
    }
    if ($null -ne $script:TrayState.Glyphs) {
        foreach ($bmp in @($script:TrayState.Glyphs.Values)) { try { $bmp.Dispose() } catch {} }
    }
    try { if ($null -ne $script:TrayState.IconObject) { $script:TrayState.IconObject.Dispose() } } catch {}
    try { if ($null -ne $script:TrayState.IconHandle) { Remove-NativeIconHandle $script:TrayState.IconHandle } } catch {}
    $script:TrayState = $null
}
