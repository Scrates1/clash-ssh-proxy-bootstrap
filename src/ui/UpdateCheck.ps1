# Periodic GitHub Release update checker with 12-hour local caching and local Clash proxy support.

$script:CanonicalReleasesUrl = 'https://github.com/Scrates1/clash-ssh-proxy-bootstrap/releases/latest'
$script:DefaultReleasesApiUrl = 'https://api.github.com/repos/Scrates1/clash-ssh-proxy-bootstrap/releases/latest'

function Get-LocalManagerVersion {
    param([string]$RepositoryRoot = $script:RepositoryRoot)

    if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $versionPath = Join-Path $RepositoryRoot 'VERSION'
        if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
            $raw = (Read-Utf8TextFile $versionPath).Trim()
            $normalized = ConvertTo-NormalizedReleaseVersion $raw
            if (-not [string]::IsNullOrWhiteSpace($normalized)) {
                return $normalized
            }
        }
    }
    return '0.0.0'
}

function ConvertTo-NormalizedReleaseVersion {
    param([AllowNull()][string]$Tag)

    if ([string]::IsNullOrWhiteSpace($Tag)) {
        return $null
    }
    $trimmed = $Tag.Trim()
    if ($trimmed.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
        $trimmed = $trimmed.Substring(1)
    }
    if ($trimmed -notmatch '^\d+\.\d+\.\d+$') {
        return $null
    }
    $parsed = $null
    if (-not [version]::TryParse($trimmed, [ref]$parsed)) {
        return $null
    }
    return $trimmed
}

function Test-NewerManagerVersion {
    param(
        [AllowNull()][string]$CandidateVersion,
        [AllowNull()][string]$CurrentVersion
    )

    $candidate = ConvertTo-NormalizedReleaseVersion $CandidateVersion
    $current = ConvertTo-NormalizedReleaseVersion $CurrentVersion
    if ([string]::IsNullOrWhiteSpace($candidate) -or [string]::IsNullOrWhiteSpace($current)) {
        return $false
    }
    return ([version]$candidate) -gt ([version]$current)
}

function Resolve-SafeReleaseUrl {
    param([AllowNull()][string]$CandidateUrl)

    if ([string]::IsNullOrWhiteSpace($CandidateUrl)) {
        return $script:CanonicalReleasesUrl
    }
    $uri = $null
    if (-not [Uri]::TryCreate($CandidateUrl.Trim(), [UriKind]::Absolute, [ref]$uri)) {
        return $script:CanonicalReleasesUrl
    }
    if ($uri.Scheme -eq 'https' -and
        $uri.Host.Equals('github.com', [StringComparison]::OrdinalIgnoreCase) -and
        $uri.AbsolutePath.StartsWith('/Scrates1/clash-ssh-proxy-bootstrap/releases', [StringComparison]::OrdinalIgnoreCase) -and
        [string]::IsNullOrEmpty($uri.UserInfo)) {
        return $uri.AbsoluteUri
    }
    return $script:CanonicalReleasesUrl
}

function Get-ManagerUpdateCachePath {
    param([string]$ConfigPath)

    $expanded = [Environment]::ExpandEnvironmentVariables($ConfigPath)
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($expanded))
    return Join-Path $parent 'update-check.json'
}

function Read-ManagerUpdateCache {
    param([string]$CachePath)

    if (-not (Test-Path -LiteralPath $CachePath -PathType Leaf)) {
        return $null
    }
    try {
        return (Read-Utf8TextFile $CachePath | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Write-ManagerUpdateCache {
    param(
        [string]$CachePath,
        [hashtable]$Entry
    )

    try {
        $parent = Split-Path -Parent $CachePath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $tempPath = "$CachePath.$PID.tmp"
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $json = ConvertTo-Json -InputObject ([pscustomobject]$Entry) -Depth 4 -Compress
        try {
            [IO.File]::WriteAllText($tempPath, "$json`n", $encoding)
            Move-Item -LiteralPath $tempPath -Destination $CachePath -Force
        }
        finally {
            if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        # Update cache persistence is best-effort and must never break the UI.
    }
}

function Test-UpdateProxyListener {
    param([string]$HostName, [int]$PortNumber)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connectTask = $client.ConnectAsync($HostName, $PortNumber)
        return $connectTask.Wait(400) -and $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Get-ConfiguredUpdateProxy {
    param([string]$ConfigPath)

    $localHost = '127.0.0.1'
    $localPort = 7897
    try {
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
            $parsed = Read-Utf8TextFile $ConfigPath | ConvertFrom-Json
            if ($null -ne $parsed -and $null -ne $parsed.PSObject.Properties['proxy'] -and $null -ne $parsed.proxy) {
                if ($null -ne $parsed.proxy.PSObject.Properties['localHost'] -and -not [string]::IsNullOrWhiteSpace([string]$parsed.proxy.localHost)) {
                    $localHost = [string]$parsed.proxy.localHost
                }
                if ($null -ne $parsed.proxy.PSObject.Properties['localPort'] -and [int]$parsed.proxy.localPort -ge 1 -and [int]$parsed.proxy.localPort -le 65535) {
                    $localPort = [int]$parsed.proxy.localPort
                }
            }
        }
    }
    catch {}
    return [pscustomobject]@{ Host = $localHost; Port = $localPort }
}

function Invoke-GitHubReleaseRequest {
    param(
        [string]$ApiUrl,
        [string]$CurrentVersion,
        [AllowNull()][string]$ProxyUri
    )

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {}

    $request = [Net.HttpWebRequest]::Create($ApiUrl)
    $request.Method = 'GET'
    $request.UserAgent = "ClashSshProxyManager/$CurrentVersion"
    $request.Accept = 'application/vnd.github+json'
    $request.Headers['X-GitHub-Api-Version'] = '2022-11-28'
    $request.Timeout = 3500
    $request.ReadWriteTimeout = 3500
    $request.AllowAutoRedirect = $true
    if (-not [string]::IsNullOrWhiteSpace($ProxyUri)) {
        $request.Proxy = New-Object System.Net.WebProxy($ProxyUri)
    }
    else {
        $request.Proxy = $null
    }

    $response = $null
    try {
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)
        try {
            return ($reader.ReadToEnd() | ConvertFrom-Json)
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

function Get-LatestGitHubReleaseInfo {
    param(
        [string]$ConfigPath,
        [string]$CurrentVersion,
        [string]$ApiUrl = $script:DefaultReleasesApiUrl
    )

    $proxyInfo = Get-ConfiguredUpdateProxy $ConfigPath
    $proxyCandidates = @()
    if (Test-UpdateProxyListener $proxyInfo.Host $proxyInfo.Port) {
        $proxyCandidates += "http://$($proxyInfo.Host):$($proxyInfo.Port)"
    }
    $proxyCandidates += $null

    $payload = $null
    foreach ($proxyUri in $proxyCandidates) {
        try {
            $payload = Invoke-GitHubReleaseRequest -ApiUrl $ApiUrl -CurrentVersion $CurrentVersion -ProxyUri $proxyUri
            if ($null -ne $payload) { break }
        }
        catch {
            continue
        }
    }
    if ($null -eq $payload) {
        return $null
    }

    $isDraft = $null -ne $payload.PSObject.Properties['draft'] -and [bool]$payload.draft
    $isPrerelease = $null -ne $payload.PSObject.Properties['prerelease'] -and [bool]$payload.prerelease
    if ($isDraft -or $isPrerelease) {
        return [pscustomobject]@{
            LatestVersion = $CurrentVersion
            ReleaseUrl = $script:CanonicalReleasesUrl
            PublishedAt = ''
        }
    }

    $tagName = if ($null -ne $payload.PSObject.Properties['tag_name']) { [string]$payload.tag_name } else { '' }
    $latestVersion = ConvertTo-NormalizedReleaseVersion $tagName
    if ([string]::IsNullOrWhiteSpace($latestVersion)) {
        return $null
    }
    $rawUrl = if ($null -ne $payload.PSObject.Properties['html_url']) { [string]$payload.html_url } else { '' }
    $publishedAt = if ($null -ne $payload.PSObject.Properties['published_at'] -and $null -ne $payload.published_at) { [string]$payload.published_at } else { '' }
    return [pscustomobject]@{
        LatestVersion = $latestVersion
        ReleaseUrl = Resolve-SafeReleaseUrl $rawUrl
        PublishedAt = $publishedAt
    }
}

function Get-ManagerUpdateStatus {
    param(
        [string]$ConfigPath,
        [switch]$Force,
        [switch]$SkipNetwork,
        [int]$CacheTtlSeconds = 43200,
        [string]$ApiUrl = $script:DefaultReleasesApiUrl,
        [string]$RepositoryRoot = $script:RepositoryRoot
    )

    $currentVersion = Get-LocalManagerVersion -RepositoryRoot $RepositoryRoot
    if ($SkipNetwork) {
        return [ordered]@{
            currentVersion = $currentVersion
            latestVersion = $currentVersion
            updateAvailable = $false
            releaseUrl = $script:CanonicalReleasesUrl
            publishedAt = ''
            checkedAt = ''
            checkFailed = $false
        }
    }

    $cachePath = Get-ManagerUpdateCachePath $ConfigPath
    $cached = Read-ManagerUpdateCache $cachePath
    $cachedVersion = if ($null -ne $cached -and $null -ne $cached.PSObject.Properties['latestVersion']) {
        ConvertTo-NormalizedReleaseVersion ([string]$cached.latestVersion)
    } else { $null }
    $cachedCheckedAt = if ($null -ne $cached -and $null -ne $cached.PSObject.Properties['checkedAt']) {
        [string]$cached.checkedAt
    } else { '' }
    $cachedUrl = if ($null -ne $cached -and $null -ne $cached.PSObject.Properties['releaseUrl']) {
        Resolve-SafeReleaseUrl ([string]$cached.releaseUrl)
    } else { $script:CanonicalReleasesUrl }
    $cachedPublishedAt = if ($null -ne $cached -and $null -ne $cached.PSObject.Properties['publishedAt']) {
        [string]$cached.publishedAt
    } else { '' }

    if (-not $Force -and -not [string]::IsNullOrWhiteSpace($cachedVersion) -and -not [string]::IsNullOrWhiteSpace($cachedCheckedAt)) {
        $parsedTime = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($cachedCheckedAt, [ref]$parsedTime)) {
            $ageSeconds = ([DateTimeOffset]::UtcNow - $parsedTime).TotalSeconds
            if ($ageSeconds -ge 0 -and $ageSeconds -lt $CacheTtlSeconds) {
                return [ordered]@{
                    currentVersion = $currentVersion
                    latestVersion = $cachedVersion
                    updateAvailable = Test-NewerManagerVersion $cachedVersion $currentVersion
                    releaseUrl = $cachedUrl
                    publishedAt = $cachedPublishedAt
                    checkedAt = $cachedCheckedAt
                    checkFailed = $false
                }
            }
        }
    }

    $live = Get-LatestGitHubReleaseInfo -ConfigPath $ConfigPath -CurrentVersion $currentVersion -ApiUrl $ApiUrl
    if ($null -ne $live) {
        $nowIso = (Get-Date).ToUniversalTime().ToString('o')
        Write-ManagerUpdateCache -CachePath $cachePath -Entry @{
            checkedAt = $nowIso
            latestVersion = $live.LatestVersion
            releaseUrl = $live.ReleaseUrl
            publishedAt = $live.PublishedAt
        }
        return [ordered]@{
            currentVersion = $currentVersion
            latestVersion = $live.LatestVersion
            updateAvailable = Test-NewerManagerVersion $live.LatestVersion $currentVersion
            releaseUrl = $live.ReleaseUrl
            publishedAt = $live.PublishedAt
            checkedAt = $nowIso
            checkFailed = $false
        }
    }

    $fallbackVersion = if (-not [string]::IsNullOrWhiteSpace($cachedVersion)) { $cachedVersion } else { $currentVersion }
    return [ordered]@{
        currentVersion = $currentVersion
        latestVersion = $fallbackVersion
        updateAvailable = Test-NewerManagerVersion $fallbackVersion $currentVersion
        releaseUrl = $cachedUrl
        publishedAt = $cachedPublishedAt
        checkedAt = $cachedCheckedAt
        checkFailed = [bool]$Force
    }
}
