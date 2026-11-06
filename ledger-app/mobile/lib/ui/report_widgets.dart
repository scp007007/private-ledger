import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ledger_controller.dart';
import '../model/ledger_transaction.dart';
import '../model/report_breakdown.dart';
import 'motion.dart';

class MonthSelector extends StatelessWidget {
  const MonthSelector({super.key, required this.year, required this.month, required this.onChange});
  final int year;
  final int month;
  final ValueChanged<DateTime> onChange;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text('$year年$month月', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600))),
      IconButton(tooltip: '上个月', onPressed: year == 1 && month == 1 ? null : () => onChange(DateTime(year, month - 1)), icon: const Icon(Icons.chevron_left)),
      IconButton(tooltip: '下个月', onPressed: year == 9999 && month == 12 ? null : () => onChange(DateTime(year, month + 1)), icon: const Icon(Icons.chevron_right)),
    ],
  );
}

class ReportStatus extends StatelessWidget {
  const ReportStatus({super.key, required this.controller});
  final LedgerController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final pending = controller.pendingCount;
    final failed = controller.lastError != null;
    final details = <String>[
      if (pending > 0) '$pending 项修改待同步，已计入本机统计',
      if (failed) '账单同步未完成，本机统计仍可使用',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(controller.syncing ? Icons.sync_rounded : pending > 0 || failed ? Icons.cloud_off_outlined : Icons.cloud_done_outlined, size: 14, color: colors.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(child: Text([
            '按本机流水实时统计',
            if (controller.syncing) '正在同步账单',
          ].join(' · '), style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11, color: colors.onSurfaceVariant))),
        ]),
        if (details.isNotEmpty) ...[
          const SizedBox(height: 7),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(color: colors.primaryContainer.withValues(alpha: .55), borderRadius: BorderRadius.circular(12)),
            child: Text(details.join('\n'), style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11, height: 1.5, color: colors.onSurfaceVariant)),
          ),
        ],
      ]),
    );
  }
}

class ConsumptionSummary extends StatelessWidget {
  const ConsumptionSummary({super.key, required this.report, this.yearly = false});
  final Map<String, dynamic> report;
  final bool yearly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expense = reportCents(report, 'total_actual_consumption_cents');
    final income = reportCents(report, 'total_income_cents');
    return Card(color: const Color(0xFF29466F), child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(yearly ? '全年实际消费' : '本月实际消费', style: theme.textTheme.bodySmall?.copyWith(fontSize: 12, color: Colors.white.withValues(alpha: .82), letterSpacing: .3)),
        const SizedBox(height: 6),
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(formatMoney(expense), style: theme.textTheme.headlineLarge?.copyWith(fontSize: 38, height: 1.25, color: Colors.white, fontWeight: FontWeight.w600, letterSpacing: -1.1, fontFeatures: const [FontFeature.tabularFigures()]))),
        const SizedBox(height: 17),
        Divider(height: 1, color: Colors.white.withValues(alpha: .18)),
        const SizedBox(height: 13),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _SummaryAmount(label: '收入', cents: income)),
          const SizedBox(width: 12),
          Expanded(child: _SummaryAmount(label: '收支差额', cents: income - expense)),
        ]),
      ]),
    ));
  }
}

class _SummaryAmount extends StatelessWidget {
  const _SummaryAmount({required this.label, required this.cents});
  final String label;
  final int cents;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11, color: Colors.white.withValues(alpha: .76))),
    const SizedBox(height: 4),
    FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(formatMoney(cents), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.white, fontFeatures: const [FontFeature.tabularFigures()]))),
  ]);
}

class ExpenseBreakdown extends StatelessWidget {
  const ExpenseBreakdown({super.key, required this.report, required this.onCategory});
  final Map<String, dynamic> report;
  final ValueChanged<String> onCategory;

  static const _colors = [Color(0xFF527FB4), Color(0xFFD5A25B), Color(0xFF649995), Color(0xFFAE87A1), Color(0xFF8B97B5), Color(0xFF9BAAA3)];

  Future<void> _select(BuildContext context, CategorySlice slice) async {
    if (!slice.isGroup) {
      onCategory(slice.categories.single.name);
      return;
    }
    final name = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(child: ListView(shrinkWrap: true, children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 12), child: Text(slice.label, style: Theme.of(context).textTheme.titleLarge)),
        for (final category in slice.categories)
          ListTile(title: Text(category.name), trailing: Text(formatMoney(category.cents)), onTap: () => Navigator.pop(context, category.name)),
      ])),
    );
    if (name != null) onCategory(name);
  }

  @override
  Widget build(BuildContext context) {
    final categories = reportCategories(report);
    final slices = categorySlices(categories);
    final total = slices.fold(0, (sum, c) => sum + c.cents);
    final theme = Theme.of(context);
    return Card(child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text('钱都花在哪了', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))), Text('消费占比', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))]),
        const SizedBox(height: 10),
        if (total == 0)
          Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Center(child: Column(children: [Icon(Icons.donut_large, size: 48, color: theme.colorScheme.outlineVariant), const SizedBox(height: 12), const Text('这个期间还没有计入统计的消费')]))),
        if (total > 0) LayoutBuilder(builder: (context, constraints) {
          final stacked = constraints.maxWidth < 240 || MediaQuery.textScalerOf(context).scale(14) > 19;
          final diameter = stacked ? 154.0 : (constraints.maxWidth * .46).clamp(116.0, 164.0).toDouble();
          final center = diameter / 2;
          final chart = SizedBox(width: diameter, height: diameter, child: Semantics(
            label: '消费占比。${slices.map((s) => '${s.label} ${(100 * s.cents / total).toStringAsFixed(1)}%').join('，')}。可点击分类查看流水。',
            child: GestureDetector(
              onTapUp: (detail) {
                final point = detail.localPosition - Offset(center, center);
                if (point.distance < center - 30 || point.distance > center) return;
                final angle = (math.atan2(point.dy, point.dx) + math.pi / 2) % (2 * math.pi);
                var cumulative = 0.0;
                for (final slice in slices) {
                  cumulative += slice.cents / total * 2 * math.pi;
                  if (angle <= cumulative) { _select(context, slice); break; }
                }
              },
              child: Stack(alignment: Alignment.center, children: [
                Positioned.fill(child: RepaintBoundary(child: TweenAnimationBuilder<double>(
                  key: ValueKey('${report['year']}-${report['month']}-${slices.map((s) => '${s.label}:${s.cents}').join('|')}'),
                  tween: Tween(begin: 0, end: 1),
                  duration: ledgerMotionDuration(context, milliseconds: 620),
                  curve: Curves.easeOutCubic,
                  builder: (context, progress, _) => CustomPaint(painter: _DonutPainter(slices, _colors, progress: progress)),
                ))),
                Padding(padding: EdgeInsets.all(diameter * .21), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Flexible(child: Text(categories.first.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
                  const SizedBox(height: 4),
                  Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text('${(categories.first.cents / total * 100).toStringAsFixed(1)}%', style: theme.textTheme.titleLarge?.copyWith(fontSize: 24, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])))),
                ])),
              ]),
            ),
          ));
          final legend = Column(children: [
            for (var i = 0; i < slices.length; i++)
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _select(context, slices[i]),
                child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 44), child: Padding(padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2), child: Row(children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: _colors[i], shape: BoxShape.circle)),
                  const SizedBox(width: 7),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(slices[i].label, style: theme.textTheme.bodySmall?.copyWith(fontSize: 12, fontWeight: FontWeight.w500)),
                    Text(formatMoney(slices[i].cents), style: theme.textTheme.bodySmall?.copyWith(fontSize: 11, color: theme.colorScheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
                  ])),
                  const SizedBox(width: 5),
                  Text('${(slices[i].cents / total * 100).toStringAsFixed(1)}%', style: theme.textTheme.bodySmall?.copyWith(fontSize: 11, color: theme.colorScheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
                ]))),
              ),
          ]);
          if (stacked) {
            return Column(children: [Center(child: chart), const SizedBox(height: 10), legend]);
          }
          return Row(children: [chart, const SizedBox(width: 12), Expanded(child: legend)]);
        }),
        const SizedBox(height: 8),
        const Divider(height: 1),
        Theme(data: theme.copyWith(dividerColor: Colors.transparent), child: ExpansionTile(
          dense: true,
          minTileHeight: 44,
          visualDensity: VisualDensity.standard,
          expansionAnimationStyle: AnimationStyle(duration: ledgerMotionDuration(context, milliseconds: 220), curve: Curves.easeOutCubic),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 6),
          title: const Text('按实际消费统计 · 查看口径', style: TextStyle(fontSize: 12)),
          children: const [Text('消费占比按已扣关联退款后的金额计算，退款冲减原消费月份。未关联退款等待确认；红包和转账默认排除，人工调整以当前设置为准。收支差额不是账户余额。', style: TextStyle(fontSize: 12))],
        )),
      ]),
    ));
  }
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter(this.slices, this.colors, {required this.progress});
  final List<CategorySlice> slices;
  final List<Color> colors;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold(0, (sum, c) => sum + c.cents);
    if (total <= 0) return;
    final rect = (Offset.zero & size).deflate(9);
    final radius = rect.shortestSide / 2;
    final paint = Paint()..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    var start = -math.pi / 2;
    var remaining = progress.clamp(0.0, 1.0) * math.pi * 2;
    for (var i = 0; i < slices.length; i++) {
      final sweep = 2 * math.pi * slices[i].cents / total;
      final visible = math.min(sweep, remaining);
      if (visible <= 0) break;
      // Rounded ends stay within each slice, including very small categories.
      final gap = slices.length == 1 ? 0.0 : math.min(.04, visible * .12);
      final stroke = math.min(14.0, visible * radius * .65);
      final capAngle = stroke / radius;
      paint.color = colors[i];
      paint.strokeWidth = stroke;
      if (slices.length == 1 && progress >= 1) {
        canvas.drawOval(rect, paint);
      } else {
        canvas.drawArc(rect, start + (gap + capAngle) / 2, math.max(.0001, visible - gap - capAngle), false, paint);
      }
      start += sweep;
      remaining -= sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) {
    if (oldDelegate.progress != progress || oldDelegate.slices.length != slices.length || oldDelegate.colors != colors) return true;
    for (var i = 0; i < slices.length; i++) {
      if (oldDelegate.slices[i].cents != slices[i].cents) return true;
    }
    return false;
  }
}

class RefundNotice extends StatelessWidget {
  const RefundNotice({super.key, required this.report});
  final Map<String, dynamic> report;
  @override
  Widget build(BuildContext context) {
    final count = reportCents(report, 'unlinked_refunds_count');
    final over = reportCents(report, 'over_refund_cents');
    if (count == 0 && over == 0) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(top: 12), child: Card(child: ListTile(
      leading: Icon(Icons.info_outline, color: Theme.of(context).colorScheme.primary),
      title: Text(count > 0 ? '$count 笔退款待关联' : '退款金额需要核对'),
      subtitle: Text([
        if (count > 0) '${formatMoney(reportCents(report, 'unlinked_refunds_cents'))} 暂未抵扣消费，请在退款流水中关联原消费。',
        if (over > 0) '关联退款超过原消费 ${formatMoney(over)}，超出部分未抵扣。',
      ].join('\n')),
    )));
  }
}
