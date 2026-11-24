import 'package:cam_board_core/cam_board_core.dart';
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
      expect(h.camera.isOpen, isFalse);
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

    test('鏡頭開不了：只結束這個鄉民端，看板仍在等候', () async {
      h.camera.failOnOpen = true;
      await h.join('mac-1');

      expect(h.server.dismissed['mac-1'], ByeReason.boardStopped);
      expect(h.controller.state, BoardState.waiting);
    });

    test('視訊連線建不起來：只結束這個鄉民端，鏡頭關掉', () async {
      h.failOnCreateLink = true;
      await h.join('mac-1');

      expect(h.server.dismissed['mac-1'], ByeReason.boardStopped);
      expect(h.controller.state, BoardState.waiting);
      expect(h.camera.isOpen, isFalse);
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

    test('點擊對焦會把位置交給鏡頭，超出畫面的位置拉回邊緣', () async {
      await h.controller.focusAt(0.25, 0.75);
      await h.controller.focusAt(1.4, -0.2);

      expect(h.camera.focusPoints, [(0.25, 0.75), (1.0, 0.0)]);
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

    test('所有人離開後倍率回到 1 倍', () async {
      h.controller.pinchStarted();
      await h.controller.pinchUpdated(3);
      await h.controller.stopShowing();

      expect(h.controller.zoom, minZoom);
    });
  });
}
