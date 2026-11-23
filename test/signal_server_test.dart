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

  Future<WebSocket> connect(int port) =>
      WebSocket.connect('ws://127.0.0.1:$port');

  test('連上之後第一則訊息是看板的名字', () async {
    final port = await server.start(boardName: '教室白板');
    final socket = await connect(port);

    final hello = SignalMessage.decode(await socket.first as String);
    expect(hello, isA<HelloMessage>());
    expect((hello as HelloMessage).name, '教室白板');
    expect(hello.isCompatible, isTrue);
  });

  test('停止時通知已經連上的鄉民端', () async {
    final port = await server.start(boardName: '教室白板');
    final socket = await connect(port);
    final messages = <SignalMessage>[];
    final done = socket
        .map((raw) => SignalMessage.decode(raw as String))
        .forEach(messages.add);

    // 等 hello 送到，確定伺服器已經登記這條連線。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await server.stop();
    await done;

    expect(messages.last, isA<ByeMessage>());
    expect((messages.last as ByeMessage).reason, ByeReason.boardUnregistered);
  });

  test('停止之後連不上', () async {
    final port = await server.start(boardName: '教室白板');
    await server.stop();
    expect(connect(port), throwsA(isA<SocketException>()));
  });

  test('想用的埠被佔用時改用別的埠', () async {
    final occupied = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(occupied.close);
    server = WebSocketSignalServer(preferredPort: occupied.port);

    final port = await server.start(boardName: '教室白板');
    expect(port, isNot(occupied.port));
    final socket = await connect(port);
    expect(
      SignalMessage.decode(await socket.first as String),
      isA<HelloMessage>(),
    );
  });

  test('可以停止後再啟動', () async {
    await server.start(boardName: '第一次');
    await server.stop();
    final port = await server.start(boardName: '第二次');
    final socket = await connect(port);
    final hello = SignalMessage.decode(await socket.first as String);
    expect((hello as HelloMessage).name, '第二次');
  });
}
