import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_mobile/data/local_store.dart';
import 'package:ledger_mobile/ledger_controller.dart';
import 'package:ledger_mobile/ui/import_page.dart';

class _Store implements LocalStore {
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
class _Controller extends LedgerController {
  _Controller() : super.forTesting(store:_Store());
  int commits=0;
  final offsets=<int>[];
  @override
  Future<Map<String,dynamic>> reviewImport(String id,int offset) async {
    offsets.add(offset);
    return {'total':61,'offset':offset,'rows':[
      for(var i=offset;i<(offset+50>61 ? 61 : offset+50);i++)
        {'id':'fixture-$i','merchant':'Synthetic $i','occurred_at':'2026-10-01T12:00:00+08:00',
          'amount_cents':100,'direction':'expense','kind':'payment','duplicate':false}
    ]};
  }
  @override
  Future<Map<String,dynamic>> commitImport(String id) async {
    commits++;
    return {'imported':61,'duplicate':0,'skipped':0};
  }
}
void main() {
  testWidgets('import is paginated and requires review plus final confirmation', (tester) async {
    final controller=_Controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:ImportPage(controller:controller,
      initialPreview:const {'preview_id':'fixture-preview','total_rows':61,'new_count':61,'duplicate_count':0,'skipped_count':0}))));
    await tester.pumpAndSettle();
    expect(controller.commits,0);
    await tester.scrollUntilVisible(find.text('下一页'),600,scrollable:find.byType(Scrollable).first,maxScrolls:50);
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    expect(controller.offsets,[0,50]);
    await tester.scrollUntilVisible(find.text('确认导入 61 笔新增流水'),600,scrollable:find.byType(Scrollable).first,maxScrolls:50);
    final commit=find.widgetWithText(FilledButton,'确认导入 61 笔新增流水');
    expect(tester.widget<FilledButton>(commit).onPressed,isNull);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(commit);
    await tester.tap(commit);
    await tester.pumpAndSettle();
    expect(find.text('审核后确认入账'),findsOneWidget);
    expect(controller.commits,0);
    await tester.tap(find.text('确认入账'));
    await tester.pumpAndSettle();
    expect(controller.commits,1);
    expect(find.textContaining('导入完成'),findsOneWidget);
    expect(tester.takeException(),isNull);
  });
}
