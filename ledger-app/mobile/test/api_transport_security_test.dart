import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ledger_mobile/data/api_client.dart';
import 'package:ledger_mobile/model/ledger_transaction.dart';

// Synthetic fixtures only; these tests never contact a server or read storage.
const _token = 'fixture-access-token';
const _privateDetail = 'fixture-private-bill-and-token';
const _edit = PendingEdit(
  operationId: 'fixture-operation',
  transactionId: 'fixture-transaction',
  expectedVersion: 1,
  changes: {'note': _privateDetail},
  status: 'pending',
);

class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return handler(request);
  }
}

http.StreamedResponse _response(
  String body,
  int status, {
  Map<String, String> headers = const {},
}) => http.StreamedResponse(
  Stream.value(utf8.encode(body)),
  status,
  headers: headers,
);

ApiClient _api(http.Client client) =>
    ApiClient('https://ledger.example.com', _token, client: client);

Matcher _safeError({String? guidance, int? status}) {
  var matcher = isA<ApiException>()
      .having((error) => error.toString(), 'private detail', isNot(contains(_privateDetail)))
      .having((error) => error.toString(), 'token', isNot(contains(_token)));
  if (guidance != null) {
    matcher = matcher.having((error) => error.message, 'guidance', contains(guidance));
  }
  if (status != null) {
    matcher = matcher.having((error) => error.statusCode, 'status', status);
  }
  return matcher;
}

void main() {
  final operations = <String, Future<void> Function(ApiClient)>{
    'sync': (api) async { await api.fetchSync(0); },
    'edit': (api) async { await api.sendEdit(_edit); },
    'month report': (api) async { await api.fetchMonthReport(2026, 9); },
    'year report': (api) async { await api.fetchYearReport(2026); },
    'import preview': (api) async {
      await api.previewImport(
        source: 'wechat',
        fileName: 'fixture.csv',
        bytes: Uint8List.fromList(utf8.encode(_privateDetail)),
      );
    },
    'import commit': (api) async { await api.commitImport('fixture-preview'); },
    'CSV export': (api) async { await api.exportCsv(2026, 9, redact: false); },
    'settings': (api) async { await api.updateExcludeRedPackets(false); },
    'read rules': (api) async { await api.fetchRules(); },
    'create rule': (api) async {
      await api.createRule(
        conditions: {'merchant': _privateDetail},
        actions: {'category': 'fixture-category'},
      );
    },
    'delete rule': (api) async { await api.deleteRule('fixture-rule'); },
  };

  for (final operation in operations.entries) {
    for (final status in [301, 302, 303, 307, 308]) {
      test('${operation.key} blocks redirect $status and hides its target', () async {
        final client = _RecordingClient((request) async => _response(
          _privateDetail,
          status,
          headers: {'location': 'http://untrusted.example/$_privateDetail'},
        ));
        final api = _api(client);
        addTearDown(api.close);

        await expectLater(
          operation.value(api),
          throwsA(_safeError(guidance: '跳转', status: status)),
        );

        expect(client.requests, hasLength(1));
        final request = client.requests.single;
        expect(request.followRedirects, isFalse);
        expect(request.url.host, 'ledger.example.com');
        expect(request.headers['Authorization'], 'Bearer $_token');
      });
    }

    test('${operation.key} explains 401 without echoing server content', () async {
      final api = _api(_RecordingClient((_) async =>
          _response('<html>$_privateDetail $_token</html>', 401)));
      addTearDown(api.close);
      await expectLater(
        operation.value(api),
        throwsA(_safeError(guidance: '令牌验证失败', status: 401)),
      );
    });
  }

  for (final status in [400, 403, 422, 500]) {
    test('error $status never exposes server detail or invalid response text', () async {
      final api = _api(_RecordingClient((_) async => _response(
        jsonEncode({'detail': '$_privateDetail $_token'}), status,
      )));
      addTearDown(api.close);
      await expectLater(api.fetchSync(0), throwsA(_safeError(status: status)));
    });
  }

  for (final failure in [
    (status: 400, guidance: '原始导出表头'),
    (status: 413, guidance: '拆分'),
    (status: 415, guidance: 'CSV'),
    (status: 422, guidance: '日期和金额'),
  ]) {
    test('import preview ${failure.status} has safe file guidance', () async {
      final api = _api(_RecordingClient((_) async => _response(
        jsonEncode({'detail': '$_privateDetail $_token'}), failure.status,
      )));
      addTearDown(api.close);
      await expectLater(
        api.previewImport(
          source: 'wechat',
          fileName: 'fixture.csv',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
        throwsA(_safeError(guidance: failure.guidance, status: failure.status)),
      );
    });
  }

  test('expired preview has safe recovery guidance', () async {
    final api = _api(_RecordingClient((_) async => _response(
      jsonEncode({'detail': '$_privateDetail $_token'}), 404,
    )));
    addTearDown(api.close);
    await expectLater(
      api.commitImport('fixture-preview'),
      throwsA(_safeError(guidance: '预览已失效', status: 404)),
    );
  });

  test('mutation timeout does not claim that the operation failed', () async {
    final api = _api(_RecordingClient((_) async =>
        throw TimeoutException('$_privateDetail $_token')));
    addTearDown(api.close);
    await expectLater(
      api.commitImport('fixture-preview'),
      throwsA(_safeError(guidance: '超时不代表操作未完成')),
    );
  });

  final networkFailures = <({Object error, String guidance})>[
    (error: TimeoutException(_privateDetail), guidance: '连接超时'),
    (error: const SocketException(_privateDetail), guidance: '无法连接服务器'),
    (error: const HandshakeException(_privateDetail), guidance: 'HTTPS'),
    (error: http.ClientException(_privateDetail), guidance: '网络连接失败'),
    (error: const HttpException(_privateDetail), guidance: '连接中断'),
  ];
  for (final failure in networkFailures) {
    test('${failure.error.runtimeType} has safe actionable guidance', () async {
      final api = _api(_RecordingClient((_) async => throw failure.error));
      addTearDown(api.close);
      await expectLater(
        api.fetchSync(0),
        throwsA(_safeError(guidance: failure.guidance)),
      );
    });
  }

  testWidgets('request deadline also covers a server that never answers', (tester) async {
    final pending = Completer<http.StreamedResponse>();
    final api = _api(_RecordingClient((_) => pending.future));
    addTearDown(api.close);
    final result = expectLater(
      api.fetchSync(0),
      throwsA(_safeError(guidance: '连接超时')),
    );
    await tester.pump(ApiClient.timeout + const Duration(milliseconds: 1));
    await result;
    pending.complete(_response('{}', 200));
    await tester.pump();
  });

  test('response stream failures are sanitized too', () async {
    final api = _api(_RecordingClient((_) async => http.StreamedResponse(
      Stream<List<int>>.error(const SocketException(_privateDetail)), 200,
    )));
    addTearDown(api.close);
    await expectLater(
      api.fetchSync(0),
      throwsA(_safeError(guidance: '无法连接服务器')),
    );
  });

  test('malformed bill fields never appear in parsing errors', () async {
    final api = _api(_RecordingClient((_) async => _response(jsonEncode({
      'ledger_id': 'fixture-ledger',
      'revision': 1,
      'transactions': [{
        'id': 'fixture-transaction',
        'occurred_at': _privateDetail,
        'amount_cents': 100,
      }],
    }), 200)));
    addTearDown(api.close);
    await expectLater(
      api.fetchSync(0),
      throwsA(_safeError(guidance: '响应格式不正确')),
    );
  });

  test('safe transport preserves edit JSON and conflict handling', () async {
    final current = {
      'id': 'fixture-transaction',
      'occurred_at': '2026-09-01T12:00:00+08:00',
      'amount_cents': 100,
      'note': _privateDetail,
      'version': 2,
    };
    final api = _api(_RecordingClient((request) async {
      expect(request.method, 'POST');
      expect(request.headers['Content-Type'], 'application/json; charset=utf-8');
      expect(jsonDecode((request as http.Request).body), {
        'operation_id': _edit.operationId,
        'transaction_id': _edit.transactionId,
        'expected_version': _edit.expectedVersion,
        'changes': _edit.changes,
      });
      return _response(jsonEncode({'current': current}), 409);
    }));
    addTearDown(api.close);
    await expectLater(api.sendEdit(_edit), throwsA(
      isA<EditConflict>()
          .having((error) => error.current.version, 'current version', 2)
          .having((error) => error.toString(), 'private detail', isNot(contains(_privateDetail))),
    ));
  });
}
