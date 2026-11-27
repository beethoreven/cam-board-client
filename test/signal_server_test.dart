import 'dart:io';

import 'package:cam_board_client/services/signal_server.dart';
import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 這裡用真的 WebSocket 連線，確認伺服器實際上能連、訊息格式正確。
void main() {
  // 用埠 0 讓系統挑空的埠，避免跟這台機器上其他程式衝突。
  late WebSocketSignalServer server;

  setUp(() => server = WebSocketSignalServer(preferredPort: 0));
  tearDown(() => server.stop());

  /// 一個扮演鄉民端的連線，把收到的訊息依序記下來。
  Future<({WebSocket socket, List<SignalMessage> received, Future<void> done})>
  connect(int port) async {
    final socket = await WebSocket.connect('ws://127.0.0.1:$port');
    final received = <SignalMessage>[];
    final done = socket
        .map((raw) => SignalMessage.decode(raw as String))
        .forEach(received.add);
    return (socket: socket, received: received, done: done);
  }

  /// 等訊息在本機的連線上送到。
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 100));

  test('連上之後第一則訊息是看板的名字', () async {
    final port = await server.start(boardName: '教室白板');
    final viewer = await connect(port);
    await settle();

    final hello = viewer.received.single as HelloMessage;
    expect(hello.name, '教室白板');
    expect(hello.isCompatible, isTrue);
  });

  test('鄉民端送來的訊息會帶著它的編號轉出來，不同鄉民端編號不同', () async {
    final port = await server.start(boardName: '教室白板');
    final incoming = <ViewerMessage>[];
    server.messages.listen(incoming.add);

    final first = await connect(port);
    final second = await connect(port);
    first.socket.add(const JoinMessage().encode());
    await settle();
    second.socket.add(const AnswerMessage(sdp: 'v=0').encode());
    await settle();

    expect(incoming, hasLength(2));
    expect(incoming[0].message, isA<JoinMessage>());
    expect(incoming[1].message, isA<AnswerMessage>());
    expect(incoming[0].viewerId, isNot(incoming[1].viewerId));
  });

  test('看不懂的訊息被丟掉，連線不受影響', () async {
    final port = await server.start(boardName: '教室白板');
    final incoming = <ViewerMessage>[];
    server.messages.listen(incoming.add);

    final viewer = await connect(port);
    viewer.socket.add('這不是合法的訊息');
    viewer.socket.add(const JoinMessage().encode());
    await settle();

    expect(incoming.single.message, isA<JoinMessage>());
  });

  test('可以送訊息給指定的鄉民端，其他人收不到', () async {
    final port = await server.start(boardName: '教室白板');
    final incoming = <ViewerMessage>[];
    server.messages.listen(incoming.add);
    final first = await connect(port);
    final second = await connect(port);
    first.socket.add(const JoinMessage().encode());
    await settle();

    server.send(incoming.single.viewerId, const OfferMessage(sdp: 'v=0'));
    await settle();

    expect(first.received.last, isA<OfferMessage>());
    expect(second.received.whereType<OfferMessage>(), isEmpty);
  });

  test('鄉民端自己斷線時會通報', () async {
    final port = await server.start(boardName: '教室白板');
    final dropped = <String>[];
    server.disconnections.listen(dropped.add);

    final viewer = await connect(port);
    await settle();
    await viewer.socket.close();
    await settle();

    expect(dropped, hasLength(1));
  });

  test('看板端主動結束某個鄉民端：對方收到原因，而且不會再通報斷線', () async {
    final port = await server.start(boardName: '教室白板');
    final incoming = <ViewerMessage>[];
    final dropped = <String>[];
    server.messages.listen(incoming.add);
    server.disconnections.listen(dropped.add);
    final viewer = await connect(port);
    viewer.socket.add(const JoinMessage().encode());
    await settle();

    await server.dismiss(incoming.single.viewerId, ByeReason.boardStopped);
    await viewer.done;
    await settle();

    expect((viewer.received.last as ByeMessage).reason, ByeReason.boardStopped);
    expect(dropped, isEmpty);
  });

  test('停止時通知所有連著的鄉民端看板撤銷註冊了', () async {
    final port = await server.start(boardName: '教室白板');
    final first = await connect(port);
    final second = await connect(port);
    await settle();

    await server.stop();
    await Future.wait([first.done, second.done]);

    for (final viewer in [first, second]) {
      expect(
        (viewer.received.last as ByeMessage).reason,
        ByeReason.boardUnregistered,
      );
    }
  });

  test('停止之後連不上', () async {
    final port = await server.start(boardName: '教室白板');
    await server.stop();
    expect(
      WebSocket.connect('ws://127.0.0.1:$port'),
      throwsA(isA<SocketException>()),
    );
  });

  test('想用的埠被佔用時改用別的埠', () async {
    final occupied = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(occupied.close);
    server = WebSocketSignalServer(preferredPort: occupied.port);

    final port = await server.start(boardName: '教室白板');
    expect(port, isNot(occupied.port));
    final viewer = await connect(port);
    await settle();
    expect(viewer.received.single, isA<HelloMessage>());
  });

  test('可以停止後再啟動', () async {
    await server.start(boardName: '第一次');
    await server.stop();
    final port = await server.start(boardName: '第二次');
    final viewer = await connect(port);
    await settle();
    expect((viewer.received.single as HelloMessage).name, '第二次');
  });

  group('不該進來的連線', () {
    test('從網頁發出的連線（帶 Origin）被拒絕', () async {
      final port = await server.start(boardName: '教室白板');

      await expectLater(
        WebSocket.connect(
          'ws://127.0.0.1:$port',
          headers: {'Origin': 'https://example.com'},
        ),
        throwsA(isA<WebSocketException>()),
      );
    });

    test('超過連線數上限的被拒絕，有人離開之後又連得進來', () async {
      server = WebSocketSignalServer(preferredPort: 0, maxViewers: 2);
      final port = await server.start(boardName: '教室白板');
      final first = await connect(port);
      await connect(port);
      await settle();

      await expectLater(
        WebSocket.connect('ws://127.0.0.1:$port'),
        throwsA(isA<WebSocketException>()),
      );

      await first.socket.close();
      await settle();
      final third = await connect(port);
      await settle();
      expect(third.received.single, isA<HelloMessage>());
    });

    test('連上之後一直不說話的會被關掉，並通報它走了', () async {
      server = WebSocketSignalServer(
        preferredPort: 0,
        silenceTimeout: const Duration(milliseconds: 150),
      );
      final port = await server.start(boardName: '教室白板');
      final gone = <String>[];
      server.disconnections.listen(gone.add);
      final viewer = await connect(port);

      await viewer.done.timeout(const Duration(seconds: 2));
      expect(gone, hasLength(1));
    });

    test('說過話的不會因為安靜而被關掉', () async {
      server = WebSocketSignalServer(
        preferredPort: 0,
        silenceTimeout: const Duration(milliseconds: 150),
      );
      final port = await server.start(boardName: '教室白板');
      final gone = <String>[];
      server.disconnections.listen(gone.add);
      final viewer = await connect(port);
      viewer.socket.add(const JoinMessage().encode());

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(gone, isEmpty);
    });

    test('送來超大訊息或二進位資料的會被關掉', () async {
      final port = await server.start(boardName: '教室白板');
      final gone = <String>[];
      server.disconnections.listen(gone.add);

      final big = await connect(port);
      big.socket.add('x' * (WebSocketSignalServer.maxMessageLength + 1));
      await big.done.timeout(const Duration(seconds: 2));

      final binary = await connect(port);
      binary.socket.add([1, 2, 3]);
      await binary.done.timeout(const Duration(seconds: 2));

      expect(gone, hasLength(2));
    });
  });

  group('換一條新的連線接回來', () {
    test('之後的訊息走新連線，舊連線關掉也不通報離開', () async {
      final port = await server.start(boardName: '教室白板');
      final incoming = <ViewerMessage>[];
      final gone = <String>[];
      server.messages.listen(incoming.add);
      server.disconnections.listen(gone.add);

      final old = await connect(port);
      old.socket.add(const JoinMessage(session: 's1').encode());
      await settle();
      final viewerId = incoming.single.viewerId;

      final fresh = await connect(port);
      fresh.socket.add(const ResumeMessage(session: 's1').encode());
      await settle();
      server.adopt(viewerId: viewerId, from: incoming.last.viewerId);
      await settle();

      // 看板端送給這位鄉民端的訊息，到的是新連線。
      server.send(viewerId, const OfferMessage(sdp: 'v=0'));
      // 新連線送來的訊息，掛的是原本那位鄉民端的編號。
      fresh.socket.add(const RecordStartMessage().encode());
      await settle();

      expect(incoming.last.viewerId, viewerId);
      expect(incoming.last.message, isA<RecordStartMessage>());
      expect(fresh.received.whereType<OfferMessage>(), hasLength(1));
      expect(old.received.whereType<OfferMessage>(), isEmpty);
      expect(gone, isEmpty, reason: '舊連線被取代不算離開');

      // 之後新連線真的斷了，才通報這位鄉民端離開。
      await fresh.socket.close();
      await settle();
      expect(gone, [viewerId]);
    });

    test('被取代之後，舊連線才送到的訊息不算數', () async {
      final port = await server.start(boardName: '教室白板');
      final incoming = <ViewerMessage>[];
      server.messages.listen(incoming.add);

      final old = await connect(port);
      old.socket.add(const JoinMessage(session: 's1').encode());
      await settle();
      final viewerId = incoming.single.viewerId;
      final fresh = await connect(port);
      fresh.socket.add(const ResumeMessage(session: 's1').encode());
      await settle();
      server.adopt(viewerId: viewerId, from: incoming.last.viewerId);
      incoming.clear();

      old.socket.add(const RecordStopMessage().encode());
      await settle();

      expect(incoming, isEmpty);
    });
  });
}
