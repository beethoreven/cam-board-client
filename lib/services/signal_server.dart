import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cam_board_core/cam_board_core.dart';

/// 某個鄉民端送來的一則訊息。
typedef ViewerMessage = ({String viewerId, SignalMessage message});

/// 看板端讓鄉民端連進來、互傳訊息的入口。
abstract interface class SignalServer {
  /// 鄉民端送來的訊息。
  Stream<ViewerMessage> get messages;

  /// 某個鄉民端的連線斷了（它自己關掉，或網路斷了）。
  Stream<String> get disconnections;

  /// 開始接受連線，回傳實際使用的埠。
  Future<int> start({required String boardName});

  /// 送一則訊息給某個鄉民端。它已經斷線時不做任何事。
  void send(String viewerId, SignalMessage message);

  /// 送一筆二進位資料給鄉民端（照片）。要緊接在說明它的那則訊息之後送。
  void sendBytes(String viewerId, Uint8List bytes);

  /// 告訴某個鄉民端結束了，並關掉它的連線。
  Future<void> dismiss(String viewerId, ByeReason reason);

  /// 停止接受連線，並告訴所有連著的鄉民端看板撤銷註冊了。
  /// 沒有啟動時呼叫也不會出錯。
  Future<void> stop();
}

/// 用 WebSocket 實作。
class WebSocketSignalServer implements SignalServer {
  WebSocketSignalServer({this.preferredPort = defaultBoardPort});

  /// 優先使用的埠。被佔用時改由系統挑一個空的。
  final int preferredPort;

  HttpServer? _server;
  final Map<String, WebSocket> _sockets = {};
  final _messages = StreamController<ViewerMessage>.broadcast();
  final _disconnections = StreamController<String>.broadcast();
  int _nextId = 1;

  @override
  Stream<ViewerMessage> get messages => _messages.stream;

  @override
  Stream<String> get disconnections => _disconnections.stream;

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
      final viewerId = 'viewer-${_nextId++}';
      _sockets[viewerId] = socket;
      socket.add(HelloMessage(name: boardName).encode());
      socket.listen(
        (raw) => _receive(viewerId, raw),
        onDone: () => _dropped(viewerId),
        onError: (_) => _dropped(viewerId),
        cancelOnError: true,
      );
    });
    return server.port;
  }

  void _receive(String viewerId, Object? raw) {
    if (raw is! String) return;
    final SignalMessage message;
    try {
      message = SignalMessage.decode(raw);
    } on FormatException {
      // 看不懂的訊息丟掉就好，不能讓一則壞訊息弄斷整條連線。
      return;
    }
    _messages.add((viewerId: viewerId, message: message));
  }

  /// 連線從對方那邊斷掉。我們主動關掉的連線已經先從 [_sockets] 移除，不會再通報。
  void _dropped(String viewerId) {
    if (_sockets.remove(viewerId) != null) _disconnections.add(viewerId);
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
  void send(String viewerId, SignalMessage message) =>
      _sockets[viewerId]?.add(message.encode());

  @override
  void sendBytes(String viewerId, Uint8List bytes) =>
      _sockets[viewerId]?.add(bytes);

  @override
  Future<void> dismiss(String viewerId, ByeReason reason) async {
    final socket = _sockets.remove(viewerId);
    if (socket == null) return;
    socket.add(ByeMessage(reason).encode());
    await socket.close();
  }

  @override
  Future<void> stop() async {
    final server = _server;
    _server = null;
    for (final viewerId in _sockets.keys.toList()) {
      await dismiss(viewerId, ByeReason.boardUnregistered);
    }
    await server?.close(force: true);
  }
}
