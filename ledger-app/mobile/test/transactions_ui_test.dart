import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_mobile/data/local_store.dart';
import 'package:ledger_mobile/ledger_controller.dart';
import 'package:ledger_mobile/model/ledger_transaction.dart';
import 'package:ledger_mobile/ui/transactions_page.dart';
import 'package:ledger_mobile/ui/app_theme.dart';

class _UnusedStore implements LocalStore {
  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LedgerRow _row(String merchant, {
  String? category = '餐饮',
  String kind = 'payment',
  String direction = 'expense',
  String date = '2026-10-08T12:00:00',
  bool excluded = false,
  int amount = 2350,
}) => LedgerRow(
  LedgerTransaction.fromJson({
    'id': merchant,
    'source': 'wechat',
    'occurred_at': date,
    'amount_cents': amount,
    'direction': direction,
    'kind': kind,
    'merchant': merchant,
    'description': '测试账单',
    'category': category,
    'excluded': excluded,
  }),
  0,
  false,
);

class _EditController extends LedgerController {
  _EditController() : super.forTesting(store: _UnusedStore());
  LedgerTransaction? saved;
  @override
  Future<void> addTransaction(LedgerTransaction transaction) async { saved = transaction; }
  @override
  Future<void> queueEdit(LedgerTransaction edited, {LedgerTransaction? original}) async { saved = edited; }
}

Finder _field(String label) => find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.labelText == label);

void main() {
  testWidgets('manual entry validates amount and saves an incoming transaction', (tester) async {
    tester.view.physicalSize=const Size(320,880);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final capture=GlobalKey();
    var theme=ledgerTheme(Brightness.light);
    final screenshot=Platform.environment['LEDGER_UI_SCREENSHOT_DIR'];
    if (screenshot != null) {
      await tester.runAsync(() async {
        for(final font in [('LedgerPreview',Platform.environment['LEDGER_UI_FONT']),('MaterialIcons',Platform.environment['LEDGER_UI_ICON_FONT'])]) {
          if(font.$2 == null) continue;
          final bytes=await File(font.$2!).readAsBytes();
          await (FontLoader(font.$1)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        }
      });
      theme=theme.copyWith(textTheme:theme.textTheme.apply(fontFamily:'LedgerPreview'),
        appBarTheme:theme.appBarTheme.copyWith(titleTextStyle:(theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge)?.copyWith(fontFamily:'LedgerPreview')));
    }
    final controller = _EditController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(theme:theme,builder:(_,child)=>RepaintBoundary(key:capture,child:child!),home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () => openNewTransaction(context, controller), child: const Text('Add'))))));
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存账单'));
    await tester.pumpAndSettle();
    expect(controller.saved,isNull);
    expect(find.text('请输入正确金额，最多保留两位小数。'),findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(TransactionEditor))).clearSnackBars();
    await tester.enterText(_field('金额（元）'),'12.34');
    await tester.tap(find.text('收入'));
    await tester.enterText(_field('商户／收付款对象'),'Synthetic payer');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    if(screenshot != null) {
      await tester.runAsync(() async {
        final image=await (capture.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
        final bytes=await image.toByteData(format:ui.ImageByteFormat.png);
        await File('$screenshot/manual-entry-040-320.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('保存账单'));
    await tester.pumpAndSettle();
    expect(controller.saved!.amountCents,1234);
    expect(controller.saved!.direction,'income');
    expect(controller.saved!.merchant,'Synthetic payer');
    expect(controller.saved!.source,'manual');
    expect(tester.takeException(),isNull);
  });

  testWidgets('single imported transaction amount and merchant can be corrected', (tester) async {
    final controller = _EditController();
    addTearDown(controller.dispose);
    final row=_row('Original shop');
    await tester.pumpWidget(MaterialApp(home: TransactionEditor(controller:controller,row:row)));
    await tester.enterText(_field('金额（元）'),'35.60');
    await tester.enterText(_field('商户／收付款对象'),'Corrected shop');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect(controller.saved!.amountCents,3560);
    expect(controller.saved!.merchant,'Corrected shop');
    expect(controller.saved!.id,row.transaction.id);
    expect(controller.saved!.occurredAt,row.transaction.occurredAt);
  });
  testWidgets('category drilldown includes only reportable expenses in the month', (tester) async {
    final controller = LedgerController.forTesting(store: _UnusedStore());
    addTearDown(controller.dispose);
    controller.rows = [
      _row('本月午餐'),
      _row('上月午餐', date: '2026-09-08T12:00:00'),
      _row('已排除', excluded: true),
      _row('退款', kind: 'refund', direction: 'income'),
      _row('转账', kind: 'transfer', excluded: true),
      _row('收入', direction: 'income'),
      _row('交通流水', category: '交通'),
      _row('计入红包', kind: 'red_packet'),
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TransactionsPage(
      controller: controller, category: '餐饮', month: DateTime(2026, 10),
    ))));
    expect(find.text('本月午餐'), findsOneWidget);
    expect(find.text('计入红包'), findsOneWidget);
    expect(find.text('2 笔流水'), findsOneWidget);
    expect(find.text('分类原始消费明细；金额未扣关联退款'), findsOneWidget);
    for (final name in ['上月午餐', '已排除', '退款', '转账', '收入', '交通流水']) {
      expect(find.text(name), findsNothing);
    }
  });

  testWidgets('uncategorized drilldown accepts both null and empty categories', (tester) async {
    final controller = LedgerController.forTesting(store: _UnusedStore());
    addTearDown(controller.dispose);
    controller.rows = [_row('未设置', category: null), _row('空分类', category: ''), _row('显式未分类', category: '未分类'), _row('已有分类')];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TransactionsPage(
      controller: controller, category: '未分类', month: DateTime(2026, 10),
    ))));
    expect(find.text('未设置'), findsOneWidget);
    expect(find.text('空分类'), findsOneWidget);
    expect(find.text('显式未分类'), findsOneWidget);
    expect(find.text('已有分类'), findsNothing);
  });

  testWidgets('large amounts fit a narrow phone and rows still open the editor', (tester) async {
    tester.view.physicalSize = const Size(320, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = LedgerController.forTesting(store: _UnusedStore());
    addTearDown(controller.dispose);
    final row = _row('一个很长的测试商家名称', amount: 987654321098);
    controller.rows = [row];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      TransactionRowTile(controller: controller, row: row),
    ]))));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('微信'), findsOneWidget);
    await tester.tap(find.byType(TransactionRowTile));
    await tester.pumpAndSettle();
    expect(find.text('流水详情'), findsOneWidget);
    expect(find.text('保存修改'), findsOneWidget);
    expect(find.text('修改会保存在本机，联网后自动同步'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
