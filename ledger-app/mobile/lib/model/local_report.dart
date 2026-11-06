import 'dart:math' as math;

import 'ledger_transaction.dart';

/// Uses the same accounting rules as the desktop report. Rows include edits
/// saved on this device, and refunds can refer to purchases in other years.
Map<String, dynamic> buildLocalYearReport(List<LedgerRow> rows, int year) {
  final months = List.generate(12, (_) => _ReportTotals());
  final purchases = <String, LedgerTransaction>{};
  final knownIds = <String>{for (final row in rows) row.transaction.id};
  final refunds = <String, int>{};

  for (final row in rows) {
    final entry = row.transaction;
    if (entry.excluded) continue;
    final date = entry.ledgerDateTime;
    final inYear = date.year == year;
    if (entry.kind == 'refund' && entry.direction == 'income') {
      final original = entry.refundOfId;
      if (original != null && knownIds.contains(original)) {
        refunds.update(original, (cents) => cents + entry.amountCents,
            ifAbsent: () => entry.amountCents);
      } else if (inYear) {
        months[date.month - 1]
          ..unlinkedRefunds += entry.amountCents
          ..unlinkedCount += 1;
      }
    } else if (inYear) {
      final month = months[date.month - 1];
      if (entry.direction == 'expense') {
        purchases[entry.id] = entry;
        month.gross += entry.amountCents;
        month.addCategory(entry.category, entry.amountCents);
      } else {
        month.income += entry.amountCents;
      }
    }
  }

  for (final refund in refunds.entries) {
    final purchase = purchases[refund.key];
    if (purchase == null) continue;
    final month = months[purchase.ledgerDateTime.month - 1];
    final applied = math.min(refund.value, purchase.amountCents);
    month.appliedRefunds += applied;
    month.overRefunds += refund.value - applied;
    month.addCategory(purchase.category, -applied);
  }

  final annual = _ReportTotals();
  for (final month in months) {
    annual
      ..gross += month.gross
      ..income += month.income
      ..appliedRefunds += month.appliedRefunds
      ..overRefunds += month.overRefunds
      ..unlinkedRefunds += month.unlinkedRefunds
      ..unlinkedCount += month.unlinkedCount;
    for (final category in month.categories.entries) {
      annual.addCategory(category.key, category.value);
    }
  }
  return {
    'year': year,
    ...annual.toMap(),
    'months': [
      for (var i = 0; i < months.length; i++)
        {'year': year, 'month': i + 1, ...months[i].toMap()},
    ],
  };
}

class _ReportTotals {
  int gross = 0;
  int income = 0;
  int appliedRefunds = 0;
  int overRefunds = 0;
  int unlinkedRefunds = 0;
  int unlinkedCount = 0;
  final categories = <String, int>{};

  void addCategory(String? category, int cents) {
    final name = category?.trim();
    final key = name == null || name.isEmpty ? '未分类' : name;
    categories.update(key, (total) => total + cents, ifAbsent: () => cents);
  }

  Map<String, dynamic> toMap() => {
    'total_actual_consumption_cents': gross - appliedRefunds,
    'gross_consumption_cents': gross,
    'total_income_cents': income,
    'applied_refunds_cents': appliedRefunds,
    'over_refund_cents': overRefunds,
    'unlinked_refunds_cents': unlinkedRefunds,
    'unlinked_refunds_count': unlinkedCount,
    'category_totals': [
      for (final category in categories.entries)
        {'category': category.key, 'amount_cents': category.value},
    ],
  };
}
