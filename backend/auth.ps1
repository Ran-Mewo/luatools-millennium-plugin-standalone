param([ValidateSet('Initialize', 'SignIn', 'SignOut')][string]$Action)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Net.Http

$authRoot = Join-Path $env:LOCALAPPDATA 'LuaToolsPlugin'
$authFile = Join-Path $authRoot 'auth.dat'
$authStatusFile = Join-Path $authRoot 'status.json'
$supabaseUrl = 'https://db.lua.tools'
$supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE3NzYwMzkzNzYsImV4cCI6MTg5MzQ1NjAwMCwicm9sZSI6ImFub24iLCJpc3MiOiJzdXBhYmFzZSJ9.f_-K38u3odjltP-g_67FVmG32Vg-_-k-lNBvIaVUVBM'

function Write-AuthStatus($status, $displayName = '', $errorMessage = '') {
    $payload = @{
        status = $status
        displayName = $displayName
        error = $errorMessage
        updatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress
    $temporary = $authStatusFile + '.tmp'
    [IO.File]::WriteAllText($temporary, $payload)
    Move-Item -LiteralPath $temporary -Destination $authStatusFile -Force
}

function Read-AuthSession {
    if (-not [IO.File]::Exists($authFile)) { return $null }
    try {
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($authFile), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Save-AuthSession($session) {
    if (-not $session.access_token -or -not $session.refresh_token -or -not $session.expires_in) { throw 'The login server returned an incomplete session.' }
    $metadata = $session.user.user_metadata
    $displayName = $metadata.custom_claims.global_name
    if (-not $displayName) { $displayName = $metadata.full_name }
    if (-not $displayName) { $displayName = $metadata.name }
    if (-not $displayName) { $displayName = $session.user.email }
    $stored = @{
        accessToken = $session.access_token
        refreshToken = $session.refresh_token
        expiresAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + [long]$session.expires_in
        displayName = $displayName
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($stored | ConvertTo-Json -Compress))
    $encrypted = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $temporary = $authFile + '.tmp'
    [IO.File]::WriteAllBytes($temporary, $encrypted)
    Move-Item -LiteralPath $temporary -Destination $authFile -Force
    Write-AuthStatus 'signed_in' $displayName
    return [pscustomobject]$stored
}

function Request-AuthToken($grant, $body) {
    try {
        return Invoke-RestMethod -Method Post -Uri ($supabaseUrl + '/auth/v1/token?grant_type=' + $grant) -Headers @{ apikey = $supabaseKey } -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress) -TimeoutSec 30
    } catch {
        $statusCode = 0
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($grant -eq 'refresh_token' -and $statusCode -in @(400, 401, 403)) {
            Remove-Item -LiteralPath $authFile -Force -ErrorAction SilentlyContinue
            Write-AuthStatus 'signed_out'
            throw 'Your LuaTools session expired. Sign in again from Settings.'
        }
        throw 'Could not contact the LuaTools login server. Please try again.'
    }
}

function Get-AuthSession([switch]$ForceRefresh) {
    $session = Read-AuthSession
    if (-not $session -or -not $session.refreshToken) { return $null }
    if ($ForceRefresh -or [long]$session.expiresAt -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 120) {
        $response = Request-AuthToken 'refresh_token' @{ refresh_token = $session.refreshToken }
        $session = Save-AuthSession $response
    }
    return $session
}

function New-AuthMutex {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return New-Object Threading.Mutex($false, ('Local\LuaToolsPluginAuth-' + $identity))
}

function Enter-AuthMutex($mutex, $timeout) {
    try { return $mutex.WaitOne($timeout) }
    catch [Threading.AbandonedMutexException] { return $true }
}

function Get-LuaToolsToken([switch]$ForceRefresh) {
    $mutex = New-AuthMutex
    $locked = $false
    try {
        $locked = Enter-AuthMutex $mutex 35000
        if (-not $locked) { throw 'LuaTools sign-in is still in progress. Complete it in your browser first.' }
        $session = Get-AuthSession -ForceRefresh:$ForceRefresh
        if (-not $session) { throw 'Sign in to LuaTools from Settings to download from Luie.' }
        return $session.accessToken
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function ConvertTo-Base64Url([byte[]]$bytes) {
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# The callback address must match the portable client's registered OAuth redirect.
function Start-BrowserSignIn {
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = New-Object byte[] 48
        $random.GetBytes($bytes)
        $verifier = ConvertTo-Base64Url $bytes
        $challenge = ConvertTo-Base64Url ($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
    } finally {
        $random.Dispose()
        $sha.Dispose()
    }
    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add('http://localhost:53789/')
    $context = $null
    try {
        try { $listener.Start() }
        catch { throw 'Could not open the login callback. Close any other LuaTools login window and try again.' }
        $url = $supabaseUrl + '/auth/v1/authorize?provider=discord&redirect_to=' + [Uri]::EscapeDataString('http://localhost:53789/callback') + '&code_challenge=' + $challenge + '&code_challenge_method=s256'
        Write-AuthStatus 'waiting'
        Start-Process $url
        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        while ($true) {
            $pending = $listener.GetContextAsync()
            $remaining = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $pending.Wait($remaining)) { throw 'Sign-in timed out. Please try again.' }
            $context = $pending.GetAwaiter().GetResult()
            if (-not $context.Request.IsLocal -or $context.Request.HttpMethod -ne 'GET' -or $context.Request.Url.AbsolutePath -ne '/callback') {
                $context.Response.StatusCode = 404
                $context.Response.Close()
                $context = $null
                continue
            }
            $query = [Web.HttpUtility]::ParseQueryString($context.Request.Url.Query)
            if ($query['error']) { throw 'Sign-in was denied. Please try again.' }
            if (-not $query['code']) {
                $context.Response.StatusCode = 400
                $context.Response.Close()
                $context = $null
                continue
            }
            $session = Request-AuthToken 'pkce' @{ auth_code = $query['code']; code_verifier = $verifier }
            $null = Save-AuthSession $session
            $page = [Text.Encoding]::UTF8.GetBytes('Signed in! You can close this tab and return to Steam.')
            $context.Response.ContentType = 'text/plain; charset=utf-8'
            $context.Response.ContentLength64 = $page.Length
            $context.Response.OutputStream.Write($page, 0, $page.Length)
            $context.Response.Close()
            $context = $null
            return
        }
    } catch {
        if ($context) {
            $context.Response.StatusCode = 400
            $context.Response.Close()
        }
        throw
    } finally {
        $listener.Close()
    }
}

function Invoke-LuaToolsDownload($url, $destination) {
    $uri = [Uri]$url
    if ($uri.Scheme -ne 'https' -or $uri.Authority -ne 'lua.tools' -or $uri.AbsolutePath -ne '/api/manifest/download' -or $uri.UserInfo) { throw 'Invalid LuaTools download URL.' }
    $client = New-Object Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(5)
    try {
        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            $token = Get-LuaToolsToken -ForceRefresh:($attempt -gt 0)
            $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $uri)
            $request.Headers.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $token)
            $response = $null
            try {
                $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                if ([int]$response.StatusCode -eq 401 -and $attempt -eq 0) { continue }
                if (-not $response.IsSuccessStatusCode) { throw ('LuaTools download failed (HTTP ' + [int]$response.StatusCode + '). Check your account and download allowance on lua.tools.') }
                $downloadStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $stream = [IO.File]::Create($destination)
                $timeout = New-Object Threading.CancellationTokenSource
                $timeout.CancelAfter([TimeSpan]::FromMinutes(5))
                try {
                    $downloadStream.CopyToAsync($stream, 81920, $timeout.Token).GetAwaiter().GetResult()
                } finally {
                    $downloadStream.Dispose()
                    $stream.Dispose()
                    $timeout.Dispose()
                }
                return
            } finally {
                if ($response) { $response.Dispose() }
                $request.Dispose()
            }
        }
    } finally {
        $client.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $null = [IO.Directory]::CreateDirectory($authRoot)
    $mutex = New-AuthMutex
    $locked = $false
    try {
        $locked = Enter-AuthMutex $mutex 0
        if (-not $locked) { return }
        if ($Action -eq 'SignOut') {
            Remove-Item -LiteralPath $authFile -Force -ErrorAction SilentlyContinue
            Write-AuthStatus 'signed_out'
            return
        }
        Write-AuthStatus 'checking'
        try { $session = Get-AuthSession }
        catch {
            if ([IO.File]::Exists($authFile)) { throw }
            $session = $null
        }
        if ($session) { Write-AuthStatus 'signed_in' $session.displayName }
        else { Start-BrowserSignIn }
    } catch {
        Write-AuthStatus 'error' '' $_.Exception.Message
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
