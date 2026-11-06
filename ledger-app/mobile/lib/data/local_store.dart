import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../model/ledger_transaction.dart';

class LocalStore {
  LocalStore._(this._db);

  final Database _db;
  static const _uuid = Uuid();

  static Future<LocalStore> open() async {
    final support = await getApplicationSupportDirectory();
    final ledgerDirectory = Directory(path.join(support.path, 'LedgerMobile'));
    await ledgerDirectory.create(recursive: true);
    final databasePath = path.join(ledgerDirectory.path, 'ledger_mobile.db');
    return openAt(databasePath);
  }

  static Future<LocalStore> openAt(String databasePath) async {
    final db = await openDatabase(
      databasePath,
      version: 1,
      onCreate: (database, _) async {
        await database.execute('''
          CREATE TABLE transactions (
            id TEXT PRIMARY KEY,
            json TEXT NOT NULL,
            version INTEGER NOT NULL,
            revision INTEGER NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE outbox (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            operation_id TEXT NOT NULL UNIQUE,
            transaction_id TEXT NOT NULL,
            expected_version INTEGER NOT NULL,
            changes_json TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'queued',
            created_at TEXT NOT NULL
          )
        ''');
        await database.execute(
          'CREATE INDEX outbox_transaction ON outbox(transaction_id, seq)',
        );
        await database.execute('''
          CREATE TABLE reports (
            month_key TEXT PRIMARY KEY,
            json TEXT NOT NULL,
            fetched_at TEXT NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    );
    return LocalStore._(db);
  }

  Future<String?> getMeta(String key) async {
    final rows = await _db.query(
      'metadata',
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setMeta(String key, String value) async {
    await _db.insert('metadata', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> get revision async =>
      int.tryParse(await getMeta('revision') ?? '') ?? 0;

  Future<String?> get ledgerId => getMeta('ledger_id');

  Future<bool> get hasLedgerData async {
    final result = await _db.rawQuery(
      'SELECT (SELECT COUNT(*) FROM transactions) + '
      '(SELECT COUNT(*) FROM outbox) + (SELECT COUNT(*) FROM reports) AS count',
    );
    return (result.single['count'] as num).toInt() > 0 || await revision > 0;
  }

  // Accepted edits can be newer than the last completed incremental sync.
  Future<int> get minimumServerRevision async {
    final result = await _db.rawQuery(
      'SELECT COALESCE(MAX(revision), 0) AS revision FROM transactions',
    );
    final transactionRevision = (result.single['revision'] as num).toInt();
    final syncRevision = await revision;
    return transactionRevision > syncRevision
        ? transactionRevision
        : syncRevision;
  }

  Future<List<LedgerRow>> listRows({String search = ''}) async {
    final (rawTransactions, rawEdits) = await _db.transaction((txn) async {
      final transactions = await txn.query('transactions');
      final edits = await txn.query('outbox', orderBy: 'seq ASC');
      return (transactions, edits);
    });
    final editsByTransaction = <String, List<Map<String, Object?>>>{};
    for (final edit in rawEdits) {
      (editsByTransaction[edit['transaction_id'] as String] ??= []).add(edit);
    }
    final needle = search.trim().toLowerCase();
    final rows = <LedgerRow>[];
    for (final raw in rawTransactions) {
      final row = _mergeRow(
        raw,
        editsByTransaction[raw['id'] as String] ?? const [],
      );
      final transaction = row.transaction;
      final searchable = [
        transaction.merchant,
        transaction.description,
        transaction.category ?? '',
        transaction.note,
        ...transaction.tags,
      ].join(' ').toLowerCase();
      if (needle.isNotEmpty && !searchable.contains(needle)) continue;
      rows.add(row);
    }
    rows.sort(
      (a, b) => b.transaction.occurredAt.compareTo(a.transaction.occurredAt),
    );
    return rows;
  }

  Future<LedgerRow?> getRow(String transactionId) async {
    // Read the base and its pending edits from the same database snapshot.
    return _db.transaction<LedgerRow?>((txn) async {
      final rows = await txn.query(
        'transactions',
        columns: ['json'],
        where: 'id = ?',
        whereArgs: [transactionId],
      );
      if (rows.isEmpty) return null;
      final edits = await txn.query(
        'outbox',
        columns: ['changes_json', 'status'],
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
        orderBy: 'seq ASC',
      );
      return _mergeRow(rows.single, edits);
    });
  }

  static LedgerRow _mergeRow(
    Map<String, Object?> raw,
    List<Map<String, Object?>> edits,
  ) {
    var transaction = LedgerTransaction.fromJson(
      jsonDecode(raw['json'] as String) as Map<String, dynamic>,
    );
    for (final edit in edits) {
      transaction = transaction.withChanges(
        jsonDecode(edit['changes_json'] as String) as Map<String, dynamic>,
      );
    }
    return LedgerRow(
      transaction,
      edits.length,
      edits.any((edit) => edit['status'] == 'conflict'),
    );
  }

  Future<LedgerTransaction?> getServerTransaction(String transactionId) async {
    final rows = await _db.query(
      'transactions',
      where: 'id = ?',
      whereArgs: [transactionId],
    );
    if (rows.isEmpty) return null;
    return LedgerTransaction.fromJson(
      jsonDecode(rows.first['json'] as String) as Map<String, dynamic>,
    );
  }

  Future<int> pendingCount() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS count FROM outbox');
    return (rows.first['count'] as num).toInt();
  }

  Future<List<PendingEdit>> pendingEdits() async {
    final rows = await _db.query('outbox', orderBy: 'seq ASC');
    return rows
        .map(
          (row) => PendingEdit(
            operationId: row['operation_id'] as String,
            transactionId: row['transaction_id'] as String,
            expectedVersion: (row['expected_version'] as num).toInt(),
            changes:
                jsonDecode(row['changes_json'] as String)
                    as Map<String, dynamic>,
            status: row['status'] as String,
          ),
        )
        .toList(growable: false);
  }

  Future<void> queueEdit(
    String transactionId,
    Map<String, dynamic> changes, {
    int? expectedBaseVersion,
  }) async {
    await _db.transaction((txn) async {
      final transactions = await txn.query(
        'transactions',
        columns: ['version'],
        where: 'id = ?',
        whereArgs: [transactionId],
      );
      if (transactions.isEmpty) throw StateError('本地没有这笔交易，请先同步。');
      if (expectedBaseVersion != null && (transactions.first['version'] as num).toInt() != expectedBaseVersion) {
        throw StateError('这笔流水在编辑期间已有更新，请返回重新打开并核对。表单中的修改尚未提交。');
      }
      final edits = await txn.query(
        'outbox',
        columns: ['status', 'expected_version'],
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
      );
      if (edits.any((edit) => edit['status'] == 'conflict')) {
        throw StateError('请先解决这笔交易的同步冲突。');
      }
      await txn.insert('outbox', {
        'operation_id': _uuid.v4(),
        'transaction_id': transactionId,
        'expected_version': edits.any((edit) => edit['expected_version'] == 0)
            ? edits.map((edit) => (edit['expected_version'] as num).toInt()).reduce((a, b) => a > b ? a : b) + 1
            : (transactions.first['version'] as num).toInt() + edits.length,
        'changes_json': jsonEncode(changes),
        'status': 'queued',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<void> queueCreate(LedgerTransaction transaction) async {
    await _db.transaction((txn) async {
      final metadata = await txn.query('metadata', where: 'key = ?', whereArgs: ['ledger_id']);
      if (metadata.isEmpty) throw StateError('请先连接账本一次，再使用离线记账。');
      await txn.insert('transactions', {
        'id': transaction.id, 'json': jsonEncode(transaction.toJson()), 'version': 0, 'revision': 0,
      });
      await txn.insert('outbox', {
        'operation_id': _uuid.v4(), 'transaction_id': transaction.id, 'expected_version': 0,
        'changes_json': jsonEncode({
          ...transaction.editableFields,
        }..remove('refund_of_id')),
        'status': 'queued', 'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<void> acceptEdit(
    String operationId,
    LedgerTransaction serverTransaction,
  ) async {
    await _db.transaction((txn) async {
      await _upsertTransaction(txn, serverTransaction);
      await txn.delete(
        'outbox',
        where: 'operation_id = ?',
        whereArgs: [operationId],
      );
    });
  }

  Future<void> markConflict(
    String operationId,
    LedgerTransaction current,
  ) async {
    await _db.transaction((txn) async {
      await _upsertTransaction(txn, current);
      await txn.update(
        'outbox',
        {'status': 'conflict'},
        where: 'operation_id = ?',
        whereArgs: [operationId],
      );
    });
  }

  Future<void> resolveConflict(
    String transactionId, {
    required bool keepMine,
  }) async {
    await _db.transaction((txn) async {
      final transactionRows = await txn.query(
        'transactions',
        where: 'id = ?',
        whereArgs: [transactionId],
      );
      if (transactionRows.isEmpty) throw StateError('无法找到服务器版本。');
      final server = LedgerTransaction.fromJson(
        jsonDecode(transactionRows.first['json'] as String)
            as Map<String, dynamic>,
      );
      final edits = await txn.query(
        'outbox',
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
        orderBy: 'seq ASC',
      );
      if (edits.isEmpty) return;
      final changes = <String, dynamic>{};
      for (final edit in edits) {
        changes.addAll(
          jsonDecode(edit['changes_json'] as String) as Map<String, dynamic>,
        );
      }
      await txn.delete(
        'outbox',
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
      );
      if (keepMine) {
        await txn.insert('outbox', {
          'operation_id': _uuid.v4(),
          'transaction_id': transactionId,
          'expected_version': server.version,
          'changes_json': jsonEncode(changes),
          'status': 'queued',
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
    });
  }

  Future<void> applySync(
    int serverRevision,
    List<LedgerTransaction> transactions, {
    required String ledgerId,
  }) async {
    await _db.transaction((txn) async {
      final metadata = await txn.query(
        'metadata',
        where: 'key IN (?, ?)',
        whereArgs: ['ledger_id', 'revision'],
      );
      final values = {for (final row in metadata) row['key']: row['value']};
      final storedId = values['ledger_id'] as String?;
      final storedRevision =
          int.tryParse(values['revision'] as String? ?? '') ?? 0;
      if (storedId != null && storedId != ledgerId) {
        throw StateError('服务器账本已改变，本地数据和待同步修改已保留。请在连接设置中确认账本。');
      }
      final maximum = await txn.rawQuery(
        'SELECT COALESCE(MAX(revision), 0) AS revision FROM transactions',
      );
      final observedRevision = (maximum.single['revision'] as num).toInt();
      if (serverRevision < storedRevision ||
          serverRevision < observedRevision) {
        throw StateError('服务器版本比本地旧，已暂停同步。请检查服务器是否恢复了旧备份。');
      }
      if (storedId == null) {
        final data = await txn.rawQuery(
          'SELECT (SELECT COUNT(*) FROM transactions) + '
          '(SELECT COUNT(*) FROM outbox) + (SELECT COUNT(*) FROM reports) AS count',
        );
        if (storedRevision > 0 || (data.single['count'] as num) > 0) {
          throw StateError('本地缓存缺少账本身份标识，已暂停同步。请在连接设置中重新确认账本。');
        }
      }
      for (final transaction in transactions) {
        await _upsertTransaction(txn, transaction);
      }
      await txn.insert('metadata', {
        'key': 'ledger_id',
        'value': ledgerId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('metadata', {
        'key': 'revision',
        'value': '$serverRevision',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> _upsertTransaction(
    DatabaseExecutor txn,
    LedgerTransaction transaction,
  ) async {
    final existing = await txn.query(
      'transactions',
      columns: ['version', 'revision'],
      where: 'id = ?',
      whereArgs: [transaction.id],
    );
    if (existing.isNotEmpty &&
        ((existing.single['version'] as num) > transaction.version ||
            (existing.single['revision'] as num) > transaction.revision)) {
      // Retried idempotent edits may return the response saved before the preflight.
      return;
    }
    await txn.insert('transactions', {
      'id': transaction.id,
      'json': jsonEncode(transaction.toJson()),
      'version': transaction.version,
      'revision': transaction.revision,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearLedger() async {
    await _db.transaction((txn) async {
      final pending = await txn.rawQuery(
        'SELECT COUNT(*) AS count FROM outbox',
      );
      if ((pending.single['count'] as num) > 0) {
        throw StateError('还有未同步的修改，无法清空本地账本。请先同步并解决冲突。');
      }
      await txn.delete('transactions');
      await txn.delete('reports');
      await txn.delete('metadata', where: 'key = ?', whereArgs: ['ledger_id']);
      await txn.insert('metadata', {
        'key': 'revision',
        'value': '0',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete('metadata', where: 'key = ?', whereArgs: ['rules_json']);
      await txn.delete(
        'metadata',
        where: 'key = ?',
        whereArgs: ['exclude_red_packets'],
      );
    });
  }

  static String monthKey(int year, int month) =>
      month == 0 ? 'year-$year' : '$year-${month.toString().padLeft(2, '0')}';

  // Month zero is an internal annual-cache key, never sent to the monthly API.
  Future<DateTime?> reportFetchedAt(int year, int month) async {
    final rows = await _db.query('reports', columns: ['fetched_at'],
      where: 'month_key = ?', whereArgs: [monthKey(year, month)]);
    return rows.isEmpty ? null : DateTime.tryParse(rows.first['fetched_at'] as String);
  }

  Future<Map<String, dynamic>?> loadReport(int year, int month) async {
    final rows = await _db.query(
      'reports',
      where: 'month_key = ?',
      whereArgs: [monthKey(year, month)],
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['json'] as String) as Map<String, dynamic>;
  }

  Future<void> saveReport(
    int year,
    int month,
    Map<String, dynamic> report,
  ) async {
    await _db.insert('reports', {
      'month_key': monthKey(year, month),
      'json': jsonEncode(report),
      'fetched_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> close() => _db.close();
}
