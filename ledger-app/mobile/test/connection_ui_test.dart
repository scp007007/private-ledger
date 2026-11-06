import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_mobile/data/api_client.dart';
import 'package:ledger_mobile/data/local_store.dart';
import 'package:ledger_mobile/ledger_controller.dart';
import 'package:ledger_mobile/ui/app_theme.dart';
import 'package:ledger_mobile/ui/connection_screen.dart';

GlobalKey _captureKey = GlobalKey();

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['LEDGER_UI_SCREENSHOT_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final image = await (_captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

class _Store implements LocalStore {
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller extends LedgerController {
  _Controller() : super.forTesting(store: _Store());
  Object? networkFailure;
  Object? authFailure;
  int probes = 0;
  int connections = 0;
  @override
  Future<void> checkServerHealth(String url) async {
    probes++;
    if (networkFailure != null) throw networkFailure!;
  }
  @override
  Future<void> configure(String url, String? token, {
    String? confirmedLedgerId, void Function(ConnectionStage)? onProgress,
  }) async {
    connections++;
    onProgress?.call(ConnectionStage.health);
    onProgress?.call(ConnectionStage.authorization);
    if (authFailure != null) throw authFailure!;
    onProgress?.call(ConnectionStage.localCache);
    onProgress?.call(ConnectionStage.complete);
  }
}

Future<void> _open(WidgetTester tester, _Controller controller) async {
  tester.view.physicalSize = const Size(320, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(controller.dispose);
  var theme = ledgerTheme(Brightness.light);
  if (Platform.environment['LEDGER_UI_SCREENSHOT_DIR'] != null) {
    await tester.runAsync(() async {
      for (final item in [
        ('LedgerPreview', Platform.environment['LEDGER_UI_FONT']),
        ('MaterialIcons', Platform.environment['LEDGER_UI_ICON_FONT']),
      ]) {
        if (item.$2 == null) continue;
        final bytes = await File(item.$2!).readAsBytes();
        await (FontLoader(item.$1)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
    });
    theme = theme.copyWith(textTheme: theme.textTheme.apply(fontFamily: 'LedgerPreview'));
  }
  _captureKey = GlobalKey();
  await tester.pumpWidget(MaterialApp(theme: theme,
      home: RepaintBoundary(key: _captureKey,
          child: ConnectionScreen(controller: controller, initialSetup: true))));
  await tester.enterText(find.byType(TextField).first, 'https://ledger.example.com');
}

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('network can be checked without a token and before saving', (tester) async {
    final controller = _Controller();
    await _open(tester, controller);
    await _tap(tester, '先检查网络（无需令牌）');
    expect(controller.probes, 1);
    expect(controller.connections, 0);
    expect(find.textContaining('网络连通，电脑账本服务已响应'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('network timeout shows recovery instructions and keeps inputs', (tester) async {
    final controller = _Controller()..networkFailure = const ApiException('连接超时', failure: ApiFailure.timeout);
    await _open(tester, controller);
    await _tap(tester, '先检查网络（无需令牌）');
    expect(find.textContaining('换网络后 IP 可能变化'), findsOneWidget);
    expect(find.textContaining('复制诊断信息'), findsOneWidget);
    expect(controller.connections, 0);
    expect(tester.takeException(), isNull);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.ensureVisible(find.textContaining('复制诊断信息'));
    await tester.pumpAndSettle();
    await _capture(tester, 'connection-network-timeout-320');
  });
  testWidgets('bad token distinguishes passed network from failed authentication', (tester) async {
    final controller = _Controller()..authFailure = const ApiException('访问令牌验证失败', failure: ApiFailure.unauthorized);
    await _open(tester, controller);
    await tester.enterText(find.byType(TextField).last, 'synthetic-test-token');
    await _tap(tester, '连接并同步账本');
    expect(find.textContaining('手机已经能访问电脑'), findsOneWidget);
    expect(find.textContaining('无需更改防火墙'), findsOneWidget);
    expect(find.text('网络：找到电脑账本服务'), findsOneWidget);
    expect(tester.takeException(), isNull);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.ensureVisible(find.textContaining('复制诊断信息'));
    await tester.pumpAndSettle();
    await _capture(tester, 'connection-token-error-320');
  });
}
