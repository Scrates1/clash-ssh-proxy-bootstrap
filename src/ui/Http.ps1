# Local manager HTTP validation and browser security policy helpers.

function Get-ManagerHttpSecurityHeaders {
    return [ordered]@{
        'Content-Security-Policy' = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
        'X-Content-Type-Options' = 'nosniff'
        'X-Frame-Options' = 'DENY'
        'Referrer-Policy' = 'no-referrer'
        'Permissions-Policy' = 'camera=(), microphone=(), geolocation=()'
        'Cross-Origin-Resource-Policy' = 'same-origin'
    }
}

function Test-ManagerApiOrigin {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Origin,
        [int]$BoundPort
    )

    if ([string]::IsNullOrWhiteSpace($Origin)) {
        return $true
    }
    $originUri = $null
    if (-not [Uri]::TryCreate($Origin, [UriKind]::Absolute, [ref]$originUri)) {
        return $false
    }
    return $originUri.Scheme -eq 'http' -and
        $originUri.Host -eq '127.0.0.1' -and
        $originUri.Port -eq $BoundPort -and
        [string]::IsNullOrEmpty($originUri.UserInfo) -and
        [string]::IsNullOrEmpty($originUri.Query) -and
        [string]::IsNullOrEmpty($originUri.Fragment) -and
        $originUri.AbsolutePath -eq '/'
}

function Assert-ManagerRequestLength {
    param(
        [long]$ContentLength,
        [ValidateRange(1024, 1048576)]
        [int]$MaximumBytes = 65536
    )

    if ($ContentLength -gt $MaximumBytes) {
        throw [IO.InvalidDataException]::new("Request body exceeds the $MaximumBytes-byte limit.")
    }
}

function Invoke-ManagerHttpSmokeRequest {
    param(
        [ValidateSet('GET', 'POST')]
        [string]$Method,
        [string]$Path,
        [hashtable]$Headers = @{},
        [AllowNull()]
        [string]$Body
    )

    $request = [Net.HttpWebRequest]::Create("http://127.0.0.1:$($script:BoundPort)$Path")
    $request.Method = $Method
    $request.Proxy = $null
    $request.AllowAutoRedirect = $false
    $request.Timeout = 5000
    $request.ReadWriteTimeout = 5000
    $response = $null
    try {
        foreach ($header in $Headers.GetEnumerator()) {
            $request.Headers[[string]$header.Key] = [string]$header.Value
        }
        # A missing [string] parameter is normalized to an empty string by
        # Windows PowerShell 5.1. Check binding instead so GET requests do not
        # accidentally receive a content body and fail before reaching HTTP.sys.
        $contextTask = $script:Listener.GetContextAsync()
        if ($PSBoundParameters.ContainsKey('Body')) {
            $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $request.ContentType = 'application/json; charset=utf-8'
            $request.ContentLength = $bodyBytes.LongLength
            $request.ServicePoint.Expect100Continue = $false
            $requestStream = $request.GetRequestStream()
            try {
                $requestStream.Write($bodyBytes, 0, $bodyBytes.Length)
            }
            finally {
                $requestStream.Dispose()
            }
        }
        elseif ($Method -eq 'POST') {
            $request.ContentLength = 0
        }

        $responseResult = $request.BeginGetResponse($null, $null)
        if (-not $contextTask.Wait(5000)) {
            $request.Abort()
            throw "Smoke request was not received: $Method $Path"
        }
        Handle-Request $contextTask.Result
        if (-not $responseResult.AsyncWaitHandle.WaitOne(5000)) {
            $request.Abort()
            throw "Smoke response timed out: $Method $Path"
        }
        try {
            $response = $request.EndGetResponse($responseResult)
        }
        catch {
            $webException = if ($_.Exception -is [Net.WebException]) {
                $_.Exception
            }
            elseif ($_.Exception.InnerException -is [Net.WebException]) {
                $_.Exception.InnerException
            }
            else {
                $null
            }
            if ($null -eq $webException -or $null -eq $webException.Response) {
                throw "Smoke response failed for $Method ${Path}: $($_.Exception.Message)"
            }
            $response = $webException.Response
        }
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try {
            $responseBody = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Body = $responseBody
            ContentSecurityPolicy = [string]$response.Headers['Content-Security-Policy']
        }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Invoke-ManagerHttpSmokeTest {
    $page = Invoke-ManagerHttpSmokeRequest -Method GET -Path '/'
    if ($page.StatusCode -ne 200 -or
        $page.Body -notmatch '<div id="root"></div>' -or
        [string]::IsNullOrWhiteSpace($page.ContentSecurityPolicy)) {
        throw 'React static-file or security-header smoke test failed'
    }

    $unauthorized = Invoke-ManagerHttpSmokeRequest -Method GET -Path '/api/state'
    if ($unauthorized.StatusCode -ne 401 -or $unauthorized.Body -notmatch 'INVALID_SESSION') {
        throw 'React API authentication smoke test failed'
    }

    $authorizedHeaders = @{
        'X-Proxy-Manager-Token' = $script:SessionToken
        'Origin' = "http://127.0.0.1:$($script:BoundPort)"
    }
    $heartbeat = Invoke-ManagerHttpSmokeRequest `
        -Method POST `
        -Path '/api/heartbeat' `
        -Headers $authorizedHeaders
    if ($heartbeat.StatusCode -ne 200 -or $heartbeat.Body -notmatch '"ok":true') {
        throw 'React API authorized-request smoke test failed'
    }

    $crossOriginHeaders = @{
        'X-Proxy-Manager-Token' = $script:SessionToken
        'Origin' = 'https://untrusted.example'
    }
    $crossOrigin = Invoke-ManagerHttpSmokeRequest `
        -Method POST `
        -Path '/api/heartbeat' `
        -Headers $crossOriginHeaders
    if ($crossOrigin.StatusCode -ne 403 -or $crossOrigin.Body -notmatch 'ORIGIN_REJECTED') {
        throw 'React API cross-origin smoke test failed'
    }

}
