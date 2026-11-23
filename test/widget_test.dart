import 'package:cam_board_client/board_controller.dart';
import 'package:cam_board_client/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeAdvertiser advertiser;
  late FakeNameStore store;

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      CamBoardApp(
        controller: BoardController(
          advertiser: advertiser,
          server: FakeServer(),
          nameStore: store,
          findAddress: () async => '192.168.43.1',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    advertiser = FakeAdvertiser();
    store = FakeNameStore();
  });

  testWidgets('一開始顯示名稱輸入框和「註冊」', (tester) async {
    await pumpApp(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('註冊'), findsOneWidget);
    expect(find.text('撤銷註冊'), findsNothing);
  });

  testWidgets('預先填入上次的名字', (tester) async {
    store = FakeNameStore('上次的名字');
    await pumpApp(tester);
    expect(find.text('上次的名字'), findsOneWidget);
  });

  testWidgets('註冊後顯示名稱、等候中、位址和「撤銷註冊」', (tester) async {
    await pumpApp(tester);
    await tester.enterText(find.byType(TextField), '教室白板');
    await tester.tap(find.text('註冊'));
    await tester.pumpAndSettle();

    expect(find.text('教室白板'), findsOneWidget);
    expect(find.text('等候中'), findsOneWidget);
    expect(find.text('192.168.43.1:47800'), findsOneWidget);
    expect(find.text('撤銷註冊'), findsOneWidget);
    expect(advertiser.advertisedName, '教室白板');
  });

  testWidgets('名字空白時顯示原因，留在輸入畫面', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('註冊'));
    await tester.pumpAndSettle();

    expect(find.text('請幫看板取個名字'), findsOneWidget);
    expect(find.text('註冊'), findsOneWidget);
    expect(advertiser.isAdvertising, isFalse);
  });

  testWidgets('廣播失敗時回到輸入畫面並顯示原因', (tester) async {
    advertiser.failOnStart = true;
    await pumpApp(tester);
    await tester.enterText(find.byType(TextField), '教室白板');
    await tester.tap(find.text('註冊'));
    await tester.pumpAndSettle();

    expect(find.text('註冊'), findsOneWidget);
    expect(find.textContaining('註冊失敗'), findsOneWidget);
  });

  testWidgets('按「撤銷註冊」回到輸入畫面，名字還在', (tester) async {
    await pumpApp(tester);
    await tester.enterText(find.byType(TextField), '教室白板');
    await tester.tap(find.text('註冊'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤銷註冊'));
    await tester.pumpAndSettle();

    expect(find.text('註冊'), findsOneWidget);
    expect(find.text('教室白板'), findsOneWidget);
    expect(advertiser.isAdvertising, isFalse);
  });
}
