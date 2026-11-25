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
    // 正常的鄉民端會回覆連線資訊；不回覆的話看板端等一陣子就會結束它。
    h.server.receive(viewerId, const AnswerMessage(sdp: 'answer-sdp'));
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

      final focus = h.camera.focusSteps.last as PointFocus;
      expect(focus.x, closeTo(0.5, 0.01));
      expect(focus.y, closeTo(0.5, 0.01));
      // 點擊對焦後有一個 5 秒的計時，讓它跑完。
      await tester.pump(tapFocusHold);
    });

    testWidgets('預覽畫面比框窄時，點在畫面左緣算畫面的最左邊，點在旁邊的空白不算', (tester) async {
      await pumpApp(tester);
      await register(tester);
      await viewerJoins(tester, 'mac-1');
      // 畫面非常窄（寬是高的五分之一），所以一定只佔框的中間。
      h.camera.previewAspectRatio = 0.2;
      final box = tester.getRect(find.byKey(const Key('preview')));
      final videoWidth = box.height * 0.2;
      final videoLeft = box.center.dx - videoWidth / 2;
      final before = h.camera.focusSteps.length;

      await tester.tapAt(Offset(box.left + 2, box.center.dy));
      await tester.pump();
      expect(h.camera.focusSteps, hasLength(before));

      await tester.tapAt(Offset(videoLeft + 1, box.center.dy));
      await tester.pump();
      final focus = h.camera.focusSteps.last as PointFocus;
      expect(focus.x, closeTo(0, 0.02));
      expect(focus.y, closeTo(0.5, 0.01));
      await tester.pump(tapFocusHold);
    });

    testWidgets('「自動對焦」開關一開始是開的，關掉後鏡頭停在目前的位置', (tester) async {
      await pumpApp(tester);
      await register(tester);
      await viewerJoins(tester, 'mac-1');
      expect(
        tester.widget<Switch>(find.byKey(const Key('autoFocus'))).value,
        isTrue,
      );

      await tester.tap(find.byKey(const Key('autoFocus')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Switch>(find.byKey(const Key('autoFocus'))).value,
        isFalse,
      );
      expect(h.camera.focusSteps.last, isA<HoldFocus>());
    });

    testWidgets('按「拍照」把照片傳給抄錄中的鄉民端，鄉民端收到後跳出提示', (tester) async {
      await pumpApp(tester);
      await register(tester);
      await viewerJoins(tester, 'mac-1');
      h.server.receive('mac-1', const RecordStartMessage());
      await tester.pumpAndSettle();

      await tester.tap(find.text('拍照'));
      await tester.pumpAndSettle();
      expect(h.server.sentBytes['mac-1'], hasLength(1));

      h.server.receive('mac-1', const ShotReceivedMessage(id: 1));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('抄錄了這個內容'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('前一則提示還在畫面上時，新的提示直接蓋掉它，不用等它消失', (tester) async {
      await pumpApp(tester);
      await register(tester);
      h.server.receive('mac-1', const JoinMessage(name: '阿明'));
      h.server.receive('mac-2', const JoinMessage(name: '小華'));
      await tester.pumpAndSettle();
      h.server.receive('mac-1', const AnswerMessage(sdp: 'answer-sdp'));
      h.server.receive('mac-2', const AnswerMessage(sdp: 'answer-sdp'));
      await tester.pumpAndSettle();
      h.server.receive('mac-1', const RecordStartMessage());
      h.server.receive('mac-2', const RecordStartMessage());
      await tester.pumpAndSettle();
      await tester.tap(find.text('拍照'));
      await tester.pumpAndSettle();

      h.server.receive('mac-1', const ShotReceivedMessage(id: 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('阿明抄錄了這個內容'), findsOneWidget);

      // 第一則還要好幾秒才會自己消失，這時來了第二則。
      h.server.receive('mac-2', const ShotReceivedMessage(id: 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('小華抄錄了這個內容'), findsOneWidget);
      expect(find.text('阿明抄錄了這個內容'), findsNothing);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });
  });
}
