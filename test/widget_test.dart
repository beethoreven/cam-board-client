import 'package:cam_board_client/main.dart';
import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide pumpEventQueue;

import 'fakes.dart';

void main() {
  late Harness h;

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(CamBoardApp(controller: h.controller));
    await tester.pumpAndSettle();
  }

  Future<void> register(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), '教室白板');
    await tester.tap(find.text('註冊'));
    await tester.pumpAndSettle();
  }

  /// 模擬一個鄉民端加入，並讓畫面更新。
  Future<void> viewerJoins(WidgetTester tester, String viewerId) async {
    h.server.receive(viewerId, const JoinMessage());
    await tester.pumpAndSettle();
  }

  setUp(() => h = Harness());

  group('註冊', () {
    testWidgets('一開始顯示名稱輸入框和「註冊」', (tester) async {
      await pumpApp(tester);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('註冊'), findsOneWidget);
      expect(find.text('撤銷註冊'), findsNothing);
    });

    testWidgets('預先填入上次的名字', (tester) async {
      h.store = FakeNameStore('上次的名字');
      await pumpApp(tester);
      expect(find.text('上次的名字'), findsOneWidget);
    });

    testWidgets('註冊後顯示名稱、等候中、位址和「撤銷註冊」', (tester) async {
      await pumpApp(tester);
      await register(tester);

      expect(find.text('教室白板'), findsOneWidget);
      expect(find.text('等候中'), findsOneWidget);
      expect(find.text('192.168.43.1:47800'), findsOneWidget);
      expect(find.text('撤銷註冊'), findsOneWidget);
      expect(h.advertiser.advertisedName, '教室白板');
    });

    testWidgets('名字空白時顯示原因，留在輸入畫面', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('註冊'));
      await tester.pumpAndSettle();

      expect(find.text('請幫看板取個名字'), findsOneWidget);
      expect(find.text('註冊'), findsOneWidget);
      expect(h.advertiser.isAdvertising, isFalse);
    });

    testWidgets('相機權限被拒絕時顯示原因', (tester) async {
      h.camera.permissionDenied = true;
      await pumpApp(tester);
      await register(tester);

      expect(find.text('需要相機權限才能註冊'), findsOneWidget);
      expect(find.text('註冊'), findsOneWidget);
    });

    testWidgets('廣播失敗時回到輸入畫面並顯示原因', (tester) async {
      h.advertiser.failOnStart = true;
      await pumpApp(tester);
      await register(tester);

      expect(find.text('註冊'), findsOneWidget);
      expect(find.textContaining('註冊失敗'), findsOneWidget);
    });

    testWidgets('按「撤銷註冊」回到輸入畫面，名字還在', (tester) async {
      await pumpApp(tester);
      await register(tester);
      await tester.tap(find.text('撤銷註冊'));
      await tester.pumpAndSettle();

      expect(find.text('註冊'), findsOneWidget);
      expect(find.text('教室白板'), findsOneWidget);
      expect(h.advertiser.isAdvertising, isFalse);
    });
  });

  group('有鄉民端在看', () {
    testWidgets('顯示人數、「切換鏡頭」和「不給看了」', (tester) async {
      await pumpApp(tester);
      await register(tester);
      await viewerJoins(tester, 'mac-1');

      expect(find.text('1 個鄉民端正在看'), findsOneWidget);
      expect(find.text('切換鏡頭'), findsOneWidget);
      expect(find.text('不給看了'), findsOneWidget);
      expect(find.text('等候中'), findsNothing);
    });

    testWidgets('第二個人加入時人數更新', (tester) async {
      await pumpApp(tester);
      await register(tester);
      await viewerJoins(tester, 'mac-1');
      await viewerJoins(tester, 'mac-2');

      expect(find.text('2 個鄉民端正在看'), findsOneWidget);
    });

    testWidgets('按「不給看了」回到等候中，看板仍然註冊著', (tester) async {
      await pumpApp(tester);
      await register(tester);
      await viewerJoins(tester, 'mac-1');
      await tester.tap(find.text('不給看了'));
      await tester.pumpAndSettle();

      expect(find.text('等候中'), findsOneWidget);
      expect(find.text('撤銷註冊'), findsOneWidget);
      expect(h.server.dismissed['mac-1'], ByeReason.boardStopped);
      expect(h.advertiser.isAdvertising, isTrue);
    });

    testWidgets('最後一個人離開後自動回到等候中', (tester) async {
      await pumpApp(tester);
      await register(tester);
      await viewerJoins(tester, 'mac-1');

      h.server.receive('mac-1', const ByeMessage(ByeReason.viewerLeft));
      await tester.pumpAndSettle();

      expect(find.text('等候中'), findsOneWidget);
    });

    testWidgets('按「切換鏡頭」會切換', (tester) async {
      await pumpApp(tester);
      await register(tester);
      await viewerJoins(tester, 'mac-1');
      await tester.tap(find.text('切換鏡頭'));
      await tester.pumpAndSettle();

      expect(h.camera.switchCount, 1);
    });

    testWidgets('點預覽畫面的正中央會對畫面中央對焦', (tester) async {
      await pumpApp(tester);
      await register(tester);
      await viewerJoins(tester, 'mac-1');
      await tester.tap(find.byKey(const Key('preview')));
      await tester.pumpAndSettle();

      final (x, y) = h.camera.focusPoints.single;
      expect(x, closeTo(0.5, 0.01));
      expect(y, closeTo(0.5, 0.01));
    });
  });
}
