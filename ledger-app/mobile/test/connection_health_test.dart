import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ledger_mobile/data/api_client.dart';

void main() {
  for (final body in [
    {'status': 'ok'}, // Compatible with existing desktop versions.
    {'status': 'ok', 'service': 'private-ledger'},
  ]) {
    test('health probe does not send a token or follow redirects $body', () async {
      final api = ApiClient('http://192.168.1.5:8000', 'synthetic-secret',
          client: MockClient((request) async {
        expect(request.url.path, '/health');
        expect(request.headers.containsKey('Authorization'), isFalse);
        expect(request.followRedirects, isFalse);
        expect(request.body, isEmpty);
        return http.Response(jsonEncode(body), 200);
      }));
      addTearDown(api.close);
      await api.checkHealth();
    });
  }
  for (final body in ['<html>Other application</html>', '{"status":"ok","service":"other"}', '{}']) {
    test('wrong service has a distinct safe result $body', () async {
      final api = ApiClient('https://ledger.example.com', '',
          client: MockClient((_) async => http.Response(body, 200)));
      addTearDown(api.close);
      await expectLater(api.checkHealth(), throwsA(isA<ApiException>()
          .having((error) => error.failure, 'failure', ApiFailure.response)));
    });
  }
  test('health redirect stops before any credential request', () async {
    final api = ApiClient('https://ledger.example.com', 'synthetic-secret',
        client: MockClient((request) async {
      expect(request.followRedirects, isFalse);
      return http.Response('', 302, headers: {'location': 'https://other.example/'});
    }));
    addTearDown(api.close);
    await expectLater(api.checkHealth(), throwsA(isA<ApiException>()
        .having((error) => error.failure, 'failure', ApiFailure.redirect)));
  });
}
