import 'dart:async';
import 'dart:typed_data';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart' hide pumpEventQueue;

import 'fakes.dart';

void main() {
  late Harness h;

  setUp(() => h = Harness());

  group('註冊與撤銷', () {
    test('註冊成功：開始廣播、顯示位址、記住名字、螢幕恆亮', () async {
      await h.controller.register(' 教室白板 ');

      expect(h.controller.state, BoardState.waiting);
      expect(h.controller.boardName, '教室白板');
      expect(h.controller.address, '192.168.43.1:47800');
      expect(h.controller.error, isNull);
      expect(h.advertiser.advertisedName, '教室白板');
      expect(h.advertiser.advertisedPort, 47800);
      expect(h.server.running, isTrue);
      expect(h.store.saved, '教室白板');
      expect(h.awake.enabled, isTrue);
      expect(h.camera.isOpen, isFalse, reason: '沒人在看時不該開著鏡頭');
    });

    test('名字不合規定：不註冊，也不碰網路', () async {
      await h.controller.register('   ');

      expect(h.controller.state, BoardState.unregistered);
      expect(h.controller.error, isNotNull);
      expect(h.advertiser.isAdvertising, isFalse);
      expect(h.server.running, isFalse);
      expect(h.store.saved, isNull);
    });

    test('相機權限被拒絕：不註冊，並說明原因', () async {
      h.camera.permissionDenied = true;
      await h.controller.register('教室白板');

      expect(h.controller.state, BoardState.unregistered);
      expect(h.controller.error, contains('相機權限'));
      expect(h.advertiser.isAdvertising, isFalse);
      expect(h.server.running, isFalse);
    });

    test('廣播失敗：退回未註冊，伺服器也要關掉', () async {
      h.advertiser.failOnStart = true;
      await h.controller.register('教室白板');

      expect(h.controller.state, BoardState.unregistered);
      expect(h.controller.error, isNotNull);
      expect(h.server.running, isFalse);
      expect(h.awake.enabled, isFalse);
      expect(h.controller.busy, isFalse);
    });

    test('伺服器開不起來：退回未註冊，不會開始廣播', () async {
      h.server.failOnStart = true;
      await h.controller.register('教室白板');

      expect(h.controller.state, BoardState.unregistered);
      expect(h.controller.error, isNotNull);
      expect(h.advertiser.isAdvertising, isFalse);
    });

    test('失敗之後可以再註冊一次', () async {
      h.advertiser.failOnStart = true;
      await h.controller.register('教室白板');

      h.advertiser.failOnStart = false;
      await h.controller.register('教室白板');
      expect(h.controller.state, BoardState.waiting);
      expect(h.controller.error, isNull);
    });

    test('找不到區域網路位址：仍然註冊，位址是空的', () async {
      h.lanAddress = null;
      await h.controller.register('教室白板');

      expect(h.controller.state, BoardState.waiting);
      expect(h.controller.address, isNull);
    });

    test('撤銷註冊：停止廣播、關掉伺服器、關掉螢幕恆亮', () async {
      await h.controller.register('教室白板');
      await h.controller.unregister();

      expect(h.controller.state, BoardState.unregistered);
      expect(h.controller.boardName, isNull);
      expect(h.controller.address, isNull);
      expect(h.advertiser.isAdvertising, isFalse);
      expect(h.server.running, isFalse);
      expect(h.awake.enabled, isFalse);
    });

    test('已經註冊時再按註冊不會有作用', () async {
      await h.controller.register('第一個');
      await h.controller.register('第二個');
      expect(h.controller.boardName, '第一個');
    });

    test('讀得到上次存的名字', () async {
      h.store = FakeNameStore('上次的名字');
      expect(await h.controller.loadSavedName(), '上次的名字');
    });
  });

  group('鄉民端加入與離開', () {
    setUp(() => h.controller.register('教室白板'));

    test('第一個鄉民端加入：開鏡頭、送出連線資訊、變成顯示中', () async {
      await h.join('mac-1');

      expect(h.controller.state, BoardState.showing);
      expect(h.controller.viewerCount, 1);
      expect(h.camera.isOpen, isTrue);
      final offer = h.server.sent['mac-1']!.single as OfferMessage;
      expect(offer.sdp, 'offer-sdp');
    });

    test('沒註冊時有人要加入：不理會', () async {
      await h.controller.unregister();
      await h.join('mac-1');

      expect(h.controller.viewerCount, 0);
      expect(h.camera.isOpen, isFalse);
    });

    test('版本不同的鄉民端被拒絕，並告知原因', () async {
      await h.join('mac-old', protocol: 999);

      expect(h.server.dismissed['mac-old'], ByeReason.versionMismatch);
      expect(h.controller.state, BoardState.waiting);
    });

    test('鄉民端的回覆和網路路徑會交給它自己的連線', () async {
      await h.join('mac-1');
      await h.join('mac-2');
      const candidate = CandidateMessage(candidate: 'c1', sdpMid: '0');

      h.server.receive('mac-2', const AnswerMessage(sdp: 'answer-2'));
      h.server.receive('mac-2', candidate);
      await pumpEventQueue();

      expect(h.links[0].answer, isNull);
      expect(h.links[1].answer, 'answer-2');
      expect(h.links[1].candidates, [candidate]);
    });

    test('看板端找到的網路路徑會送給對應的鄉民端', () async {
      await h.join('mac-1');
      const candidate = CandidateMessage(candidate: 'mine');

      h.links.single.emitCandidate(candidate);

      expect(h.server.sent['mac-1']!.last, candidate);
    });

    test('網路路徑全部找完時，告訴對應的鄉民端送完了', () async {
      await h.join('mac-1');
      await h.join('mac-2');

      h.links[1].emitCandidatesDone();

      expect(h.server.sent['mac-2']!.last, isA<CandidatesDoneMessage>());
      expect(
        h.server.sent['mac-1'],
        isNot(contains(isA<CandidatesDoneMessage>())),
      );
    });

    test('多個鄉民端可以同時看，共用同一個鏡頭', () async {
      await h.join('mac-1');
      await h.join('mac-2');

      expect(h.controller.viewerCount, 2);
      expect(h.links, hasLength(2));
    });

    test('同一個鄉民端重複送加入：只算一次', () async {
      await h.join('mac-1');
      await h.join('mac-1');

      expect(h.controller.viewerCount, 1);
      expect(h.links, hasLength(1));
    });

    test('一個人按「不看了」：其他人繼續看，鏡頭不關', () async {
      await h.join('mac-1');
      await h.join('mac-2');

      h.server.receive('mac-1', const ByeMessage(ByeReason.viewerLeft));
      await pumpEventQueue();

      expect(h.controller.viewerCount, 1);
      expect(h.links[0].closed, isTrue);
      expect(h.links[1].closed, isFalse);
      expect(h.camera.isOpen, isTrue);
    });

    test('最後一個人離開：關鏡頭，回到等候中', () async {
      await h.join('mac-1');
      h.server.receive('mac-1', const ByeMessage(ByeReason.viewerLeft));
      await pumpEventQueue();

      expect(h.controller.state, BoardState.waiting);
      expect(h.camera.isOpen, isFalse);
      expect(h.advertiser.isAdvertising, isTrue, reason: '看板仍然在清單上');
    });

    test('鄉民端的連線斷了：當成離開', () async {
      await h.join('mac-1');
      h.server.drop('mac-1');
      await pumpEventQueue();

      expect(h.controller.state, BoardState.waiting);
      expect(h.links.single.closed, isTrue);
    });

    test('視訊連線中斷：當成離開', () async {
      await h.join('mac-1');
      h.links.single.lose();
      await pumpEventQueue();

      expect(h.controller.state, BoardState.waiting);
      expect(h.camera.isOpen, isFalse);
    });

    test('鏡頭被系統收走又開不回來：只結束這個鄉民端，看板仍在等候', () async {
      h.camera.isOpen = false;
      h.camera.failOnOpen = true;
      await h.join('mac-1');

      expect(h.server.dismissed['mac-1'], ByeReason.boardStopped);
      expect(h.controller.state, BoardState.waiting);
    });

    test('視訊連線建不起來：只結束這個鄉民端', () async {
      h.failOnCreateLink = true;
      await h.join('mac-1');

      expect(h.server.dismissed['mac-1'], ByeReason.boardStopped);
      expect(h.controller.state, BoardState.waiting);
    });
  });

  group('「不給看了」與撤銷', () {
    setUp(() async {
      await h.controller.register('教室白板');
      await h.join('mac-1');
      await h.join('mac-2');
    });

    test('「不給看了」：通知所有鄉民端、關鏡頭，看板仍在清單上', () async {
      await h.controller.stopShowing();

      expect(h.server.dismissed, {
        'mac-1': ByeReason.boardStopped,
        'mac-2': ByeReason.boardStopped,
      });
      expect(h.links.every((link) => link.closed), isTrue);
      expect(h.camera.isOpen, isFalse);
      expect(h.controller.state, BoardState.waiting);
      expect(h.advertiser.isAdvertising, isTrue);
      expect(h.server.running, isTrue);
    });

    test('「不給看了」之後，鄉民端可以再連進來', () async {
      await h.controller.stopShowing();
      await h.join('mac-3');

      expect(h.controller.state, BoardState.showing);
      expect(h.camera.isOpen, isTrue);
    });

    test('有人在看時撤銷註冊：通知所有鄉民端並從清單消失', () async {
      await h.controller.unregister();

      expect(h.server.dismissed, {
        'mac-1': ByeReason.boardUnregistered,
        'mac-2': ByeReason.boardUnregistered,
      });
      expect(h.camera.isOpen, isFalse);
      expect(h.controller.state, BoardState.unregistered);
      expect(h.advertiser.isAdvertising, isFalse);
    });
  });

  group('鏡頭控制', () {
    setUp(() async {
      await h.controller.register('教室白板');
      await h.join('mac-1');
      // 鏡頭剛開時會套用一次設定，清掉它，下面每個測試只看自己造成的。
      h.camera.applied.clear();
    });

    test('雙指縮放會設定鏡頭倍率', () async {
      h.controller.pinchStarted();
      await h.controller.pinchUpdated(2);

      expect(h.controller.zoom, 2);
      expect(h.camera.zooms, [2]);
    });

    test('第二次手勢從上一次的倍率接續', () async {
      h.controller.pinchStarted();
      await h.controller.pinchUpdated(2);
      h.controller.pinchStarted();
      await h.controller.pinchUpdated(1.5);

      expect(h.controller.zoom, 3);
    });

    test('倍率不會超出範圍', () async {
      h.controller.pinchStarted();
      await h.controller.pinchUpdated(100);
      expect(h.controller.zoom, maxZoom);

      h.controller.pinchStarted();
      await h.controller.pinchUpdated(0.001);
      expect(h.controller.zoom, minZoom);
    });

    test('倍率沒變時不重複設定鏡頭', () async {
      h.controller.pinchStarted();
      await h.controller.pinchUpdated(1);
      expect(h.camera.zooms, isEmpty);
    });

    test('只改倍率時對焦維持自動，不會觸發新的對焦', () async {
      h.controller.pinchStarted();
      await h.controller.pinchUpdated(2);

      expect(h.camera.applied.single.zoom, 2);
      expect(h.camera.applied.single.focus, isA<ContinuousFocus>());
    });

    test('點擊對焦會把位置交給鏡頭，超出畫面的位置拉回邊緣', () async {
      await h.controller.focusAt(0.25, 0.75);
      await h.controller.focusAt(1.4, -0.2);

      expect(h.camera.focusSteps, [
        const PointFocus(0.25, 0.75),
        const PointFocus(1.0, 0.0),
      ]);
    });

    test('放大中點擊對焦，倍率跟著對焦一起送給鏡頭，縮放不會掉回去', () async {
      h.controller.pinchStarted();
      await h.controller.pinchUpdated(3);
      await h.controller.focusAt(0.5, 0.5);

      // 對焦和接著補上的固定距離，都帶著同一個倍率。
      final steps = h.camera.applied;
      expect(steps[steps.length - 2], (
        zoom: 3.0,
        focus: const PointFocus(0.5, 0.5),
      ));
      expect(steps.last, (zoom: 3.0, focus: const DistanceFocus(2.5)));
      expect(h.controller.zoom, 3);
    });

    test('點擊對焦後再改倍率，對焦留在剛才鎖住的距離', () async {
      h.camera.reportedDistance = 4.2;
      await h.controller.focusAt(0.5, 0.5);
      h.controller.pinchStarted();
      await h.controller.pinchUpdated(2);

      expect(h.camera.applied.last, (
        zoom: 2.0,
        focus: const DistanceFocus(4.2),
      ));
    });

    test('切換鏡頭後倍率回到 1 倍', () async {
      h.controller.pinchStarted();
      await h.controller.pinchUpdated(3);
      await h.controller.switchCamera();

      expect(h.camera.switchCount, 1);
      expect(h.controller.zoom, minZoom);
    });

    test('鏡頭不支援這些控制時不會出錯，觀看照常進行', () async {
      h.camera.controlsUnsupported = true;

      h.controller.pinchStarted();
      await h.controller.pinchUpdated(2);
      await h.controller.focusAt(0.5, 0.5);
      await h.controller.switchCamera();

      expect(h.controller.state, BoardState.showing);
      expect(h.controller.viewerCount, 1);
      expect(h.camera.isOpen, isTrue);
    });

    test('切換鏡頭後，自動對焦開著就繼續自動對焦', () async {
      await h.controller.switchCamera();

      expect(h.camera.applied.last, (
        zoom: minZoom,
        focus: const ContinuousFocus(),
      ));
    });

    test('所有人離開後倍率回到 1 倍', () async {
      h.controller.pinchStarted();
      await h.controller.pinchUpdated(3);
      await h.controller.stopShowing();

      expect(h.controller.zoom, minZoom);
    });
  });

  group('自動對焦開關', () {
    setUp(() async {
      await h.controller.register('教室白板');
      await h.join('mac-1');
      h.camera.applied.clear();
    });

    test('註冊後開關是開的，鏡頭一開就是自動對焦', () async {
      final fresh = Harness();
      await fresh.controller.register('教室白板');
      await fresh.join('mac-1');

      expect(fresh.controller.autoFocus, isTrue);
      expect(fresh.camera.applied.single, (
        zoom: minZoom,
        focus: const ContinuousFocus(),
      ));
    });

    test('開著時點擊對焦：5 秒內不自動對焦，時間到才恢復', () {
      fakeAsync((async) {
        h.controller.focusAt(0.3, 0.3);
        async.flushMicrotasks();
        expect(h.camera.focusSteps, [const PointFocus(0.3, 0.3)]);

        async.elapse(tapFocusHold - const Duration(milliseconds: 1));
        expect(h.camera.focusSteps, hasLength(1));

        async.elapse(const Duration(milliseconds: 1));
        expect(h.camera.focusSteps.last, isA<ContinuousFocus>());
      });
    });

    test('5 秒內再點一次，重新計時', () {
      fakeAsync((async) {
        h.controller.focusAt(0.3, 0.3);
        async.elapse(const Duration(seconds: 4));
        h.controller.focusAt(0.6, 0.6);
        async.elapse(const Duration(seconds: 4));

        expect(h.camera.focusSteps, [
          const PointFocus(0.3, 0.3),
          const PointFocus(0.6, 0.6),
        ]);

        async.elapse(const Duration(seconds: 1));
        expect(h.camera.focusSteps.last, isA<ContinuousFocus>());
      });
    });

    test('連點兩次時，比較晚回報的第一次不會蓋掉第二次鎖住的距離', () async {
      await h.controller.setAutoFocus(false);
      final slow = Completer<void>();
      h.camera
        ..reportedDistance = 1.0
        ..nextFocusGate = slow;
      final first = h.controller.focusAt(0.2, 0.2);
      h.camera.reportedDistance = 7.0;
      await h.controller.focusAt(0.8, 0.8);
      slow.complete();
      await first;

      h.controller.pinchStarted();
      await h.controller.pinchUpdated(2);

      expect(h.camera.focusSteps.last, const DistanceFocus(7.0));
    });

    test('關掉開關：停在目前的位置', () async {
      await h.controller.setAutoFocus(false);

      expect(h.controller.autoFocus, isFalse);
      expect(h.camera.focusSteps.single, isA<HoldFocus>());
    });

    test('關掉開關：鏡頭回報距離後，直接固定在那個距離', () async {
      h.camera.reportedDistance = 4.2;
      await h.controller.setAutoFocus(false);

      expect(h.camera.focuses, [isA<HoldFocus>(), const DistanceFocus(4.2)]);
    });

    test('關著時點擊對焦：對好之後固定在新的距離', () async {
      await h.controller.setAutoFocus(false);
      h.camera.reportedDistance = 9.0;
      await h.controller.focusAt(0.3, 0.3);

      expect(h.camera.focuses.last, const DistanceFocus(9.0));
    });

    test('鏡頭沒回報距離時，不另外固定', () async {
      h.camera.reportedDistance = null;
      await h.controller.setAutoFocus(false);

      expect(h.camera.focuses, [isA<HoldFocus>()]);
    });

    test('這支手機不能直接設定距離時，固定失敗也不會一直重試', () async {
      h.camera.distanceUnsupported = true;
      await h.controller.setAutoFocus(false);

      expect(h.camera.focuses, [isA<HoldFocus>(), const DistanceFocus(2.5)]);
    });

    test('關著時點擊對焦：過多久都不會恢復自動對焦', () {
      fakeAsync((async) {
        h.controller.setAutoFocus(false);
        h.controller.focusAt(0.3, 0.3);
        async.elapse(tapFocusHold * 3);

        expect(h.camera.focusSteps, [
          isA<HoldFocus>(),
          const PointFocus(0.3, 0.3),
        ]);
      });
    });

    test('點擊對焦的 5 秒內關掉開關，時間到也不會恢復自動對焦', () {
      fakeAsync((async) {
        h.controller.focusAt(0.3, 0.3);
        async.elapse(const Duration(seconds: 1));
        h.controller.setAutoFocus(false);
        async.elapse(tapFocusHold * 2);

        expect(h.camera.focusSteps.last, isA<HoldFocus>());
      });
    });

    test('再打開開關：恢復自動對焦', () async {
      await h.controller.setAutoFocus(false);
      await h.controller.setAutoFocus(true);

      expect(h.camera.focusSteps.last, isA<ContinuousFocus>());
    });

    test('鄉民端離開再回來，鏡頭重開時套回鎖住的對焦距離', () async {
      h.camera.reportedDistance = 4.2;
      await h.controller.setAutoFocus(false);
      await h.controller.focusAt(0.5, 0.5);
      h.server.drop('mac-1');
      await pumpEventQueue();
      expect(h.camera.isOpen, isFalse);
      h.camera.applied.clear();

      await h.join('mac-2');

      expect(h.controller.autoFocus, isFalse);
      expect(h.camera.applied.single, (
        zoom: minZoom,
        focus: const DistanceFocus(4.2),
      ));
    });

    test('鏡頭被系統收走，回到前景重開時套回鎖住的對焦距離', () async {
      h.camera.reportedDistance = 4.2;
      await h.controller.setAutoFocus(false);
      await h.controller.focusAt(0.5, 0.5);
      h.camera.isOpen = false;
      h.camera.applied.clear();

      await h.controller.ensureCameraAlive();

      expect(h.camera.isOpen, isTrue);

      expect(h.controller.autoFocus, isFalse);
      expect(h.camera.applied.single, (
        zoom: minZoom,
        focus: const DistanceFocus(4.2),
      ));
    });

    test('手機不能直接設定對焦距離時，鏡頭重開後改對畫面中央對焦一次', () async {
      h.camera.reportedDistance = 4.2;
      h.camera.distanceUnsupported = true;
      await h.controller.setAutoFocus(false);
      h.camera.isOpen = false;
      h.camera.applied.clear();

      await h.controller.ensureCameraAlive();

      expect(h.camera.focusSteps, [
        const DistanceFocus(4.2),
        const PointFocus(0.5, 0.5),
      ]);
    });

    test('切換鏡頭後，開關關著就對畫面中央重新對焦，不沿用另一顆的距離', () async {
      await h.controller.setAutoFocus(false);
      await h.controller.switchCamera();

      expect(h.camera.focusSteps.last, const PointFocus(0.5, 0.5));
    });

    test('撤銷註冊後重新註冊，開關回到開著', () async {
      await h.controller.setAutoFocus(false);
      await h.controller.unregister();
      await h.controller.register('教室白板');

      expect(h.controller.autoFocus, isTrue);
    });
  });

  group('拍照', () {
    late List<String> notices;

    setUp(() async {
      await h.controller.register('教室白板');
      notices = [];
      h.controller.notices.listen(notices.add);
    });

    test('沒有人在抄錄時不做任何事', () async {
      await h.join('mac-1', name: '阿明');
      await h.controller.takeShot();

      expect(h.camera.captureCount, 0);
      expect(h.server.sentBytes, isEmpty);
    });

    test('只把照片傳給抄錄中的鄉民端，先送說明再送照片', () async {
      await h.join('mac-1', name: '阿明');
      await h.joinRecording('mac-2', name: '小華');
      await h.controller.takeShot();

      expect(h.camera.captureCount, 1);
      final shot = h.server.sent['mac-2']!.last as ShotMessage;
      // 說明裡帶著畫面的寬、高和要轉幾度，後面的資料是還沒壓縮的畫面。
      expect((shot.width, shot.height, shot.rotation), (4, 2, 90));
      expect(h.server.sentBytes['mac-2']!.single, h.camera.frame!.i420);
      expect(h.server.sentBytes['mac-2']!.single, hasLength(shot.bytes));
      expect(h.server.sentBytes['mac-1'], isNull);
      expect(h.server.sent['mac-1'], isNot(contains(isA<ShotMessage>())));
    });

    test('多個鄉民端在抄錄時拍一次，每個都收到同一張', () async {
      await h.joinRecording('mac-1', name: '阿明');
      await h.joinRecording('mac-2', name: '小華');
      await h.controller.takeShot();

      expect(h.camera.captureCount, 1);
      final first = h.server.sent['mac-1']!.last as ShotMessage;
      final second = h.server.sent['mac-2']!.last as ShotMessage;
      expect(first.id, second.id);
    });

    test('每張照片的編號不同', () async {
      await h.joinRecording('mac-1', name: '阿明');
      await h.controller.takeShot();
      await h.controller.takeShot();

      final ids = h.server.sent['mac-1']!.whereType<ShotMessage>().map(
        (shot) => shot.id,
      );
      expect(ids.toSet(), hasLength(2));
    });

    test('鄉民端抄錄完了之後就不再傳給它', () async {
      await h.joinRecording('mac-1', name: '阿明');
      h.server.receive('mac-1', const RecordStopMessage());
      await pumpEventQueue();
      await h.controller.takeShot();

      expect(h.camera.captureCount, 0);
    });

    test('鄉民端說收到了，才跳出誰抄錄了的提示', () async {
      await h.joinRecording('mac-1', name: '阿明');
      await h.controller.takeShot();
      await pumpEventQueue();
      expect(notices, isEmpty);

      h.server.receive('mac-1', const ShotReceivedMessage(id: 1));
      await pumpEventQueue();

      expect(notices, ['阿明抄錄了這個內容']);
    });

    test('拍照失敗時提示，而且之後還能再拍', () async {
      await h.joinRecording('mac-1', name: '阿明');
      h.camera.frame = null;
      await h.controller.takeShot();
      await pumpEventQueue();

      expect(notices, ['拍照失敗']);
      expect(h.controller.shooting, isFalse);
      expect(h.server.sentBytes, isEmpty);
    });

    test('不給看了之後，沒有人算在抄錄', () async {
      await h.joinRecording('mac-1', name: '阿明');
      await h.controller.stopShowing();
      await h.join('mac-1', name: '阿明');
      await h.controller.takeShot();

      expect(h.camera.captureCount, 0);
    });
  });

  group('加入到一半發生別的事', () {
    test('鏡頭補開到一半鄉民端就斷線：不會留下一個沒人的觀看', () async {
      await h.controller.register('教室白板');
      // 鏡頭被系統收走了，下一個鄉民端加入時要補開，而且要花時間。
      h.camera.isOpen = false;
      h.camera.openGate = Completer<void>();
      h.server.receive('mac-1', const JoinMessage());
      await pumpEventQueue();
      h.server.drop('mac-1');
      await pumpEventQueue();
      h.camera.openGate!.complete();
      await pumpEventQueue();

      expect(h.controller.viewerCount, 0);
      expect(h.controller.state, BoardState.waiting);
      expect(h.links.single.closed, isTrue);
    });

    test('鏡頭還在開的時候第二個人加入：鏡頭只開一次，兩個人都看得到', () async {
      await h.controller.register('教室白板');
      h.camera.openGate = Completer<void>();
      h.server.receive('mac-1', const JoinMessage());
      h.server.receive('mac-2', const JoinMessage());
      await pumpEventQueue();
      h.camera.openGate!.complete();
      await pumpEventQueue();

      expect(h.camera.openCount, 1);
      expect(h.controller.viewerCount, 2);
      expect(h.links, hasLength(2));
    });

    test('同一個鄉民端連送兩次「我要看」：只建一條連線', () async {
      await h.controller.register('教室白板');
      h.camera.openGate = Completer<void>();
      h.server.receive('mac-1', const JoinMessage());
      h.server.receive('mac-1', const JoinMessage());
      await pumpEventQueue();
      h.camera.openGate!.complete();
      await pumpEventQueue();

      expect(h.links, hasLength(1));
      expect(h.controller.viewerCount, 1);
    });

    test('鏡頭還在開的時候按「撤銷註冊」：加入的人被結束，鏡頭不會留著', () async {
      await h.controller.register('教室白板');
      h.camera.openGate = Completer<void>();
      h.server.receive('mac-1', const JoinMessage());
      await pumpEventQueue();
      final unregistering = h.controller.unregister();
      h.camera.openGate!.complete();
      await unregistering;

      expect(h.controller.state, BoardState.unregistered);
      expect(h.camera.isOpen, isFalse);
      expect(h.server.dismissed['mac-1'], ByeReason.boardUnregistered);
    });

    test('鏡頭剛開要對焦，但不等對焦做完就先送出連線資訊', () async {
      await h.controller.register('教室白板');
      h.camera.nextFocusGate = Completer<void>();
      await h.join('mac-1');

      expect(h.server.sent['mac-1']!.whereType<OfferMessage>(), hasLength(1));
    });
  });

  group('鄉民端沒有照規矩來', () {
    test('加入之後一直不回覆連線資訊：時間到就結束它，鏡頭關掉', () {
      fakeAsync((async) {
        h.controller.register('教室白板');
        async.flushMicrotasks();
        h.server.receive('mac-1', const JoinMessage());
        async.flushMicrotasks();
        expect(h.camera.isOpen, isTrue);

        async.elapse(const Duration(seconds: 11));

        expect(h.server.dismissed['mac-1'], ByeReason.boardStopped);
        expect(h.controller.viewerCount, 0);
        expect(h.camera.isOpen, isFalse);
      });
    });

    test('有回覆的不受影響', () {
      fakeAsync((async) {
        h.controller.register('教室白板');
        async.flushMicrotasks();
        h.server.receive('mac-1', const JoinMessage());
        async.flushMicrotasks();
        h.server.receive('mac-1', const AnswerMessage(sdp: 'answer-sdp'));
        async.elapse(const Duration(seconds: 30));

        expect(h.server.dismissed, isEmpty);
        expect(h.controller.viewerCount, 1);
      });
    });

    test('畫面的連線斷了：告訴鄉民端結束了，不只是自己收掉', () async {
      await h.controller.register('教室白板');
      await h.join('mac-1');
      h.links.single.lose();
      await pumpEventQueue();

      expect(h.server.dismissed['mac-1'], ByeReason.boardStopped);
      expect(h.controller.viewerCount, 0);
    });

    test('沒傳過照片給它，它卻回報收到：不跳提示', () async {
      final notices = <String>[];
      h.controller.notices.listen(notices.add);
      await h.controller.register('教室白板');
      await h.join('mac-1', name: '阿明');
      h.server.receive('mac-1', const ShotReceivedMessage(id: 1));
      await pumpEventQueue();

      expect(notices, isEmpty);
    });

    test('同一張照片回報兩次：只跳一次提示', () async {
      final notices = <String>[];
      h.controller.notices.listen(notices.add);
      await h.controller.register('教室白板');
      await h.joinRecording('mac-1', name: '阿明');
      await h.controller.takeShot();
      h.server.receive('mac-1', const ShotReceivedMessage(id: 1));
      h.server.receive('mac-1', const ShotReceivedMessage(id: 1));
      await pumpEventQueue();

      expect(notices, ['阿明抄錄了這個內容']);
    });
  });

  group('其他', () {
    test('對焦還沒做完時縮放：不打斷對焦，對焦完再把倍率補上', () async {
      await h.controller.register('教室白板');
      await h.join('mac-1');
      h.camera.applied.clear();
      final gate = h.camera.nextFocusGate = Completer<void>();
      final focusing = h.controller.focusAt(0.5, 0.5);
      await pumpEventQueue();
      h.controller.pinchStarted();
      await h.controller.pinchUpdated(2);

      expect(h.camera.applied, hasLength(1), reason: '對焦期間不該再送設定');

      gate.complete();
      await focusing;
      expect(h.camera.applied.last.zoom, h.controller.zoom);
      expect(h.controller.zoom, greaterThan(1));
    });

    test('換了網路之後重新找位址', () async {
      await h.controller.register('教室白板');
      h.lanAddress = '10.0.0.7';
      await h.controller.refreshAddress();

      expect(h.controller.address, '10.0.0.7:47800');
    });

    test('廣播途中出問題會提示', () async {
      final notices = <String>[];
      h.controller.notices.listen(notices.add);
      await h.controller.register('教室白板');
      h.advertiser.emitProblem('廣播停止了');
      await pumpEventQueue();

      expect(notices, ['廣播停止了']);
    });
  });

  group('鏡頭跟著鄉民端開關', () {
    setUp(() => h.controller.register('教室白板'));

    test('註冊後沒有人在看：鏡頭不開', () async {
      expect(h.camera.isOpen, isFalse);
      expect(h.camera.openCount, 0);
    });

    test('第一個鄉民端來才開，還有人在看就不關', () async {
      await h.join('mac-1');
      await h.join('mac-2');
      h.server.receive('mac-1', const ByeMessage(ByeReason.viewerLeft));
      await pumpEventQueue();

      expect(h.camera.isOpen, isTrue);
      expect(h.camera.openCount, 1);
    });

    test('重建視訊連線不會把鏡頭關掉再開', () async {
      await h.join('mac-1', session: 's1');
      h.server.receive('mac-1', const VideoRestartMessage());
      await pumpEventQueue();

      expect(h.camera.isOpen, isTrue);
      expect(h.camera.openCount, 1);
    });

    test('換一條新的連線接回來也不會動到鏡頭', () async {
      await h.join('mac-1', session: 's1');
      h.server.receive('new-socket', const ResumeMessage(session: 's1'));
      await pumpEventQueue();

      expect(h.camera.isOpen, isTrue);
      expect(h.camera.openCount, 1);
    });

    test('回到前景時沒有人在看：不開鏡頭', () async {
      await h.controller.ensureCameraAlive();

      expect(h.camera.isOpen, isFalse);
    });

    test('回到前景時有人在看、鏡頭還有畫面：什麼都不做', () async {
      await h.join('mac-1');
      await h.controller.ensureCameraAlive();

      expect(h.camera.openCount, 1);
    });

    test('回到前景時有人在看、鏡頭拿不到畫面：關掉重開', () async {
      await h.join('mac-1');
      h.camera.frame = null;
      await h.controller.ensureCameraAlive();

      expect(h.camera.openCount, 2);
      expect(h.camera.isOpen, isTrue);
      expect(h.controller.viewerCount, 1, reason: '鄉民端沒有被結束');
    });
  });

  group('卡住時救回來', () {
    setUp(() => h.controller.register('教室白板'));

    test('「你還在嗎」馬上回覆同一個編號', () async {
      await h.join('mac-1', session: 's1');
      h.server.receive('mac-1', const PingMessage(42));

      expect(h.server.sent['mac-1']!.last, isA<PongMessage>());
      expect((h.server.sent['mac-1']!.last as PongMessage).n, 42);
    });

    test('換一條新的連線接回來：還是同一位鄉民端，鏡頭和視訊連線都不動', () async {
      await h.joinRecording('mac-1', name: '阿明', session: 's1');
      h.server.receive('new-socket', const ResumeMessage(session: 's1'));
      await pumpEventQueue();

      expect(h.server.adopted.single, (viewerId: 'mac-1', from: 'new-socket'));
      expect(h.controller.viewerCount, 1);
      expect(h.links.single.closed, isFalse);
      expect(h.camera.isOpen, isTrue);
      expect(h.server.dismissed, isEmpty);
    });

    test('接回來時，還沒確認的照片照順序再給一次', () async {
      await h.joinRecording('mac-1', name: '阿明', session: 's1');
      await h.controller.takeShot();
      await h.controller.takeShot();
      h.server.receive('mac-1', const ShotReceivedMessage(id: 1));
      await pumpEventQueue();
      h.server.sent['mac-1']!.clear();
      h.server.sentBytes['mac-1']!.clear();

      h.server.receive('new-socket', const ResumeMessage(session: 's1'));
      await pumpEventQueue();

      final shots = h.server.sent['mac-1']!.whereType<ShotMessage>();
      expect(shots.map((shot) => shot.id), [2]);
      expect(h.server.sentBytes['mac-1'], hasLength(1));
    });

    test('補送的照片被確認後，照樣顯示誰抄錄了', () async {
      await h.joinRecording('mac-1', name: '阿明', session: 's1');
      final notices = <String>[];
      h.controller.notices.listen(notices.add);
      await h.controller.takeShot();
      h.server.receive('new-socket', const ResumeMessage(session: 's1'));
      await pumpEventQueue();
      h.server.receive('mac-1', const ShotReceivedMessage(id: 1));
      await pumpEventQueue();

      expect(notices, ['阿明抄錄了這個內容']);
    });

    test('不認得的代號：請它從頭來，不影響其他人', () async {
      await h.join('mac-1', session: 's1');
      h.server.receive('new-socket', const ResumeMessage(session: '別人的'));
      await pumpEventQueue();

      expect(h.server.dismissed, {'new-socket': ByeReason.boardStopped});
      expect(h.server.adopted, isEmpty);
      expect(h.controller.viewerCount, 1);
    });

    test('版本不同的接回被拒絕', () async {
      await h.join('mac-1', session: 's1');
      h.server.receive(
        'new-socket',
        const ResumeMessage(session: 's1', protocol: 999),
      );
      await pumpEventQueue();

      expect(h.server.dismissed, {'new-socket': ByeReason.versionMismatch});
    });

    test('已經離開的鄉民端不能再接回', () async {
      await h.join('mac-1', session: 's1');
      h.server.receive('mac-1', const ByeMessage(ByeReason.viewerLeft));
      await pumpEventQueue();
      h.server.receive('new-socket', const ResumeMessage(session: 's1'));
      await pumpEventQueue();

      expect(h.server.dismissed, {'new-socket': ByeReason.boardStopped});
    });

    test('重建視訊：換一條新的視訊連線，鏡頭和抄錄都不動', () async {
      await h.joinRecording('mac-1', name: '阿明', session: 's1');
      h.server.sent['mac-1']!.clear();

      h.server.receive('mac-1', const VideoRestartMessage());
      await pumpEventQueue();

      expect(h.links, hasLength(2));
      expect(h.links.first.closed, isTrue);
      expect(h.links.last.closed, isFalse);
      expect(h.server.sent['mac-1']!.whereType<OfferMessage>(), hasLength(1));
      expect(h.controller.viewerCount, 1);
      expect(h.camera.openCount, 1);
      // 抄錄還在：拍照仍然會傳給它。
      await h.controller.takeShot();
      expect(h.server.sent['mac-1']!.whereType<ShotMessage>(), hasLength(1));
    });

    test('重建之後，舊的那條視訊連線回報斷線不算數', () async {
      await h.join('mac-1', session: 's1');
      h.server.receive('mac-1', const VideoRestartMessage());
      await pumpEventQueue();
      h.links.first.lose();
      h.links.first.emitCandidate(const CandidateMessage(candidate: '舊的'));
      await pumpEventQueue();

      expect(h.controller.viewerCount, 1);
      expect(h.server.dismissed, isEmpty);
      expect(
        h.server.sent['mac-1']!.whereType<CandidateMessage>(),
        isEmpty,
        reason: '舊連線的網路路徑不能送給鄉民端',
      );
    });

    test('重建後的回覆交給新的那條視訊連線', () async {
      await h.join('mac-1', session: 's1');
      h.server.receive('mac-1', const VideoRestartMessage());
      await pumpEventQueue();
      h.server.receive('mac-1', const AnswerMessage(sdp: '新的回覆'));
      await pumpEventQueue();

      expect(h.links.last.answer, '新的回覆');
      expect(h.links.first.answer, isNull);
    });

    test('會自己救的鄉民端，視訊連線斷了不結束它，等它要求重建', () async {
      await h.join('mac-1', session: 's1');
      h.links.single.lose();
      await pumpEventQueue();

      expect(h.controller.viewerCount, 1);
      expect(h.server.dismissed, isEmpty);
    });

    test('沒加入過的連線要求重建視訊：不理它', () async {
      h.server.receive('stranger', const VideoRestartMessage());
      await pumpEventQueue();

      expect(h.links, isEmpty);
    });
  });

  group('卡住時救回來：跟時間有關的', () {
    test('連線斷掉後 10 秒內接回來：照常繼續', () {
      fakeAsync((async) {
        h.controller.register('教室白板');
        async.flushMicrotasks();
        h.server.receive('mac-1', const JoinMessage(session: 's1'));
        async.flushMicrotasks();
        h.server.receive('mac-1', const AnswerMessage(sdp: 'v=0'));
        async.flushMicrotasks();
        h.server.drop('mac-1');
        async.elapse(const Duration(seconds: 9));
        expect(h.controller.viewerCount, 1, reason: '還在等它接回來');

        h.server.receive('new-socket', const ResumeMessage(session: 's1'));
        async.elapse(const Duration(seconds: 30));

        expect(h.controller.viewerCount, 1);
        expect(h.links.single.closed, isFalse);
      });
    });

    test('連線斷掉後 10 秒都沒接回來：當成離開', () {
      fakeAsync((async) {
        h.controller.register('教室白板');
        async.flushMicrotasks();
        h.server.receive('mac-1', const JoinMessage(session: 's1'));
        async.flushMicrotasks();
        h.server.drop('mac-1');
        async.elapse(const Duration(seconds: 11));

        expect(h.controller.viewerCount, 0);
        expect(h.links.single.closed, isTrue);
        expect(h.controller.state, BoardState.waiting);
      });
    });

    test('不會自己救的（沒帶代號）連線一斷就當成離開', () {
      fakeAsync((async) {
        h.controller.register('教室白板');
        async.flushMicrotasks();
        h.server.receive('mac-1', const JoinMessage());
        async.flushMicrotasks();
        h.server.drop('mac-1');
        async.flushMicrotasks();

        expect(h.controller.viewerCount, 0);
      });
    });

    test('照片 10 秒都沒被確認：放棄，告訴使用者誰沒收到', () {
      fakeAsync((async) {
        final notices = <String>[];
        h.controller.notices.listen(notices.add);
        h.controller.register('教室白板');
        async.flushMicrotasks();
        h.server.receive('mac-1', const JoinMessage(name: '阿明', session: 's1'));
        async.flushMicrotasks();
        h.server.receive('mac-1', const AnswerMessage(sdp: 'v=0'));
        h.server.receive('mac-1', const RecordStartMessage());
        async.flushMicrotasks();
        h.controller.takeShot();
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 9));
        expect(notices, isEmpty);
        async.elapse(const Duration(seconds: 2));

        expect(notices, ['阿明沒收到這張，請再拍一次']);
        // 放棄之後才回報的不算數。
        h.server.receive('mac-1', const ShotReceivedMessage(id: 1));
        async.flushMicrotasks();
        expect(notices, hasLength(1));
      });
    });

    test('有確認的照片不會被放棄', () {
      fakeAsync((async) {
        final notices = <String>[];
        h.controller.notices.listen(notices.add);
        h.controller.register('教室白板');
        async.flushMicrotasks();
        h.server.receive('mac-1', const JoinMessage(name: '阿明', session: 's1'));
        async.flushMicrotasks();
        h.server.receive('mac-1', const AnswerMessage(sdp: 'v=0'));
        h.server.receive('mac-1', const RecordStartMessage());
        async.flushMicrotasks();
        h.controller.takeShot();
        async.flushMicrotasks();
        h.server.receive('mac-1', const ShotReceivedMessage(id: 1));
        async.elapse(const Duration(seconds: 30));

        expect(notices, ['阿明抄錄了這個內容']);
      });
    });

    test('同一張最多補送 3 次', () {
      fakeAsync((async) {
        h.controller.register('教室白板');
        async.flushMicrotasks();
        h.server.receive('mac-1', const JoinMessage(name: '阿明', session: 's1'));
        async.flushMicrotasks();
        h.server.receive('mac-1', const AnswerMessage(sdp: 'v=0'));
        h.server.receive('mac-1', const RecordStartMessage());
        async.flushMicrotasks();
        h.controller.takeShot();
        async.flushMicrotasks();
        for (var i = 0; i < 5; i++) {
          h.server.receive('socket-$i', const ResumeMessage(session: 's1'));
          async.flushMicrotasks();
        }

        // 第一次送出 1 次，加上補送 3 次。
        expect(
          h.server.sent['mac-1']!.whereType<ShotMessage>(),
          hasLength(1 + maxShotResends),
        );
      });
    });

    test('暫存滿了：丟掉最舊的，新的照樣拍，並告訴使用者哪一張沒送到', () {
      fakeAsync((async) {
        final notices = <String>[];
        h.controller.notices.listen(notices.add);
        h.camera.frame = RawFrame(
          width: 1920,
          height: 1080,
          rotation: 90,
          i420: Uint8List(RawFrame.byteLength(1920, 1080)),
        );
        h.controller.register('教室白板');
        async.flushMicrotasks();
        h.server.receive('mac-1', const JoinMessage(name: '阿明', session: 's1'));
        async.flushMicrotasks();
        h.server.receive('mac-1', const AnswerMessage(sdp: 'v=0'));
        h.server.receive('mac-1', const RecordStartMessage());
        async.flushMicrotasks();
        // 鄉民端一直不回報：照片越積越多。
        final fits = maxPendingShotBytes ~/ RawFrame.byteLength(1920, 1080);
        for (var i = 0; i < fits + 2; i++) {
          h.controller.takeShot();
          async.flushMicrotasks();
        }

        // 每一次都拍得成，不會被擋住。
        expect(h.camera.captureCount, fits + 2);
        expect(
          h.server.sent['mac-1']!.whereType<ShotMessage>(),
          hasLength(fits + 2),
        );
        // 最舊的兩張被丟掉，各提示一次。
        expect(notices, ['阿明沒收到這張，請再拍一次', '阿明沒收到這張，請再拍一次']);

        // 被丟掉的不再補送：接回來時只補還留著的那幾張。
        h.server.sent['mac-1']!.clear();
        h.server.receive('new-socket', const ResumeMessage(session: 's1'));
        async.flushMicrotasks();
        expect(
          h.server.sent['mac-1']!.whereType<ShotMessage>().map((s) => s.id),
          [for (var id = 3; id <= fits + 2; id++) id],
        );

        // 留著的那些時間到了照樣放棄，之後不會再為被丟掉的兩張多跳提示。
        async.elapse(const Duration(seconds: 11));
        expect(notices, hasLength(2 + fits));
      });
    });
  });
}
