import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'data/api_client.dart';
import 'data/local_store.dart';
import 'model/ledger_transaction.dart';
import 'model/local_report.dart';

class LedgerResetRequired implements Exception {
  const LedgerResetRequired(this.ledgerId);

  final String ledgerId;

  @override
  String toString() => '此服务器提供了不同的账本。确认后将替换手机上的账本缓存。';
}

class LedgerController extends ChangeNotifier with WidgetsBindingObserver {
  LedgerController._(this._store, this._secureStorage);

  @visibleForTesting
  LedgerController.forTesting({
    required LocalStore store,
    ApiClient? api,
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
  }) : _store = store,
       _secureStorage = secureStorage,
       _api = api;

  final LocalStore _store;
  final FlutterSecureStorage _secureStorage;
  ApiClient? _api;
  Timer? _timer;
  Future<void>? _syncTask;
  bool _configuring = false;

  String? baseUrl;
  bool hasToken = false;
  bool syncing = false;
  bool autoSync = true;
  bool _foreground = true;
  bool excludeRedPackets = true;
  String appearance = 'light';
  String? lastError;
  DateTime? lastSyncAt;
  int pendingCount = 0;
  List<LedgerRow> rows = const [];
  List<Map<String, dynamic>> rules = const [];
  int reportYear = DateTime.now().year;
  int reportMonth = DateTime.now().month;
  Map<String, dynamic>? report;
  Map<String, dynamic>? yearReport;

  bool get configured => _api != null;

  String _syncErrorMessage(Object error) {
    if (error is ApiException) return error.message;
    const knownMessages = {
      '服务器账本已改变，本地数据和待同步修改已保留。请在连接设置中确认账本。',
      '服务器版本比本地旧，已暂停同步。请检查服务器是否恢复了旧备份。',
      '本地缓存缺少账本身份标识，已暂停同步。请在连接设置中重新确认账本。',
    };
    if (error is StateError && knownMessages.contains(error.message)) {
      return error.message.toString();
    }
    // Database and parsing exceptions can include SQL values or bill contents.
    return '同步未完成。请检查连接设置、电脑服务和手机可用存储空间，恢复后重新同步核对。';
  }

  static Future<LedgerController> create() async {
    const storage = FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.unlocked_this_device,
      ),
    );
    final controller = LedgerController._(await LocalStore.open(), storage);
    controller.baseUrl = await controller._store.getMeta('server_url');
    controller.autoSync = await controller._store.getMeta('auto_sync') != 'false';
    controller.excludeRedPackets =
        await controller._store.getMeta('exclude_red_packets') != 'false';
    final appearance = await controller._store.getMeta('appearance');
    if (const ['light', 'dark', 'system'].contains(appearance)) {
      controller.appearance = appearance!;
    }
    final token = await storage.read(key: 'server_token');
    controller.hasToken = token != null && token.isNotEmpty;
    if (controller.baseUrl != null && controller.hasToken) {
      controller._api = ApiClient(controller.baseUrl!, token!);
    }
    await controller._reload();
    final cachedRules = await controller._store.getMeta('rules_json');
    if (cachedRules != null) {
      controller.rules = (jsonDecode(cachedRules) as List<dynamic>)
          .map((rule) => rule as Map<String, dynamic>)
          .toList(growable: false);
    }
    WidgetsBinding.instance.addObserver(controller);
    controller._timer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => controller.scheduleAutoSync(),
    );
    return controller;
  }

  Future<void> _reload() async {
    rows = await _store.listRows();
    pendingCount = rows.fold(0, (count, row) => count + row.pendingCount);
    _updateReports();
    notifyListeners();
  }

  void _updateReports() {
    final annual = buildLocalYearReport(rows, reportYear);
    yearReport = annual;
    report = (annual['months'] as List<Map<String, dynamic>>)[reportMonth - 1];
  }

  Future<void> setAppearance(String value) async {
    if (!const ['light', 'dark', 'system'].contains(value)) {
      throw ArgumentError.value(value, 'value', 'Unknown appearance');
    }
    await _store.setMeta('appearance', value);
    appearance = value;
    notifyListeners();
  }

  void scheduleAutoSync() {
    if (autoSync && _foreground) unawaited(syncNow());
  }

  Future<void> setAutoSync(bool enabled) async {
    await _store.setMeta('auto_sync', '$enabled');
    autoSync = enabled;
    notifyListeners();
    if (enabled) scheduleAutoSync();
  }

  Future<void> checkServerHealth(String url) async {
    final probe = ApiClient(url, '');
    try {
      await probe.checkHealth();
    } finally {
      probe.close();
    }
  }

  Future<void> configure(
    String url,
    String? token, {
    String? confirmedLedgerId,
    void Function(ConnectionStage)? onProgress,
  }) async {
    if (_configuring) throw StateError('正在更新连接，请稍后再试。');
    final normalized = ApiClient.normalizeBaseUrl(url);
    _configuring = true;
    ApiClient? candidate;
    var connected = false;
    try {
      await _syncTask;
      final existingToken = await _secureStorage.read(key: 'server_token');
      final effectiveToken = token?.trim().isNotEmpty == true
          ? token!.trim()
          : existingToken;
      if (effectiveToken == null || effectiveToken.isEmpty) {
        throw const FormatException('请输入访问令牌。');
      }
      candidate = ApiClient(normalized, effectiveToken);
      onProgress?.call(ConnectionStage.health);
      await candidate.checkHealth();
      onProgress?.call(ConnectionStage.authorization);
      final snapshot = await candidate.fetchSync(0);
      final localLedgerId = await _store.ledgerId;
      final needsReset =
          (localLedgerId != null && localLedgerId != snapshot.ledgerId) ||
          (localLedgerId == null && await _store.hasLedgerData);
      if (needsReset) {
        if (await _store.pendingCount() > 0) {
          throw StateError('服务器账本已改变，但手机还有未同步的修改。修改已保留，请先连接原账本完成同步。');
        }
        if (confirmedLedgerId != snapshot.ledgerId) {
          throw LedgerResetRequired(snapshot.ledgerId);
        }
      } else if (snapshot.revision < await _store.minimumServerRevision) {
        throw StateError('服务器版本比本地旧，已暂停同步。请检查服务器是否恢复了旧备份。');
      }
      onProgress?.call(ConnectionStage.localCache);
      await _secureStorage.write(key: 'server_token', value: effectiveToken);
      if (needsReset) {
        await _store.clearLedger();
        rules = const [];
      }
      await _store.setMeta('server_url', normalized);
      await _store.applySync(
        snapshot.revision,
        snapshot.transactions,
        ledgerId: snapshot.ledgerId,
      );
      _api?.close();
      _api = candidate;
      connected = true;
      baseUrl = normalized;
      hasToken = true;
      excludeRedPackets = snapshot.excludeRedPackets;
      await _store.setMeta('exclude_red_packets', '$excludeRedPackets');
      await _saveRules(snapshot.rules);
      lastError = null;
      lastSyncAt = DateTime.now();
      await _reload();
      onProgress?.call(ConnectionStage.complete);
    } finally {
      _configuring = false;
      if (!connected) candidate?.close();
    }
    scheduleAutoSync();
  }

  Future<void> queueEdit(
    LedgerTransaction edited, {
    LedgerTransaction? original,
  }) async {
    if (_configuring) throw StateError('正在更新服务器连接，请完成后再保存修改。');
    final current = (await _store.getRow(edited.id))?.transaction;
    final base = original ?? current;
    if (base == null) throw StateError('本地没有这笔交易，请先同步。');
    if (edited.direction != 'expense' && rows.any((row) => row.transaction.refundOfId == edited.id)) {
      throw StateError('这笔支出已关联退款，请先解除退款关联，再修改收支方向。');
    }
    if (original != null && current != null && original.version != current.version) {
      throw StateError('这笔流水在编辑期间已有更新。你填写的内容仍保留在表单中，请返回流水重新打开后核对并保存。');
    }
    final before = base.editableFields;
    final changes = <String, dynamic>{};
    for (final entry in edited.editableFields.entries) {
      final previous = before[entry.key];
      final equal = previous is List && entry.value is List
          ? listEquals(previous, entry.value as List)
          : previous == entry.value;
      if (!equal) changes[entry.key] = entry.value;
    }
    if (changes.isEmpty) return;
    await _store.queueEdit(edited.id, changes, expectedBaseVersion: base.version);
    await _reload();
    scheduleAutoSync();
  }

  Future<void> addTransaction(LedgerTransaction transaction) async {
    if (_configuring) throw StateError('正在更新连接，请稍后再保存。');
    await _store.queueCreate(transaction);
    await _reload();
    scheduleAutoSync();
  }

  Future<Map<String, dynamic>> reviewImport(String id, int offset) async {
    final api = _api;
    if (api == null) throw StateError('请先连接服务器。');
    return api.reviewImport(id, offset);
  }

  Future<void> resolveConflict(
    String transactionId, {
    required bool keepMine,
  }) async {
    if (_configuring) throw StateError('正在更新服务器连接，请完成后再处理冲突。');
    await _store.resolveConflict(transactionId, keepMine: keepMine);
    await _reload();
    scheduleAutoSync();
  }

  Future<LedgerTransaction?> serverVersion(String transactionId) =>
      _store.getServerTransaction(transactionId);

  Future<void> syncNow() {
    if (_configuring) return Future<void>.value();
    return _syncTask ??= _performSync().whenComplete(() {
      _syncTask = null;
    });
  }

  Future<void> _applyPayload(SyncPayload payload) async {
    await _store.applySync(
      payload.revision,
      payload.transactions,
      ledgerId: payload.ledgerId,
    );
    excludeRedPackets = payload.excludeRedPackets;
    await _store.setMeta('exclude_red_packets', '$excludeRedPackets');
    await _saveRules(payload.rules);
  }

  Future<void> _performSync() async {
    final api = _api;
    if (api == null) return;
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      // Validate identity and rollback before any queued edit can leave this device.
      final preflight = await api.fetchSync(await _store.revision);
      await _applyPayload(preflight);
      final edits = await _store.pendingEdits();
      final blocked = <String>{};
      for (final edit in edits) {
        if (edit.status == 'conflict') {
          blocked.add(edit.transactionId);
          continue;
        }
        if (blocked.contains(edit.transactionId)) continue;
        try {
          final accepted = edit.expectedVersion == 0
              ? await api.createTransaction(edit)
              : await api.sendEdit(edit);
          await _store.acceptEdit(edit.operationId, accepted);
        } on EditConflict catch (conflict) {
          await _store.markConflict(edit.operationId, conflict.current);
          blocked.add(edit.transactionId);
        }
      }
      final since = await _store.revision;
      final payload = await api.fetchSync(since);
      await _applyPayload(payload);
      lastSyncAt = DateTime.now();
      await _reload();
    } catch (error) {
      lastError = _syncErrorMessage(error);
      await _reload();
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  void selectReportMonth(int year, int month) {
    reportYear = year;
    reportMonth = month;
    _updateReports();
    notifyListeners();
  }

  Future<Map<String, dynamic>> previewImport(
    String source,
    String fileName,
    Uint8List bytes,
  ) async {
    final api = _api;
    if (api == null) throw StateError('请先连接服务器。');
    return api.previewImport(source: source, fileName: fileName, bytes: bytes);
  }

  Future<Map<String, dynamic>> commitImport(String previewId) async {
    final api = _api;
    if (api == null) throw StateError('请先连接服务器。');
    final result = await api.commitImport(previewId);
    await syncNow();
    return result;
  }

  Future<Uint8List> exportCsv(
    int year,
    int? month, {
    required bool redact,
  }) async {
    final api = _api;
    if (api == null) throw StateError('请先连接服务器。');
    await syncNow();
    if (lastError != null) throw ApiException(lastError!);
    return api.exportCsv(year, month, redact: redact);
  }

  Future<void> setExcludeRedPackets(bool value) async {
    final api = _api;
    if (api == null) throw StateError('请先连接服务器。');
    excludeRedPackets = await api.updateExcludeRedPackets(value);
    await _store.setMeta('exclude_red_packets', '$excludeRedPackets');
    notifyListeners();
    await syncNow();
  }

  Future<void> _saveRules(List<Map<String, dynamic>>? next) async {
    if (next == null) return;
    rules = next;
    await _store.setMeta('rules_json', jsonEncode(next));
    notifyListeners();
  }

  Future<void> refreshRules() async {
    final api = _api;
    if (api == null) throw StateError('请先连接服务器。');
    await _saveRules(await api.fetchRules());
  }

  Future<void> createRule(
    Map<String, dynamic> conditions,
    Map<String, dynamic> actions,
  ) async {
    final api = _api;
    if (api == null) throw StateError('请先连接服务器。');
    await api.createRule(conditions: conditions, actions: actions);
    await refreshRules();
  }

  Future<void> deleteRule(String id) async {
    final api = _api;
    if (api == null) throw StateError('请先连接服务器。');
    await api.deleteRule(id);
    await refreshRules();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) scheduleAutoSync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _api?.close();
    unawaited(_store.close());
    super.dispose();
  }
}
