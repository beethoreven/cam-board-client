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
///
/// 伺服器開在區域網路上，誰都連得到，所以進門前先擋幾種不該出現的連線：
/// 從網頁發出的（瀏覽器會帶 `Origin`，鄉民端不會）、不是從區域網路來的、
/// 以及超過 [maxViewers] 的。連上之後一直不說話的、送來超大訊息的也會被關掉。
class WebSocketSignalServer implements SignalServer {
  WebSocketSignalServer({
    this.preferredPort = defaultBoardPort,
    this.maxViewers = 16,
    this.silenceTimeout = const Duration(seconds: 10),
  });

  /// 一則文字訊息最多多長。最大的是連線資訊，通常幾千個字。
  static const maxMessageLength = 64 * 1024;

  /// 多久確認一次對方還在。對方沒回應時連線會被關掉，看板端才知道它走了。
  static const _pingInterval = Duration(seconds: 10);

  /// 優先使用的埠。被佔用時改由系統挑一個空的。
  final int preferredPort;

  /// 同時最多幾條連線（包含只是來確認看板名稱的）。
  final int maxViewers;

  /// 連上之後這麼久都沒送過一則看得懂的訊息，就關掉。
  final Duration silenceTimeout;

  HttpServer? _server;
  final Map<String, WebSocket> _sockets = {};
  final Map<String, Timer> _silenceTimers = {};
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
    server.listen((request) => _accept(server, request, boardName));
    return server.port;
  }

  Future<void> _accept(
    HttpServer server,
    HttpRequest request,
    String boardName,
  ) async {
    try {
      final refusal = _refusal(request);
      if (refusal != null) {
        request.response.statusCode = refusal;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      // 交握的這段時間看板可能已經撤銷註冊了。
      if (!identical(_server, server)) {
        await socket.close();
        return;
      }
      socket.pingInterval = _pingInterval;
      final viewerId = 'viewer-${_nextId++}';
      _sockets[viewerId] = socket;
      _silenceTimers[viewerId] = Timer(silenceTimeout, () => _close(viewerId));
      socket.add(HelloMessage(name: boardName).encode());
      socket.listen(
        (raw) => _receive(viewerId, raw),
        onDone: () => _dropped(viewerId),
        onError: (_) => _dropped(viewerId),
        cancelOnError: true,
      );
    } catch (_) {
      // 交握到一半對方就斷了之類的：這一條不算，不影響其他連線。
    }
  }

  /// 這個連線要求該不該拒絕。要拒絕時回傳 HTTP 狀態碼，可以收時回傳 null。
  int? _refusal(HttpRequest request) {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      return HttpStatus.badRequest;
    }
    // 瀏覽器裡的網頁發出的連線一定帶 Origin，鄉民端不會帶。
    // 不擋的話，使用者開著的任何網頁都能連到區域網路上的看板。
    if (request.headers.value('origin') != null) return HttpStatus.forbidden;
    final remote = request.connectionInfo?.remoteAddress.address;
    if (remote == null || !isLanPeer(remote)) return HttpStatus.forbidden;
    if (_sockets.length >= maxViewers) return HttpStatus.serviceUnavailable;
    return null;
  }

  void _receive(String viewerId, Object? raw) {
    // 鄉民端只會送文字訊息，而且都很短。其他的不是正常的鄉民端。
    if (raw is! String || raw.length > maxMessageLength) {
      _close(viewerId);
      return;
    }
    final SignalMessage message;
    try {
      message = SignalMessage.decode(raw);
    } on FormatException {
      // 看不懂的訊息丟掉就好，不能讓一則壞訊息弄斷整條連線。
      return;
    }
    _silenceTimers.remove(viewerId)?.cancel();
    _messages.add((viewerId: viewerId, message: message));
  }

  /// 由我們這邊關掉一條不正常的連線，並通報它走了。
  void _close(String viewerId) {
    final socket = _sockets[viewerId];
    _dropped(viewerId);
    socket?.close(WebSocketStatus.policyViolation);
  }

  /// 連線從對方那邊斷掉。我們主動關掉的連線已經先從 [_sockets] 移除，不會再通報。
  void _dropped(String viewerId) {
    _silenceTimers.remove(viewerId)?.cancel();
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
    _silenceTimers.remove(viewerId)?.cancel();
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
