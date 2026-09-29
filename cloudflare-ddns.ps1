$ErrorActionPreference = 'Stop'

# 1. 显式加载 System.Net.Http 程序集（修复 PowerShell 5.1 找不到 HttpClientHandler 的问题）
Add-Type -AssemblyName System.Net.Http

$BaseDir   = 'C:\ProgramData\CloudflareDDNS'
$ConfigFile = Join-Path $BaseDir 'config.json'
$LogFile    = Join-Path $BaseDir 'ddns.log'
$CacheFile  = Join-Path $BaseDir 'last_ip.txt'

# 强制禁用 .NET 全局默认代理设置（确保直连拨号 IP，不走 Clash/v2ray 等代理）
[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy

# 确保工作目录存在
if (-not (Test-Path -LiteralPath $BaseDir)) {
    New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    
    # 日志超过 2MB 时自动重置
    if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item $LogFile).Length -gt 2MB)) {
        Remove-Item $LogFile -Force
    }
    
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    # 使用 Write-Host 避免变量泄漏污染函数返回值
    Write-Host $line
}

# 强行绕过代理（直连）发起 HTTP 请求
function Invoke-DirectRequest {
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [string]$Body = $null,
        [int]$TimeoutSec = 10
    )

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $handler.Proxy = $null

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

    try {
        foreach ($key in $Headers.Keys) {
            $null = $client.DefaultRequestHeaders.TryAddWithoutValidation($key, $Headers[$key])
        }

        if ($Method -eq 'GET') {
            $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
        }
        elseif ($Method -eq 'PATCH') {
            $content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, 'application/json')
            # 显式实例化 HttpMethod("PATCH") 兼容 PS 5.1 .NET Framework
            $httpMethod = New-Object System.Net.Http.HttpMethod('PATCH')
            $request = New-Object System.Net.Http.HttpRequestMessage($httpMethod, $Uri)
            $request.Content = $content
            try {
                $response = $client.SendAsync($request).GetAwaiter().GetResult()
            }
            finally {
                $request.Dispose()
                $content.Dispose()
            }
        }

        $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            throw ("HTTP Request Failed [{0}]: {1}" -f [int]$response.StatusCode, $responseBody)
        }

        return $responseBody
    }
    finally {
        $client.Dispose()
    }
}

function Get-PublicIPv4 {
    $urls = @(
        'https://api4.ipify.org',
        'https://ipv4.icanhazip.com',
        'https://checkip.amazonaws.com'
    )

    $ips = @()
    foreach ($url in $urls) {
        try {
            $res = (Invoke-DirectRequest -Uri $url -TimeoutSec 5).Trim()
            $address = $null
            if ([System.Net.IPAddress]::TryParse($res, [ref]$address) -and $address.AddressFamily -eq 'InterNetwork') {
                $ips += $res
                Write-Log ('Direct IP source OK: {0} -> {1}' -f $url, $res)
            } else {
                Write-Log ('IP source returned invalid IPv4: {0} -> {1}' -f $url, $res)
            }
        }
        catch {
            Write-Log ('IP source failed (Direct): {0} -> {1}' -f $url, $_.Exception.Message)
        }
    }

    if ($ips.Count -eq 0) {
        throw 'No public IPv4 source succeeded via direct connection.'
    }

    $groups = $ips | Group-Object | Sort-Object Count -Descending
    $best = $groups[0]

    if ($best.Count -ge 2) {
        Write-Log ('IP verification OK: {0} ({1} sources agreed)' -f $best.Name, $best.Count)
        return [string]$best.Name
    }

    if ($ips.Count -eq 1) {
        Write-Log ('Warning: Only 1 direct IP source responded ({0}). Using it as fallback.' -f $ips[0])
        return [string]$ips[0]
    }

    Write-Log ('IP sources disagree: {0}; skip update.' -f ($ips -join ', '))
    return $null
}

Write-Log '========== DDNS START =========='

try {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw ('Config file not found: {0}' -f $ConfigFile)
    }

    $config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $ApiToken   = [string]$config.ApiToken
    $ZoneId     = [string]$config.ZoneId
    $RecordName = [string]$config.RecordName

    if ([string]::IsNullOrWhiteSpace($ApiToken) -or 
        [string]::IsNullOrWhiteSpace($ZoneId) -or 
        [string]::IsNullOrWhiteSpace($RecordName)) {
        throw 'Missing required config parameters (ApiToken, ZoneId, or RecordName).'
    }

    # 1. 强制直连获取公网真实 IP
    $publicIp = Get-PublicIPv4
    if ([string]::IsNullOrWhiteSpace($publicIp)) {
        Write-Log 'No valid direct public IPv4 retrieved. Exit.'
        exit 0
    }

    # 2. 本地缓存检查（减少 Cloudflare API 频率限制）
    if (Test-Path -LiteralPath $CacheFile) {
        $cachedIp = (Get-Content -LiteralPath $CacheFile -Raw).Trim()
        if ($cachedIp -eq $publicIp) {
            Write-Log ('Direct Public IP ({0}) matches local cache. No update needed.' -f $publicIp)
            exit 0
        }
    }

    Write-Log ('Detected direct public IPv4: {0}' -f $publicIp)

    $headers = @{
        'Authorization' = ('Bearer {0}' -f $ApiToken)
        'Accept'        = 'application/json'
    }

    # 3. 直连获取 Cloudflare DNS 记录
    $encodedName = [Uri]::EscapeDataString($RecordName)
    $getUri = 'https://api.cloudflare.com/client/v4/zones/{0}/dns_records?type=A&name={1}' -f $ZoneId, $encodedName
    
    $getResponseBody = Invoke-DirectRequest -Uri $getUri -Headers $headers -Method GET -TimeoutSec 10
    $getResponse = $getResponseBody | ConvertFrom-Json

    if (-not $getResponse.success) {
        throw 'Cloudflare GET API returned success=false.'
    }
    if ($getResponse.result.Count -eq 0) {
        throw ('A record not found in Cloudflare: {0}' -f $RecordName)
    }

    $record = $getResponse.result[0]
    $currentIp = [string]$record.content
    $recordId  = [string]$record.id

    Write-Log ('Cloudflare remote IP: {0}' -f $currentIp)

    # 4. 比对云端 IP 并更新
    if ($currentIp -eq $publicIp) {
        Write-Log 'IP unchanged on Cloudflare. Updating local cache.'
        Set-Content -LiteralPath $CacheFile -Value $publicIp -Encoding UTF8
        exit 0
    }

    Write-Log ('IP change detected: {0} -> {1}. Updating Cloudflare...' -f $currentIp, $publicIp)

    $patchUri = 'https://api.cloudflare.com/client/v4/zones/{0}/dns_records/{1}' -f $ZoneId, $recordId
    $bodyJson = @{ content = $publicIp } | ConvertTo-Json -Compress

    $patchResponseBody = Invoke-DirectRequest -Uri $patchUri -Headers $headers -Method PATCH -Body $bodyJson -TimeoutSec 10
    $patchResponse = $patchResponseBody | ConvertFrom-Json

    if ($patchResponse.success) {
        Write-Log ('Cloudflare update successful: {0} -> {1}' -f $RecordName, $publicIp)
        Set-Content -LiteralPath $CacheFile -Value $publicIp -Encoding UTF8
    } else {
        throw 'Cloudflare PATCH API returned success=false.'
    }
}
catch {
    Write-Log ('ERROR: {0}' -f $_.Exception.Message)
    exit 1
}
finally {
    Write-Log '========== DDNS END =========='
}