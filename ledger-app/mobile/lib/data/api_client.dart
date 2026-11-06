import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../model/ledger_transaction.dart';

enum ApiFailure { network, timeout, tls, redirect, unauthorized, server, response }

enum ConnectionStage { health, authorization, localCache, complete }

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.failure});

  final String message;
  final int? statusCode;
  final ApiFailure? failure;

  @override
  String toString() => message;
}

class EditConflict extends ApiException {
  const EditConflict(this.current) : super('服务器上的交易已被其他设备修改。', statusCode: 409);

  final LedgerTransaction current;
}

class SyncPayload {
  const SyncPayload(
    this.ledgerId,
    this.revision,
    this.transactions,
    this.excludeRedPackets,
    this.rules,
  );

  final String ledgerId;
  final int revision;
  final List<LedgerTransaction> transactions;
  final bool excludeRedPackets;
  final List<Map<String, dynamic>>? rules;
}

class ApiClient {
  ApiClient(String baseUrl, this.token, {http.Client? client})
    : baseUrl = normalizeBaseUrl(baseUrl),
      _client = client ?? http.Client();

  final String baseUrl;
  final String token;
  final http.Client _client;
  static const timeout = Duration(seconds: 25);

  static String normalizeBaseUrl(String value) {
    final raw = value.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException('请输入服务器根地址，例如 https://ledger.example.com');
    }
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' && isPrivateHttpHost(uri.host))) {
      throw const FormatException('HTTP 只允许私有 IP、VPN IP 或本机开发地址；公网请使用 HTTPS。');
    }
    return uri
        .replace(path: '', query: null, fragment: null)
        .toString()
        .replaceFirst(RegExp(r'/$'), '');
  }

  static bool isPrivateHttpHost(String host) {
    if (host == 'localhost' || host == '::1') return true;
    final address = Uri.tryParse('http://$host')?.host;
    if (address == null) return false;
    final parts = address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 ||
        parts.any((part) => part == null || part < 0 || part > 255)) {
      return false;
    }
    final a = parts[0]!;
    final b = parts[1]!;
    return a == 10 ||
        a == 127 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 100 && b >= 64 && b <= 127);
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    return Uri.parse('$baseUrl$path').replace(queryParameters: query);
  }

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/json',
  };

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
  }) {
    final request = http.Request(method, uri);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    return _send(request);
  }

  Future<http.Response> _send(http.BaseRequest request, {bool authenticated = true}) async {
    // Every endpoint carries credentials; uploads also carry private bill data.
    // Never let a redirect forward either to a different address or protocol.
    request.followRedirects = false;
    if (authenticated) request.headers.addAll(_headers);
    try {
      final response = await (() async {
        final streamed = await _client.send(request);
        return http.Response.fromStream(streamed);
      })().timeout(authenticated ? timeout : const Duration(seconds: 6));
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw ApiException(
          '服务器要求跳转到其他地址，已停止请求以保护令牌和账单。请核对服务器根地址及 HTTPS 配置。',
          statusCode: response.statusCode,
          failure: ApiFailure.redirect,
        );
      }
      if (response.statusCode == 401 && authenticated) {
        throw const ApiException(
          '访问令牌验证失败。请在连接设置中重新填写与电脑端一致的令牌，然后测试连接。',
          statusCode: 401,
          failure: ApiFailure.unauthorized,
        );
      }
      return response;
    } on TimeoutException {
      throw const ApiException(
        '连接超时。请检查手机与电脑是否在同一可信 Wi-Fi（或已连接 VPN）、电脑服务是否启动，以及服务器 IP、端口和防火墙设置。超时不代表操作未完成，恢复连接后请先同步核对。',
        failure: ApiFailure.timeout,
      );
    } on TlsException {
      throw const ApiException(
        '无法验证服务器的 HTTPS 安全连接。请检查证书是否有效、域名是否匹配，以及手机时间是否正确。',
        failure: ApiFailure.tls,
      );
    } on SocketException {
      throw const ApiException(
        '无法连接服务器。请检查网络、服务器 IP 和端口，确认电脑服务已启动且防火墙允许连接。',
        failure: ApiFailure.network,
      );
    } on http.ClientException {
      throw const ApiException(
        '网络连接失败。请检查手机网络、服务器地址和电脑服务状态；使用 HTTPS 时请检查证书配置。',
        failure: ApiFailure.network,
      );
    } on HttpException {
      throw const ApiException('服务器连接中断或响应无效。请检查电脑服务和网络后重试。', failure: ApiFailure.network);
    }
  }

  /// Probe without credentials or bill data; saving a connection still requires
  /// authenticated sync and ledger identity checks.
  Future<void> checkHealth() async {
    final response = await _send(http.Request('GET', _uri('/health')), authenticated: false);
    if (response.statusCode != 200) {
      throw ApiException('地址已有 HTTP 响应，但账本健康检查未通过（${response.statusCode}）。请核对电脑端显示的根地址和端口。',
          statusCode: response.statusCode, failure: ApiFailure.server);
    }
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map<String, dynamic> || body['status'] != 'ok' ||
          (body['service'] != null && body['service'] != 'private-ledger')) {
        throw const FormatException();
      }
    } on FormatException {
      throw const ApiException('这个地址返回的内容不是账本服务。请使用电脑端显示的服务器地址。', failure: ApiFailure.response);
    }
  }

  Map<String, dynamic> _json(
    http.Response response, {
    Map<int, String> errorMessages = const {},
  }) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Server error bodies can contain request data. Never display them.
      throw ApiException(
        errorMessages[response.statusCode] ??
            (response.statusCode == 403
                ? '服务器拒绝访问。请检查令牌权限及服务器访问设置。'
                : '服务器请求失败（${response.statusCode}）。请检查电脑服务后重试。'),
        statusCode: response.statusCode,
      );
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ApiException('服务器返回了无法解析的数据。', statusCode: response.statusCode);
    }
    if (body is! Map<String, dynamic>) {
      throw const ApiException('服务器响应格式不正确。');
    }
    return body;
  }

  T _readJson<T>(
    http.Response response,
    T Function(Map<String, dynamic>) read,
  ) {
    try {
      return read(_json(response));
    } on FormatException {
      throw const ApiException('服务器响应格式不正确，请检查手机与服务器版本是否兼容。');
    } on TypeError {
      throw const ApiException('服务器响应格式不正确，请检查手机与服务器版本是否兼容。');
    }
  }

  Future<SyncPayload> fetchSync(int since) async {
    final response = await _request(
      'GET',
      _uri('/api/v1/sync', {'since': '$since'}),
    );
    return _readJson(response, (body) {
      final rawTransactions = body['transactions'] as List<dynamic>? ?? const [];
      final settings = body['settings'] as Map<String, dynamic>? ?? const {};
      final rawRules = body['rules'] as List<dynamic>?;
      final ledgerId = body['ledger_id'];
      if (ledgerId is! String || ledgerId.trim().isEmpty) {
        throw const ApiException('服务器未提供账本身份标识，请先更新服务器。');
      }
      return SyncPayload(
        ledgerId,
        (body['revision'] as num).toInt(),
        rawTransactions
            .map(
              (item) => LedgerTransaction.fromJson(item as Map<String, dynamic>),
            )
            .toList(growable: false),
        settings['exclude_red_packets'] != false,
        rawRules
            ?.map((rule) => rule as Map<String, dynamic>)
            .toList(growable: false),
      );
    });
  }

  Future<LedgerTransaction> sendEdit(PendingEdit edit) async {
    final response = await _request(
      'POST',
      _uri('/api/v1/edits'),
      body: {
        'operation_id': edit.operationId,
        'transaction_id': edit.transactionId,
        'expected_version': edit.expectedVersion,
        'changes': edit.changes,
      },
    );
    if (response.statusCode == 409) {
      try {
        final body =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        throw EditConflict(
          LedgerTransaction.fromJson(body['current'] as Map<String, dynamic>),
        );
      } on EditConflict {
        rethrow;
      } on Object {
        throw const ApiException('服务器报告版本冲突，但未返回当前交易。', statusCode: 409);
      }
    }
    return _readJson(
      response,
      (body) => LedgerTransaction.fromJson(
        body['transaction'] as Map<String, dynamic>,
      ),
    );
  }

  Future<LedgerTransaction> createTransaction(PendingEdit edit) async {
    final response = await _request('POST', _uri('/api/v1/transactions'), body: {
      'operation_id': edit.operationId, 'transaction_id': edit.transactionId, ...edit.changes,
    });
    if (response.statusCode == 404) {
      throw const ApiException('电脑端尚未支持手动记账，请更新并重新启动电脑端服务；本机待同步账单仍保留。', statusCode: 404);
    }
    return _readJson(response, (body) => LedgerTransaction.fromJson(body['transaction'] as Map<String, dynamic>));
  }

  Future<Map<String, dynamic>> reviewImport(String id, int offset) async {
    return _json(await _request('GET', _uri('/api/v1/imports/${Uri.encodeComponent(id)}/rows', {
      'offset': '$offset', 'limit': '50',
    })), errorMessages: const {404: '无法读取审核明细。请确认电脑端已更新并重启，再重新选择文件；旧预览可能已失效。'});
  }

  Future<Map<String, dynamic>> fetchMonthReport(int year, int month) async {
    final response = await _request(
      'GET',
      _uri('/api/v1/reports/month', {'year': '$year', 'month': '$month'}),
    );
    return _json(response);
  }

  Future<Map<String, dynamic>> fetchYearReport(int year) async {
    final response = await _request(
      'GET',
      _uri('/api/v1/reports/year', {'year': '$year'}),
    );
    return _json(response);
  }

  Future<Map<String, dynamic>> previewImport({
    required String source,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      _uri('/api/v1/imports/preview'),
    );
    request.fields['source'] = source;
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: fileName),
    );
    return _json(
      await _send(request),
      errorMessages: const {
        400: '无法读取账单文件。请确认来源选择正确，使用原始导出表头；加密 ZIP 请先解压。',
        413: '账单文件或解压后的内容超过服务器限制，请按月份拆分后导入。',
        415: '服务器不支持这个文件格式，请选择 CSV、TXT 或包含账单的 ZIP。',
        422: '账单内容不符合导入要求。请核对来源、原始表头、日期和金额格式；加密 ZIP 请先解压。当前官方账单格式可能需要适配。',
      },
    );
  }

  Future<Map<String, dynamic>> commitImport(String previewId) async {
    final response = await _request(
      'POST',
      _uri('/api/v1/imports/${Uri.encodeComponent(previewId)}/commit'),
    );
    return _json(
      response,
      errorMessages: const {
        404: '导入预览已失效或不存在。请重新选择文件并核对预览后导入；已导入的重复流水会跳过。',
        422: '导入预览信息无效，请重新选择文件并生成预览。',
      },
    );
  }

  Future<Uint8List> exportCsv(
    int year,
    int? month, {
    required bool redact,
  }) async {
    final response = await _request(
      'GET',
      _uri('/api/v1/export.csv', {
        'year': '$year',
        if (month != null) 'month': '$month',
        'redact': '$redact',
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        'CSV 导出失败（${response.statusCode}）。',
        statusCode: response.statusCode,
      );
    }
    return response.bodyBytes;
  }

  Future<bool> updateExcludeRedPackets(bool exclude) async {
    final response = await _request(
      'PATCH',
      _uri('/api/v1/settings'),
      body: {'exclude_red_packets': exclude},
    );
    return _readJson(response, (body) {
      final settings = body['settings'] as Map<String, dynamic>? ?? const {};
      return settings['exclude_red_packets'] != false;
    });
  }

  Future<List<Map<String, dynamic>>> fetchRules() async {
    final response = await _request('GET', _uri('/api/v1/rules'));
    return _readJson(
      response,
      (body) => (body['rules'] as List<dynamic>? ?? const [])
          .map((rule) => rule as Map<String, dynamic>)
          .toList(growable: false),
    );
  }

  Future<void> createRule({
    required Map<String, dynamic> conditions,
    required Map<String, dynamic> actions,
  }) async {
    final response = await _request(
      'POST',
      _uri('/api/v1/rules'),
      body: {
        'enabled': true,
        'priority': 100,
        'conditions': conditions,
        'actions': actions,
      },
    );
    _json(response);
  }

  Future<void> deleteRule(String id) async {
    final response = await _request(
      'DELETE',
      _uri('/api/v1/rules/${Uri.encodeComponent(id)}'),
    );
    _json(response);
  }

  void close() => _client.close();
}
