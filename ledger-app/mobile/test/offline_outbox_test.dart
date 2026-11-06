import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_mobile/data/local_store.dart';
import 'package:ledger_mobile/model/ledger_transaction.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test(
    'offline edits survive restart and conflict resolution rebases on server',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ledger_outbox_test_',
      );
      final databasePath = '${directory.path}/test.db';
      var store = await LocalStore.openAt(databasePath);
      try {
        final original = LedgerTransaction.fromJson({
          'id': '1457de4f-67a5-49aa-a7d4-18b2d81bbc4e',
          'source': 'wechat',
          'external_id': 'wx-1',
          'occurred_at': '2026-09-01T12:00:00+08:00',
          'amount_cents': 2500,
          'direction': 'expense',
          'kind': 'payment',
          'merchant': '午餐店',
          'description': '午餐',
          'category': null,
          'tags': <String>[],
          'note': '',
          'excluded': false,
          'exclusion_reason': null,
          'refund_of_id': null,
          'version': 1,
          'revision': 1,
        });
        await store.applySync(1, [original], ledgerId: 'ledger-one');
        await store.queueEdit(original.id, {'category': '餐饮'});
        await store.queueEdit(original.id, {'note': '工作午餐'});
        final initialOutbox = await store.pendingEdits();
        expect(initialOutbox.map((edit) => edit.expectedVersion), [1, 2]);

        await store.close();
        store = await LocalStore.openAt(databasePath);
        expect(await store.pendingCount(), 2);
        expect((await store.getRow(original.id))!.transaction.note, '工作午餐');
        expect(
          (await store.pendingEdits()).first.operationId,
          initialOutbox.first.operationId,
        );

        final remote = original.withChanges({
          'category': '交通',
          'version': 2,
          'revision': 2,
        });
        await store.markConflict(initialOutbox.first.operationId, remote);
        expect((await store.getRow(original.id))!.hasConflict, isTrue);
        await store.resolveConflict(original.id, keepMine: true);
        final rebased = await store.pendingEdits();
        expect(rebased, hasLength(1));
        expect(rebased.single.expectedVersion, 2);
        expect(
          rebased.single.operationId,
          isNot(initialOutbox.first.operationId),
        );
        expect(rebased.single.changes, {'category': '餐饮', 'note': '工作午餐'});
        expect((await store.getRow(original.id))!.transaction.category, '餐饮');
        expect((await store.getRow(original.id))!.transaction.note, '工作午餐');

        final accepted = remote.withChanges({
          'category': '餐饮',
          'note': '工作午餐',
          'version': 3,
          'revision': 3,
        });
        await store.acceptEdit(rebased.single.operationId, accepted);
        expect(await store.pendingCount(), 0);
        expect((await store.getRow(original.id))!.transaction.version, 3);
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
