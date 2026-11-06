import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_mobile/data/local_store.dart';
import 'package:ledger_mobile/ledger_controller.dart';
import 'package:ledger_mobile/model/ledger_transaction.dart';
import 'package:ledger_mobile/model/report_breakdown.dart';
import 'package:ledger_mobile/ui/app_theme.dart';
import 'package:ledger_mobile/ui/overview_page.dart';
import 'package:ledger_mobile/ui/report_widgets.dart';
import 'package:ledger_mobile/ui/reports_page.dart';
import 'package:ledger_mobile/ui/transactions_page.dart';

class _Store implements LocalStore {
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> sampleReport() => {
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

void main() {
  test('breakdown conserves every cent and keeps unclassified visible', () {
    final categories = reportCategories({'category_totals': [
      for (var i = 0; i < 8; i++) {'category': '分类$i', 'amount_cents': 1000 - i},
      {'category': '未分类', 'amount_cents': 1},
      {'category': '已全额退款', 'amount_cents': 0},
    ]});
    final slices = categorySlices(categories);
    expect(slices.length, 6);
    expect(slices.any((s) => s.label == '未分类'), isTrue);
    expect(slices.fold<int>(0, (sum, s) => sum + s.cents), categories.fold<int>(0, (sum, c) => sum + c.cents));
    expect(slices.last.categories.length, 4);
  });

  test('China accounting month is stable when a timestamp is stored as UTC', () {
    final transaction = LedgerTransaction.fromJson({'id': 'one', 'source': 'wechat', 'occurred_at': '2026-10-01T00:10:00+08:00', 'amount_cents': 100});
    final roundTrip = LedgerTransaction.fromJson(transaction.toJson());
    expect(roundTrip.ledgerDateTime, DateTime(2026, 10, 1, 0, 10));
  });

  testWidgets('zero expense shows an honest empty state', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: ledgerTheme(Brightness.light), home: Scaffold(body: ExpenseBreakdown(report: const {'category_totals': []}, onCategory: (_) {}))));
    expect(find.text('这个期间还没有计入统计的消费'), findsOneWidget);
    expect(find.textContaining('NaN'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('overview at $width has no overflow and opens category transactions', (tester) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = LedgerController.forTesting(store: _Store());
      addTearDown(controller.dispose);
      controller.reportYear = 2026;
      controller.reportMonth = 10;
      controller.report = sampleReport();
      controller.pendingCount = 1;
      controller.rows = [LedgerRow(LedgerTransaction.fromJson({'id': 'lunch', 'source': 'wechat', 'occurred_at': '2026-10-09T12:00:00+08:00', 'amount_cents': 3200, 'merchant': '巷口食堂', 'description': '午餐', 'category': '餐饮'}), 0, false)];
      final screenshotDirectory = Platform.environment['LEDGER_UI_SCREENSHOT_DIR'];
      var theme = ledgerTheme(Brightness.light);
      final fontPath = Platform.environment['LEDGER_UI_FONT'];
      if (screenshotDirectory != null && fontPath != null) {
        await tester.runAsync(() async {
          final bytes = await File(fontPath).readAsBytes();
          final loader = FontLoader('LedgerPreview')..addFont(Future.value(ByteData.sublistView(bytes)));
          await loader.load().timeout(const Duration(seconds: 20));
          final iconPath = Platform.environment['LEDGER_UI_ICON_FONT'];
          if (iconPath != null) {
            final iconBytes = await File(iconPath).readAsBytes();
            final icons = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(iconBytes)));
            await icons.load().timeout(const Duration(seconds: 20));
          }
        });
        theme = theme.copyWith(textTheme: theme.textTheme.apply(fontFamily: 'LedgerPreview'));
      }
      final boundary = GlobalKey();
      await tester.pumpWidget(MaterialApp(theme: theme, home: RepaintBoundary(key: boundary, child: Scaffold(appBar: AppBar(title: const Text('私有账本')), body: OverviewPage(controller: controller, onImport: () {}, onTransactions: () {})))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('1 项修改待同步'), findsOneWidget);
      if (screenshotDirectory != null) {
        await tester.runAsync(() async {
          final image = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = Directory(screenshotDirectory);
          await output.create(recursive: true);
          await File('${output.path}/overview-${width.toInt()}.png').writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final category = find.text('餐饮').last;
      await tester.ensureVisible(category);
      await tester.pumpAndSettle();
      await tester.tap(category);
      await tester.pumpAndSettle();
      expect(find.byType(TransactionsPage), findsOneWidget);
      expect(find.text('巷口食堂'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('annual trend selects the correct month', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    int? selected;
    await tester.pumpWidget(MaterialApp(theme: ledgerTheme(Brightness.light), builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.8)), child: child!), home: Scaffold(body: MonthlyTrend(report: {'year': 2026, 'months': [for (var month = 1; month <= 12; month++) {'month': month, 'total_actual_consumption_cents': month * 10000}]}, selectedMonth: 10, onMonth: (month) => selected = month))));
    await tester.tap(find.text('8月'));
    await tester.pump();
    expect(selected, 8);
    expect(tester.takeException(), isNull);
  });
}
