[CmdletBinding()]
param(
    [string]$Config,
    [ValidateRange(17900, 18100)]
    [int]$Port = 17997,
    [switch]$OpenBrowser,
    [switch]$SmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:RepositoryRoot = $PSScriptRoot
$script:Utf8Encoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $script:Utf8Encoding
try { [Console]::InputEncoding = $script:Utf8Encoding } catch {}
try { [Console]::OutputEncoding = $script:Utf8Encoding } catch {}

$commonPath = Join-Path $script:RepositoryRoot 'src/Common.ps1'
$bootstrapPath = Join-Path $script:RepositoryRoot 'src/ui/Bootstrap.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) { throw "Shared module was not found: $commonPath" }
if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) { throw "UI bootstrap module was not found: $bootstrapPath" }
. $commonPath
. $bootstrapPath

if ([string]::IsNullOrWhiteSpace($Config)) { $Config = Get-DefaultConfigPath }
$script:Config = [Environment]::ExpandEnvironmentVariables($Config)
$script:ManagerPath = Join-Path $script:RepositoryRoot 'proxy-manager.ps1'
$script:WebRoot = Join-Path $script:RepositoryRoot 'web/dist'
$script:SessionToken = [Guid]::NewGuid().ToString('N')
$script:LogEntries = New-Object 'System.Collections.Generic.List[object]'
$script:InstanceMutex = $null
$script:Listener = $null
$script:BoundPort = 0
$script:LastHeartbeat = Get-Date

function Start-ElevatedReactHost {
    $argumentValues = @(
        '-NoLogo',
        '-NoProfile',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-Config', $script:Config,
        '-Port', [string]$Port
    )
    if ($OpenBrowser) {
        $argumentValues += '-OpenBrowser'
    }
    if ($SmokeTest) {
        $argumentValues += '-SmokeTest'
    }
    $argumentLine = ($argumentValues | ForEach-Object {
        ConvertTo-WindowsArgument ([string]$_)
    }) -join ' '
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $argumentLine | Out-Null
}

function Add-WebLog {
    param([string]$Message, [ValidateSet('default', 'success', 'warning', 'error')][string]$Tone = 'default')
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $cleanMessage = [regex]::Replace($Message, ([string][char]27) + '\[[0-?]*[ -/]*[@-~]', '')
    [void]$script:LogEntries.Insert(0, [pscustomobject]@{
        id = [Guid]::NewGuid().ToString('N'); time = Get-Date -Format 'HH:mm:ss'; message = $cleanMessage.Trim(); tone = $Tone
    })
    while ($script:LogEntries.Count -gt 12) { $script:LogEntries.RemoveAt($script:LogEntries.Count - 1) }
}

function Get-BodyText {
    param([System.Net.HttpListenerRequest]$Request)
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-PropertyValue {
    param([AllowNull()]$Object, [string]$Name, $DefaultValue = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { return $Object.$Name }
    return $DefaultValue
}

function Get-LegacyTargetId {
    param([string]$TargetName)
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$TargetName)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $hashBytes = $sha256.ComputeHash($bytes) } finally { $sha256.Dispose() }
    $hash = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    return "tgt-legacy-$hash"
}

function Write-HttpResponse {
    param([System.Net.HttpListenerContext]$Context, [int]$StatusCode, [string]$ContentType, [byte[]]$Bytes, [string]$CacheControl = 'no-store')
    $response = $Context.Response
    $response.StatusCode = $StatusCode; $response.ContentType = $ContentType; $response.ContentLength64 = $Bytes.LongLength
    $response.Headers['Cache-Control'] = $CacheControl
    try { $response.OutputStream.Write($Bytes, 0, $Bytes.Length) } finally { $response.Close() }
}

function Write-JsonResponse {
    param([System.Net.HttpListenerContext]$Context, [int]$StatusCode, $Value)
    Write-HttpResponse $Context $StatusCode 'application/json; charset=utf-8' $script:Utf8Encoding.GetBytes((ConvertTo-Json -InputObject $Value -Depth 10 -Compress))
}

function Write-TextResponse {
    param([System.Net.HttpListenerContext]$Context, [int]$StatusCode, [string]$Content, [string]$ContentType = 'text/plain; charset=utf-8')
    Write-HttpResponse $Context $StatusCode $ContentType $script:Utf8Encoding.GetBytes($Content)
}

function Test-ApiToken {
    param([System.Net.HttpListenerRequest]$Request)
    return [string]::Equals([string]$Request.Headers['X-Proxy-Manager-Token'], $script:SessionToken, [StringComparison]::Ordinal)
}

function Test-LocalProxy {
    param([string]$HostName, [int]$PortNumber)
    $client = New-Object System.Net.Sockets.TcpClient
    try { $connect = $client.ConnectAsync($HostName, $PortNumber); return $connect.Wait(800) -and $client.Connected }
    catch { return $false }
    finally { $client.Dispose() }
}

function Read-WebConfig {
    if (-not (Test-Path -LiteralPath $script:Config -PathType Leaf)) {
        return [pscustomobject]@{
            version = 1
            proxy = [pscustomobject]@{ localHost = '127.0.0.1'; localPort = 7897 }
            defaults = [pscustomobject]@{ sshPort = 22; identityFile = '~/.ssh/id_ed25519'; remoteProxyPort = 17897; noProxyExtra = @() }
            targets = @()
        }
    }
    return Read-Utf8TextFile $script:Config | ConvertFrom-Json
}

function Invoke-ManagerCommand {
    param([Parameter(Mandatory = $true)][string]$Command, [hashtable]$Parameters = @{})
    if (-not (Test-Path -LiteralPath $script:ManagerPath -PathType Leaf)) { throw "Manager script was not found: $script:ManagerPath" }
    $invokeParameters = @{ Config = $script:Config; Confirm = $false }
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($null -eq $value) { continue }
        $invokeParameters[$key] = $value
    }
    $rawRecords = @(& $script:ManagerPath $Command @invokeParameters *>&1)
    $records = @($rawRecords | Where-Object { $_ -isnot [System.Management.Automation.ProgressRecord] })
    $text = (@($records | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if ($records.Count -gt 0 -and [string]::IsNullOrWhiteSpace($text)) { throw "$Command returned no output" }
    return $text
}

function Invoke-ManagerJson {
    param([string]$Command, [hashtable]$Parameters = @{})
    $Parameters.Json = $true
    $text = Invoke-ManagerCommand $Command $Parameters
    if ([string]::IsNullOrWhiteSpace($text)) { throw "$Command returned no JSON result" }
    try { return $text | ConvertFrom-Json } catch { throw "$Command returned invalid JSON: $text" }
}

function Get-TargetStatusMap {
    param($ManagerConfig)
    $map = @{}
    if (@($ManagerConfig.targets).Count -eq 0) { return $map }
    try {
        $statusResults = New-Object 'System.Collections.Generic.List[object]'
        foreach ($result in @(Invoke-ManagerJson 'status')) {
            if ($result -is [System.Array]) {
                foreach ($item in $result) { [void]$statusResults.Add($item) }
            }
            else {
                [void]$statusResults.Add($result)
            }
        }
        foreach ($item in $statusResults) {
            $name = [string](Get-PropertyValue $item 'Name' '')
            if (-not [string]::IsNullOrWhiteSpace($name)) { $map[$name] = $item }
        }
    } catch { Add-WebLog "Status refresh could not complete: $($_.Exception.Message)" 'warning' }
    return $map
}

function Get-LiveState {
    $config = Read-WebConfig
    $statusMap = Get-TargetStatusMap $config
    $proxy = Get-PropertyValue $config 'proxy' ([pscustomobject]@{ localHost = '127.0.0.1'; localPort = 7897 })
    $localHost = [string](Get-PropertyValue $proxy 'localHost' '127.0.0.1')
    $localPort = [int](Get-PropertyValue $proxy 'localPort' 7897)
    $defaults = Get-PropertyValue $config 'defaults' ([pscustomobject]@{ sshPort = 22; identityFile = '~/.ssh/id_ed25519'; remoteProxyPort = 17897; noProxyExtra = @() })
   $targets = foreach ($rawTarget in @($config.targets)) {
       $name = [string](Get-PropertyValue $rawTarget 'name' '')
       $targetId = [string](Get-PropertyValue $rawTarget 'id' (Get-LegacyTargetId $name))
       $hostName = [string](Get-PropertyValue $rawTarget 'host' '')
        $userName = [string](Get-PropertyValue $rawTarget 'user' '')
        $taskName = [string](Get-PropertyValue $rawTarget 'taskName' "ClashProxyTo-$name")
        $enabled = [bool](Get-PropertyValue $rawTarget 'enabled' $true)
        $sshPort = [int](Get-PropertyValue $rawTarget 'sshPort' (Get-PropertyValue $defaults 'sshPort' 22))
        $identityFile = [string](Get-PropertyValue $rawTarget 'identityFile' (Get-PropertyValue $defaults 'identityFile' '~/.ssh/id_ed25519'))
        $remoteProxyPort = [int](Get-PropertyValue $rawTarget 'remoteProxyPort' (Get-PropertyValue $defaults 'remoteProxyPort' 17897))
        $status = if ($statusMap.ContainsKey($name)) { $statusMap[$name] } else { $null }
        $defaultTaskState = if ($enabled) { 'Unknown' } else { 'Disabled' }
        $defaultProxyState = if ($enabled) { 'UNKNOWN' } else { 'DISABLED' }
        $noProxyExtra = @((Get-PropertyValue $rawTarget 'noProxyExtra' (Get-PropertyValue $defaults 'noProxyExtra' @())) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
        [ordered]@{
            id = $targetId; name = $name; host = $hostName; user = $userName
           destination = [string](Get-PropertyValue $status 'Destination' "$userName@$hostName")
            task = $taskName
            taskState = [string](Get-PropertyValue $status 'TaskState' $defaultTaskState)
            enabled = $enabled
            ssh = [string](Get-PropertyValue $status 'SSH' 'UNKNOWN')
            proxy = [string](Get-PropertyValue $status 'Proxy' $defaultProxyState)
           remotePort = $remoteProxyPort; sshPort = $sshPort; identityFile = $identityFile
            identityManaged = [bool](Get-PropertyValue $rawTarget 'identityManaged' $false)
           noProxyExtra = $noProxyExtra
            checkedAt = [string](Get-PropertyValue $status 'CheckedAt' '')
            durationMs = [int](Get-PropertyValue $status 'DurationMs' 0)
        }
    }
    $state = [ordered]@{}
    $state.mode = 'live'
    $state.configPath = $script:Config
    $state.localProxy = [ordered]@{}
    $state.localProxy.host = $localHost
    $state.localProxy.port = $localPort
    $state.localProxy.up = Test-LocalProxy $localHost $localPort
    $state.targets = @($targets | ForEach-Object { $_ })
    $state.logs = @($script:LogEntries | ForEach-Object { $_ })
    $state.checkedAt = (Get-Date).ToUniversalTime().ToString('o')
    return $state
}

function Get-TargetCommandParameters {
    param($Target)
   $parameters = @{ Name = [string](Get-PropertyValue $Target 'name' '') }
   foreach ($mapping in @(
        @('id', 'TargetId'),
       @('host', 'RemoteHost'), @('user', 'RemoteUser'), @('sshPort', 'SshPort'),
        @('identityFile', 'IdentityFile'), @('remoteProxyPort', 'RemoteProxyPort'), @('taskName', 'TaskName')
    )) {
        $value = Get-PropertyValue $Target $mapping[0] $null
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { $parameters[$mapping[1]] = $value }
    }
    $extra = [string](Get-PropertyValue $Target 'noProxyExtra' '')
    if (-not [string]::IsNullOrWhiteSpace($extra)) { $parameters.NoProxyExtra = @($extra -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    return $parameters
}

function Start-InteractiveBootstrap {
    param($Target)
    $payload = [ordered]@{
        managerPath = $script:ManagerPath
        config = $script:Config
        parameters = Get-TargetCommandParameters $Target
    }
    $payloadJson = $payload | ConvertTo-Json -Depth 8 -Compress
    $payloadBase64 = [Convert]::ToBase64String($script:Utf8Encoding.GetBytes($payloadJson))
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
    Start-Process -FilePath 'powershell.exe' -Verb Open -WorkingDirectory $script:RepositoryRoot -WindowStyle Normal -ArgumentList $argumentLine | Out-Null
}

function Invoke-ApiAction {
    param($Body)
    $command = [string](Get-PropertyValue $Body 'command' '')
    $target = Get-PropertyValue $Body 'target' $null
    $deleteIdentityFile = [bool](Get-PropertyValue $Body 'deleteIdentityFile' $false)
    if ($command -notin @('status', 'add', 'update', 'enable', 'disable', 'remove', 'prepare-ssh', 'bootstrap-key')) { throw "Unsupported manager action: $command" }
    if ($command -eq 'status') { Add-WebLog 'Health check requested.'; return [ordered]@{ ok = $true; message = 'Health check completed.' } }
    if ($null -eq $target) { throw "Action '$command' requires a target." }
    $parameters = Get-TargetCommandParameters $target
    if ($command -eq 'bootstrap-key') {
        Start-InteractiveBootstrap $target
        Add-WebLog "Opened an interactive SSH key setup window for $($parameters.Name)." 'success'
        return [ordered]@{ ok = $true; message = 'Interactive SSH setup opened.' }
    }
    if ($command -eq 'prepare-ssh') {
        $readiness = Invoke-ManagerJson 'prepare-ssh' $parameters
        Add-WebLog "SSH readiness checked for $($parameters.Name)." 'success'
        return [ordered]@{
            ok = $true
            message = 'SSH readiness checked.'
            ready = [bool](Get-PropertyValue $readiness 'Ready' $false)
            interactionRequired = [bool](Get-PropertyValue $readiness 'InteractionRequired' $false)
            identityCreated = [bool](Get-PropertyValue $readiness 'IdentityCreated' $false)
            publicKeyUpdated = [bool](Get-PropertyValue $readiness 'PublicKeyUpdated' $false)
        }
    }
    if ($command -eq 'remove' -and $deleteIdentityFile) {
        $parameters.DeleteIdentityFile = $true
    }
    $output = Invoke-ManagerCommand $command $parameters
    $message = if ([string]::IsNullOrWhiteSpace($output)) { "$command completed." } else { $output }
    $tone = if ($command -eq 'remove') { 'warning' } else { 'success' }
    Add-WebLog $message $tone
    return [ordered]@{ ok = $true; message = $message }
}

function Get-MimeType {
    param([string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }; '.js' { return 'text/javascript; charset=utf-8' }; '.css' { return 'text/css; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }; '.svg' { return 'image/svg+xml' }; '.png' { return 'image/png' }; '.ico' { return 'image/x-icon' }
        default { return 'application/octet-stream' }
    }
}

function Serve-StaticFile {
    param([System.Net.HttpListenerContext]$Context)
    $relativePath = [Uri]::UnescapeDataString($Context.Request.Url.AbsolutePath.TrimStart('/'))
    if ([string]::IsNullOrWhiteSpace($relativePath)) { $relativePath = 'index.html' }
    $root = [IO.Path]::GetFullPath($script:WebRoot)
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
    if (-not ($candidate.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) { Write-TextResponse $Context 403 'Forbidden'; return }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { $candidate = Join-Path $root 'index.html' }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { Write-TextResponse $Context 503 'React UI has not been built. Run npm install and npm run build in web/.'; return }
    $cacheControl = if ([IO.Path]::GetFileName($candidate) -eq 'index.html') { 'no-store' } else { 'public, max-age=31536000, immutable' }
    Write-HttpResponse $Context 200 (Get-MimeType $candidate) ([IO.File]::ReadAllBytes($candidate)) $cacheControl
}

function Handle-Request {
    param([System.Net.HttpListenerContext]$Context)
    $request = $Context.Request; $path = $request.Url.AbsolutePath
    if ($path.StartsWith('/api/', [StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-ApiToken $request)) { Write-JsonResponse $Context 401 ([ordered]@{ error = 'Invalid manager session token.' }); return }
        try {
            if ($path -eq '/api/state' -and $request.HttpMethod -eq 'GET') { Write-JsonResponse $Context 200 (Get-LiveState); return }
            if ($path -eq '/api/heartbeat' -and $request.HttpMethod -eq 'POST') {
                $script:LastHeartbeat = Get-Date


                Write-JsonResponse $Context 200 ([ordered]@{ ok = $true }); return
            }
            if ($path -eq '/api/action' -and $request.HttpMethod -eq 'POST') {
                $bodyText = Get-BodyText $request; $body = if ([string]::IsNullOrWhiteSpace($bodyText)) { $null } else { $bodyText | ConvertFrom-Json }
                Write-JsonResponse $Context 200 (Invoke-ApiAction $body); return
            }
            Write-JsonResponse $Context 404 ([ordered]@{ error = 'API endpoint not found.' })
        } catch {
            Add-WebLog $_.Exception.Message 'error'
            Write-JsonResponse $Context 500 ([ordered]@{ error = $_.Exception.Message })
        }
        return
    }
    Serve-StaticFile $Context
}

function Start-Listener {
    param([int]$PreferredPort)
    $listener = New-Object System.Net.HttpListener
    for ($candidatePort = $PreferredPort; $candidatePort -le ($PreferredPort + 20); $candidatePort++) {
        try {
            $listener.Prefixes.Clear(); $listener.Prefixes.Add("http://127.0.0.1:$candidatePort/"); $listener.Start()
            $script:BoundPort = $candidatePort; $script:Listener = $listener; return
        } catch [System.Net.HttpListenerException] {
            if ($candidatePort -eq ($PreferredPort + 20)) { $listener.Close(); throw }
        }
    }
}

try {
    if (-not (Test-Administrator)) {
        Start-ElevatedReactHost
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $script:WebRoot 'index.html') -PathType Leaf)) { throw 'React UI build output is missing. Run npm install and npm run build in web/ first.' }
    $script:InstanceMutex = Enter-UiInstanceMutex
    if ($null -eq $script:InstanceMutex) { throw 'Clash SSH Proxy Manager is already running for this Windows session.' }
    Add-WebLog 'React manager started. Local status is ready to inspect.' 'success'
    Start-Listener $Port
    if ($SmokeTest) {
        Write-Output 'React UI smoke test passed'
        return
    }
    $url = "http://127.0.0.1:$($script:BoundPort)/?token=$($script:SessionToken)"
    Write-Output "React UI listening at $url"
    if ($OpenBrowser) {
        $edge = $null; $edgeCommand = Get-Command 'msedge.exe' -ErrorAction SilentlyContinue
        if ($null -ne $edgeCommand) { $edge = $edgeCommand.Source }
        foreach ($candidate in @((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'), (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'))) {
            if ($null -eq $edge -and -not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $edge = $candidate }
        }
        if ($null -ne $edge) { Start-Process -FilePath $edge -ArgumentList "--app=$url" | Out-Null } else { Start-Process -FilePath $url | Out-Null }
    }
    while ($script:Listener.IsListening) {
        try {
            $contextTask = $script:Listener.GetContextAsync()
            $timedOut = $false
            while (-not $contextTask.Wait(500)) {
                if ($OpenBrowser -and ((Get-Date) - $script:LastHeartbeat).TotalSeconds -gt 90) {
                    $timedOut = $true
                    $script:Listener.Stop()
                    break
                }
            }
            if ($timedOut) { break }
            if ($contextTask.IsCompleted -and -not $contextTask.IsFaulted) {
                Handle-Request $contextTask.Result
            }
        }
        catch [System.Net.HttpListenerException] { if ($script:Listener.IsListening) { throw }; break }
        catch [System.AggregateException] { if ($script:Listener.IsListening) { throw }; break }
    }
}
finally {
    if ($null -ne $script:Listener) { $script:Listener.Stop(); $script:Listener.Close(); $script:Listener = $null }
    if ($null -ne $script:InstanceMutex) { Exit-UiInstanceMutex $script:InstanceMutex; $script:InstanceMutex = $null }
}
