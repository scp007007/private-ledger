import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ledger_mobile/data/api_client.dart';
import 'package:ledger_mobile/data/local_store.dart';
import 'package:ledger_mobile/ledger_controller.dart';
import 'package:ledger_mobile/model/ledger_transaction.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

LedgerTransaction transaction({
  int version = 1,
  int revision = 1,
  String note = '',
}) => LedgerTransaction.fromJson({
  'id': '1457de4f-67a5-49aa-a7d4-18b2d81bbc4e',
  'source': 'wechat',
  'external_id': 'wx-1',
  'occurred_at': '2026-09-01T12:00:00+08:00',
  'amount_cents': 2500,
  'direction': 'expense',
  'kind': 'payment',
  'merchant': 'Lunch shop',
  'description': 'Lunch',
  'note': note,
  'version': version,
  'revision': revision,
});

http.Response jsonResponse(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response syncResponse({
  String ledgerId = 'ledger-one',
  required int revision,
  List<LedgerTransaction> transactions = const [],
}) => jsonResponse({
  'ledger_id': ledgerId,
  'revision': revision,
  'transactions': transactions.map((item) => item.toJson()).toList(),
  'settings': {'exclude_red_packets': true},
  'rules': <Map<String, dynamic>>[],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory directory;
  late LocalStore store;
  LedgerController? controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ledger_sync_test_');
    store = await LocalStore.openAt('${directory.path}/test.db');
  });

  test('local reports reflect pending edits and cross-year refunds without report requests', () async {
    final purchase = transaction().withChanges({
      'occurred_at': '2025-12-31T23:50:00+08:00',
      'category': '餐饮',
    });
    final refund = transaction().withChanges({
      'id': 'refund',
      'occurred_at': '2026-01-01T00:05:00+08:00',
      'amount_cents': 600,
      'kind': 'refund',
      'direction': 'income',
      'refund_of_id': purchase.id,
    });
    final draft = transaction().withChanges({
      'id': 'draft',
      'source': 'manual',
      'occurred_at': '2025-12-31T20:00:00+08:00',
      'amount_cents': 1200,
      'category': '交通',
      'version': 0,
      'revision': 0,
    });
    var offline = false;
    final requests = <String>[];
    controller = LedgerController.forTesting(
      store: store,
      api: ApiClient(
        'http://127.0.0.1:8000',
        'synthetic-test-token',
        client: MockClient((request) async {
          requests.add(request.url.path);
          if (offline) throw const SocketException('Offline');
          return syncResponse(revision: 1, transactions: [purchase, refund]);
        }),
      ),
    );
    final ledger = controller!;
    await ledger.setAutoSync(false);
    await ledger.syncNow();
    expect(requests, ['/api/v1/sync', '/api/v1/sync']);
    expect(ledger.lastError, isNull);
    offline = true;
    requests.clear();
    ledger.selectReportMonth(2025, 12);
    expect(ledger.report!['total_actual_consumption_cents'], 1900);

    await ledger.addTransaction(draft);
    await ledger.queueEdit(purchase.withChanges({
      'amount_cents': 2000,
      'category': '生活',
    }));
    expect(ledger.pendingCount, 2);
    expect(ledger.report!['total_actual_consumption_cents'], 2600);
    expect(ledger.report!['category_totals'], unorderedEquals([
      {'category': '生活', 'amount_cents': 1400},
      {'category': '交通', 'amount_cents': 1200},
    ]));
    expect(ledger.yearReport!['total_actual_consumption_cents'], 2600);
    ledger.selectReportMonth(2026, 1);
    expect(ledger.report!['total_income_cents'], 0);
    expect(ledger.report!['unlinked_refunds_count'], 0);
    expect(requests, isEmpty);

    await ledger.syncNow();
    expect(ledger.lastError, isNotNull);
    ledger.selectReportMonth(2025, 12);
    expect(ledger.report!['total_actual_consumption_cents'], 2600);
    expect(ledger.pendingCount, 2);
  });

  test('offline manual creation survives reopening, retries and edits once', () async {
    await store.applySync(0, [], ledgerId: 'ledger-one');
    final draft = transaction().withChanges({'source':'manual','version':0,'revision':0});
    await store.queueCreate(draft);
    await store.queueEdit(draft.id, {'amount_cents':3200});
    final queued = await store.pendingEdits();
    expect(queued.map((e) => e.expectedVersion), [0,1]);
    await store.close();
    store = await LocalStore.openAt('${directory.path}/test.db');
    expect((await store.getRow(draft.id))!.transaction.amountCents, 3200);
    var revision = 0;
    LedgerTransaction? remote;
    var createCalls = 0;
    var dropResponse = true;
    controller = LedgerController.forTesting(store: store, api: ApiClient('http://127.0.0.1:8000','synthetic-test-token',client:MockClient((request) async {
      if (request.url.path == '/api/v1/sync') return syncResponse(revision:revision,transactions:remote == null ? [] : [remote!]);
      if (request.url.path == '/api/v1/transactions') {
        createCalls++;
        final body=jsonDecode(request.body) as Map<String,dynamic>;
        remote ??= draft.withChanges({...body,'id':body['transaction_id'],'version':1,'revision':1});
        revision=1;
        if (dropResponse) { dropResponse=false; throw const SocketException('Synthetic lost response'); }
        return jsonResponse({'transaction':remote!.toJson()});
      }
      if (request.url.path == '/api/v1/edits') {
        final body=jsonDecode(request.body) as Map<String,dynamic>;
        expect(body['expected_version'],1);
        remote=remote!.withChanges({...body['changes'] as Map<String,dynamic>,'version':2,'revision':2});
        revision=2;
        return jsonResponse({'transaction':remote!.toJson()});
      }
      return jsonResponse({'year':2026,'month':10});
    })));
    await controller!.syncNow();
    expect(await store.pendingCount(),2);
    await controller!.syncNow();
    expect(createCalls,2);
    expect(await store.pendingCount(),0);
    expect((await store.listRows()).length,1);
    expect((await store.getRow(draft.id))!.transaction.amountCents,3200);
  });

  test('manual drafts require a known book and auto sync setting persists', () async {
    final draft = transaction().withChanges({'source':'manual','version':0,'revision':0});
    await expectLater(store.queueCreate(draft),throwsStateError);
    expect(await store.pendingCount(),0);
    controller=LedgerController.forTesting(store:store);
    await controller!.setAutoSync(false);
    expect(controller!.autoSync,isFalse);
    expect(await store.getMeta('auto_sync'),'false');
  });

  tearDown(() async {
    controller?.dispose();
    controller = null;
    await store.close();
    await directory.delete(recursive: true);
  });

  test('single-row reads isolate and order pending edits and conflicts', () async {
    final original = transaction();
    final other = original.withChanges({
      'id': 'other-transaction',
      'merchant': 'Other shop',
      'note': 'Other server note',
    });
    await store.applySync(1, [original, other], ledgerId: 'ledger-one');
    await store.queueEdit(original.id, {'note': 'First note', 'category': 'Meals'});
    await store.queueEdit(other.id, {'note': 'Other pending note'});
    await store.queueEdit(original.id, {'note': 'Latest note', 'tags': ['Work']});
    final edits = await store.pendingEdits();
    await store.markConflict(
      edits.first.operationId,
      original.withChanges({'version': 2, 'revision': 2, 'note': 'Remote note'}),
    );

    final row = (await store.getRow(original.id))!;
    expect(row.transaction.note, 'Latest note');
    expect(row.transaction.category, 'Meals');
    expect(row.transaction.tags, ['Work']);
    expect(row.transaction.version, 2);
    expect(row.pendingCount, 2);
    expect(row.hasConflict, isTrue);

    final otherRow = (await store.getRow(other.id))!;
    expect(otherRow.transaction.note, 'Other pending note');
    expect(otherRow.transaction.category, isNull);
    expect(otherRow.pendingCount, 1);
    expect(otherRow.hasConflict, isFalse);
    expect(await store.getRow('missing-transaction'), isNull);

    final listed = (await store.listRows())
        .singleWhere((item) => item.transaction.id == original.id);
    expect(row.transaction.toJson(), listed.transaction.toJson());
    expect(row.pendingCount, listed.pendingCount);
    expect(row.hasConflict, listed.hasConflict);
    expect(await store.pendingCount(), 3);
  });

  for (final scenario in [
    (name: 'different ledger', ledgerId: 'ledger-two', revision: 4),
    (name: 'rolled-back ledger', ledgerId: 'ledger-one', revision: 2),
  ]) {
    test(
      '${scenario.name} preflight never uploads or drops pending edits',
      () async {
        final original = transaction(version: 3, revision: 3);
        await store.applySync(3, [original], ledgerId: 'ledger-one');
        await store.queueEdit(original.id, {'note': 'Saved while offline'});
        final queued = (await store.pendingEdits()).single;
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          return syncResponse(
            ledgerId: scenario.ledgerId,
            revision: scenario.revision,
            transactions: [transaction(note: 'Unexpected server data')],
          );
        });
        controller = LedgerController.forTesting(
          store: store,
          api: ApiClient('http://127.0.0.1:8000', 'test-token', client: client),
        );

        await controller!.syncNow();

        expect(requests, hasLength(1));
        expect(requests.single.method, 'GET');
        expect(requests.single.url.path, '/api/v1/sync');
        expect(requests.single.url.queryParameters['since'], '3');
        expect(
          controller!.lastError,
          contains(scenario.ledgerId == 'ledger-two' ? '账本已改变' : '版本比本地旧'),
        );
        expect(controller!.syncing, isFalse);
        expect(await store.ledgerId, 'ledger-one');
        expect(await store.revision, 3);
        expect(
          (await store.pendingEdits()).single.operationId,
          queued.operationId,
        );
        expect(
          (await store.getRow(original.id))!.transaction.note,
          'Saved while offline',
        );
        expect((await store.getServerTransaction(original.id))!.note, isEmpty);
      },
    );
  }

  test(
    'rollback guard includes an accepted edit newer than the sync cursor',
    () async {
      final original = transaction();
      await store.applySync(1, [original], ledgerId: 'ledger-one');
      await store.queueEdit(original.id, {'note': 'First edit'});
      final acceptedEdit = (await store.pendingEdits()).single;
      await store.acceptEdit(
        acceptedEdit.operationId,
        transaction(version: 2, revision: 5, note: 'First edit'),
      );
      await store.queueEdit(original.id, {'note': 'Still offline'});
      final requests = <http.Request>[];
      controller = LedgerController.forTesting(
        store: store,
        api: ApiClient(
          'http://127.0.0.1:8000',
          'test-token',
          client: MockClient((request) async {
            requests.add(request);
            return syncResponse(revision: 4);
          }),
        ),
      );

      await controller!.syncNow();

      expect(requests.map((request) => request.method), ['GET']);
      expect(controller!.lastError, isNotNull);
      expect(await store.pendingCount(), 1);
      expect(await store.revision, 1);
      expect(await store.minimumServerRevision, 5);
      expect(
        (await store.getRow(original.id))!.transaction.note,
        'Still offline',
      );
    },
  );

  test(
    'retried edit response cannot overwrite a newer preflight transaction',
    () async {
      final original = transaction();
      await store.applySync(1, [original], ledgerId: 'ledger-one');
      await store.queueEdit(original.id, {'note': 'My accepted edit'});
      final queued = (await store.pendingEdits()).single;
      final latest = transaction(
        version: 3,
        revision: 3,
        note: 'Later edit from the other phone',
      );
      final cachedReply = transaction(
        version: 2,
        revision: 2,
        note: 'My accepted edit',
      );
      final requests = <http.Request>[];
      var syncRequests = 0;
      controller = LedgerController.forTesting(
        store: store,
        api: ApiClient(
          'http://127.0.0.1:8000',
          'test-token',
          client: MockClient((request) async {
            requests.add(request);
            if (request.url.path == '/api/v1/sync') {
              syncRequests++;
              return syncResponse(
                revision: 3,
                transactions: syncRequests == 1 ? [latest] : [],
              );
            }
            if (request.url.path == '/api/v1/edits') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              expect(request.method, 'POST');
              expect(body['operation_id'], queued.operationId);
              expect(body['expected_version'], 1);
              return jsonResponse({'transaction': cachedReply.toJson()});
            }
            throw StateError(
              'Unexpected request: ${request.method} ${request.url}',
            );
          }),
        ),
      );

      await controller!.syncNow();

      expect(controller!.lastError, isNull);
      expect(requests.map((request) => (request.method, request.url.path)), [
        ('GET', '/api/v1/sync'),
        ('POST', '/api/v1/edits'),
        ('GET', '/api/v1/sync'),
      ]);
      expect(requests[2].url.queryParameters['since'], '3');
      expect(await store.pendingCount(), 0);
      expect(await store.revision, 3);
      final stored = (await store.getRow(original.id))!.transaction;
      expect(stored.version, 3);
      expect(stored.revision, 3);
      expect(stored.note, latest.note);
    },
  );

  test(
    'clearing a ledger refuses pending edits and preserves cached data',
    () async {
      final original = transaction();
      await store.applySync(1, [original], ledgerId: 'ledger-one');
      await store.saveReport(2026, 9, {'expense_cents': 2500});
      await store.queueEdit(original.id, {'category': 'Meals'});
      final operationId = (await store.pendingEdits()).single.operationId;

      await expectLater(store.clearLedger(), throwsStateError);

      expect(await store.ledgerId, 'ledger-one');
      expect(await store.revision, 1);
      expect((await store.pendingEdits()).single.operationId, operationId);
      expect((await store.getRow(original.id))!.transaction.category, 'Meals');
      expect(await store.loadReport(2026, 9), {'expense_cents': 2500});
    },
  );

  test('unexpected sync errors hide private values and preserve offline edits', () async {
    const privateDetail = 'synthetic-private-sql-bill-value';
    final original = transaction();
    await store.applySync(1, [original], ledgerId: 'ledger-one');
    await store.queueEdit(original.id, {'note': 'Saved while offline'});
    final operationId = (await store.pendingEdits()).single.operationId;
    controller = LedgerController.forTesting(
      store: store,
      api: ApiClient(
        'http://127.0.0.1:8000',
        'synthetic-test-token',
        client: MockClient((_) async => throw StateError(privateDetail)),
      ),
    );

    await controller!.syncNow();

    expect(controller!.lastError, contains('同步未完成'));
    expect(controller!.lastError, isNot(contains(privateDetail)));
    expect(controller!.syncing, isFalse);
    expect((await store.pendingEdits()).single.operationId, operationId);
    expect((await store.getRow(original.id))!.transaction.note, 'Saved while offline');
    expect(await store.ledgerId, 'ledger-one');
  });

  test(
    'editing a note leaves the default exclusion policy untouched',
    () async {
      final original = transaction().withChanges({
        'kind': 'red_packet',
        'excluded': true,
        'exclusion_reason': 'default_red_packet',
      });
      await store.applySync(1, [original], ledgerId: 'ledger-one');
      controller = LedgerController.forTesting(store: store);

      await controller!.queueEdit(
        original.withChanges({'note': 'Birthday gift'}),
        original: original,
      );

      final queued = (await store.pendingEdits()).single;
      expect(queued.changes, {'note': 'Birthday gift'});
      final local = (await store.getRow(original.id))!.transaction;
      expect(local.excluded, isTrue);
      expect(local.exclusionReason, 'default_red_packet');
    },
  );

  test('a stale editor cannot overwrite a newly synced remote version', () async {
    final original = transaction();
    await store.applySync(1, [original], ledgerId: 'ledger-one');
    final remote = transaction(version: 2, revision: 2, note: 'Other device');
    await store.applySync(2, [remote], ledgerId: 'ledger-one');
    controller = LedgerController.forTesting(store: store);
    await expectLater(controller!.queueEdit(original.withChanges({'note': 'Old form'}), original: original), throwsStateError);
    expect(await store.pendingCount(), 0);
    expect((await store.getRow(original.id))!.transaction.note, 'Other device');
  });

  test('annual and monthly caches have independent keys and timestamps', () async {
    await store.saveReport(2026, 10, {'month': 10});
    await store.saveReport(2026, 0, {'year': 2026});
    expect(await store.loadReport(2026, 10), {'month': 10});
    expect(await store.loadReport(2026, 0), {'year': 2026});
    expect(await store.reportFetchedAt(2026, 0), isNotNull);
    expect(await store.reportFetchedAt(2025, 0), isNull);
    await store.clearLedger();
    expect(await store.loadReport(2026, 0), isNull);
    expect(await store.reportFetchedAt(2026, 0), isNull);
  });

  test('outbox atomically rejects an outdated editor base version', () async {
    await store.applySync(2, [transaction(version: 2, revision: 2, note: 'Remote')], ledgerId: 'ledger-one');
    await expectLater(store.queueEdit(transaction().id, {'note': 'Stale'}, expectedBaseVersion: 1), throwsStateError);
    expect(await store.pendingCount(), 0);
    await store.queueEdit(transaction().id, {'note': 'Reviewed'}, expectedBaseVersion: 2);
    expect((await store.pendingEdits()).single.expectedVersion, 2);
  });
}
