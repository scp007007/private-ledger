class LedgerTransaction {
  const LedgerTransaction({
    required this.id,
    required this.source,
    required this.occurredAt,
    required this.amountCents,
    required this.direction,
    required this.kind,
    required this.merchant,
    required this.description,
    required this.category,
    required this.tags,
    required this.note,
    required this.excluded,
    required this.exclusionReason,
    required this.refundOfId,
    required this.version,
    required this.revision,
    this.externalId,
  });

  final String id;
  final String source;
  final String? externalId;
  final DateTime occurredAt;
  final int amountCents;
  final String direction;
  final String kind;
  final String merchant;
  final String description;
  final String? category;
  final List<String> tags;
  final String note;
  final bool excluded;
  final String? exclusionReason;
  final String? refundOfId;
  final int version;
  final int revision;

  // The importer and server assign accounting months in UTC+08:00.
  // A phone's travel timezone must not move a transaction to another month.
  DateTime get ledgerDateTime {
    final wall = occurredAt.isUtc ? occurredAt.add(const Duration(hours: 8)) : occurredAt;
    return DateTime(wall.year, wall.month, wall.day, wall.hour, wall.minute, wall.second);
  }

  factory LedgerTransaction.fromJson(Map<String, dynamic> data) {
    return LedgerTransaction(
      id: data['id'] as String,
      source: (data['source'] ?? 'manual') as String,
      externalId: data['external_id'] as String?,
      occurredAt: DateTime.parse(data['occurred_at'] as String),
      amountCents: (data['amount_cents'] as num).toInt(),
      direction: (data['direction'] ?? 'expense') as String,
      kind: (data['kind'] ?? 'other') as String,
      merchant: (data['merchant'] ?? '') as String,
      description: (data['description'] ?? '') as String,
      category: data['category'] as String?,
      tags: ((data['tags'] as List<dynamic>?) ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      note: (data['note'] ?? '') as String,
      excluded: data['excluded'] == true,
      exclusionReason: data['exclusion_reason'] as String?,
      refundOfId: data['refund_of_id'] as String?,
      version: (data['version'] as num?)?.toInt() ?? 1,
      revision: (data['revision'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'external_id': externalId,
    'occurred_at': occurredAt.toIso8601String(),
    'amount_cents': amountCents,
    'direction': direction,
    'kind': kind,
    'merchant': merchant,
    'description': description,
    'category': category,
    'tags': tags,
    'note': note,
    'excluded': excluded,
    'exclusion_reason': exclusionReason,
    'refund_of_id': refundOfId,
    'version': version,
    'revision': revision,
  };

  Map<String, dynamic> get editableFields => {
    'amount_cents': amountCents,
    'direction': direction,
    'merchant': merchant,
    'description': description,
    'occurred_at': occurredAt.toIso8601String(),
    'category': category,
    'tags': tags,
    'note': note,
    'excluded': excluded,
    'refund_of_id': refundOfId,
  };

  LedgerTransaction withChanges(Map<String, dynamic> changes) {
    return LedgerTransaction.fromJson({...toJson(), ...changes});
  }
}

class LedgerRow {
  const LedgerRow(this.transaction, this.pendingCount, this.hasConflict);

  final LedgerTransaction transaction;
  final int pendingCount;
  final bool hasConflict;
}

class PendingEdit {
  const PendingEdit({
    required this.operationId,
    required this.transactionId,
    required this.expectedVersion,
    required this.changes,
    required this.status,
  });

  final String operationId;
  final String transactionId;
  final int expectedVersion;
  final Map<String, dynamic> changes;
  final String status;
}

String formatMoney(int cents) {
  final sign = cents < 0 ? '-' : '';
  final absolute = cents.abs();
  return '$sign¥${absolute ~/ 100}.${(absolute % 100).toString().padLeft(2, '0')}';
}

String formatDate(DateTime date) {
  final local = date.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}
