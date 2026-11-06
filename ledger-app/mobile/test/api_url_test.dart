import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_mobile/data/api_client.dart';

void main() {
  test('server addresses normalize whitespace and a trailing root slash', () {
    expect(
      ApiClient.normalizeBaseUrl('  https://ledger.example.com/  '),
      'https://ledger.example.com',
    );
    expect(
      ApiClient.normalizeBaseUrl('http://192.168.1.5:8000/'),
      'http://192.168.1.5:8000',
    );
  });

  for (final host in [
    'localhost',
    '127.0.0.1',
    '10.0.0.1',
    '172.16.0.1',
    '172.31.255.254',
    '192.168.1.5',
    '100.64.0.1',
    '100.127.255.254',
  ]) {
    test('HTTP supports private or VPN host $host', () {
      expect(
        ApiClient.normalizeBaseUrl('http://$host:8000'),
        'http://$host:8000',
      );
    });
  }

  for (final address in [
    'http://ledger.example.com',
    'http://8.8.8.8',
    'http://172.15.255.255',
    'http://172.32.0.1',
    'http://100.63.255.255',
    'http://100.128.0.1',
    'https://user:password@ledger.example.com',
    'https://ledger.example.com/api',
    'https://ledger.example.com?token=secret',
    'https://ledger.example.com#fragment',
    'file:///ledger.db',
  ]) {
    test('rejects unsafe or non-root address $address', () {
      expect(() => ApiClient.normalizeBaseUrl(address), throwsFormatException);
    });
  }
}
