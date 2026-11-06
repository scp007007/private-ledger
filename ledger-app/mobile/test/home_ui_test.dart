import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_mobile/data/local_store.dart';
import 'package:ledger_mobile/ledger_controller.dart';
import 'package:ledger_mobile/main.dart';
import 'package:ledger_mobile/model/ledger_transaction.dart';
import 'package:ledger_mobile/ui/app_theme.dart';
import 'package:ledger_mobile/ui/home_screen.dart';
import 'package:ledger_mobile/ui/motion.dart';
import 'package:ledger_mobile/ui/report_widgets.dart';

class _PreviewStore implements LocalStore {
  final metadata = <String, String>{};
  @override
  Future<void> close() async {}
  @override
  Future<void> setMeta(String key, String value) async { metadata[key] = value; }
  @override
  Future<Map<String, dynamic>?> loadReport(int year, int month) async => null;
  @override
  Future<DateTime?> reportFetchedAt(int year, int month) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LedgerController _controller(_PreviewStore store) {
  final controller = LedgerController.forTesting(store: store);
  controller.reportYear = 2026;
  controller.reportMonth = 10;
  controller.report = {
    'year': 2026, 'month': 10,
    'total_actual_consumption_cents': 428050,
    'total_income_cents': 1200000,
    'category_totals': [
      {'category': '餐饮', 'amount_cents': 162659},
      {'category': '购物', 'amount_cents': 115574},
      {'category': '交通', 'amount_cents': 68488},
      {'category': '居家', 'amount_cents': 51366},
      {'category': '其他', 'amount_cents': 29963},
    ],
  };
  controller.rows = [
    for (final item in [('巷口食堂', '餐饮', 3200), ('地铁出行', '交通', 600), ('生活超市', '居家', 12680)])
      LedgerRow(LedgerTransaction.fromJson({
        'id': item.$1, 'source': 'wechat', 'occurred_at': '2026-10-11T12:00:00+08:00',
        'merchant': item.$1, 'category': item.$2, 'amount_cents': item.$3,
        'direction': 'expense', 'description': '界面测试账单',
      }), 0, false),
  ];
  return controller;
}

Future<ThemeData> _previewTheme(WidgetTester tester) async {
  var theme = ledgerTheme(Brightness.light);
  if (Platform.environment['LEDGER_UI_SCREENSHOT_DIR'] == null) return theme;
  final font = Platform.environment['LEDGER_UI_FONT'];
  final icons = Platform.environment['LEDGER_UI_ICON_FONT'];
  await tester.runAsync(() async {
    for (final entry in [('LedgerPreview', font), ('MaterialIcons', icons)]) {
      if (entry.$2 == null) continue;
      final bytes = await File(entry.$2!).readAsBytes();
      final loader = FontLoader(entry.$1)..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load().timeout(const Duration(seconds: 20));
    }
  });
  if (font != null) theme = theme.copyWith(textTheme: theme.textTheme.apply(fontFamily: 'LedgerPreview'));
  return theme;
}

Future<void> _screenshot(WidgetTester tester, GlobalKey boundary, String name) async {
  final directory = Platform.environment['LEDGER_UI_SCREENSHOT_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final image = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets('transaction row swipes work with keyboard open in both directions', (tester) async {
    tester.view.physicalSize = const Size(390, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final controller = _controller(_PreviewStore());
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(theme: ledgerTheme(Brightness.light), home: HomeScreen(controller: controller)));
    await tester.pumpAndSettle();
    for (final direction in [-1, 1]) {
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '巷口');
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      final row = find.text('巷口食堂');
      await tester.dragFrom(tester.getCenter(row), Offset(direction * 230, -25));
      await tester.pumpAndSettle();
      final pager = tester.widget<PageView>(find.byKey(const ValueKey('main-page-swipe')));
      expect(pager.controller!.page, closeTo(direction < 0 ? 2 : 0, .01));
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('transaction page follows the finger before release and supports rapid navigation', (tester) async {
    tester.view.physicalSize = const Size(390, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _controller(_PreviewStore());
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(theme: ledgerTheme(Brightness.light), home: HomeScreen(controller: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-1')));
    await tester.pumpAndSettle();
    final area = find.byKey(const ValueKey('main-page-swipe'));
    final gesture = await tester.startGesture(tester.getCenter(find.text('巷口食堂')));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    final pager = tester.widget<PageView>(area);
    expect(pager.controller!.page, greaterThan(1));
    expect(pager.controller!.page, lessThan(2));
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-0')));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byKey(const ValueKey('nav-3')));
    await tester.pumpAndSettle();
    expect(pager.controller!.page, closeTo(3, .01));
    expect(find.text('私人账本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal swipes change tabs, preserve search and stop at edges', (tester) async {
    tester.view.physicalSize = const Size(390, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _controller(_PreviewStore());
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(theme: ledgerTheme(Brightness.light), home: HomeScreen(controller: controller)));
    await tester.pumpAndSettle();
    final area = find.byKey(const ValueKey('main-page-swipe'));
    await tester.drag(area, const Offset(240, 0));
    await tester.pumpAndSettle();
    expect(find.text('本月实际消费'), findsOneWidget);
    await tester.drag(area, const Offset(-240, 0));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '巷口');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.drag(area, const Offset(240, 0));
    await tester.pumpAndSettle();
    await tester.drag(area, const Offset(-240, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '巷口');
    await tester.tap(find.byKey(const ValueKey('nav-3')));
    await tester.pumpAndSettle();
    await tester.drag(area, const Offset(-240, 0));
    await tester.pumpAndSettle();
    expect(find.text('私人账本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vertical scrolling and small horizontal drags do not change tabs', (tester) async {
    final controller = _controller(_PreviewStore());
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(theme: ledgerTheme(Brightness.light), home: HomeScreen(controller: controller)));
    await tester.pumpAndSettle();
    final area = find.byKey(const ValueKey('main-page-swipe'));
    await tester.drag(area, const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.drag(area, const Offset(-15, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-0')), findsOneWidget);
    expect(find.text('本月实际消费'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 850), const Size(390, 880), const Size(1000, 740)]) {
    testWidgets('home shell ${size.width} preserves search across tabs and fits', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _controller(_PreviewStore());
      addTearDown(controller.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(MaterialApp(theme: await _previewTheme(tester),
        home: RepaintBoundary(key: boundary, child: HomeScreen(controller: controller))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('本月实际消费'), findsOneWidget);
      await _screenshot(tester, boundary, 'home-v030-${size.width.toInt()}');

      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '巷口');
      await tester.pumpAndSettle();
      expect(find.text('1 笔流水'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '巷口');
      expect(find.text('1 笔流水'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large text and reduced motion remain usable in the full shell', (tester) async {
    tester.view.physicalSize = const Size(320, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _controller(_PreviewStore());
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(theme: ledgerTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.8), disableAnimations: true),
        child: child!), home: HomeScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final context = tester.element(find.byType(ConsumptionSummary));
    expect(ledgerMotionDuration(context, milliseconds: 620), Duration.zero);
    await tester.tap(find.byKey(const ValueKey('nav-3')));
    await tester.pumpAndSettle();
    expect(find.text('私人账本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('light is the default on a dark device; appearance saves locally', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final store = _PreviewStore();
    final controller = _controller(store);
    addTearDown(controller.dispose);
    await tester.pumpWidget(LedgerApp(controller: controller));
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.light);
    await controller.setAppearance('system');
    await tester.pumpAndSettle();
    expect(store.metadata['appearance'], 'system');
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.system);
    expect(tester.takeException(), isNull);
  });
}
