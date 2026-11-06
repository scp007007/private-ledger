import '../l10n/ledger_l10n.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../ledger_controller.dart';
import '../model/ledger_transaction.dart';

class ImportPage extends StatefulWidget {
  const ImportPage({super.key, required this.controller, this.initialPreview});

  final LedgerController controller;
  final Map<String, dynamic>? initialPreview;

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  String _source = 'wechat';
  bool _busy = false;
  String? _fileName;
  Map<String, dynamic>? _preview;
  List<dynamic> _reviewRows = [];
  int _offset = 0;
  bool _reviewReady = false;
  bool _approved = false;

  @override
  void initState() {
    super.initState();
    _preview = widget.initialPreview;
    if (_preview != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadReview(0);
      });
    }
  }

  Future<void> _loadReview(int offset) async {
    final id = _preview?['preview_id'] as String?;
    if (id == null) return;
    setState(() => _busy = true);
    try {
      final page = await widget.controller.reviewImport(id, offset);
      if (mounted) {
        setState(() {
          _reviewRows = page['rows'] as List<dynamic>;
          _offset = offset;
          _reviewReady = true;
        });
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(localizedProblem(context, _errorMessage(error)))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _errorMessage(Object error) {
    if (error is ApiException) return error.message;
    if (error is StateError &&
        (error.message == '请先连接服务器。' ||
            error.message == '文件超过 10 MiB，请按月份拆分后导入。')) {
      return error.message;
    }
    return '无法处理文件，请检查文件读取权限、格式和服务器连接后重试。';
  }

  Future<void> _chooseAndPreview() async {
    setState(() => _busy = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'txt', 'zip'],
      );
      if (!mounted || result.isEmpty) return;
      final file = result.single;
      setState(() {
        _preview = null;
        _fileName = null;
        _approved = false;
        _reviewReady = false;
        _reviewRows = [];
      });
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      if (bytes.length > 10 * 1024 * 1024) {
        throw StateError('文件超过 10 MiB，请按月份拆分后导入。');
      }
      final preview = await widget.controller.previewImport(
        _source,
        file.name,
        bytes,
      );
      if (mounted) {
        setState(() {
          _fileName = file.name;
          _preview = preview;
        });
        await _loadReview(0);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr(context, "账单预览失败：{0}", [localizedProblem(context, _errorMessage(error))]))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    final previewId = _preview?['preview_id'] as String?;
    if (previewId == null || !_approved || !_reviewReady) return;
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(tr(context, "审核后确认入账")),
      content: Text(tr(context, "本次将尝试导入 {0} 笔新增流水，重复流水自动跳过。确认后会更新账本；尚未确认的预览不计入收支。", [_preview?['new_count']])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, "继续核对"))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, "确认入账")))],
    ));
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await widget.controller.commitImport(previewId);
      if (!mounted) return;
      setState(() {
        _preview = null;
        _fileName = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(context, "导入完成：新增 {0} 笔，重复 {1} 笔，跳过 {2} 笔。", [result['imported'], result['duplicate'], result['skipped']]),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr(context, "导入失败：{0}", [localizedProblem(context, _errorMessage(error))]))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final preview = _preview;
    final rows = _reviewRows;
    final warnings = preview?['warnings'] as List<dynamic>? ?? const [];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Icon(Icons.file_copy_outlined, size: 30, color: colors.onPrimaryContainer),
                  ),
                ),
                const SizedBox(height: 18),
                Text(tr(context, "把账单带进来"), textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  tr(context, "选择官方导出或钱迹 CSV 账单\n逐页审核，再确认入账，重复流水自动跳过"),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant, height: 1.6),
                ),
                const SizedBox(height: 24),
                Text(tr(context, "个人支付账户暂未接入官方自动读取 API。此处导入由你选取的文件；手机与电脑的自动同步在“我的”中设置。"),
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.6)),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: _source,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: tr(context, "账单来源")),
                  items: [
                    DropdownMenuItem(value: 'wechat', child: Text(tr(context, "微信账单"))),
                    DropdownMenuItem(value: 'alipay', child: Text(tr(context, "支付宝账单"))),
                    DropdownMenuItem(value: 'generic', child: Text(tr(context, "标准 CSV"))),
                  ],
                  onChanged: _busy ? null : (source) => setState(() {
                    _source = source ?? 'wechat';
                    _preview = null;
                    _fileName = null;
                  }),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _chooseAndPreview,
                  icon: const Icon(Icons.folder_open_rounded),
                  label: Text(preview == null ? tr(context, "选择文件并预览") : tr(context, "重新选择文件")),
                ),
                const SizedBox(height: 10),
                Text(tr(context, "支持 CSV、TXT、ZIP · 单个文件不超过 10 MiB"),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                const SizedBox(height: 12),
                Text(
                  tr(context, "文件只发送到你配置的账本服务器，不需要微信或支付宝账号密码。普通 HTTP 不加密账单，请使用可信网络、HTTPS 或加密 VPN。"),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant, height: 1.6),
                ),
              ],
            ),
          ),
        ),
        if (_busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(tr(context, "正在处理账单…"), style: theme.textTheme.bodySmall),
        ],
        if (preview != null) ...[
          const SizedBox(height: 22),
          Text(tr(context, "确认导入内容"), style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_fileName ?? tr(context, "账单预览"), style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(tr(context, "共 {0} 笔流水", [preview['total_rows']]),
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                  const SizedBox(height: 20),
                  Row(children: [
                    _count(tr(context, "新增"), preview['new_count'], accent: true),
                    _count(tr(context, "重复"), preview['duplicate_count']),
                    _count(tr(context, "跳过"), preview['skipped_count']),
                  ]),
                ],
              ),
            ),
          ),
          for (final warning in warnings)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('$warning', style: TextStyle(color: colors.error)),
            ),
          const SizedBox(height: 20),
          Text(tr(context, "逐页审核流水（{0} 起，每页最多 50 笔）", [_offset + 1]), style: theme.textTheme.titleMedium),
          if (!_reviewReady) TextButton(onPressed: _busy ? null : () => _loadReview(0), child: Text(tr(context, "加载审核明细"))),
          const SizedBox(height: 10),
          if (rows.isNotEmpty)
            Card(child: Column(children: [
              for (var index = 0; index < rows.length; index++) ...[
                if (index > 0) const Divider(height: 1, indent: 18, endIndent: 18),
                _previewRow(rows[index] as Map<String, dynamic>),
                if ((rows[index] as Map<String, dynamic>)['duplicate'] == true) Padding(
                  padding: EdgeInsets.only(bottom: 8), child: Text(tr(context, "重复流水，将跳过"))),
              ],
            ])),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: TextButton(onPressed: _busy || _offset == 0 ? null : () => _loadReview(_offset - 50), child: Text(tr(context, "上一页")))),
            Expanded(child: TextButton(onPressed: _busy || _offset + rows.length >= (preview['total_rows'] as num).toInt() ? null : () => _loadReview(_offset + 50), child: Text(tr(context, "下一页")))),
          ]),
          CheckboxListTile(value: _approved, onChanged: _busy ? null : (value) => setState(() => _approved = value ?? false),
            title: Text(tr(context, "我已核对本次账单，确认新增流水入账")),
            subtitle: Text(tr(context, "确认前仅为预览，不会自动写入账本。"))),
          FilledButton.icon(
            onPressed: _busy || !_approved || !_reviewReady || (preview['new_count'] as num? ?? 0) == 0 ? null : _commit,
            icon: const Icon(Icons.check_rounded),
            label: Text(tr(context, "确认导入 {0} 笔新增流水", [preview['new_count']])),
          ),
          TextButton(
            onPressed: _busy ? null : () => setState(() {
              _preview = null;
              _fileName = null;
            }),
            child: Text(tr(context, "取消本次预览")),
          ),
        ],
        const SizedBox(height: 18),
        Card(
          child: ExpansionTile(
            leading: Icon(Icons.help_outline, color: colors.primary),
            title: Text(tr(context, "导入说明")),
            childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            children: [
              Text(
                tr(context, "导入需要连接你的账本服务器，文件会在自己的服务器上解析。请保留导出文件的原始表头；加密 ZIP 请先解压。如果预览失败，请检查账单来源和文件格式，未确认的预览不会计入账本。服务器会暂存预览，未提交的预览 24 小时后失效，并在服务启动或下次导入操作时清理。确认导入后会清除预览中的流水副本，正式账本仍会保留。"),
                style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant, height: 1.7),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _count(String label, dynamic value, {bool accent = false}) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('${value ?? 0}', style: theme.textTheme.headlineSmall?.copyWith(
                color: accent ? theme.colorScheme.primary : null,
                fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _previewRow(Map<String, dynamic> transaction) {
    final theme = Theme.of(context);
    final merchant = '${transaction['merchant'] ?? ''}'.trim();
    final description = '${transaction['description'] ?? ''}'.trim();
    final category = '${transaction['category'] ?? ''}'.trim();
    final occurredAt = DateTime.tryParse('${transaction['occurred_at'] ?? ''}');
    final kind = switch (transaction['kind']) {
      'payment' => tr(context, "消费"),
      'refund' => tr(context, "退款"),
      'transfer' => tr(context, "转账"),
      'red_packet' => tr(context, "红包"),
      _ => tr(context, "其他"),
    };
    final income = transaction['direction'] == 'income';
    final amount = (transaction['amount_cents'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(
                merchant.isNotEmpty ? merchant : description.isNotEmpty ? description : tr(context, "未命名流水"),
                maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall)),
              const SizedBox(width: 12),
              Flexible(child: Text(
                '${income ? '+' : '−'}${formatMoney(amount)}',
                textAlign: TextAlign.end,
                style: theme.textTheme.titleSmall?.copyWith(color: income ? theme.colorScheme.primary : null),
              )),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${occurredAt == null ? tr(context, "日期待确认") : formatDate(occurredAt)}\n'
            '${category.isEmpty ? tr(context, "未分类") : category} · $kind',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.6),
          ),
        ],
      ),
    );
  }
}
