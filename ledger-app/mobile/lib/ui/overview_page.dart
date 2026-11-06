import '../l10n/ledger_l10n.dart';
import 'package:flutter/material.dart';

import '../ledger_controller.dart';
import '../model/ledger_transaction.dart';
import 'report_widgets.dart';
import 'transactions_page.dart';

class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key, required this.controller, required this.onImport, required this.onTransactions});
  final LedgerController controller;
  final VoidCallback onImport;
  final VoidCallback onTransactions;

  Widget _recent(BuildContext context, List<LedgerRow> recent) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(tr(context, "最近流水"), style: theme.textTheme.titleMedium)),
        TextButton(onPressed: onTransactions, child: Text(tr(context, "查看全部 ›"))),
      ]),
      if (recent.isEmpty) Card(child: Padding(padding: const EdgeInsets.all(20),
        child: Text(tr(context, "这个月还没有流水"), style: theme.textTheme.bodySmall))),
      if (recent.isNotEmpty) Card(child: Column(children: [
        for (var i = 0; i < recent.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 62, endIndent: 16),
          TransactionRowTile(controller: controller, row: recent[i]),
        ],
      ])),
    ]);
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Card(child: Padding(padding: const EdgeInsets.all(26), child: Column(children: [
      Container(width: 68, height: 68,
        decoration: BoxDecoration(color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(23)),
        child: Icon(Icons.account_balance_wallet_outlined,
          size: 32, color: theme.colorScheme.primary)),
      const SizedBox(height: 20),
      Text(tr(context, "从第一份账单开始"),
        textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
      const SizedBox(height: 10),
      Text(tr(context, "导入支付宝或微信账单\n看看每一笔钱花在哪里"),
        textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 22),
      SizedBox(width: double.infinity, child: FilledButton.icon(
        onPressed: onImport,
        icon: const Icon(Icons.file_upload_outlined),
        label: Text(tr(context, "导入账单")))),
    ])));
  }

  @override
  Widget build(BuildContext context) {
    final report = controller.report;
    final recent = controller.rows.where((row) {
      final date = row.transaction.ledgerDateTime;
      return date.year == controller.reportYear && date.month == controller.reportMonth;
    }).take(3).toList(growable: false);
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 720;
      final summary = report == null || controller.rows.isEmpty ? _empty(context) : Column(children: [
        ConsumptionSummary(report: report), RefundNotice(report: report),
      ]);
      final breakdown = report == null || controller.rows.isEmpty ? null : ExpenseBreakdown(
        report: report, onCategory: (category) => openCategoryTransactions(context, controller, category));
      return RefreshIndicator(
        onRefresh: controller.syncNow,
        child: ListView(
          key: const PageStorageKey('overview-scroll'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            MonthSelector(year: controller.reportYear, month: controller.reportMonth,
              onChange: (month) => controller.selectReportMonth(month.year, month.month)),
            ReportStatus(controller: controller),
            if (wide && breakdown != null)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(children: [summary, const SizedBox(height: 14), _recent(context, recent)])),
                const SizedBox(width: 20),
                Expanded(child: breakdown),
              ])
            else ...[
              summary,
              if (breakdown != null) ...[const SizedBox(height: 14), breakdown],
              const SizedBox(height: 10),
              _recent(context, recent),
            ],
          ],
        ),
      );
    });
  }
}

void openCategoryTransactions(BuildContext context, LedgerController controller, String category, {bool yearly = false}) {
  final year = controller.reportYear;
  final month = controller.reportMonth;
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (context) => Scaffold(
    appBar: AppBar(title: Text(isEnglish(context)
      ? '${reportCategoryLabel(context, category)} · $year${yearly ? '' : '/$month'}'
      : '$category · $year年${yearly ? '' : '$month月'}')),
    body: SafeArea(child: Center(child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: TransactionsPage(controller: controller, category: category,
        month: yearly ? null : DateTime(year, month), year: yearly ? year : null),
    ))),
  )));
}
