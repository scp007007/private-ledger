# Windows PowerShell 5.1 requires a UTF-8 BOM when reading non-ASCII scripts.
$script:ledgerEnglish = @{
    '私有账本 · 电脑端' = 'Private Ledger · Desktop'
    '让手机连接你的账本' = 'Connect your phone'
    '启动服务 → 手机填写当前地址 → 复制令牌完成同步' = 'Start the service, enter the address on your phone, then copy the token.'
    '尚未启动' = 'Service stopped'
    '电脑网络地址（自动选择，多个网卡时可切换）' = 'Network address (select an adapter if you have more than one)'
    '启动后显示手机应填的地址' = 'The address appears when the service starts'
    '复制地址' = 'Copy address'
    '首次使用可粘贴手机原有令牌；留空则自动生成。以后自动复用。' = 'Paste your existing token or leave this blank to generate one on first use.'
    '复制连接令牌' = 'Copy token'
    '已复制令牌，请仅粘贴到你自己的手机应用中；不要发给他人。' = 'Token copied. Paste it only into your own ledger app.'
    '点击启动后，本窗口会检查服务是否真正就绪。窗口最小化后仍可同步；关闭会停止服务。' = 'Start the service and wait for the health check. Minimise this window to keep syncing.'
    '数据保存在本机，令牌加密保存。HTTP 在局域网内仍是明文；外出同步请配置加密 VPN 或 HTTPS。' = 'Your ledger stays on this computer. The token is stored encrypted. Use an encrypted VPN or HTTPS when syncing across networks.'
    '启动服务' = 'Start service'
    '未找到可用局域网网卡，请连接网络后重新打开电脑端。' = 'No usable local network adapter. Connect to the network and reopen the app.'
    '账本路径指向文件夹，请核对 LEDGER_DB_PATH。' = 'The ledger path is a folder. Check LEDGER_DB_PATH.'
    '8000 端口已有服务，请先停止旧账本服务或运行连接诊断；本窗口不会接管未知服务。' = 'Port 8000 is already in use. Stop the previous ledger service or run connection diagnostics.'
    '正在启动并检查服务…' = 'Starting and checking service…'
    '等待服务响应。只有健康检查通过后，才会显示《服务就绪》。' = 'Waiting for the health check to pass.'
    '启动失败，请检查 Python 依赖、网络与账本路径。' = 'Could not start. Check Python dependencies, the network, and the ledger path.'
    '启动失败' = 'Startup failed'
    '停止服务' = 'Stop service'
    '正在安全停止…' = 'Stopping service…'
    '检查连接' = 'Check connection'
    '无法读取' = 'Unknown'
    '公用网络，核对入站访问权限' = 'Public network. Check inbound access.'
    '私人网络' = 'Private network'
    '域网络，可能受组织策略管理' = 'Domain network. Organisation policies may apply.'
    '本机健康检查通过' = 'Local health check passed'
    '本机服务未就绪，先启动服务' = 'Start the service first'
    '服务已停止' = 'Service stopped'
    '服务启动失败或已退出' = 'Service failed to start or exited'
    '检查 Python 依赖、8000 端口占用、账本路径和文件权限；可按 server/README.md 手动启动定位。' = 'Check Python dependencies, port 8000, the ledger path, and file permissions. See server/README.md.'
    'Python 运行依赖缺失，请先按 server/README.md 安装 requirements.txt，再启动服务。' = 'Install the Python dependencies using requirements.txt, then start the service. See server/README.md.'
    '8000 端口已被占用，请停止旧服务后重试；不要关闭不明进程。' = 'Port 8000 is in use. Stop the previous ledger service and retry.'
    '电脑 IP 已改变或网卡已断开，请重新打开电脑端，选择当前地址。' = 'The IP address changed or the adapter disconnected. Reopen the app and choose the current address.'
    '账本路径无法读写，请检查数据库目录权限和磁盘可用空间。' = 'The ledger cannot be read or written. Check folder permissions and available disk space.'
    '服务就绪 · 等待手机连接' = 'Service ready · Waiting for phone'
    '① 复制当前地址到手机  ② 手机点《检查网络》  ③ 复制令牌并连接。若手机仍不通，请按下方步骤排查。' = 'Copy the address to your phone, check the network, then copy the token and connect.'
    '进程仍运行，但健康检查未通过' = 'Service running · Health check failed'
    '请停止服务后核对网卡地址；如果刚切换了网络，请重新打开电脑端刷新地址。' = 'Stop the service and check the adapter address. If you changed networks, reopen the app to refresh it.'
    '关闭电脑端会停止账本同步服务。要继续在后台同步，请取消并最小化窗口。现在停止并退出吗？' = 'Closing this window stops the sync service. Choose No and minimise it to keep syncing. Stop and exit?'
    '停止账本服务' = 'Stop ledger service'
    '正在等待服务完成当前请求，请稍后关闭' = 'Waiting for current requests to finish. Try closing again shortly.'
    'LEDGER_PYTHON 指定的 Python 文件不存在。' = 'The Python executable specified by LEDGER_PYTHON does not exist.'
    '未找到 Python 虚拟环境。请按 server/README.md 安装 Python 和依赖到 server/.venv，再双击启动。' = 'No Python virtual environment found. Run setup-ledger-server.cmd or see server/README.md.'
    '已保存的令牌无法解密。请使用最初保存令牌的 Windows 账户和电脑，或先找回原令牌；本次不会生成或覆盖令牌。' = 'Could not decrypt the saved token. Use the original Windows account and computer, or recover the original token.'
    '已保存的令牌格式无效；本次不会生成或覆盖令牌。' = 'The saved token format is invalid. Restore the original token before starting.'
    'LEDGER_API_TOKEN 与已保存的令牌不同。请移除当前环境变量后复用已保存令牌，或核实原来的配置；本次未替换令牌。' = 'LEDGER_API_TOKEN differs from the saved token. Remove the environment variable to reuse the saved token, or check the original configuration.'
    '令牌须为至少 24、至多 1024 个可打印 ASCII 字符，不能含空格。未保存令牌，请重新输入原令牌或生成新令牌。' = 'Enter a token with 24–1024 printable ASCII characters and no spaces.'
    '无法安全保存加密令牌。请检查文件夹权限和是否重复启动；已有令牌不会被覆盖。' = 'Could not save the encrypted token. Check folder permissions and whether the app is already running.'
    '无法保存界面语言。' = 'Could not save the display language.'
}

$script:ledgerHelpZh = "手机仍连接不上？`r`n1. 手机先点《检查网络》，不需要令牌。`r`n2. 手机应使用这里的当前地址；换网络后地址可能改变。`r`n3. 电脑就绪但手机不通：检查访客 Wi-Fi、路由器设备隔离、代理/VPN。`r`n4. Windows 防火墙只允许可信私人网络访问 TCP 8000；保持防火墙开启。"
$script:ledgerHelpEn = "Phone still unable to connect?`r`n1. Run Check network on your phone. This does not need a token.`r`n2. Use the current address shown here. It may change when you switch networks.`r`n3. Check guest Wi-Fi, router device isolation, proxies, and VPN settings.`r`n4. Allow TCP 8000 only on trusted private networks in Windows Firewall."
$script:ledgerUsbZh = '当前使用 USB 网络共享，先确认手机与此电脑地址能够互通。'
$script:ledgerUsbEn = 'USB tethering detected. Check that your phone can reach this computer.'
$script:ledgerEnglish[$script:ledgerHelpZh] = $script:ledgerHelpEn
$script:ledgerEnglish[$script:ledgerUsbZh + "`r`n" + $script:ledgerHelpZh] = $script:ledgerUsbEn + "`r`n" + $script:ledgerHelpEn

function Get-LedgerText([string]$Text) {
    if ($script:ledgerLanguage -ne 'en') { return $Text }
    if ($script:ledgerEnglish.ContainsKey($Text)) { return $script:ledgerEnglish[$Text] }
    if ($Text -match '^发现旧账本：(.*)。请先将 LEDGER_DB_PATH') {
        return ('Existing ledger found: {0}. Set LEDGER_DB_PATH to this file before starting.' -f $Matches[1])
    }
    if ($Text -match '^(.*)。Windows：(.*)。手机仍需点《检查网络》确认跨设备连通。$') {
        $localState = $Matches[1]
        $networkCategory = $Matches[2]
        return ('{0}. Windows: {1}. Run Check network on your phone to verify the connection.' -f (Get-LedgerText $localState), (Get-LedgerText $networkCategory))
    }
    return $Text
}

function Set-LedgerText($Control, [string]$Text) {
    $Control.Tag = $Text
    $Control.Text = Get-LedgerText $Text
}
