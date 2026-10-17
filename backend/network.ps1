# Cloudflare is reached by IP so the lookup still works when the system DNS is what blocks the host.
$cloudflareDnsUrl = 'https://1.1.1.1/dns-query'
# curl exit codes for never reaching the host (DNS, connect, TLS, reset, timeout), as opposed to an HTTP error.
$unreachableExitCodes = @(6, 7, 28, 35, 52, 56, 60)

function Resolve-WithCloudflare([string]$hostName) {
    $ErrorActionPreference = 'Continue'
    try {
        $reply = & curl.exe --silent --max-time 10 --header 'accept: application/dns-json' ($cloudflareDnsUrl + '?name=' + [Uri]::EscapeDataString($hostName) + '&type=A')
        if ($LASTEXITCODE -ne 0) { return @() }
        $answer = ($reply -join '') | ConvertFrom-Json
        if ($answer.Status -ne 0) { return @() }
        return @($answer.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data })
    } catch {
        return @()
    }
}

function Test-SystemDnsAgrees([string]$hostName, [string[]]$addresses) {
    try { $systemAddresses = @([Net.Dns]::GetHostAddresses($hostName) | ForEach-Object { $_.IPAddressToString }) }
    catch { return $false }
    return @($addresses | Where-Object { $systemAddresses -contains $_ }).Count -gt 0
}

function Invoke-CurlOnce([string[]]$arguments, $standardInput) {
    $ErrorActionPreference = 'Continue'
    if ($null -ne $standardInput) { $output = $standardInput | & curl.exe @arguments 2>&1 }
    else { $output = & curl.exe @arguments 2>&1 }
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = (@($output) | ForEach-Object { "$_" }) -join "`n"
    }
}

function Invoke-Curl([string]$url, [string[]]$arguments, $standardInput = $null) {
    $result = Invoke-CurlOnce ($arguments + $url) $standardInput
    if ($result.ExitCode -notin $unreachableExitCodes) { return $result }

    $uri = [Uri]$url
    if ($uri.HostNameType -ne [UriHostNameType]::Dns) { return $result }
    $addresses = @(Resolve-WithCloudflare $uri.DnsSafeHost)
    if ($addresses.Count -eq 0 -or (Test-SystemDnsAgrees $uri.DnsSafeHost $addresses)) { return $result }

    $pinnedAddress = $uri.DnsSafeHost + ':' + $uri.Port + ':' + $addresses[0]
    return Invoke-CurlOnce (@('--resolve', $pinnedAddress) + $arguments + $url) $standardInput
}
