import '../l10n/ledger_l10n.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../ledger_controller.dart';
import '../model/ledger_transaction.dart';
import '../model/report_breakdown.dart';
import 'motion.dart';
import 'overview_page.dart';
import 'report_widgets.dart';

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, required this.controller});
  final LedgerController controller;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  bool _busy = false;
  bool _yearly = false;
  void _changeMonth(DateTime date) {
    widget.controller.selectReportMonth(date.year, date.month);
  }

  Future<void> _export() async {
    final options = await showDialog<(bool, bool)>(context: context, builder: (context) => AlertDialog(
      title: Text(tr(context, "导出账单 CSV")),
      content: SingleChildScrollView(child: Text(tr(context, "选择月份或全年，以及完整或脱敏数据。脱敏版隐藏商家、描述、交易号、标签和备注，将分类改为别名，并更换记录标识。日期和金额仍保留，分享前请自行检查。此功能需要更新电脑端服务。\n\nCSV 按交易发生时间导出流水；跨月退款可能位于另一份文件，不能直接相加得到这里的实际消费。脱敏记录标识和分类别名仅在本次文件内有效，不能用于关联多次导出。"))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, "取消"))),
        TextButton(onPressed: () => Navigator.pop(context, (false, false)), child: Text(tr(context, "本月完整"))),
        TextButton(onPressed: () => Navigator.pop(context, (false, true)), child: Text(tr(context, "本年完整"))),
        TextButton(onPressed: () => Navigator.pop(context, (true, false)), child: Text(tr(context, "本月脱敏"))),
        FilledButton(onPressed: () => Navigator.pop(context, (true, true)), child: Text(tr(context, "本年脱敏"))),
      ],
    ));
    if (options == null || !mounted) return;
    final (redact, wholeYear) = options;
    setState(() => _busy = true);
    try {
      final year = widget.controller.reportYear;
      final month = widget.controller.reportMonth;
      final bytes = await widget.controller.exportCsv(year, wholeYear ? null : month, redact: redact);
      final saved = await FilePicker.saveFile(
        fileName: 'ledger_$year${wholeYear ? '' : '_${month.toString().padLeft(2, '0')}'}${redact ? '_redacted' : ''}.csv',
        bytes: bytes, mimeType: 'text/csv', type: FileType.custom, allowedExtensions: ['csv'],
      );
      if (mounted && saved != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, "CSV 已保存到所选位置。"))));
    } catch (error) {
      if (!mounted) return;
      final message = error is ApiException
          ? error.message
          : tr(context, "无法导出文件，请检查服务器连接、保存位置和文件访问权限后重试。");
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, "导出失败：{0}", [localizedProblem(context, message)]))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final controller = widget.controller;
    final report = _yearly ? controller.yearReport : controller.report;
    final theme = Theme.of(context);
    final categories = reportCategories(report);
    final total = reportCents(report, 'total_actual_consumption_cents');
    return RefreshIndicator(onRefresh: controller.syncNow, child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
      children: [
        SegmentedButton<bool>(showSelectedIcon: false, segments: [ButtonSegment(value: false, label: Text(tr(context, "月度"))), ButtonSegment(value: true, label: Text(tr(context, "年度")))], selected: {_yearly}, onSelectionChanged: (value) => setState(() => _yearly = value.single)),
        const SizedBox(height: 10),
        if (!_yearly) MonthSelector(year: controller.reportYear, month: controller.reportMonth, onChange: _changeMonth)
        else Row(children: [Expanded(child: Text(tr(context, "{0}年", [controller.reportYear]), style: theme.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600))), IconButton(tooltip: tr(context, "上一年"), onPressed: controller.reportYear <= 1 ? null : () => _changeMonth(DateTime(controller.reportYear - 1, controller.reportMonth)), icon: const Icon(Icons.chevron_left)), IconButton(tooltip: tr(context, "下一年"), onPressed: controller.reportYear >= 9999 ? null : () => _changeMonth(DateTime(controller.reportYear + 1, controller.reportMonth)), icon: const Icon(Icons.chevron_right))]),
        ReportStatus(controller: controller),
        if (report == null) Card(child: Padding(padding: EdgeInsets.all(24), child: Text(tr(context, "这个期间还没有本机流水。"))))
        else ...[
          ConsumptionSummary(report: report, yearly: _yearly),
          RefundNotice(report: report),
        ],
        const SizedBox(height: 16),
        if (controller.yearReport != null) MonthlyTrend(report: controller.yearReport!, selectedMonth: controller.reportMonth, onMonth: (month) { setState(() => _yearly = false); _changeMonth(DateTime(controller.reportYear, month)); }),
        if (report != null) ...[
          const SizedBox(height: 16),
          Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_yearly ? tr(context, "全年分类排行") : tr(context, "本月分类排行"), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            if (categories.isEmpty) Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text(tr(context, "暂无计入统计的消费"))),
            for (final category in categories) InkWell(onTap: () => openCategoryTransactions(context, controller, category.name, yearly: _yearly), borderRadius: BorderRadius.circular(12), child: Padding(padding: const EdgeInsets.symmetric(vertical: 11), child: Column(children: [
              Row(children: [Expanded(child: Text(reportCategoryLabel(context, category.name), style: theme.textTheme.bodyMedium)), const SizedBox(width: 8), Expanded(child: Text(formatMoney(category.cents), textAlign: TextAlign.end, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)))]),
              const SizedBox(height: 6),
              Row(children: [Expanded(child: TweenAnimationBuilder<double>(
                key: ValueKey('rank-${controller.reportYear}-${_yearly ? 'year' : controller.reportMonth}-${category.name}'),
                tween: Tween(begin: 0, end: total <= 0 ? 0 : (category.cents / total).clamp(0, 1).toDouble()),
                duration: ledgerMotionDuration(context, milliseconds: 460),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => LinearProgressIndicator(value: value, minHeight: 5, borderRadius: BorderRadius.circular(5), backgroundColor: theme.scaffoldBackgroundColor),
              )), const SizedBox(width: 12), Text('${(total <= 0 ? 0 : category.cents / total * 100).toStringAsFixed(1)}%', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))]),
            ]))),
          ]))),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(onPressed: controller.configured && !controller.syncing ? controller.syncNow : null, icon: const Icon(Icons.sync), label: Text(controller.syncing ? tr(context, "正在同步账单…") : tr(context, "同步账单"))),
        const SizedBox(height: 10),
        OutlinedButton.icon(onPressed: _busy ? null : _export, icon: const Icon(Icons.file_download_outlined), label: Text(tr(context, "导出月度或年度 CSV"))),
        const SizedBox(height: 12),
        Text(tr(context, "退款抵扣原消费月份。流水保存后立即更新统计。"), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    ));
  });
}

class MonthlyTrend extends StatefulWidget {
  const MonthlyTrend({super.key, required this.report, required this.selectedMonth, required this.onMonth});
  final Map<String, dynamic> report;
  final int selectedMonth;
  final ValueChanged<int> onMonth;
  @override
  State<MonthlyTrend> createState() => _MonthlyTrendState();
}

class _MonthlyTrendState extends State<MonthlyTrend> {
  late bool _secondHalf = widget.selectedMonth > 6;
  @override
  void didUpdateWidget(MonthlyTrend oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedMonth != widget.selectedMonth) _secondHalf = widget.selectedMonth > 6;
  }
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final months = ((widget.report['months'] as List<dynamic>?) ?? const []).whereType<Map<String, dynamic>>().toList();
    final selected = months.where((m) => m['month'] == widget.selectedMonth).firstOrNull;
    final shown = months.where((m) => _secondHalf ? (m['month'] as int) > 6 : (m['month'] as int) <= 6).toList();
    final max = shown.fold<int>(0, (largest, m) { final amount = reportCents(m, 'total_actual_consumption_cents'); return amount > largest ? amount : largest; });
    return Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, children: [Text(tr(context, "月消费走势"), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)), DropdownButton<bool>(value: _secondHalf, underline: const SizedBox.shrink(), items: [DropdownMenuItem(value: false, child: Text(tr(context, "上半年"))), DropdownMenuItem(value: true, child: Text(tr(context, "下半年")))], onChanged: (v) => setState(() => _secondHalf = v!))]),
      Text(tr(context, "{0}年 · {1}月 {2}", [widget.report['year'], widget.selectedMonth, formatMoney(reportCents(selected, 'total_actual_consumption_cents'))]), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 16),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final month in shown) Expanded(child: _TrendColumn(
          key: ValueKey('trend-${widget.report['year']}-${month['month']}'),
          month: month['month'] as int,
          cents: reportCents(month, 'total_actual_consumption_cents'),
          maximum: max,
          selected: month['month'] == widget.selectedMonth,
          onTap: () => widget.onMonth(month['month'] as int),
        )),
      ]),
    ])));
  }
}

class _TrendColumn extends StatelessWidget {
  const _TrendColumn({super.key, required this.month, required this.cents, required this.maximum, required this.selected, required this.onTap});
  final int month;
  final int cents;
  final int maximum;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = maximum <= 0 ? 0.0 : (cents / maximum * 116).clamp(0.0, 116.0).toDouble();
    return Semantics(
      button: true,
      selected: selected,
      label: tr(context, "{0}月实际消费 {1}，查看月报", [month, formatMoney(cents)]),
      child: Tooltip(
        message: formatMoney(cents),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Column(children: [
              SizedBox(height: 120, child: Align(
                alignment: Alignment.bottomCenter,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: height),
                  duration: ledgerMotionDuration(context, milliseconds: 500),
                  curve: Curves.easeOutCubic,
                  builder: (context, animatedHeight, child) => SizedBox(height: animatedHeight, width: 26, child: child),
                  child: AnimatedContainer(
                    duration: ledgerMotionDuration(context, milliseconds: 240),
                    decoration: BoxDecoration(
                      color: selected ? theme.colorScheme.primary : theme.colorScheme.primaryContainer,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
                    ),
                  ),
                ),
              )),
              const SizedBox(height: 8),
              AnimatedContainer(
                duration: ledgerMotionDuration(context, milliseconds: 240),
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
                decoration: BoxDecoration(color: selected ? theme.colorScheme.primaryContainer.withValues(alpha: .6) : Colors.transparent, borderRadius: BorderRadius.circular(8)),
                child: Text(tr(context, "{0}月", [month]), textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
