class CategoryAmount {
  const CategoryAmount(this.name, this.cents);
  final String name;
  final int cents;
}

class CategorySlice {
  const CategorySlice(this.label, this.cents, this.categories);
  final String label;
  final int cents;
  final List<CategoryAmount> categories;
  bool get isGroup => categories.length > 1;
}

List<CategoryAmount> reportCategories(Map<String, dynamic>? report) {
  final rows = report?['category_totals'] as List<dynamic>? ?? const [];
  final totals = <String, int>{};
  for (final item in rows.whereType<Map>()) {
    final name = (item['category']?.toString().trim() ?? '');
    final cents = (item['amount_cents'] as num?)?.toInt() ?? 0;
    if (cents <= 0) continue;
    final key = name.isEmpty ? '未分类' : name;
    totals[key] = (totals[key] ?? 0) + cents;
  }
  return totals.entries.map((e) => CategoryAmount(e.key, e.value)).toList()
    ..sort((a, b) {
      final amount = b.cents.compareTo(a.cents);
      return amount != 0 ? amount : a.name.compareTo(b.name);
    });
}

/// Keep the small unclassified slice visible so it can be corrected.
List<CategorySlice> categorySlices(List<CategoryAmount> categories) {
  if (categories.length <= 6) {
    return categories.map((c) => CategorySlice(c.name, c.cents, [c])).toList();
  }
  final visible = categories.take(5).toList();
  final uncategorized = categories.where((c) => c.name == '未分类').firstOrNull;
  if (uncategorized != null && !visible.contains(uncategorized)) {
    visible[4] = uncategorized;
  }
  final rest = categories.where((c) => !visible.contains(c)).toList();
  return [
    ...visible.map((c) => CategorySlice(c.name, c.cents, [c])),
    CategorySlice('其余 ${rest.length} 类', rest.fold(0, (sum, c) => sum + c.cents), rest),
  ];
}

int reportCents(Map<String, dynamic>? report, String key) =>
    (report?[key] as num?)?.toInt() ?? 0;
