#requires -Version 5.1
[CmdletBinding()]
param([switch]$SmokeTest, [string]$ScreenshotPath, [switch]$IntegrationTest, [string]$TestDataDirectory)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'start-ledger-server.ps1') -FunctionsOnly
$serverDirectory = $PSScriptRoot
if ($IntegrationTest) {
    if (-not $SmokeTest -or -not $TestDataDirectory) { throw 'Integration test requires SmokeTest and an isolated test directory.' }
    $testRoot = [System.IO.Path]::GetFullPath((Join-Path $serverDirectory '../../../work')) + [System.IO.Path]::DirectorySeparatorChar
    $testData = [System.IO.Path]::GetFullPath($TestDataDirectory)
    if (-not $testData.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $testData)) {
        throw 'Integration test directory must be new and within this workspace work folder.'
    }
}
$script:ledgerProcess = $null
$script:ledgerToken = $null
$script:ledgerAddress = $null
$script:ledgerStartedAt = $null
$script:ledgerOutput = $null
$script:ledgerErrors = $null
$script:ledgerReady = $false
$script:ledgerStopping = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = '私有账本 · 电脑端'
$form.Size = New-Object System.Drawing.Size(760, 780)
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$form.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F3F5F9')
$form.AutoScroll = $true

function Add-LedgerLabel($Text, $X, $Y, $Width, $Height) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.SetBounds($X, $Y, $Width, $Height)
    $form.Controls.Add($label)
    return $label
}
function Add-LedgerButton($Text, $X, $Y, $Width, $Handler) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.SetBounds($X, $Y, $Width, 40)
    $button.Add_Click($Handler)
    $form.Controls.Add($button)
    return $button
}

$heading = Add-LedgerLabel '让手机连接你的账本' 28 24 660 38
$heading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 18, [System.Drawing.FontStyle]::Bold)
$null = Add-LedgerLabel '启动服务 → 手机填写当前地址 → 复制令牌完成同步' 28 72 670 28
$status = Add-LedgerLabel '尚未启动' 28 115 670 36
$status.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$null = Add-LedgerLabel '电脑网络地址（自动选择，多个网卡时可切换）' 28 166 670 27
$adapters = New-Object System.Windows.Forms.ComboBox
$adapters.DropDownStyle = 'DropDownList'
$adapters.SetBounds(28, 198, 670, 32)
$form.Controls.Add($adapters)
$candidates = @()
try { $candidates = @(Get-LedgerLanCandidates @(Get-LedgerAdapterInventory)) } catch {}
foreach ($item in $candidates) { [void]$adapters.Items.Add(('{0}  ·  {1}' -f $item.Address, $item.Name)) }
if ($adapters.Items.Count -gt 0) { $adapters.SelectedIndex = 0 }

$urlBox = New-Object System.Windows.Forms.TextBox
$urlBox.SetBounds(28, 250, 480, 32)
$urlBox.ReadOnly = $true
$urlBox.Text = '启动后显示手机应填的地址'
$form.Controls.Add($urlBox)
$copyUrl = Add-LedgerButton '复制地址' 520 246 178 {
    if ($script:ledgerReady) { [System.Windows.Forms.Clipboard]::SetText($urlBox.Text) }
}
$copyUrl.Enabled = $false
$null = Add-LedgerLabel '首次使用可粘贴手机原有令牌；留空则自动生成。以后自动复用。' 28 304 670 28
$tokenInput = New-Object System.Windows.Forms.TextBox
$tokenInput.SetBounds(28, 336, 480, 32)
$tokenInput.UseSystemPasswordChar = $true
$form.Controls.Add($tokenInput)
$copyToken = Add-LedgerButton '复制连接令牌' 520 332 178 {
    if ($script:ledgerReady -and $script:ledgerToken) {
        [System.Windows.Forms.Clipboard]::SetText($script:ledgerToken)
        $detail.Text = '已复制令牌，请仅粘贴到你自己的手机应用中；不要发给他人。'
    }
}
$copyToken.Enabled = $false
$detail = Add-LedgerLabel '点击启动后，本窗口会检查服务是否真正就绪。窗口最小化后仍可同步；关闭会停止服务。' 28 438 670 54
$help = Add-LedgerLabel ("手机仍连接不上？`r`n1. 手机先点《检查网络》，不需要令牌。`r`n2. 手机应使用这里的当前地址；换网络后地址可能改变。`r`n3. 电脑就绪但手机不通：检查访客 Wi-Fi、路由器设备隔离、代理/VPN。`r`n4. Windows 防火墙只允许可信私人网络访问 TCP 8000；保持防火墙开启。") 28 505 670 152
$null = Add-LedgerLabel '数据保存在本机，令牌加密保存。HTTP 在局域网内仍是明文；外出同步请配置加密 VPN 或 HTTPS。' 28 667 670 48

function Set-LedgerStopped([string]$Message) {
    $status.Text = $Message
    $script:ledgerReady = $false
    $script:ledgerStopping = $false
    $copyUrl.Enabled = $false
    $copyToken.Enabled = $false
    $start.Enabled = $true
    $stop.Enabled = $false
    $adapters.Enabled = $true
    $tokenInput.Enabled = $true
}

$start = Add-LedgerButton '启动服务' 28 387 210 {
    try {
        if ($adapters.SelectedIndex -lt 0) { Stop-LedgerSetup '未找到可用局域网网卡，请连接网络后重新打开电脑端。' }
        $python = Get-LedgerPythonPath $serverDirectory $env:LEDGER_PYTHON
        $dataDirectory = if ($IntegrationTest) { $testData } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PrivateLedger' }
        $configuredDatabase = if ($IntegrationTest) { Join-Path $testData 'synthetic.sqlite3' } else { $env:LEDGER_DB_PATH }
        $database = Resolve-LedgerDatabasePath $serverDirectory $dataDirectory $configuredDatabase
        if (Test-Path -LiteralPath $database -PathType Container) { Stop-LedgerSetup '账本路径指向文件夹，请核对 LEDGER_DB_PATH。' }
        $script:ledgerAddress = $candidates[$adapters.SelectedIndex].Address
        # Never attach to, stop or replace another process on this port.
        $probe = New-Object System.Net.Sockets.TcpClient
        try {
            $task = $probe.ConnectAsync($script:ledgerAddress, 8000)
            try { [void]$task.Wait(300) } catch {}
            if ($probe.Connected) { Stop-LedgerSetup '8000 端口已有服务，请先停止旧账本服务或运行连接诊断；本窗口不会接管未知服务。' }
        } finally { $probe.Dispose() }
        [void][System.IO.Directory]::CreateDirectory($dataDirectory)
        $requested = $tokenInput.Text.Trim()
        if (-not $requested -and -not $IntegrationTest) { $requested = $env:LEDGER_API_TOKEN }
        $tokenFile = Join-Path $dataDirectory 'api-token.dpapi'
        if (-not (Test-Path -LiteralPath $tokenFile) -and -not $requested) { $requested = New-LedgerRandomToken }
        $script:ledgerToken = Get-LedgerPersistentToken $tokenFile $requested
        $tokenInput.Clear()
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $python
        $info.Arguments = '-m app.desktop_runner --host ' + $script:ledgerAddress + ' --port 8000'
        $info.WorkingDirectory = $serverDirectory
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.EnvironmentVariables['LEDGER_API_TOKEN'] = $script:ledgerToken
        $info.EnvironmentVariables['LEDGER_DB_PATH'] = $database
        $script:ledgerProcess = New-Object System.Diagnostics.Process
        $script:ledgerProcess.StartInfo = $info
        [void]$script:ledgerProcess.Start()
        $script:ledgerOutput = $script:ledgerProcess.StandardOutput.ReadToEndAsync()
        $script:ledgerErrors = $script:ledgerProcess.StandardError.ReadToEndAsync()
        $script:ledgerStartedAt = [DateTime]::UtcNow
        $urlBox.Text = 'http://' + $script:ledgerAddress + ':8000'
        $status.Text = '正在启动并检查服务…'
        $detail.Text = '等待服务响应。只有健康检查通过后，才会显示《服务就绪》。'
        $start.Enabled = $false
        $stop.Enabled = $true
        $adapters.Enabled = $false
        $tokenInput.Enabled = $false
    }
    catch {
        $message = '启动失败，请检查 Python 依赖、网络与账本路径。'
        if ($_.Exception.Data['LedgerSafeMessage']) { $message = $_.Exception.Message }
        Set-LedgerStopped '启动失败'
        $detail.Text = $message
    }
}
$start.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#DBE8FF')
$stop = Add-LedgerButton '停止服务' 252 387 210 {
    if ($script:ledgerProcess -and -not $script:ledgerProcess.HasExited) {
        $script:ledgerProcess.StandardInput.Close()
        $script:ledgerStopping = $true
        $script:ledgerReady = $false
        $copyUrl.Enabled = $false
        $copyToken.Enabled = $false
        $stop.Enabled = $false
        $status.Text = '正在安全停止…'
    }
}
$stop.Enabled = $false
$diagnose = Add-LedgerButton '检查连接' 476 387 222 {
    $networkCategory = '无法读取'
    try {
        $selected = $candidates[$adapters.SelectedIndex]
        $profile = Get-NetConnectionProfile -InterfaceAlias $selected.Name -ErrorAction Stop | Select-Object -First 1
        $networkCategory = switch ($profile.NetworkCategory.ToString()) {
            'Public' { '公用网络，核对入站访问权限' }
            'Private' { '私人网络' }
            default { '域网络，可能受组织策略管理' }
        }
    } catch {}
    $localState = if ($script:ledgerReady) { '本机健康检查通过' } else { '本机服务未就绪，先启动服务' }
    $detail.Text = $localState + '。Windows：' + $networkCategory + '。手机仍需点《检查网络》确认跨设备连通。'
}
if ($candidates.Count -gt 0 -and $candidates[0].Description -match 'RNDIS|Internet Sharing') {
    $help.Text = '当前使用 USB 网络共享，先确认手机与此电脑地址能够互通。' + "`r`n" + $help.Text
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1200
$timer.Add_Tick({
    if (-not $script:ledgerProcess) { return }
    if ($script:ledgerProcess.HasExited) {
        $wasStopping = $script:ledgerStopping
        Set-LedgerStopped $(if ($wasStopping) { '服务已停止' } else { '服务启动失败或已退出' })
        if (-not $wasStopping) {
            # Do not display raw stderr: it can include paths or bill values.
            $detail.Text = '检查 Python 依赖、8000 端口占用、账本路径和文件权限；可按 server/README.md 手动启动定位。'
            if ($script:ledgerErrors -and $script:ledgerErrors.IsCompleted) {
                $safeClassify = $script:ledgerErrors.Result
                if ($safeClassify -match 'No module named|ModuleNotFoundError') {
                    $detail.Text = 'Python 运行依赖缺失，请先按 server/README.md 安装 requirements.txt，再启动服务。'
                } elseif ($safeClassify -match '10048|address already in use') {
                    $detail.Text = '8000 端口已被占用，请停止旧服务后重试；不要关闭不明进程。'
                } elseif ($safeClassify -match '10049|cannot assign requested address') {
                    $detail.Text = '电脑 IP 已改变或网卡已断开，请重新打开电脑端，选择当前地址。'
                } elseif ($safeClassify -match 'PermissionError|unable to open database|readonly database') {
                    $detail.Text = '账本路径无法读写，请检查数据库目录权限和磁盘可用空间。'
                }
            }
        }
        $script:ledgerProcess.Dispose()
        $script:ledgerProcess = $null
        $script:ledgerToken = $null
        return
    }
    if ($script:ledgerStopping) { return }
    $response = $null
    $reader = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($urlBox.Text + '/health')
        $request.Proxy = $null
        $request.AllowAutoRedirect = $false
        $request.Timeout = 350
        $request.ReadWriteTimeout = 350
        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $buffer = New-Object char[] 512
        $count = $reader.ReadBlock($buffer, 0, 512)
        if ($count -le 0 -or $count -ge 512) { throw 'Invalid health payload' }
        $health = (-join $buffer[0..($count - 1)]) | ConvertFrom-Json
        if ($health.status -ne 'ok' -or $health.service -ne 'private-ledger') { throw 'Wrong service' }
        if (-not $script:ledgerReady) {
            $status.Text = '服务就绪 · 等待手机连接'
            $detail.Text = '① 复制当前地址到手机  ② 手机点《检查网络》  ③ 复制令牌并连接。若手机仍不通，请按下方步骤排查。'
        }
        $script:ledgerReady = $true
        $copyUrl.Enabled = $true
        $copyToken.Enabled = $true
    } catch {
        $script:ledgerReady = $false
        $copyUrl.Enabled = $false
        $copyToken.Enabled = $false
        if (([DateTime]::UtcNow - $script:ledgerStartedAt).TotalSeconds -gt 15) {
            $status.Text = '进程仍运行，但健康检查未通过'
            $detail.Text = '请停止服务后核对网卡地址；如果刚切换了网络，请重新打开电脑端刷新地址。'
        }
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
    }
})
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:ledgerProcess -and -not $script:ledgerProcess.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show('关闭电脑端会停止账本同步服务。要继续在后台同步，请取消并最小化窗口。现在停止并退出吗？', '停止账本服务', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { $eventArgs.Cancel = $true; return }
        $script:ledgerProcess.StandardInput.Close()
        if (-not $script:ledgerProcess.WaitForExit(12000)) {
            $eventArgs.Cancel = $true
            $script:ledgerStopping = $true
            $status.Text = '正在等待服务完成当前请求，请稍后关闭'
            return
        }
    }
    $timer.Stop()
})

if ($SmokeTest) {
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    if ($IntegrationTest) {
        $timer.Start()
        try {
            $start.PerformClick()
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            while (-not $script:ledgerReady -and [DateTime]::UtcNow -lt $deadline) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
            if (-not $script:ledgerReady) { throw ('Desktop readiness failed: ' + $detail.Text) }
            Write-Output 'Desktop integration: bound selected LAN address and health passed with isolated synthetic book.'
        }
        catch {
            if ($script:ledgerProcess -and -not $script:ledgerProcess.HasExited) {
                $script:ledgerProcess.StandardInput.Close()
                [void]$script:ledgerProcess.WaitForExit(15000)
            }
            throw
        }
    }
    # Build and paint the actual controls without running a service or reading secrets.
    if ($ScreenshotPath) {
        $form.Show()
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        try { $form.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height))); $bitmap.Save($ScreenshotPath) }
        finally { $bitmap.Dispose() }
    }
    if ($IntegrationTest) {
        $stop.PerformClick()
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ($script:ledgerProcess -and [DateTime]::UtcNow -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        if ($script:ledgerProcess) { throw 'Desktop service did not stop gracefully.' }
        Write-Output 'Desktop integration: stop button shut down its own server.'
    }
    $timer.Stop()
    Write-Output ('Desktop control smoke check passed: ' + $form.Controls.Count + ' controls')
    $form.Dispose()
    exit 0
}
$timer.Start()
[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
