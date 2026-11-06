import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/api_client.dart';
import '../ledger_controller.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({
    super.key,
    required this.controller,
    this.initialSetup = false,
  });

  final LedgerController controller;
  final bool initialSetup;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  late final TextEditingController _url;
  final _token = TextEditingController();
  bool _busy = false;
  bool _showToken = false;
  bool _privateHttpConfirmed = false;
  String? _error;
  ApiFailure? _failure;
  ConnectionStage? _stage;
  ConnectionStage? _failedStage;
  bool _networkReady = false;

  void _progress(ConnectionStage stage) {
    if (mounted) {
      setState(() {
        _stage = stage;
        if (stage.index >= ConnectionStage.authorization.index) _networkReady = true;
      });
    }
  }

  bool _confirmNetwork() {
    final uri = Uri.tryParse(_url.text.trim());
    if (uri?.scheme == 'http' && !_privateHttpConfirmed) {
      setState(() {
        _error = '请先确认这是可信局域网或已加密 VPN 中的私有 IP。';
        _failure = null;
      });
      return false;
    }
    return true;
  }

  Future<void> _checkNetwork() async {
    if (_busy || !_confirmNetwork()) return;
    setState(() {
      _busy = true;
      _error = null;
      _failure = null;
      _failedStage = null;
      _stage = ConnectionStage.health;
      _networkReady = false;
    });
    try {
      await widget.controller.checkServerHealth(_url.text.trim());
      if (mounted) {
        setState(() {
          _networkReady = true;
          _stage = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _connectionError(error);
          _failure = error is ApiException ? error.failure : null;
          _failedStage = ConnectionStage.health;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _nextSteps {
    if (_failure == ApiFailure.unauthorized) {
      return '手机已经能访问电脑。请在电脑端点击“复制连接令牌”，粘贴到下方令牌框后重试。无需更改防火墙。';
    }
    if (_failure == ApiFailure.tls || _failure == ApiFailure.redirect) {
      return '检查电脑端或反向代理的 HTTPS 根地址和证书。不要跳过证书校验。';
    }
    if (_failedStage == ConnectionStage.localCache) {
      return '网络和令牌已通过。请检查手机可用空间与安全存储权限后重试，本机离线修改仍需保留。';
    }
    if (_failure == ApiFailure.response || _failure == ApiFailure.server) {
      return '这个地址有响应，但服务内容不符合预期。请核对端口，并更新、重新启动电脑端账本服务。';
    }
    if (_failedStage == ConnectionStage.authorization) {
      return '网络检查已通过。请确认电脑服务仍在运行，并查看电脑端状态；还未完成令牌验证或账本同步。';
    }
    return '1. 打开电脑端，点击“启动服务”，等待“服务就绪”。\n'
        '2. 将电脑端当前地址重新填入；换网络后 IP 可能变化，不要填 127.0.0.1 或 198.18.x.x。\n'
        '3. 电脑就绪仍不通：检查访客 Wi-Fi、路由器设备隔离和代理/VPN；在 Windows 防火墙中只允许可信私人网络访问账本端口。';
  }

  Future<void> _copyDiagnosis() async {
    var address = '地址格式待核对';
    try { address = ApiClient.normalizeBaseUrl(_url.text); } on FormatException { /* Never copy credentials or queries from invalid input. */ }
    await Clipboard.setData(ClipboardData(text: '账本连接诊断\n地址：$address\n'
        '阶段：${_failedStage?.name ?? _stage?.name ?? '未开始'}\n'
        '网络检查：${_networkReady ? '通过' : '未通过或未检查'}\n'
        '提示：${_error ?? '无'}\n不含访问令牌或账单。'));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制诊断信息，不含令牌和账单。')));
  }

  String _connectionError(Object error) {
    if (error is ApiException) return error.message;
    // Only client-authored validation messages may reach the screen. Storage
    // and unexpected parsing errors can include private values in toString().
    const knownMessages = {
      '请输入服务器根地址，例如 https://ledger.example.com',
      'HTTP 只允许私有 IP、VPN IP 或本机开发地址；公网请使用 HTTPS。',
      '请输入访问令牌。',
      '正在更新连接，请稍后再试。',
      '服务器账本已改变，但手机还有未同步的修改。修改已保留，请先连接原账本完成同步。',
      '服务器版本比本地旧，已暂停同步。请检查服务器是否恢复了旧备份。',
      '服务器账本已改变，本地数据和待同步修改已保留。请在连接设置中确认账本。',
      '本地缓存缺少账本身份标识，已暂停同步。请在连接设置中重新确认账本。',
      '还有未同步的修改，无法清空本地账本。请先同步并解决冲突。',
    };
    final message = switch (error) {
      FormatException() => error.message,
      StateError() => error.message,
      _ => null,
    };
    if (message is String && knownMessages.contains(message)) return message;
    return '连接或保存设置失败。请检查服务器地址、电脑服务和手机可用存储空间后重试。';
  }

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.controller.baseUrl ?? '');
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final url = _url.text.trim();
    final token = _token.text;
    if (!_confirmNetwork()) return;
    if (token.trim().isEmpty && !widget.controller.hasToken) {
      setState(() => _error = '请输入电脑端的连接令牌；也可以先点击“检查网络”。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _failure = null;
      _failedStage = null;
      _stage = ConnectionStage.health;
      _networkReady = false;
    });
    try {
      try {
        await widget.controller.configure(url, token, onProgress: _progress);
      } on LedgerResetRequired catch (change) {
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('切换到另一个账本？'),
            content: const Text(
              '此服务器的账本与手机缓存不同。手机目前没有待同步的修改。确认后将清除手机上的流水和报表缓存，并下载新账本；原服务器数据仍会保留。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('切换账本'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        await widget.controller.configure(
          url,
          token,
          confirmedLedgerId: change.ledgerId,
          onProgress: _progress,
        );
      }
      if (!mounted) return;
      if (!widget.initialSetup) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('连接已更新，正在同步账本。')));
      }
      _token.clear();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _connectionError(error);
        _failure = error is ApiException ? error.failure : null;
        _failedStage = _stage;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: widget.initialSetup ? null : AppBar(title: const Text('连接设置')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 72, height: 72,
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(Icons.account_balance_wallet_outlined,
                  size: 34, color: colors.onPrimaryContainer),
              ),
            ),
            const SizedBox(height: 20),
            Text(widget.initialSetup ? '连接你的私有账本' : '管理服务器连接',
              textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 10),
            Text('账本保存在自己的电脑上\n手机保存本地副本，离线也能查看和修改',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant, height: 1.6)),
            const SizedBox(height: 26),
            Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('首次连接，只需三步', style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                const Text('① 电脑打开“账本电脑端”，启动到“服务就绪”。\n'
                    '② 手机和电脑连可互通的私人网络，填写电脑端当前显示的地址。\n'
                    '③ 先检查网络，再粘贴连接令牌并同步。', style: TextStyle(height: 1.7)),
                const SizedBox(height: 8),
                Text('这是连接你自己的电脑，无需注册账号。', style: theme.textTheme.bodySmall),
              ],
            ))),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('服务器信息', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _url,
                      enabled: !_busy,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (_) => setState(() {
                        _privateHttpConfirmed = false;
                        _networkReady = false;
                        _stage = null;
                        _failedStage = null;
                        _error = null;
                      }),
                      decoration: const InputDecoration(
                        labelText: '服务器地址',
                        hintText: 'http://192.168.1.5:8000',
                        helperText: '局域网填写电脑的私有 IP 和端口，例如 http://192.168.1.5:8000；真机不要填 localhost 或 127.0.0.1。',
                        helperMaxLines: 4,
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _checkNetwork,
                      icon: const Icon(Icons.network_check_rounded),
                      label: const Text('先检查网络（无需令牌）'),
                    ),
                    if (_networkReady) const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text('✓ 网络连通，电脑账本服务已响应。接下来验证令牌。'),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _token,
                      enabled: !_busy,
                      obscureText: !_showToken,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onSubmitted: _busy ? null : (_) => _save(),
                      decoration: InputDecoration(
                        labelText: '访问令牌',
                        helperText: widget.controller.hasToken ? '留空则继续使用已保存令牌' : '填写服务器配置的访问令牌',
                        helperMaxLines: 2,
                        prefixIcon: const Icon(Icons.key_outlined),
                        suffixIcon: IconButton(
                          tooltip: _showToken ? '隐藏令牌' : '显示令牌',
                          icon: Icon(_showToken ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                          onPressed: _busy ? null : () => setState(() => _showToken = !_showToken),
                        ),
                      ),
                    ),
                    if (Uri.tryParse(_url.text.trim())?.scheme == 'http') ...[
                      const SizedBox(height: 12),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _privateHttpConfirmed,
                        onChanged: _busy ? null : (value) => setState(() => _privateHttpConfirmed = value ?? false),
                        title: const Text('此地址位于可信局域网或已加密 VPN'),
                        subtitle: const Text('普通 HTTP 不加密访问令牌和账单内容。需要传输加密时请使用 HTTPS 或已加密 VPN；请勿在公网或不可信 Wi-Fi 使用 HTTP。'),
                      ),
                    ],
                    const SizedBox(height: 22),
                    FilledButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: _busy
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.link_rounded),
                      label: Text(_busy ? '正在检查…' : '连接并同步账本'),
                    ),
                    if (_stage != null) ...[
                      const SizedBox(height: 18),
                      for (final entry in const [
                        (ConnectionStage.health, '网络：找到电脑账本服务'),
                        (ConnectionStage.authorization, '令牌：验证权限并读取账本'),
                        (ConnectionStage.localCache, '本机：保存连接与离线副本'),
                      ]) Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Row(children: [
                        Icon(_failedStage == entry.$1 ? Icons.error_outline :
                            _stage!.index > entry.$1.index ? Icons.check_circle_outline : Icons.radio_button_unchecked,
                            size: 20, color: _failedStage == entry.$1 ? colors.error : colors.primary),
                        const SizedBox(width: 8),
                        Expanded(child: Text(entry.$2)),
                      ])),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.error,
                            height: 1.6,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(_nextSteps, style: theme.textTheme.bodyMedium?.copyWith(height: 1.7)),
                      TextButton.icon(onPressed: _copyDiagnosis,
                          icon: const Icon(Icons.copy_outlined, size: 18), label: const Text('复制诊断信息（不含令牌）')),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline_rounded, size: 18, color: colors.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  '建议使用 HTTPS，或通过已加密 VPN 连接。可信局域网内的普通 HTTP 仍不加密传输。令牌保存在系统安全存储中；手机保存账本本地副本。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant, height: 1.7))),
              ],
            ),
            if (!widget.initialSetup) ...[
              const SizedBox(height: 18),
              Text('更换同一账本的地址会保留本地修改。切换到不同账本时，需要先同步完修改，再确认替换手机缓存。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant, height: 1.7)),
            ],
          ],
        ),
      ),
    );
  }
}
