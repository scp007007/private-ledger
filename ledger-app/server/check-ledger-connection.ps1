#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port = 8000,
    [switch]$FunctionsOnly
)

$ErrorActionPreference = 'Stop'
# Dot sourcing the launcher binds its parameter variables in this scope.
$loadDiagnosticHelpersOnly = $FunctionsOnly
. (Join-Path $PSScriptRoot 'start-ledger-server.ps1') -Port $Port -FunctionsOnly

function Get-LedgerHealthResult {
    param([string]$Address, [int]$TargetPort)
    $response = $null
    $reader = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create(('http://{0}:{1}/health' -f $Address, $TargetPort))
        $request.Proxy = $null
        $request.AllowAutoRedirect = $false
        $request.Timeout = 2000
        $request.ReadWriteTimeout = 2000
        $request.Method = 'GET'
        # This endpoint is public. Never load or transmit the saved API token.
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200) { return 'HTTP 已响应，但不是健康检查成功状态' }
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $buffer = New-Object char[] 4096
        $count = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($count -eq 0 -or $count -eq $buffer.Length) { return 'HTTP 已响应，但内容不是预期的账本健康检查' }
        $payload = -join $buffer[0..($count - 1)]
        $health = $payload | ConvertFrom-Json -ErrorAction Stop
        if ($health.status -eq 'ok') { return '成功：status=ok' }
        return 'HTTP 已响应，但内容不是预期的账本健康检查'
    }
    catch [System.Net.WebException] {
        # Error responses also own a response stream and must be disposed.
        if ($null -eq $response) { $response = $_.Exception.Response }
        if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout) { return '连接超时' }
        if ($null -ne $_.Exception.Response) { return ('HTTP {0}；不是健康检查成功状态' -f [int]$_.Exception.Response.StatusCode) }
        return '连接失败：该地址无可访问的 HTTP 服务'
    }
    catch { return '无法确认健康检查结果' }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

if ($loadDiagnosticHelpersOnly) { return }

try {
    Write-Host '私有账本 — 只读连接诊断'
    Write-Host '本工具只读取网卡、TCP 监听状态，并请求不带令牌的 /health。'
    $inventory = @(Get-LedgerAdapterInventory)
    $candidates = @(Get-LedgerLanCandidates $inventory)
    Write-Host ''
    Write-Host '当前电脑 IPv4：'
    foreach ($item in $inventory) {
        $usable = @($candidates | Where-Object { $_.Address -eq $item.Address -and $_.Name -eq $item.Name }).Count -gt 0
        $label = if ($usable) { '可选择的私有地址' } else { '不作为手机局域网地址' }
        Write-Host ('  {0}  [{1}]  {2}' -f $item.Address, $item.Name, $label)
    }
    if ($inventory.Count -eq 0) { Write-Host '  未找到已连接的 IPv4 网卡。' }
    Write-Host ''
    $ports = @($Port, 8000, 18000 | Select-Object -Unique)
    $listeners = @()
    $listenerInventoryAvailable = $true
    try {
        $listeners = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -in $ports })
    }
    catch { $listenerInventoryAvailable = $false }
    Write-Host ('TCP 监听（{0}）：' -f ($ports -join ', '))
    if (-not $listenerInventoryAvailable) {
        Write-Host '  系统限制了监听状态的读取，无法确认；继续进行下方 HTTP 检查。' -ForegroundColor Yellow
    }
    elseif ($listeners.Count -eq 0) { Write-Host '  没有监听：账本服务尚未运行。请先双击 start-ledger-server.cmd。' -ForegroundColor Yellow }
    foreach ($listener in $listeners) {
        Write-Host ('  {0}:{1}' -f $listener.Address, $listener.Port)
        if ([System.Net.IPAddress]::IsLoopback($listener.Address)) {
            Write-Host '    仅监听本机，手机无法访问。请停止原服务，再用新启动脚本选择局域网地址。' -ForegroundColor Yellow
        }
        elseif ($listener.Address.ToString() -in @('0.0.0.0', '::')) {
            Write-Host '    监听所有网卡。手机应填写上方真实局域网 IPv4，不能填写 0.0.0.0 或 ::。'
        }
    }
    Write-Host ''
    Write-Host ('电脑本机 HTTP 检查（端口 {0}，绕过系统代理）：' -f $Port)
    $targets = @(@('127.0.0.1') + @($candidates | ForEach-Object { $_.Address }) | Select-Object -Unique)
    foreach ($address in $targets) {
        $result = Get-LedgerHealthResult $address $Port
        Write-Host ('  http://{0}:{1}/health  ->  {2}' -f $address, $Port, $result)
    }
    Write-Host ''
    Write-Host '下一步：'
    Write-Host '  1. 在手机浏览器打开选定局域网地址的 /health；得到 status=ok 后，在应用填写根地址和原令牌。'
    Write-Host '  2. 电脑检查成功但手机超时：检查是否在同一可互通网络、访客 Wi-Fi / AP 隔离、电脑或手机代理 / VPN。'
    Write-Host '  3. 在 Windows 安全中心核对防火墙提示，仅为可信的私人网络允许此 Python 服务；不要关闭防火墙。'
    Write-Host ('     如需手动规则，应限于 TCP {0}、选定本机地址和可信局域网来源，不要设置公网端口映射。' -f $Port)
    Write-Host '电脑上的健康检查成功只能证明本机服务可用；手机实际访问结果才能确认跨设备连接。'
}
catch {
    Write-Host '诊断未能完成。请在普通 Windows PowerShell 中重试，检查网卡状态和脚本文件是否齐全。' -ForegroundColor Red
    exit 1
}
