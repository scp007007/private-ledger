import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../ledger_controller.dart';
import '../model/ledger_transaction.dart';

Future<void> openNewTransaction(BuildContext context, LedgerController controller) => Navigator.of(context).push(
  MaterialPageRoute<void>(builder: (_) => TransactionEditor(controller: controller, isNew: true,
    row: LedgerRow(LedgerTransaction.fromJson({
      'id': const Uuid().v4(), 'source': 'manual', 'occurred_at': DateTime.now().toUtc().toIso8601String(),
      'amount_cents': 0, 'direction': 'expense', 'kind': 'payment', 'version': 0, 'revision': 0,
    }), 0, false))),
);

class TransactionsPage extends StatefulWidget {
  const TransactionsPage({
    super.key,
    required this.controller,
    this.category,
    this.month,
    this.year,
  });

  final LedgerController controller;
  final String? category;
  final DateTime? month;
  final int? year;

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  final _search = TextEditingController();
  bool _pendingOnly = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  @override
  void didUpdateWidget(TransactionsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final query = _search.text.trim().toLowerCase();
    final rows = widget.controller.rows
        .where((row) {
          if (_pendingOnly && row.pendingCount == 0) return false;
          final transaction = row.transaction;
          final month = widget.month;
          final date = transaction.ledgerDateTime;
          if (widget.year != null && date.year != widget.year) return false;
          if (month != null &&
              (date.year != month.year || date.month != month.month)) {
            return false;
          }
          if (widget.category != null) {
            final category = widget.category!.trim();
            final rawCategory = (transaction.category ?? '').trim();
            final displayCategory = rawCategory.isEmpty ? '未分类' : rawCategory;
            if (displayCategory != category ||
                transaction.direction != 'expense' ||
                transaction.excluded) {
              return false;
            }
          }
          if (query.isEmpty) return true;
          return [
            transaction.merchant,
            transaction.description,
            transaction.category ?? '',
            transaction.note,
            ...transaction.tags,
          ].join(' ').toLowerCase().contains(query);
        })
        .toList()
      ..sort((a, b) =>
          b.transaction.occurredAt.compareTo(a.transaction.occurredAt));
    final grouped = <DateTime, List<LedgerRow>>{};
    for (final row in rows) {
      final date = row.transaction.ledgerDateTime;
      final day = DateTime(date.year, date.month, date.day);
      grouped.putIfAbsent(day, () => []).add(row);
    }
    final days = grouped.keys.toList(growable: false);

    return Column(
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Row(children: [
          Expanded(child: Text('点击流水可编辑金额、分类等', style: Theme.of(context).textTheme.bodySmall)),
          TextButton.icon(onPressed: () => openNewTransaction(context, widget.controller),
            icon: const Icon(Icons.add), label: const Text('记一笔')),
        ])),
        if (widget.controller.lastError != null)
          MaterialBanner(
            leading: const Icon(Icons.cloud_off_outlined),
            content: const Text('暂未同步，正在显示本机账本'),
            actions: [
              TextButton(
                onPressed: () => widget.controller.syncNow(),
                child: const Text('重试'),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: '搜索商家、分类、标签或备注',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(_search.clear),
                    ),
              isDense: true,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              FilterChip(
                label: const Text('待同步与冲突'),
                selected: _pendingOnly,
                onSelected: (value) => setState(() => _pendingOnly = value),
              ),
              const Spacer(),
              Text('${rows.length} 笔流水',
                  style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12)),
            ],
          ),
        ),
        if (widget.category != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.primaryContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '分类原始消费明细；金额未扣关联退款',
              style: TextStyle(color: colors.onPrimaryContainer, fontSize: 12),
            ),
          ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.receipt_long_outlined,
                            size: 44, color: colors.outline),
                        const SizedBox(height: 14),
                        Text(
                          widget.controller.rows.isEmpty
                              ? '导入第一份账单，开始整理收支'
                              : '没有符合条件的流水',
                          style: TextStyle(color: colors.onSurfaceVariant),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  key: const PageStorageKey('transactions-scroll'),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: days.length,
                  itemBuilder: (context, index) {
                    final day = days[index];
                    final group = grouped[day]!;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 12, 2, 10),
                          child: Row(
                            children: [
                              Text(_dayLabel(day),
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                              const Spacer(),
                              Text('${group.length} 笔',
                                  style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12)),
                            ],
                          ),
                        ),
                        Card(
                          margin: EdgeInsets.zero,
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            children: [
                              for (var i = 0; i < group.length; i++) ...[
                                if (i > 0)
                                  Divider(height: 1, indent: 66,
                                      color: colors.outlineVariant.withValues(alpha: 0.45)),
                                TransactionRowTile(controller: widget.controller, row: group[i]),
                              ],
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

String _dayLabel(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  if (day == today) return '今天 · ${day.month}月${day.day}日';
  if (day == DateTime(now.year, now.month, now.day - 1)) {
    return '昨天 · ${day.month}月${day.day}日';
  }
  return '${day.year == now.year ? '' : '${day.year}年'}${day.month}月${day.day}日';
}

String _sourceLabel(String source) => switch (source) {
  'alipay' => '支付宝',
  'wechat' || 'weixin' || 'wechat_pay' => '微信',
  'manual' => '手动记账',
  'generic' || 'csv' => '导入账单',
  _ => '其他来源',
};

String _categoryLabel(String? category) =>
    category == null || category.trim().isEmpty ? '未分类' : category;

String _merchantLabel(LedgerTransaction transaction) =>
    transaction.merchant.isNotEmpty
        ? transaction.merchant
        : transaction.description.isNotEmpty
        ? transaction.description
        : '未命名流水';

IconData _transactionIcon(LedgerTransaction transaction) {
  if (transaction.kind == 'refund') return Icons.undo_rounded;
  if (transaction.kind == 'transfer') return Icons.swap_horiz_rounded;
  if (transaction.kind == 'red_packet') return Icons.card_giftcard_rounded;
  if (transaction.direction == 'income') return Icons.account_balance_wallet_outlined;
  final category = transaction.category ?? '';
  if (category.contains('餐') || category.contains('食')) return Icons.restaurant_outlined;
  if (category.contains('交通') || category.contains('出行')) return Icons.directions_bus_outlined;
  if (category.contains('购') || category.contains('日用')) return Icons.shopping_bag_outlined;
  if (category.contains('居') || category.contains('住房')) return Icons.home_outlined;
  return Icons.receipt_long_outlined;
}

class TransactionRowTile extends StatelessWidget {
  const TransactionRowTile({
    super.key,
    required this.controller,
    required this.row,
    this.onTap,
  });

  final LedgerController controller;
  final LedgerRow row;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final transaction = row.transaction;
    final isExpense = transaction.direction == 'expense';
    final date = transaction.ledgerDateTime;
    final time = '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    return InkWell(
      onTap: onTap ?? () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TransactionEditor(controller: controller, row: row),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: colors.primaryContainer.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_transactionIcon(transaction), color: colors.primary, size: 19),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(builder: (context, constraints) => Row(
                    children: [
                      Expanded(
                        child: Text(_merchantLabel(transaction),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      ),
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.48),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('${isExpense ? '−' : '+'}${formatMoney(transaction.amountCents)}',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15,
                              color: transaction.excluded ? colors.onSurfaceVariant : isExpense ? colors.onSurface : colors.primary)),
                        ),
                      ),
                    ],
                  )),
                  const SizedBox(height: 5),
                  Text('${_categoryLabel(transaction.category)} · ${_sourceLabel(transaction.source)} · $time',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11)),
                  if (transaction.tags.isNotEmpty || transaction.kind == 'refund' || transaction.kind == 'transfer' || transaction.kind == 'red_packet') ...[
                    const SizedBox(height: 4),
                    Text([
                      if (transaction.kind == 'refund' || transaction.kind == 'transfer' || transaction.kind == 'red_packet') _kindLabel(transaction.kind),
                      ...transaction.tags.take(2).map((tag) => '#$tag'),
                    ].join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11)),
                  ],
                  if (transaction.excluded || row.pendingCount > 0 || row.hasConflict) ...[
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 6, runSpacing: 4,
                      children: [
                        if (transaction.excluded) _StatusLabel(text: '不计入报表', color: colors.onSurfaceVariant, background: colors.surfaceContainerHighest),
                        if (row.hasConflict) _StatusLabel(text: '同步冲突', color: colors.error, background: colors.errorContainer),
                        if (row.pendingCount > 0 && !row.hasConflict) _StatusLabel(text: '待同步', color: colors.primary, background: colors.primaryContainer),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.text, required this.color, required this.background});
  final String text;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(color: background.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(6)),
    child: Text(text, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w500)),
  );
}

String _kindLabel(String kind) => switch (kind) {
  'payment' => '消费',
  'refund' => '退款',
  'transfer' => '转账',
  'red_packet' => '红包',
  _ => '其他',
};

class TransactionEditor extends StatefulWidget {
  const TransactionEditor({
    super.key,
    required this.controller,
    required this.row,
    this.isNew = false,
  });

  final LedgerController controller;
  final LedgerRow row;
  final bool isNew;

  @override
  State<TransactionEditor> createState() => _TransactionEditorState();
}

class _TransactionEditorState extends State<TransactionEditor> {
  late final TextEditingController _amount;
  late final TextEditingController _merchant;
  late final TextEditingController _description;
  late String _direction;
  late DateTime _date;
  bool _dateChanged = false;
  late final TextEditingController _category;
  late final TextEditingController _tags;
  late final TextEditingController _note;
  late bool _excluded;
  late String? _refundOfId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final transaction = widget.row.transaction;
    _amount = TextEditingController(text: widget.isNew ? '' : '${transaction.amountCents ~/ 100}.${(transaction.amountCents % 100).toString().padLeft(2, '0')}');
    _merchant = TextEditingController(text: transaction.merchant);
    _description = TextEditingController(text: transaction.description);
    _direction = transaction.direction;
    _date = transaction.ledgerDateTime;
    _category = TextEditingController(text: transaction.category ?? '');
    _tags = TextEditingController(text: transaction.tags.join('，'));
    _note = TextEditingController(text: transaction.note);
    _excluded = transaction.excluded;
    _refundOfId = transaction.refundOfId;
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _description.dispose();
    _category.dispose();
    _tags.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final text = _amount.text.trim();
      if (!RegExp(r'^\d{1,13}(\.\d{1,2})?$').hasMatch(text)) {
        throw const FormatException('请输入正确金额，最多保留两位小数。');
      }
      final parts = text.split('.');
      final cents = int.parse(parts[0]) * 100 + int.parse(parts.length == 1 ? '0' : parts[1].padRight(2, '0'));
      if (cents <= 0) throw const FormatException('金额必须大于零。');
      final category = _category.text.trim();
      final tags = _tags.text
          .split(RegExp(r'[,，、]'))
          .map((tag) => tag.trim())
          .where((tag) => tag.isNotEmpty)
          .toSet()
          .toList(growable: false);
      final edited = widget.row.transaction.withChanges({
        'amount_cents': cents,
        'direction': _direction,
        'merchant': _merchant.text.trim(),
        'description': _description.text.trim(),
        'occurred_at': _dateChanged ? DateTime.utc(_date.year, _date.month, _date.day, _date.hour, _date.minute).subtract(const Duration(hours: 8)).toIso8601String() : widget.row.transaction.occurredAt.toIso8601String(),
        'category': category.isEmpty ? null : category,
        'tags': tags,
        'note': _note.text.trim(),
        'excluded': _excluded,
        'refund_of_id': _refundOfId,
      });
      if (tags.length > 50) throw const FormatException('标签最多 50 个。');
      if (widget.isNew) {
        await widget.controller.addTransaction(edited);
      } else {
        await widget.controller.queueEdit(edited, original: widget.row.transaction);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error is FormatException ? error.message :
            error is StateError ? error.message : '保存失败，请检查本机空间和账本连接后重试。')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resolve() async {
    final remote = await widget.controller.serverVersion(
      widget.row.transaction.id,
    );
    if (!mounted || remote == null) return;
    final local = widget.row.transaction;
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解决同步冲突'),
        content: SingleChildScrollView(
          child: Text(
            '本机：${local.category ?? '未分类'} / ${local.tags.join('、')} / ${local.note}\n\n'
            '服务器：${remote.category ?? '未分类'} / ${remote.tags.join('、')} / ${remote.note}\n\n'
            '选择“保留本机”会基于服务器新版本重新提交本机字段。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('稍后处理'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('采用服务器'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保留本机'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    await widget.controller.resolveConflict(local.id, keepMine: choice);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(context: context, initialDate: _date,
      firstDate: DateTime(1900), lastDate: DateTime(2100, 12, 31));
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_date));
    if (time != null && mounted) {
      setState(() {
        _dateChanged = true;
        _date = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      });
    }
  }

  Future<void> _pickRefund() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _RefundPicker(
        controller: widget.controller,
        rows: widget.controller.rows
            .where(
              (row) =>
                  row.transaction.direction == 'expense' &&
                  (row.transaction.kind == 'payment' ||
                      row.transaction.kind == 'other') &&
                  row.transaction.id != widget.row.transaction.id,
            )
            .toList(growable: false),
      ),
    );
    if (selected != null && mounted) {
      setState(() => _refundOfId = selected.isEmpty ? null : selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final transaction = widget.row.transaction;
    final colors = Theme.of(context).colorScheme;
    final isExpense = transaction.direction == 'expense';
    final suggestions = widget.controller.rows
        .map((row) => row.transaction.category)
        .whereType<String>()
        .where(
          (category) =>
              category.isNotEmpty &&
              category.toLowerCase().contains(
                _category.text.trim().toLowerCase(),
              ),
        )
        .toSet()
        .take(8)
        .toList(growable: false);
    final linked = widget.controller.rows
        .where((row) => row.transaction.id == _refundOfId)
        .map((row) => row.transaction)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(widget.isNew ? '记一笔' : '流水详情')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  onPressed: _saving || widget.row.hasConflict ? null : _save,
                  child: Text(_saving ? '保存中…' : widget.isNew ? '保存账单' : '保存修改'),
                ),
              ),
              const SizedBox(height: 8),
              Text(widget.controller.autoSync ? '修改会保存在本机，联网后自动同步' : '自动同步已关闭；保存后请手动同步',
                  style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11)),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
            SegmentedButton<String>(segments: const [
              ButtonSegment(value: 'expense', label: Text('支出')),
              ButtonSegment(value: 'income', label: Text('收入')),
            ], selected: {_direction}, onSelectionChanged: transaction.kind == 'refund' ? null :
                (value) => setState(() => _direction = value.single)),
            const SizedBox(height: 14),
            TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: '金额（元）', prefixIcon: Icon(Icons.payments_outlined))),
            const SizedBox(height: 14),
            TextField(controller: _merchant, maxLength: 500,
              decoration: const InputDecoration(labelText: '商户／收付款对象')),
            TextField(controller: _description, maxLength: 2000,
              decoration: const InputDecoration(labelText: '账单说明')),
            ListTile(contentPadding: EdgeInsets.zero, title: const Text('交易时间（北京时间）'),
              subtitle: Text(formatDate(_date)), trailing: const Icon(Icons.edit_calendar), onTap: _pickDate),
          ]))),
          if (!widget.isNew) ...[
          const Padding(padding: EdgeInsets.only(top: 16), child: Text('保存前的流水信息')),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 22),
            child: Column(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Icon(_transactionIcon(transaction), color: colors.primary, size: 27),
                ),
                const SizedBox(height: 14),
                Text(_merchantLabel(transaction),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('${isExpense ? '−' : '+'}${formatMoney(transaction.amountCents)}',
                    style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700,
                        letterSpacing: -1, color: colors.onSurface)),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _StatusLabel(text: _sourceLabel(transaction.source), color: colors.primary, background: colors.primaryContainer),
                    _StatusLabel(text: _kindLabel(transaction.kind), color: colors.onSurfaceVariant, background: colors.surfaceContainerHighest),
                  ],
                ),
              ],
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _DetailLine(label: '交易时间', value: formatDate(transaction.ledgerDateTime)),
                  if (transaction.description.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _DetailLine(label: '账单说明', value: transaction.description),
                  ],
                ],
              ),
            ),
          ),
          ],
          if (widget.row.hasConflict) ...[
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _resolve,
              icon: const Icon(Icons.warning_amber),
              label: const Text('先解决同步冲突'),
            ),
          ],
          const SizedBox(height: 24),
          const Text('整理这笔流水', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _category,
                    maxLength: 200,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: '分类',
                      hintText: '例如：餐饮、交通、日用品',
                      prefixIcon: Icon(Icons.category_outlined),
                    ),
                  ),
                  if (suggestions.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: suggestions.map((category) => ActionChip(
                        label: Text(category),
                        onPressed: () => setState(() => _category.text = category),
                      )).toList(),
                    ),
                  ],
                  const SizedBox(height: 18),
                  TextField(
                    controller: _tags,
                    decoration: const InputDecoration(
                      labelText: '标签',
                      hintText: '工作午餐，出差',
                      helperText: '用逗号分隔，便于以后查找',
                      prefixIcon: Icon(Icons.sell_outlined),
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _note,
                    maxLength: 4000,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: '备注',
                      hintText: '记录具体商品或用途…',
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                  title: const Text('不计入收支报表', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: const Text('流水仍然保留，可随时搜索', style: TextStyle(fontSize: 12)),
                  value: _excluded,
                  onChanged: (value) => setState(() => _excluded = value),
                ),
                if (transaction.kind == 'refund') ...[
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    title: const Text('关联原消费', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        linked == null
                            ? (_refundOfId == null ? '尚未关联，月报会列为待确认退款' : '已关联的消费暂不在本机')
                            : '${_merchantLabel(linked)} · ${formatMoney(linked.amountCents)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _pickRefund,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(width: 74, child: Text(label,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12))),
      Expanded(child: Text(value, textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 12))),
    ],
  );
}

class _RefundPicker extends StatefulWidget {
  const _RefundPicker({required this.controller, required this.rows});

  final LedgerController controller;
  final List<LedgerRow> rows;

  @override
  State<_RefundPicker> createState() => _RefundPickerState();
}

class _RefundPickerState extends State<_RefundPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows
        .where((row) {
          final transaction = row.transaction;
          return '${transaction.merchant} ${transaction.description} ${transaction.category ?? ''}'
              .toLowerCase()
              .contains(_query.toLowerCase());
        })
        .toList(growable: false);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: Column(
            children: [
              const Text('关联原消费',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text('退款将抵扣原消费所在月份的支出',
                  style: TextStyle(fontSize: 12)),
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '搜索原消费',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              ListTile(
                title: const Text('取消关联'),
                leading: const Icon(Icons.link_off),
                onTap: () => Navigator.pop(context, ''),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 16, top: 8),
                        child: Text(formatDate(rows[index].transaction.ledgerDateTime),
                            style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      ),
                      TransactionRowTile(
                        controller: widget.controller,
                        row: rows[index],
                        onTap: () => Navigator.pop(context, rows[index].transaction.id),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
