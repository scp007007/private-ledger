#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BindAddress,
    [ValidateRange(1024, 65535)][int]$Port = 8000,
    [switch]$FunctionsOnly
)

# This switch allows the read-only checker and synthetic tests to load helpers.
# Loading helpers performs no network requests, file writes or server startup.
function Stop-LedgerSetup {
    param([string]$Message)
    $failure = New-Object System.InvalidOperationException($Message)
    $failure.Data['LedgerSafeMessage'] = $true
    throw $failure
}

function Test-LedgerPrivateIPv4 {
    param([string]$Address)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    # Reject abbreviated addresses accepted by IPAddress.TryParse.
    if ($parsed.ToString() -ne $Address) { return $false }
    $bytes = $parsed.GetAddressBytes()
    return ($bytes[0] -eq 10 -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168))
}

function Get-LedgerAdapterInventory {
    foreach ($adapter in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($adapter.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        $properties = $adapter.GetIPProperties()
        $hasGateway = @($properties.GatewayAddresses | Where-Object {
            $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
            $_.Address.ToString() -ne '0.0.0.0'
        }).Count -gt 0
        foreach ($unicast in $properties.UnicastAddresses) {
            if ($unicast.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            [pscustomobject]@{
                Address = $unicast.Address.ToString()
                Name = $adapter.Name
                Description = $adapter.Description
                InterfaceType = $adapter.NetworkInterfaceType.ToString()
                HasGateway = $hasGateway
            }
        }
    }
}

function Get-LedgerLanCandidates {
    param([object[]]$Adapters)
    # Only assigned RFC1918 IPv4 addresses; virtual proxy/container adapters are excluded.
    # Private VPNs such as WireGuard remain selectable when assigned an RFC1918 address.
    @($Adapters | Where-Object {
        (Test-LedgerPrivateIPv4 $_.Address) -and
        $_.InterfaceType -ne 'Loopback' -and
        ($_.Name + ' ' + $_.Description) -notmatch '(?i)WSL|vEthernet|Hyper-V|VirtualBox|VMware|Docker|Loopback|Meta|Clash|Mihomo|TUNNELBEARPROXY'
    } | Sort-Object @{ Expression = {
        if ($_.HasGateway -and $_.InterfaceType -in @('Ethernet', 'Wireless80211')) { 0 }
        elseif ($_.HasGateway) { 1 }
        elseif ($_.InterfaceType -in @('Ethernet', 'Wireless80211')) { 2 }
        else { 3 }
    } }, Name, Address)
}

function Select-LedgerLanAddress {
    param([object[]]$Candidates, [string]$RequestedAddress)
    if ($Candidates.Count -eq 0) {
        Stop-LedgerSetup '未找到可用的私有 IPv4。请连接可信 Wi-Fi 或以太网后重试；198.18.x.x 代理地址不能用于手机连接。'
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedAddress)) {
        if (@($Candidates | Where-Object { $_.Address -eq $RequestedAddress }).Count -ne 1) {
            Stop-LedgerSetup '指定地址不是当前可用的局域网 IPv4。请运行连接诊断查看当前地址。'
        }
        return $RequestedAddress
    }
    Write-Host ''
    Write-Host '请选择手机能访问的电脑网卡（优先列出带网关的 Wi-Fi / 以太网）：'
    for ($index = 0; $index -lt $Candidates.Count; $index++) {
        $item = $Candidates[$index]
        $gatewayText = if ($item.HasGateway) { '有网关' } else { '无网关' }
        Write-Host ('  {0}. {1}  [{2}，{3}]' -f ($index + 1), $item.Address, $item.Name, $gatewayText)
    }
    while ($true) {
        $answer = Read-Host '输入序号，直接回车选择 1'
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Candidates[0].Address }
        $selection = 0
        if ([int]::TryParse($answer, [ref]$selection) -and $selection -ge 1 -and $selection -le $Candidates.Count) {
            return $Candidates[$selection - 1].Address
        }
        Write-Host '请输入列表中的序号。'
    }
}

function Get-LedgerPythonPath {
    param([string]$ServerDirectory, [string]$OverridePath)
    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        if (-not (Test-Path -LiteralPath $OverridePath -PathType Leaf)) {
            Stop-LedgerSetup 'LEDGER_PYTHON 指定的 Python 文件不存在。'
        }
        return (Resolve-Path -LiteralPath $OverridePath).Path
    }
    $possible = @(
        (Join-Path $ServerDirectory '.venv\Scripts\python.exe'),
        (Join-Path $ServerDirectory '..\..\..\work\.venv\Scripts\python.exe')
    )
    foreach ($candidate in $possible) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    Stop-LedgerSetup '未找到 Python 虚拟环境。请按 server/README.md 安装 Python 和依赖到 server/.venv，再双击启动。'
}

function Resolve-LedgerDatabasePath {
    param([string]$ServerDirectory, [string]$DataDirectory, [string]$ConfiguredPath)
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) {
            return [System.IO.Path]::GetFullPath($ConfiguredPath)
        }
        return [System.IO.Path]::GetFullPath((Join-Path $ServerDirectory $ConfiguredPath))
    }
    $defaultPath = Join-Path $DataDirectory 'ledger.sqlite3'
    $legacyPath = Join-Path $ServerDirectory 'data\ledger.sqlite3'
    if ((Test-Path -LiteralPath $legacyPath -PathType Leaf) -and -not (Test-Path -LiteralPath $defaultPath)) {
        Stop-LedgerSetup ('发现旧账本：{0}。请先将 LEDGER_DB_PATH 设为该文件的完整路径，再启动；本次未创建新账本。' -f $legacyPath)
    }
    return $defaultPath
}

function ConvertFrom-LedgerSecureToken {
    param([System.Security.SecureString]$SecureToken)
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}

function Test-LedgerToken {
    param([string]$Token)
    # Token is used in an HTTP header and Python's ASCII constant-time comparison.
    # Absolute anchors reject a trailing newline, which regex '$' would accept.
    return ($Token.Length -ge 24 -and $Token.Length -le 1024 -and $Token -cmatch '\A[\x21-\x7e]+\z')
}

function New-LedgerRandomToken {
    $bytes = New-Object byte[] 48
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) }
    finally { $random.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-LedgerPersistentToken {
    param([string]$TokenFile, [string]$EnvironmentToken)
    if (Test-Path -LiteralPath $TokenFile) {
        $secure = $null
        try {
            $encrypted = [System.IO.File]::ReadAllText($TokenFile).Trim()
            $secure = ConvertTo-SecureString -String $encrypted -ErrorAction Stop
            $saved = ConvertFrom-LedgerSecureToken $secure
        }
        catch {
            Stop-LedgerSetup '已保存的令牌无法解密。请使用最初保存令牌的 Windows 账户和电脑，或先找回原令牌；本次不会生成或覆盖令牌。'
        }
        finally { if ($null -ne $secure) { $secure.Dispose() } }
        if (-not (Test-LedgerToken $saved)) { Stop-LedgerSetup '已保存的令牌格式无效；本次不会生成或覆盖令牌。' }
        if (-not [string]::IsNullOrEmpty($EnvironmentToken) -and $EnvironmentToken -cne $saved) {
            Stop-LedgerSetup 'LEDGER_API_TOKEN 与已保存的令牌不同。请移除当前环境变量后复用已保存令牌，或核实原来的配置；本次未替换令牌。'
        }
        return $saved
    }
    $token = $EnvironmentToken
    if ([string]::IsNullOrEmpty($token)) {
        Write-Host ''
        Write-Host '首次配置：如果手机已有令牌，请输入同一个值；直接回车将生成新令牌。'
        $entered = Read-Host '既有令牌（输入时隐藏）' -AsSecureString
        try { $token = ConvertFrom-LedgerSecureToken $entered }
        finally { $entered.Dispose() }
        if ([string]::IsNullOrEmpty($token)) { $token = New-LedgerRandomToken }
    }
    if (-not (Test-LedgerToken $token)) {
        Stop-LedgerSetup '令牌须为至少 24、至多 1024 个可打印 ASCII 字符，不能含空格。未保存令牌，请重新输入原令牌或生成新令牌。'
    }
    $secure = ConvertTo-SecureString -String $token -AsPlainText -Force
    try { $protected = ConvertFrom-SecureString -SecureString $secure -ErrorAction Stop }
    finally { $secure.Dispose() }
    # DPAPI binds the ciphertext to this Windows user on this machine.
    # CreateNew prevents another launch from overwriting a saved token.
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($TokenFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($protected)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    catch { Stop-LedgerSetup '无法安全保存加密令牌。请检查文件夹权限和是否重复启动；已有令牌不会被覆盖。' }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
    return $token
}

if ($FunctionsOnly) { return }

$ErrorActionPreference = 'Stop'
$oldToken = $env:LEDGER_API_TOKEN
$oldDatabasePath = $env:LEDGER_DB_PATH
$serverDirectory = $PSScriptRoot
$serverExitCode = 1
$locationPushed = $false
$stage = '读取本机配置'
try {
    Write-Host '私有账本 — Windows 局域网服务'
    $dataDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PrivateLedger'
    $python = Get-LedgerPythonPath $serverDirectory $env:LEDGER_PYTHON
    $databasePath = Resolve-LedgerDatabasePath $serverDirectory $dataDirectory $env:LEDGER_DB_PATH
    if (Test-Path -LiteralPath $databasePath -PathType Container) { Stop-LedgerSetup 'LEDGER_DB_PATH 指向了文件夹，请改为账本 .sqlite3 文件路径。' }
    $stage = '检测 Python 依赖'
    & $python -c 'import fastapi, uvicorn, multipart' 2>$null
    if ($LASTEXITCODE -ne 0) { Stop-LedgerSetup 'Python 依赖不完整，请使用所选 Python 安装 server/requirements.txt 后重试。' }
    $stage = '选择局域网地址'
    $candidates = @(Get-LedgerLanCandidates @(Get-LedgerAdapterInventory))
    $selectedAddress = Select-LedgerLanAddress $candidates $BindAddress
    $listeners = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port })
    if ($listeners.Count -gt 0) {
        Stop-LedgerSetup ('TCP {0} 已有服务监听。请先运行连接诊断，确认原服务；本脚本不会停止或替换已有服务。' -f $Port)
    }
    $stage = '准备固定令牌'
    [void][System.IO.Directory]::CreateDirectory($dataDirectory)
    $tokenFile = Join-Path $dataDirectory 'api-token.dpapi'
    $token = Get-LedgerPersistentToken $tokenFile $env:LEDGER_API_TOKEN
    $env:LEDGER_API_TOKEN = $token
    $env:LEDGER_DB_PATH = $databasePath
    Write-Host ''
    Write-Host ('手机服务器地址：http://{0}:{1}' -f $selectedAddress, $Port) -ForegroundColor Green
    Write-Host ('连通性检查：http://{0}:{1}/health' -f $selectedAddress, $Port)
    Write-Host ('主账本路径：{0}' -f $databasePath)
    Write-Host ('加密令牌位置：{0}（同一 Windows 账户自动复用）' -f $tokenFile)
    # Write the secret directly to the interactive console, never to a log or the output pipeline.
    if (-not [Console]::IsOutputRedirected) {
        [Console]::WriteLine('手机 API 令牌（请勿分享或截图）：')
        [Console]::WriteLine($token)
    }
    else { Write-Host '输出已重定向，已隐藏令牌。请双击启动脚本，在本机控制台查看。' }
    Write-Host ''
    Write-Host '正在启动。出现 Application startup complete 后再连接手机；请保持窗口打开。'
    Write-Host '手机和电脑须在能互通的可信局域网中；按 Ctrl+C 停止。'
    Write-Host '当前使用 HTTP，令牌和账单在网络中未加密；外出连接请使用 HTTPS 或加密的私有网络。'
    Write-Host '若手机仍超时，运行 check-ledger-connection.cmd，并在手机浏览器打开上述 /health。'
    $stage = '运行账本服务'
    Push-Location -LiteralPath $serverDirectory
    $locationPushed = $true
    & $python -m uvicorn app.main:app --host $selectedAddress --port $Port --no-access-log --no-use-colors
    $serverExitCode = $LASTEXITCODE
}
catch {
    if ($_.Exception.Data['LedgerSafeMessage']) { Write-Host ('无法启动：{0}' -f $_.Exception.Message) -ForegroundColor Red }
    else { Write-Host ('无法启动：{0}失败。请检查权限、配置和网络，或运行连接诊断。' -f $stage) -ForegroundColor Red }
    $serverExitCode = 1
}
finally {
    if ($locationPushed) { Pop-Location }
    $env:LEDGER_API_TOKEN = $oldToken
    $env:LEDGER_DB_PATH = $oldDatabasePath
    $token = $null
}
exit $serverExitCode
