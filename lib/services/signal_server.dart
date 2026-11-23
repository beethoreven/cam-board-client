import 'dart:io';

import 'package:cam_board_core/cam_board_core.dart';

/// 看板端讓鄉民端連進來的入口。
abstract interface class SignalServer {
  /// 開始接受連線，回傳實際使用的埠。
  Future<int> start({required String boardName});

  /// 停止接受連線，並告訴已經連上的鄉民端看板撤銷註冊了。
  /// 沒有啟動時呼叫也不會出錯。
  Future<void> stop();
}

/// 用 WebSocket 實作。
///
/// 目前只做到「連上就報上名字」，讓鄉民端確認這裡真的是看板。
/// 交換視訊連線資訊的部分還沒做。
class WebSocketSignalServer implements SignalServer {
  WebSocketSignalServer({this.preferredPort = defaultBoardPort});

  /// 優先使用的埠。被佔用時改由系統挑一個空的。
  final int preferredPort;

  HttpServer? _server;
  final Set<WebSocket> _sockets = {};

  @override
  Future<int> start({required String boardName}) async {
    await stop();
    final server = await _bind();
    _server = server;
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      socket.add(HelloMessage(name: boardName).encode());
      socket.listen(
        (_) {},
        onDone: () => _sockets.remove(socket),
        onError: (_) => _sockets.remove(socket),
        cancelOnError: true,
      );
    });
    return server.port;
  }

  Future<HttpServer> _bind() async {
    try {
      return await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      // 埠被佔用。埠 0 代表請系統挑一個空的，實際的埠會跟著廣播出去。
      return HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
  }

  @override
  Future<void> stop() async {
    final server = _server;
    _server = null;
    final sockets = _sockets.toList();
    _sockets.clear();
    for (final socket in sockets) {
      socket.add(const ByeMessage(ByeReason.boardUnregistered).encode());
      await socket.close();
    }
    await server?.close(force: true);
  }
}
